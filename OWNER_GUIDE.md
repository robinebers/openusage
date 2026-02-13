# Owner Guide: Windows Release Setup

Generate Windows certificate from your Mac, add GitHub secrets, push a tag.

## 1. Generate Windows Certificate

Install OpenSSL if not present:

```bash
brew install openssl
```

Create certificate:

```bash
# Create private key
openssl genrsa -out windows.key 4096

# Create certificate
openssl req -new -x509 -key windows.key -out windows.crt -days 365 \
  -subj "/CN=Sunstory/O=Sunstory/C=US"

# Convert to PFX
openssl pkcs12 -export -out codesign.pfx -inkey windows.key -in windows.crt
# Enter password when prompted (save this!)
```

For production: Buy a certificate from DigiCert/Sectigo instead.

## 2. Encode for GitHub Secrets

```bash
# Base64 encode
cat codesign.pfx | base64 > cert_base64.txt

# Copy to clipboard (macOS)
cat cert_base64.txt | pbcopy

# Cleanup sensitive files
rm windows.key windows.crt codesign.pfx
```

## 3. Add GitHub Secrets

Go to: `https://github.com/robinebers/openusage/settings/secrets/actions`

Add:

| Secret | Value |
|--------|-------|
| `WINDOWS_CERTIFICATE` | Paste from clipboard (base64) |
| `WINDOWS_CERTIFICATE_PASSWORD` | Password from step 1 |

## 4. Update Versions

Set same version in all 3 files:

```bash
# Check current
grep '"version"' package.json src-tauri/tauri.conf.json
grep '^version' src-tauri/Cargo.toml

# Edit files (use your editor)
cursor src-tauri/tauri.conf.json  # "version": "0.6.4"
cursor src-tauri/Cargo.toml       # version = "0.6.4"
cursor package.json               # "version": "0.6.4"
```

## 5. Create Release

```bash
# Commit
git add src-tauri/tauri.conf.json src-tauri/Cargo.toml package.json
git commit -m "chore: release v0.6.4"

# Push
git push origin main

# Tag
git tag v0.6.4
git push origin v0.6.4
```

## 6. Monitor Build

```bash
# Watch workflow
gh run watch

# Or open browser
open "https://github.com/robinebers/openusage/actions"
```

## 7. Verify

```bash
# Check release assets
gh release view v0.6.4
```

Should have:
- `OpenUsage_0.6.4_aarch64.dmg`
- `OpenUsage_0.6.4_x64.dmg`
- `OpenUsage_0.6.4_x64_en-US.msi` (Windows)
- `OpenUsage_0.6.4_x64-setup.exe` (Windows)
- `latest.json`

## Troubleshooting

**Missing WINDOWS_CERTIFICATE**
- Check secret exists in GitHub → Settings → Secrets

**Version mismatch**
- All 3 files must have same version number

**No Windows assets**
- Check workflow logs for Windows build errors
- Verify `WINDOWS_CERTIFICATE_PASSWORD` is correct

## Commands Reference

```bash
# Check versions
grep -h version package.json src-tauri/tauri.conf.json src-tauri/Cargo.toml

# List releases
gh release list

# View workflow runs
gh run list --workflow=publish.yml

# Check specific run
gh run view <run-id>
```
