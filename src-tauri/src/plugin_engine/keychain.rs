#[cfg(target_os = "macos")]
use std::process::Command;

pub fn read_generic_password(service: &str) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        return read_macos_generic_password(service);
    }

    #[cfg(target_os = "windows")]
    {
        return read_windows_generic_password(service);
    }

    #[allow(unreachable_code)]
    Err("keychain API is only supported on macOS and Windows".to_string())
}

pub fn write_generic_password(service: &str, value: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return write_macos_generic_password(service, value);
    }

    #[cfg(target_os = "windows")]
    {
        return write_windows_generic_password(service, value);
    }

    #[allow(unreachable_code)]
    Err("keychain API is only supported on macOS and Windows".to_string())
}

pub fn delete_generic_password(service: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return delete_macos_generic_password(service);
    }

    #[cfg(target_os = "windows")]
    {
        return delete_windows_generic_password(service);
    }

    #[allow(unreachable_code)]
    Err("keychain API is only supported on macOS and Windows".to_string())
}

#[cfg(target_os = "macos")]
fn read_macos_generic_password(service: &str) -> Result<String, String> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", service, "-w"])
        .output()
        .map_err(|err| format!("keychain read failed: {}", err))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first_line = stderr.lines().next().unwrap_or("").trim();
        return Err(format!("keychain item not found: {}", first_line));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(target_os = "macos")]
fn write_macos_generic_password(service: &str, value: &str) -> Result<(), String> {
    let mut account_arg: Option<String> = None;
    let find_output = Command::new("security")
        .args(["find-generic-password", "-s", service])
        .output();

    if let Ok(output) = find_output {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                if let Some(start) = line.find("\"acct\"<blob>=\"") {
                    let rest = &line[start + 14..];
                    if let Some(end) = rest.find('"') {
                        account_arg = Some(rest[..end].to_string());
                        break;
                    }
                }
            }
        }
    }

    let output = if let Some(ref account) = account_arg {
        Command::new("security")
            .args([
                "add-generic-password",
                "-s",
                service,
                "-a",
                account,
                "-w",
                value,
                "-U",
            ])
            .output()
    } else {
        Command::new("security")
            .args(["add-generic-password", "-s", service, "-w", value, "-U"])
            .output()
    }
    .map_err(|err| format!("keychain write failed: {}", err))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first_line = stderr.lines().next().unwrap_or("").trim();
        return Err(format!("keychain write failed: {}", first_line));
    }

    Ok(())
}

#[cfg(target_os = "macos")]
fn delete_macos_generic_password(service: &str) -> Result<(), String> {
    let output = Command::new("security")
        .args(["delete-generic-password", "-s", service])
        .output()
        .map_err(|err| format!("keychain delete failed: {}", err))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first_line = stderr.lines().next().unwrap_or("").trim();
        return Err(format!("keychain item not found: {}", first_line));
    }

    Ok(())
}

#[cfg(target_os = "windows")]
mod windows_impl {
    use std::ffi::c_void;
    use std::io;
    use std::ptr;

    const CRED_TYPE_GENERIC: u32 = 1;
    const CRED_PERSIST_LOCAL_MACHINE: u32 = 2;
    const ERROR_NOT_FOUND: i32 = 1168;

    #[repr(C)]
    struct FileTime {
        dw_low_date_time: u32,
        dw_high_date_time: u32,
    }

    #[repr(C)]
    struct CredentialAttributeW {
        keyword: *mut u16,
        flags: u32,
        value_size: u32,
        value: *mut u8,
    }

    #[repr(C)]
    struct CredentialW {
        flags: u32,
        credential_type: u32,
        target_name: *mut u16,
        comment: *mut u16,
        last_written: FileTime,
        credential_blob_size: u32,
        credential_blob: *mut u8,
        persist: u32,
        attribute_count: u32,
        attributes: *mut CredentialAttributeW,
        target_alias: *mut u16,
        user_name: *mut u16,
    }

    #[link(name = "Advapi32")]
    unsafe extern "system" {
        fn CredReadW(
            target_name: *const u16,
            credential_type: u32,
            flags: u32,
            credential: *mut *mut CredentialW,
        ) -> i32;
        fn CredWriteW(credential: *const CredentialW, flags: u32) -> i32;
        fn CredDeleteW(target_name: *const u16, credential_type: u32, flags: u32) -> i32;
        fn CredEnumerateW(
            filter: *const u16,
            flags: u32,
            count: *mut u32,
            credentials: *mut *mut *mut CredentialW,
        ) -> i32;
        fn CredFree(buffer: *const c_void);
    }

    pub fn read(service: &str) -> Result<String, String> {
        match read_exact(service) {
            Ok(value) => Ok(value),
            Err(err) if is_not_found(&err) => read_best_prefix_match(service),
            Err(err) => Err(err),
        }
    }

