param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$clientRoot = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $clientRoot "micaGO.Windows.sln"
$source = Join-Path $clientRoot "src\micaGO.App\bin\x64\$Configuration\net10.0-windows10.0.19041.0"
$artifacts = Join-Path $clientRoot "artifacts"
$stage = Join-Path $artifacts "micaGO-release-x64"
$archive = Join-Path $artifacts "micaGO-release-x64.zip"

dotnet clean $solution -c $Configuration -p:Platform=x64
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
dotnet build $solution -c $Configuration -p:Platform=x64
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not (Test-Path (Join-Path $source "micaGO.App.exe"))) {
    throw "Release executable was not produced at $source"
}

New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

# A previous RID publish can leave a self-contained win-x64 child folder under
# the normal build output. That publish path produces incompatible Page XBFs,
# so it must never leak into the tested archive.
Get-ChildItem -LiteralPath $source -Force |
    Where-Object Name -ne "win-x64" |
    Copy-Item -Destination $stage -Recurse -Force

# SQLite ships native libraries for every supported platform. This archive is
# explicitly x64 Windows, so retain only the matching runtime asset directory.
$runtimeRoot = Join-Path $stage "runtimes"
if (Test-Path $runtimeRoot) {
    Get-ChildItem -LiteralPath $runtimeRoot -Directory |
        Where-Object Name -ne "win-x64" |
        Remove-Item -Recurse -Force
}

# WinUI carries MUI resources for many locales. micaGO currently exposes only
# English, Simplified Chinese and Traditional Chinese on Windows.
$structuralDirectories = @("Assets", "Controls", "Microsoft.UI.Xaml", "runtimes", "Styles", "Views")
$keptLocales = @("en-us", "zh-CN", "zh-TW")
Get-ChildItem -LiteralPath $stage -Directory | Where-Object {
    $_.Name -notin $structuralDirectories -and
    $_.Name -notin $keptLocales -and
    $_.Name -match '^[a-z]{2,3}(?:-[A-Za-z0-9]+)+$'
} | Remove-Item -Recurse -Force

Get-ChildItem -LiteralPath $stage -Filter "*.pdb" -File | Remove-Item -Force

$flagCount = (Get-ChildItem (Join-Path $stage "Assets\TwemojiFlags") -Filter "*.svg" -File).Count
if ($flagCount -ne 266) { throw "Expected 266 Twemoji flag SVG assets, found $flagCount." }
$emoji17Count = (Get-ChildItem (Join-Path $stage "Assets\TwemojiEmoji17") -Filter "*.svg" -File).Count
if ($emoji17Count -ne 163) { throw "Expected 163 Twemoji Emoji 17 SVG assets, found $emoji17Count." }

if (Test-Path $archive) { Remove-Item -LiteralPath $archive -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $archive -CompressionLevel Optimal

$stageFiles = Get-ChildItem -LiteralPath $stage -Recurse -File
$hash = Get-FileHash -Algorithm SHA256 $archive
[pscustomobject]@{
    Stage = $stage
    Archive = $archive
    Files = $stageFiles.Count
    UncompressedBytes = ($stageFiles | Measure-Object Length -Sum).Sum
    ArchiveBytes = (Get-Item $archive).Length
    Sha256 = $hash.Hash
}
