param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$clientRoot = Split-Path -Parent $PSScriptRoot
$packageScript = Join-Path $PSScriptRoot "package-release-x64.ps1"
$archive = Join-Path $clientRoot "artifacts\micaGO-release-x64.zip"
$artifacts = Join-Path $clientRoot "artifacts"
$installerScript = Join-Path $clientRoot "installer\micaGO-x64.iss"
$propsPath = Join-Path $clientRoot "Directory.Build.props"

& $packageScript -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not (Test-Path -LiteralPath $archive)) { throw "Release archive was not produced at $archive" }

[xml]$props = Get-Content -LiteralPath $propsPath
$version = [string]($props.Project.PropertyGroup.MicaGoVersion | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($version)) { throw "MicaGoVersion is missing from $propsPath" }

$compilerCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 7\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 7\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 7\ISCC.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    throw "Inno Setup compiler was not found. Install Inno Setup 7, then run this script again."
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$stage = [IO.Path]::GetFullPath((Join-Path $tempRoot ("micaGO-installer-" + [Guid]::NewGuid().ToString("N"))))
if (-not $stage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create installer staging outside the temporary directory."
}

try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    & $compiler "/DSourceDir=$stage" "/DOutputDir=$artifacts" "/DAppVersion=$version" $installerScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    if (Test-Path -LiteralPath $stage) {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        if ($resolvedStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}

$installer = Join-Path $artifacts "micaGO-Setup-x64.exe"
if (-not (Test-Path -LiteralPath $installer)) { throw "Installer was not produced at $installer" }
$hash = Get-FileHash -LiteralPath $installer -Algorithm SHA256
[pscustomobject]@{
    Installer = $installer
    Bytes = (Get-Item -LiteralPath $installer).Length
    Sha256 = $hash.Hash
}
