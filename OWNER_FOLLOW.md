# Owner follow-up

## Windows code signing
- Add GitHub secrets:
  - `WINDOWS_CERTIFICATE`: base64-encoded PFX
  - `WINDOWS_CERTIFICATE_PASSWORD`: PFX password
- Update `src-tauri/tauri.conf.json` with Windows signing config:
  - `bundle.windows.certificateThumbprint`
  - `bundle.windows.digestAlgorithm`: `sha256`
  - `bundle.windows.timestampUrl`: trusted timestamp URL
- After secrets + config are set, Windows updater artifacts will be signed during publish.
