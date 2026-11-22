[CmdletBinding()]
param(
    [string]$PlatformToolset = '',
    [switch]$SkipRuntimeRegen
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SlnPath = Join-Path $Root 'vmprotect.sln'

$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $VsWhere)) {
    throw "vswhere.exe not found at $VsWhere"
}

$VsRoot = & $VsWhere -latest -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1
if (-not $VsRoot) {
    throw 'Visual Studio with MSBuild not found.'
}

$MsBuild = Join-Path $VsRoot 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $MsBuild)) {
    $MsBuild = Get-ChildItem -Path (Join-Path $VsRoot 'MSBuild') -Filter 'MSBuild.exe' -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $MsBuild -or -not (Test-Path -LiteralPath $MsBuild)) {
    throw 'MSBuild.exe not found.'
}

function Invoke-MsBuildTarget {
    param(
        [string]$Target,
        [string]$Configuration,
        [string]$Platform = 'x64'
    )
    $label = if ($PlatformToolset) { "$Configuration|$Platform, toolset=$PlatformToolset" } else { "$Configuration|$Platform" }
    Write-Host "[RevengeProtect] Building $Target ($label)..."
    $msArgs = @($SlnPath, "/t:$Target", "/p:Configuration=$Configuration", "/p:Platform=$Platform", '/m', '/nologo', '/v:minimal')
    if ($PlatformToolset) {
        $msArgs += "/p:PlatformToolset=$PlatformToolset"
    }
    & $MsBuild @msArgs
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed for $Target ($Configuration|$Platform) with exit code $LASTEXITCODE"
    }
}

Invoke-MsBuildTarget -Target 'VMProtectSDK' -Configuration 'Release'
Invoke-MsBuildTarget -Target 'win_runtime' -Configuration 'Release'
Invoke-MsBuildTarget -Target 'VMProtectCon' -Configuration 'Ultimate'

if (-not $SkipRuntimeRegen) {
    $RpExe = Join-Path $Root 'bin\64\Ultimate\RevengeProtect.exe'
    $RpSdk = Join-Path $Root 'bin\64\Release\VMProtectSDK64.dll'
    $RtDll = Join-Path $Root 'bin\64\Release\win_runtime.dll'
    $RtMap = Join-Path $Root 'bin\64\Release\win_runtime.map'
    $RtVmp = Join-Path $Root 'core\runtime.vmp'
    $OutInc = Join-Path $Root 'core\win_runtime64.dll.inc'

    foreach ($req in @($RpExe, $RpSdk, $RtDll, $RtMap, $RtVmp)) {
        if (-not (Test-Path -LiteralPath $req)) {
            throw "Required build artifact missing: $req"
        }
    }

    $StageDir = Join-Path $env:TEMP 'revenge_protect_rt'
    if (Test-Path -LiteralPath $StageDir) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

    try {
        Copy-Item -LiteralPath $RpExe -Destination (Join-Path $StageDir 'RevengeProtect.exe') -Force
        Copy-Item -LiteralPath $RpSdk -Destination (Join-Path $StageDir 'VMProtectSDK64.dll') -Force
        Copy-Item -LiteralPath $RtDll -Destination (Join-Path $StageDir 'win_runtime.dll') -Force
        Copy-Item -LiteralPath $RtMap -Destination (Join-Path $StageDir 'win_runtime.map') -Force

        $VmpXml = Get-Content -LiteralPath $RtVmp -Raw
        $VmpXml = $VmpXml -replace 'InputFileName="\.\./bin/64/Release/win_runtime\.dll"', 'InputFileName="win_runtime.dll"'
        $VmpXml = $VmpXml -replace 'OutputFileName="win_runtime32\.dll"', 'OutputFileName="win_runtime64.dll"'
        Set-Content -LiteralPath (Join-Path $StageDir 'runtime64.vmp') -Value $VmpXml -Encoding UTF8

        Write-Host '[RevengeProtect] Regenerating core\win_runtime64.dll.inc...'
        Push-Location $StageDir
        try {
            & (Join-Path $StageDir 'RevengeProtect.exe') 'win_runtime.dll' '-pf' 'runtime64.vmp'
            if ($LASTEXITCODE -ne 0) {
                throw "runtime.vmp generation failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }

        $GenInc = Join-Path $StageDir 'win_runtime64.dll.inc'
        if (-not (Test-Path -LiteralPath $GenInc)) {
            throw "Generated include missing at $GenInc"
        }
        $IncText = Get-Content -LiteralPath $GenInc -Raw
        if ($IncText -notmatch 'win_runtime64_dll_code\[\]' -or $IncText -notmatch 'win_runtime64_dll_file\[\]') {
            throw 'Generated win_runtime64.dll.inc is missing expected symbol arrays.'
        }

        Copy-Item -LiteralPath $GenInc -Destination $OutInc -Force
        Write-Host "[RevengeProtect] Updated $OutInc"
    } finally {
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Rebuild VMProtectCon so RevengeProtect.exe embeds the freshly generated win_runtime64.dll.inc
    Invoke-MsBuildTarget -Target 'VMProtectCon' -Configuration 'Ultimate'
}

Write-Host '[RevengeProtect] Done.'