    pub fn write(service: &str, value: &str) -> Result<(), String> {
        let mut target_name = wide(service);
        let mut credential_blob: Vec<u16> = value.encode_utf16().collect();
        let credential = CredentialW {
            flags: 0,
            credential_type: CRED_TYPE_GENERIC,
            target_name: target_name.as_mut_ptr(),
            comment: ptr::null_mut(),
            last_written: FileTime {
                dw_low_date_time: 0,
                dw_high_date_time: 0,
            },
            credential_blob_size: (credential_blob.len() * std::mem::size_of::<u16>()) as u32,
            credential_blob: credential_blob.as_mut_ptr().cast::<u8>(),
            persist: CRED_PERSIST_LOCAL_MACHINE,
            attribute_count: 0,
            attributes: ptr::null_mut(),
            target_alias: ptr::null_mut(),
            user_name: ptr::null_mut(),
        };

        let ok = unsafe { CredWriteW(&credential, 0) };
        if ok == 0 {
            return Err(last_error_message("keychain write failed"));
        }

        Ok(())
    }

    pub fn delete(service: &str) -> Result<(), String> {
        let target_name = wide(service);
        let ok = unsafe { CredDeleteW(target_name.as_ptr(), CRED_TYPE_GENERIC, 0) };
        if ok == 0 {
            if is_last_error_not_found() {
                return Err("keychain item not found".to_string());
            }
            return Err(last_error_message("keychain delete failed"));
        }

        Ok(())
    }

    fn read_exact(service: &str) -> Result<String, String> {
        let target_name = wide(service);
        let mut credential_ptr = ptr::null_mut();
        let ok = unsafe {
            CredReadW(
                target_name.as_ptr(),
                CRED_TYPE_GENERIC,
                0,
                &mut credential_ptr,
            )
        };
        if ok == 0 {
            if is_last_error_not_found() {
                return Err("keychain item not found".to_string());
            }
            return Err(last_error_message("keychain read failed"));
        }

        unsafe { read_owned_credential_value(credential_ptr) }
    }

    fn read_best_prefix_match(service: &str) -> Result<String, String> {
        let filter = wide(&format!("{}:*", service));
        let mut count = 0u32;
        let mut credentials_ptr = ptr::null_mut();
        let ok = unsafe { CredEnumerateW(filter.as_ptr(), 0, &mut count, &mut credentials_ptr) };
        if ok == 0 {
            if is_last_error_not_found() {
                return Err("keychain item not found".to_string());
            }
            return Err(last_error_message("keychain enumerate failed"));
        }

        let result = unsafe {
            let credentials = std::slice::from_raw_parts(credentials_ptr, count as usize);
            let inner = (|| -> Result<String, String> {
                let mut targets = Vec::new();
                for credential_ptr in credentials {
                    if credential_ptr.is_null() {
                        continue;
                    }
                    let target_name = wide_ptr_to_string((**credential_ptr).target_name);
                    if !target_name.is_empty() {
                        targets.push(target_name);
                    }
                }

                let selected = select_best_match(service, &targets)
                    .ok_or_else(|| "keychain item not found: no matching target".to_string())?;
                let selected_ptr = find_credential_ptr(credentials, &selected)?;
                let selected_credential = &*selected_ptr;
                read_borrowed_credential_value(selected_credential)
            })();
            CredFree(credentials_ptr.cast::<c_void>());
            inner
        };

        result
    }

    unsafe fn find_credential_ptr(
        credentials: &[*mut CredentialW],
        target_name: &str,
    ) -> Result<*mut CredentialW, String> {
        for credential_ptr in credentials {
            if credential_ptr.is_null() {
                continue;
            }
            let candidate = unsafe { wide_ptr_to_string((**credential_ptr).target_name) };
            if candidate == target_name {
                return Ok(*credential_ptr);
            }
        }
        Err("keychain item not found: matched target missing credential".to_string())
    }

    unsafe fn read_owned_credential_value(
        credential_ptr: *mut CredentialW,
    ) -> Result<String, String> {
        if credential_ptr.is_null() {
            return Err("keychain item not found: null credential".to_string());
        }

        let result = unsafe { read_borrowed_credential_value(&*credential_ptr) };
        unsafe { CredFree(credential_ptr.cast::<c_void>()) };
        result
    }

