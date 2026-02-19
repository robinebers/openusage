use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliCommandStatus {
    pub installed: bool,
    pub install_path: String,
    pub plugins_dir: String,
    pub path_export: String,
    pub plugins_export: String,
}

fn install_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "failed to resolve home directory".to_string())?;
    Ok(home.join(".local").join("bin").join("openusage-cli"))
}

fn plugins_dir() -> PathBuf {
    let base = dirs::data_local_dir().unwrap_or_else(std::env::temp_dir);
    base.join("com.sunstory.openusage").join("plugins")
}

fn status_from_paths(install_path: &PathBuf, plugins_dir: &PathBuf) -> CliCommandStatus {
    CliCommandStatus {
        installed: install_path.exists(),
        install_path: install_path.display().to_string(),
        plugins_dir: plugins_dir.display().to_string(),
        path_export: r#"export PATH="$HOME/.local/bin:$PATH""#.to_string(),
        plugins_export: format!(
            "export OPENUSAGE_PLUGINS_DIR=\"{}\"",
            plugins_dir.display()
        ),
    }
}

pub fn status() -> Result<CliCommandStatus, String> {
    let install_path = install_path()?;
    let plugins_dir = plugins_dir();
    Ok(status_from_paths(&install_path, &plugins_dir))
}

pub fn install() -> Result<CliCommandStatus, String> {
    let install_path = install_path()?;
    let plugins_dir = plugins_dir();
    let install_dir = install_path
        .parent()
        .ok_or_else(|| "failed to resolve cli install directory".to_string())?;

    std::fs::create_dir_all(install_dir).map_err(|error| {
        format!(
            "failed to create cli install directory {}: {}",
            install_dir.display(),
            error
        )
    })?;

    let source = std::env::current_exe()
        .map_err(|error| format!("failed to resolve current executable: {}", error))?;

    std::fs::copy(&source, &install_path).map_err(|error| {
        format!(
            "failed to copy {} to {}: {}",
            source.display(),
            install_path.display(),
            error
        )
    })?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o755);
        std::fs::set_permissions(&install_path, perms).map_err(|error| {
            format!(
                "failed to set execute permissions on {}: {}",
                install_path.display(),
                error
            )
        })?;
    }

    Ok(status_from_paths(&install_path, &plugins_dir))
}

pub fn uninstall() -> Result<CliCommandStatus, String> {
    let install_path = install_path()?;
    let plugins_dir = plugins_dir();
    if install_path.exists() {
        std::fs::remove_file(&install_path).map_err(|error| {
            format!(
                "failed to remove cli command at {}: {}",
                install_path.display(),
                error
            )
        })?;
    }
    Ok(status_from_paths(&install_path, &plugins_dir))
}

#[cfg(test)]
mod tests {
    use super::status_from_paths;
    use std::path::PathBuf;

    #[test]
    fn status_formats_shell_exports() {
        let install_path = PathBuf::from("/tmp/openusage-cli");
        let plugins_dir = PathBuf::from("/tmp/plugins");
        let status = status_from_paths(&install_path, &plugins_dir);
        assert_eq!(status.path_export, "export PATH=\"$HOME/.local/bin:$PATH\"");
        assert_eq!(
            status.plugins_export,
            "export OPENUSAGE_PLUGINS_DIR=\"/tmp/plugins\""
        );
    }
}
