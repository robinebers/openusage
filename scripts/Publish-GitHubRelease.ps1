param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$AssetsPath = "release-assets/windows",

    [string]$Title,

    [switch]$Prerelease,

    [switch]$Draft,

    [switch]$Clobber
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI is required. Install it from https://cli.github.com/ and run gh auth login."
}

$repositoryRoot = (& git rev-parse --show-toplevel).Trim()
if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
    throw "This script must be run from inside a Git repository."
}

& gh repo view --json nameWithOwner *> $null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub repository could not be resolved. Add an origin remote or run gh repo set-default."
}

$tag = $Version.Trim()
if (-not $tag.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
    $tag = "v$tag"
}

$releaseVersion = $tag.Substring(1)
if ([string]::IsNullOrWhiteSpace($releaseVersion)) {
    throw "Version must not be empty."
}

if ([System.IO.Path]::IsPathRooted($AssetsPath)) {
    $assetRoot = $AssetsPath
}
else {
    $assetRoot = Join-Path $repositoryRoot $AssetsPath
}

if (-not (Test-Path -LiteralPath $assetRoot -PathType Container)) {
    throw "Release asset directory was not found: $assetRoot"
}

$supportedExtensions = @(
    ".zip"
)

$assets = Get-ChildItem -LiteralPath $assetRoot -File -Recurse |
    Where-Object { $supportedExtensions -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object FullName

if (-not $assets) {
    throw "No Windows release assets were found in $assetRoot."
}

$checksumPath = Join-Path $assetRoot "SHA256SUMS.txt"
$checksums = foreach ($asset in $assets) {
    $hash = Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256
    "$($hash.Hash.ToLowerInvariant())  $($asset.Name)"
}
Set-Content -LiteralPath $checksumPath -Value $checksums -Encoding utf8

$releaseTitle = $Title
if ([string]::IsNullOrWhiteSpace($releaseTitle)) {
    $releaseTitle = "Release $tag"
}

$notesPath = Join-Path ([System.IO.Path]::GetTempPath()) "github-release-$releaseVersion.md"
Set-Content -LiteralPath $notesPath -Encoding utf8 -Value @(
    "UsageMeter release assets for $tag.",
    "",
    "Download the Windows archive for your architecture.",
    "",
    "SHA256 hashes are available in SHA256SUMS.txt."
)

$uploadFiles = @($assets.FullName) + $checksumPath

& gh release view $tag --json tagName *> $null
$releaseExists = $LASTEXITCODE -eq 0

if ($releaseExists) {
    if (-not $Clobber) {
        throw "Release $tag already exists. Re-run with -Clobber to replace uploaded assets."
    }

    & gh release upload $tag @uploadFiles --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload assets to existing release $tag."
    }

    Write-Host "Updated release assets for $tag."
    return
}

$ghArgs = @(
    "release",
    "create",
    $tag
) + $uploadFiles + @(
    "--title",
    $releaseTitle,
    "--notes-file",
    $notesPath
)

if ($Prerelease) {
    $ghArgs += "--prerelease"
}

if ($Draft) {
    $ghArgs += "--draft"
}

& gh @ghArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create GitHub Release $tag."
}

Write-Host "Created GitHub Release $tag with $($assets.Count) Windows asset(s)."