    unsafe fn read_borrowed_credential_value(credential: &CredentialW) -> Result<String, String> {
        decode_credential_blob(credential.credential_blob, credential.credential_blob_size)
            .ok_or_else(|| "keychain item not found: credential value empty".to_string())
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe fn wide_ptr_to_string(ptr: *mut u16) -> String {
        if ptr.is_null() {
            return String::new();
        }

        let mut len = 0usize;
        while unsafe { *ptr.add(len) } != 0 {
            len += 1;
        }

        String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
    }

    fn decode_credential_blob(blob: *mut u8, size: u32) -> Option<String> {
        if blob.is_null() || size == 0 {
            return None;
        }

        let size = size as usize;
        let bytes = unsafe { std::slice::from_raw_parts(blob.cast::<u8>(), size) };

        if looks_like_utf16(bytes) {
            let words = unsafe { std::slice::from_raw_parts(blob.cast::<u16>(), size / 2) };
            return Some(
                String::from_utf16_lossy(words)
                    .trim_end_matches('\0')
                    .to_string(),
            );
        }

        Some(
            String::from_utf8_lossy(bytes)
                .trim_end_matches('\0')
                .to_string(),
        )
    }

    fn looks_like_utf16(bytes: &[u8]) -> bool {
        if bytes.len() < 2 || bytes.len() % 2 != 0 {
            return false;
        }

        let odd_nuls = bytes
            .iter()
            .skip(1)
            .step_by(2)
            .filter(|byte| **byte == 0)
            .count();
        let even_nuls = bytes.iter().step_by(2).filter(|byte| **byte == 0).count();
        let pairs = bytes.len() / 2;

        odd_nuls * 2 >= pairs || even_nuls * 2 >= pairs
    }

    fn select_best_match(service: &str, targets: &[String]) -> Option<String> {
        let preferred_alias = format!("{}:", service);
        let mut sorted = targets.to_vec();
        sorted.sort_by(|left, right| {
            let left_rank = if left == &preferred_alias { 0 } else { 1 };
            let right_rank = if right == &preferred_alias { 0 } else { 1 };
            left_rank
                .cmp(&right_rank)
                .then(left.len().cmp(&right.len()))
                .then(left.cmp(right))
        });
        sorted.into_iter().next()
    }

    fn is_not_found(message: &str) -> bool {
        message == "keychain item not found" || message.contains("os error 1168")
    }

    fn is_last_error_not_found() -> bool {
        io::Error::last_os_error().raw_os_error() == Some(ERROR_NOT_FOUND)
    }

    fn last_error_message(prefix: &str) -> String {
        let err = io::Error::last_os_error();
        format!("{}: {}", prefix, err)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn select_best_match_prefers_trailing_colon_alias() {
            let matches = vec![
                "gh:github.com:Rana-Faraz".to_string(),
                "gh:github.com:".to_string(),
            ];

            assert_eq!(
                select_best_match("gh:github.com", &matches).as_deref(),
                Some("gh:github.com:")
            );
        }

        #[test]
        fn select_best_match_falls_back_to_shortest_target() {
            let matches = vec![
                "gh:github.com:zzzz".to_string(),
                "gh:github.com:aa".to_string(),
            ];

            assert_eq!(
                select_best_match("gh:github.com", &matches).as_deref(),
                Some("gh:github.com:aa")
            );
        }

        #[test]
        fn decode_credential_blob_reads_utf16_values() {
            let mut value: Vec<u16> = "gho_token".encode_utf16().collect();
            let decoded = decode_credential_blob(
                value.as_mut_ptr().cast::<u8>(),
                (value.len() * std::mem::size_of::<u16>()) as u32,
            );

            assert_eq!(decoded.as_deref(), Some("gho_token"));
        }

        #[test]
        fn decode_credential_blob_reads_utf8_values() {
            let mut value = b"plain-token".to_vec();
            let decoded = decode_credential_blob(value.as_mut_ptr(), value.len() as u32);

            assert_eq!(decoded.as_deref(), Some("plain-token"));
        }

        #[test]
        fn decode_credential_blob_prefers_utf8_for_even_length_ascii_tokens() {
            let mut value = b"gho_1234567890abcdef1234567890abcdef1234".to_vec();
            let decoded = decode_credential_blob(value.as_mut_ptr(), value.len() as u32);

            assert_eq!(
                decoded.as_deref(),
                Some("gho_1234567890abcdef1234567890abcdef1234")
            );
        }

        #[test]
        fn windows_keychain_round_trip() {
            let service = format!("UsageTray-test-{}", uuid::Uuid::new_v4());
            write(&service, "secret-token").expect("write");
            let read_back = read(&service).expect("read");
            assert_eq!(read_back, "secret-token");
            delete(&service).expect("delete");
            assert!(read(&service).is_err());
        }
    }
}

#[cfg(target_os = "windows")]
fn read_windows_generic_password(service: &str) -> Result<String, String> {
    windows_impl::read(service)
}

#[cfg(target_os = "windows")]
fn write_windows_generic_password(service: &str, value: &str) -> Result<(), String> {
    windows_impl::write(service, value)
}

#[cfg(target_os = "windows")]
fn delete_windows_generic_password(service: &str) -> Result<(), String> {
    windows_impl::delete(service)
}
