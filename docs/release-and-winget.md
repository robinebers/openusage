# Release and WinGet Publishing

This repository publishes app installers to GitHub Releases. The main `Publish` workflow builds the Tauri app for macOS and Windows when a `vMAJOR.MINOR.PATCH` tag is pushed.

After the package is accepted once in the Windows Package Manager community repository, the `Publish WinGet package` workflow can submit manifest updates.

## Release Windows executables

The normal release path is a tag push:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The `Publish` workflow uploads the Windows installers produced by Tauri to the GitHub Release.

For a manual Windows-only asset upload, put Windows release assets in `release-assets/windows/`, then run:

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Version 1.0.0
```

The repository must have a GitHub remote configured before publishing.

The release publisher uploads supported Windows installer formats:

- `.exe`
- `.msi`
- `.msix`
- `.msixbundle`
- `.appx`
- `.appxbundle`
- `.zip`

It also generates and uploads `SHA256SUMS.txt`.

The same publisher can also be started from the **Upload Windows Release Assets** workflow.

## Publish to winget

Winget packages are published through the Microsoft community repository, not from this repository directly.

Required repository settings:

- Secret: `WINGET_PAT`
- Variable: `WINGET_PACKAGE_IDENTIFIER`

Use a package identifier in the form `Publisher.AppName`, for example `Contoso.Widget`.

The first winget submission must create the package in `microsoft/winget-pkgs`. After that package exists, this repository's **Publish WinGet package** workflow can submit updates after the `Publish` workflow completes.

See `winget/README.md` for the exact first-submission and update flow.
