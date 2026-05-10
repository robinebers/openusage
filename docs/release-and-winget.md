# Release And WinGet

UsageMeter ships as a Windows-only zip produced by `dotnet publish`.

## Local Release Asset

```powershell
$version = "0.1.0"
$publishDir = ".\artifacts\publish\UsageMeter-win-x64"
$zipPath = ".\release-assets\windows\UsageMeter-v$version-win-x64.zip"

dotnet publish .\src\UsageMeter.App\UsageMeter.App.csproj -c Release -r win-x64 --self-contained true -p:Version=$version -o $publishDir
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath -Force
```

## GitHub Release

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Version $version -AssetsPath .\release-assets\windows
```

The script uploads release assets and writes `SHA256SUMS.txt`.

## WinGet

After the package exists in the Windows Package Manager community repository, `.github/workflows/winget.yml` can submit updates from release assets.

Required repository settings:

- `WINGET_PACKAGE_IDENTIFIER` repository variable.
- `WINGET_PAT` repository secret.
