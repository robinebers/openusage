# WinGet Publishing

WinGet package manifests are submitted to the Microsoft community repository at `microsoft/winget-pkgs`.

This repository includes `.github/workflows/winget.yml` to submit package updates after the `Publish` workflow completes. That workflow assumes the package already exists in winget.

## First submission

1. Publish a GitHub Release with the Windows release zip.
2. Install or download `wingetcreate`.
3. Create and submit the first manifest:

```powershell
wingetcreate.exe new "https://github.com/ddieppa/usage-meter/releases/download/v1.0.0/UsageMeter-v1.0.0-win-x64.zip" --submit --token $env:WINGET_PAT
```

If you publish multiple architectures, include all release URLs when creating the manifest.

## Repository settings for updates

Add these in GitHub repository settings:

- `WINGET_PACKAGE_IDENTIFIER` repository variable, for example `Contoso.Widget`
- `WINGET_PAT` repository secret

After the first package manifest is accepted, every successful `Publish` workflow run can submit:

```powershell
wingetcreate.exe update <PackageIdentifier> --version <Version> --urls <ReleaseUrls> --submit --token <GitHubToken>
```

## Local manifest validation

Once a manifest exists, test it locally before submitting changes:

```powershell
winget install --manifest .\manifests\Publisher\AppName\1.0.0
```

Winget requires SHA256 hashes for release URLs; `wingetcreate` fills those during submission.
