[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [ValidateSet('nightly', 'stable')]
    [string]$BuildChannel = 'nightly',

    [string]$StableVersion,
    [string]$NightlyTargetVersion,
    [string]$PackageVersion,
    [string]$BuildDirectory = 'build',
    [string]$InstallDirectory = 'dist',
    [string]$PackageOutputDirectory = '.',
    [string]$VcpkgRoot,
    [string]$CudaPath,
    [switch]$Clean,
    [switch]$SkipPackage,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Usage: .\build_windows_ci.ps1 [options]

CI-aligned local Windows build script for LichtFeld Studio.
It mirrors the GitHub nightly packaging workflow locally:
  1. Verifies CUDA, CMake, Ninja, Git, and MSVC
  2. Uses -VcpkgRoot or VCPKG_ROOT, otherwise bootstraps ..\vcpkg
  3. Configures with CMake + Ninja
  4. Builds with vcvars64.bat loaded
  5. Installs to dist
  6. Optionally creates a zip package and .sha256 sidecar

Options:
  -Configuration <Release|Debug>      Build type (default: Release)
  -BuildChannel <nightly|stable>      Package naming mode (default: nightly)
  -StableVersion <x.y.z>              Required for stable packaging unless -PackageVersion is set
  -NightlyTargetVersion <x.y|x.y.z>   Overrides .github\nightly-target-version.txt
  -PackageVersion <version>           Explicit package version override
  -BuildDirectory <path>              Build directory (default: build)
  -InstallDirectory <path>            Install directory (default: dist)
  -PackageOutputDirectory <path>      Zip output directory (default: repo root)
  -VcpkgRoot <path>                   Override VCPKG_ROOT (default: VCPKG_ROOT env var or ..\vcpkg)
  -CudaPath <path>                    Override CUDA root path
  -Clean                              Remove build and dist before building
  -SkipPackage                        Build and install only; do not create zip
  -Help                               Show this message

Examples:
  .\build_windows_ci.ps1
  .\build_windows_ci.ps1 -Configuration Debug -SkipPackage
  .\build_windows_ci.ps1 -BuildChannel stable -StableVersion 0.6.1
"@
    exit 0
}

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandPathOrNull {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Resolve-AbsolutePath {
    param(
        [string]$BasePath,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Join-CmdArguments {
    param([string[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }

    return ($quoted -join ' ')
}

function Test-CudaRequiresVs2022OrEarlier {
    param([string]$CudaPath)

    if ([string]::IsNullOrWhiteSpace($CudaPath)) {
        return $false
    }

    $hostConfigPath = Join-Path $CudaPath 'include\crt\host_config.h'
    if (-not (Test-Path $hostConfigPath)) {
        return $false
    }

    return Select-String -Path $hostConfigPath -Pattern 'Only the versions between 2017 and 2022 \(inclusive\) are supported' -Quiet
}

function Get-VcpkgPlatformToolsetForVcVarsPath {
    param([string]$VcVarsPath)

    if ($VcVarsPath -match '\\2022\\') {
        return 'v143'
    }

    if ($VcVarsPath -match '\\18\\') {
        return 'v145'
    }

    return $null
}

function Get-VcVarsPath {
    param([string]$CudaPath)

    $candidateRoots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio')
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } |
        Select-Object -Unique

    $vcVarsCandidates = foreach ($root in $candidateRoots) {
        Get-ChildItem -Path (Join-Path $root '*\*\VC\Auxiliary\Build\vcvars64.bat') -File -ErrorAction SilentlyContinue
    }

    if ($null -eq $vcVarsCandidates -or $vcVarsCandidates.Count -eq 0) {
        throw "No Visual Studio installation with vcvars64.bat was found under: $($candidateRoots -join ', ')"
    }

    $resolvedCandidates = $vcVarsCandidates |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                ToolsetVersion = Get-LatestMsvcToolsetVersion -VcVarsPath $_.FullName
            }
        } |
        Sort-Object { [version]$_.ToolsetVersion } -Descending

    $bestCandidate = $null
    if (Test-CudaRequiresVs2022OrEarlier -CudaPath $CudaPath) {
        $bestCandidate = $resolvedCandidates |
            Where-Object { $_.Path -match '\\2022\\' } |
            Select-Object -First 1
    }

    if ($null -eq $bestCandidate) {
        $bestCandidate = $resolvedCandidates | Select-Object -First 1
    }

    if ($null -eq $bestCandidate -or [string]::IsNullOrWhiteSpace($bestCandidate.Path)) {
        throw 'Failed to resolve a Visual Studio vcvars64.bat path.'
    }

    return $bestCandidate.Path
}

function Get-LatestMsvcToolsetVersion {
    param([string]$VcVarsPath)

    $vcRoot = Split-Path (Split-Path (Split-Path $VcVarsPath -Parent) -Parent) -Parent
    $vcToolsRoot = Join-Path $vcRoot 'Tools\MSVC'
    if (-not (Test-Path $vcToolsRoot)) {
        throw "MSVC tools directory not found: $vcToolsRoot"
    }

    $latestDir = Get-ChildItem $vcToolsRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1

    if ($null -eq $latestDir) {
        throw "No MSVC toolset directories found under $vcToolsRoot"
    }

    return $latestDir.Name
}

function Get-LatestWindowsSdkInfo {
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    $includeRoot = Join-Path $sdkRoot 'Include'
    $libRoot = Join-Path $sdkRoot 'Lib'

    if (-not (Test-Path $includeRoot) -or -not (Test-Path $libRoot)) {
        throw "Windows 10 SDK include/lib roots were not found under $sdkRoot"
    }

    $latestSdk = Get-ChildItem $includeRoot -Directory |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'ucrt\corecrt.h')) -and
            (Test-Path (Join-Path $libRoot "$($_.Name)\ucrt\x64\ucrt.lib")) -and
            (Test-Path (Join-Path $libRoot "$($_.Name)\um\x64\kernel32.lib"))
        } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1

    if ($null -eq $latestSdk) {
        throw "No Windows 10 SDK with UCRT and UM x64 libraries was found under $sdkRoot"
    }

    $sdkVersion = $latestSdk.Name
    return [pscustomobject]@{
        Root = $sdkRoot
        Version = $sdkVersion
        IncludePaths = @(
            (Join-Path $includeRoot "$sdkVersion\ucrt"),
            (Join-Path $includeRoot "$sdkVersion\um"),
            (Join-Path $includeRoot "$sdkVersion\shared"),
            (Join-Path $includeRoot "$sdkVersion\winrt"),
            (Join-Path $includeRoot "$sdkVersion\cppwinrt")
        )
        LibPaths = @(
            (Join-Path $libRoot "$sdkVersion\ucrt\x64"),
            (Join-Path $libRoot "$sdkVersion\um\x64")
        )
    }
}

function New-CmdSetCommand {
    param(
        [string]$Name,
        [string]$Value
    )

    return 'set "' + $Name + '=' + $Value + '"'
}

function Get-WindowsSdkCmdSetup {
    param([pscustomobject]$WindowsSdkInfo)

    $sdkRootWithSlash = if ($WindowsSdkInfo.Root.EndsWith('\')) {
        $WindowsSdkInfo.Root
    } else {
        $WindowsSdkInfo.Root + '\'
    }
    $sdkVersionWithSlash = $WindowsSdkInfo.Version + '\'
    $includeValue = ($WindowsSdkInfo.IncludePaths -join ';') + ';!INCLUDE!'
    $libValue = ($WindowsSdkInfo.LibPaths -join ';') + ';!LIB!'

    return @(
        (New-CmdSetCommand -Name 'WindowsSdkDir' -Value $sdkRootWithSlash),
        (New-CmdSetCommand -Name 'WindowsSDKVersion' -Value $sdkVersionWithSlash),
        (New-CmdSetCommand -Name 'WindowsSDKLibVersion' -Value $sdkVersionWithSlash),
        (New-CmdSetCommand -Name 'UCRTVersion' -Value $sdkVersionWithSlash),
        (New-CmdSetCommand -Name 'INCLUDE' -Value $includeValue),
        (New-CmdSetCommand -Name 'LIB' -Value $libValue)
    ) -join ' && '
}

function Invoke-VcCommand {
    param(
        [string]$VcVarsPath,
        [string]$WorkingDirectory,
        [string]$Command,
        [string]$ToolsetVersion,
        [pscustomobject]$WindowsSdkInfo
    )

    $cmdPath = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($cmdPath) -or -not (Test-Path $cmdPath)) {
        $cmdPath = 'C:\Windows\System32\cmd.exe'
    }

    if (-not (Test-Path $cmdPath)) {
        throw 'cmd.exe was not found.'
    }

    Write-Host "> $Command" -ForegroundColor DarkGray
    $vcVarsArgs = if ([string]::IsNullOrWhiteSpace($ToolsetVersion)) {
        ''
    } else {
        " -vcvars_ver=$ToolsetVersion"
    }
    $windowsSdkSetup = if ($null -eq $WindowsSdkInfo) {
        ''
    } else {
        (Get-WindowsSdkCmdSetup -WindowsSdkInfo $WindowsSdkInfo) + ' && '
    }
    $cmdLine = "call ""$VcVarsPath""$vcVarsArgs && $windowsSdkSetup" +
        "cd /d ""$WorkingDirectory"" && $Command"
    & $cmdPath /v:on /d /s /c $cmdLine
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
}

function Get-ConfiguredCudaPath {
    param([string]$RequestedCudaPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedCudaPath)) {
        return [System.IO.Path]::GetFullPath($RequestedCudaPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CUDA_PATH_V12_8)) {
        return $env:CUDA_PATH_V12_8
    }

    $defaultCudaPath = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8'
    if (Test-Path $defaultCudaPath) {
        return $defaultCudaPath
    }

    throw 'CUDA 12.8 was not found. Pass -CudaPath or set CUDA_PATH_V12_8.'
}

function Add-ToPathIfMissing {
    param([string]$Entry)

    $currentEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
        $currentEntries = $env:PATH -split ';'
    }

    if ($currentEntries -notcontains $Entry) {
        $env:PATH = "$Entry;$env:PATH"
    }
}

function Resolve-ToolPath {
    param(
        [string]$ToolName,
        [string[]]$CandidatePaths
    )

    $existingCommandPath = Get-CommandPathOrNull -Name $ToolName
    if (-not [string]::IsNullOrWhiteSpace($existingCommandPath)) {
        return $existingCommandPath
    }

    foreach ($candidatePath in $CandidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path $candidatePath)) {
            Add-ToPathIfMissing -Entry (Split-Path -Parent $candidatePath)
            return $candidatePath
        }
    }

    return $null
}

function Get-EffectiveVcpkgRoot {
    param(
        [string]$ProjectRoot,
        [string]$RequestedVcpkgRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedVcpkgRoot)) {
        return Resolve-AbsolutePath -BasePath $ProjectRoot -Path $RequestedVcpkgRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:VCPKG_ROOT)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ProjectRoot) 'vcpkg'))
}

function Initialize-VcpkgRoot {
    param(
        [string]$VcpkgRoot,
        [string]$GitPath
    )

    $bootstrapScript = Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat'
    $vcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'

    if (-not (Test-Path $VcpkgRoot)) {
        Write-Section 'Setup vcpkg'
        Write-Host "Cloning vcpkg into $VcpkgRoot"

        $vcpkgParent = Split-Path -Parent $VcpkgRoot
        if (-not [string]::IsNullOrWhiteSpace($vcpkgParent)) {
            New-Item -ItemType Directory -Force -Path $vcpkgParent | Out-Null
        }

        & $GitPath clone https://github.com/microsoft/vcpkg.git $VcpkgRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone vcpkg into $VcpkgRoot"
        }
    }

    if (-not (Test-Path $bootstrapScript)) {
        throw "VCPKG_ROOT does not look like a vcpkg checkout: $VcpkgRoot"
    }

    if (-not (Test-Path $vcpkgExe)) {
        Write-Section 'Bootstrap vcpkg'
        Write-Host "Bootstrapping vcpkg at $VcpkgRoot"

        Push-Location $VcpkgRoot
        try {
            & $bootstrapScript -disableMetrics
            if ($LASTEXITCODE -ne 0) {
                throw "bootstrap-vcpkg.bat failed at $VcpkgRoot"
            }
        } finally {
            Pop-Location
        }
    }
}

function Get-CMakeCacheCompilerPath {
    param(
        [string]$BuildDirectory,
        [string]$CacheVariable
    )

    $cachePath = Join-Path $BuildDirectory 'CMakeCache.txt'
    if (-not (Test-Path $cachePath)) {
        return $null
    }

    $match = Select-String -Path $cachePath -Pattern "^$([regex]::Escape($CacheVariable)):FILEPATH=(.+)$" |
        Select-Object -First 1

    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value
}

function Get-MsvcToolsetVersionFromCompilerPath {
    param([string]$CompilerPath)

    if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
        return $null
    }

    $normalizedPath = $CompilerPath.Replace('\', '/')
    if ($normalizedPath -match '/VC/Tools/MSVC/([^/]+)/bin/') {
        return $Matches[1]
    }

    return $null
}

function Get-NightlyTargetVersion {
    param(
        [string]$ProjectRoot,
        [string]$RequestedNightlyTargetVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedNightlyTargetVersion)) {
        return $RequestedNightlyTargetVersion.Trim()
    }

    $targetVersionFile = Join-Path $ProjectRoot '.github\nightly-target-version.txt'
    if (-not (Test-Path $targetVersionFile)) {
        throw "Missing nightly target version file: $targetVersionFile"
    }

    $targetVersion = Get-Content $targetVersionFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($targetVersion) -or $targetVersion -eq 'SET_ME') {
        throw "Set a valid nightly target version in $targetVersionFile or pass -NightlyTargetVersion."
    }

    return $targetVersion
}

function Get-PackageVersionValue {
    param(
        [string]$ProjectRoot,
        [string]$RequestedPackageVersion,
        [string]$SelectedBuildChannel,
        [string]$RequestedStableVersion,
        [string]$RequestedNightlyTargetVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPackageVersion)) {
        return $RequestedPackageVersion.Trim()
    }

    if ($SelectedBuildChannel -eq 'stable') {
        if ([string]::IsNullOrWhiteSpace($RequestedStableVersion) -or $RequestedStableVersion -notmatch '^[0-9]+(\.[0-9]+){1,2}$') {
            throw 'Stable packaging requires -StableVersion like 0.6.1, unless -PackageVersion is provided.'
        }

        return $RequestedStableVersion.Trim()
    }

    $targetVersion = Get-NightlyTargetVersion -ProjectRoot $ProjectRoot -RequestedNightlyTargetVersion $RequestedNightlyTargetVersion
    if ($targetVersion -notmatch '^[0-9]+(\.[0-9]+){1,2}$') {
        throw "Invalid nightly target version '$targetVersion'."
    }

    $dateStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    $shortSha = (& git rev-parse --short HEAD).Trim()
    if ([string]::IsNullOrWhiteSpace($shortSha)) {
        throw 'Failed to resolve git short SHA for nightly package naming.'
    }

    return "$targetVersion.dev$dateStamp+$shortSha"
}

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$BuildDirectory = Resolve-AbsolutePath -BasePath $ProjectRoot -Path $BuildDirectory
$InstallDirectory = Resolve-AbsolutePath -BasePath $ProjectRoot -Path $InstallDirectory
$PackageOutputDirectory = Resolve-AbsolutePath -BasePath $ProjectRoot -Path $PackageOutputDirectory
$VcpkgRoot = Get-EffectiveVcpkgRoot -ProjectRoot $ProjectRoot -RequestedVcpkgRoot $VcpkgRoot
$resolvedCudaPath = Get-ConfiguredCudaPath -RequestedCudaPath $CudaPath

Write-Section 'Environment'
Write-Host "Project root: $ProjectRoot"
Write-Host "Configuration: $Configuration"
Write-Host "Build channel: $BuildChannel"
Write-Host "Build directory: $BuildDirectory"
Write-Host "Install directory: $InstallDirectory"
Write-Host "Package output directory: $PackageOutputDirectory"
Write-Host "VCPKG_ROOT: $VcpkgRoot"

$vcVarsPath = Get-VcVarsPath -CudaPath $resolvedCudaPath
$msvcToolsetVersion = Get-LatestMsvcToolsetVersion -VcVarsPath $vcVarsPath
$vcpkgPlatformToolset = Get-VcpkgPlatformToolsetForVcVarsPath -VcVarsPath $vcVarsPath
$windowsSdkInfo = Get-LatestWindowsSdkInfo
Write-Host "MSVC environment: $vcVarsPath"
Write-Host "MSVC toolset: $msvcToolsetVersion"
if (-not [string]::IsNullOrWhiteSpace($vcpkgPlatformToolset)) {
    Write-Host "vcpkg platform toolset: $vcpkgPlatformToolset"
}
Write-Host "Windows SDK: $($windowsSdkInfo.Version)"
Write-Host "CUDA_PATH_V12_8: $resolvedCudaPath"

if ($Clean) {
    Write-Section 'Clean'
    foreach ($path in @($BuildDirectory, $InstallDirectory)) {
        if (Test-Path $path) {
            Write-Host "Removing $path"
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

$cachedCompilerPath = Get-CMakeCacheCompilerPath -BuildDirectory $BuildDirectory -CacheVariable 'CMAKE_CXX_COMPILER'
$cachedToolsetVersion = Get-MsvcToolsetVersionFromCompilerPath -CompilerPath $cachedCompilerPath
if (-not [string]::IsNullOrWhiteSpace($cachedToolsetVersion) -and $cachedToolsetVersion -ne $msvcToolsetVersion) {
    throw "Build directory '$BuildDirectory' is configured for MSVC toolset $cachedToolsetVersion, but the selected toolset is $msvcToolsetVersion. Re-run with -Clean or remove the build directory so CMake can reconfigure."
}

$cmakePath = Resolve-ToolPath -ToolName 'cmake' -CandidatePaths @(
    'C:\Program Files\CMake\bin\cmake.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
)
if ([string]::IsNullOrWhiteSpace($cmakePath)) {
    throw 'cmake was not found in PATH or standard install locations.'
}
Write-Host "cmake: $cmakePath"

$gitPath = Resolve-ToolPath -ToolName 'git' -CandidatePaths @(
    'C:\Program Files\Git\cmd\git.exe',
    'C:\Program Files\Git\bin\git.exe'
)
if ([string]::IsNullOrWhiteSpace($gitPath)) {
    throw 'git was not found in PATH or standard install locations.'
}
Write-Host "git: $gitPath"

$ninjaPath = Resolve-ToolPath -ToolName 'ninja' -CandidatePaths @(
    'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
    'C:\Program Files\Ninja\ninja.exe'
)
if ([string]::IsNullOrWhiteSpace($ninjaPath)) {
    throw 'ninja was not found in PATH or standard install locations.'
}
Write-Host "ninja: $ninjaPath"

if (-not (Test-Path $resolvedCudaPath)) {
    throw "CUDA path does not exist: $resolvedCudaPath"
}

$env:CUDA_PATH_V12_8 = $resolvedCudaPath
Add-ToPathIfMissing -Entry (Join-Path $resolvedCudaPath 'bin')
Add-ToPathIfMissing -Entry (Join-Path $resolvedCudaPath 'libnvvp')

Initialize-VcpkgRoot -VcpkgRoot $VcpkgRoot -GitPath $gitPath

$repoLocalVcpkgRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot '.vcpkg'))
if ((Test-Path $repoLocalVcpkgRoot) -and ($repoLocalVcpkgRoot -ne $VcpkgRoot)) {
    Write-Host "Note: repo-local .vcpkg exists but is not being used: $repoLocalVcpkgRoot" -ForegroundColor Yellow
}

$vcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'
if (-not (Test-Path $vcpkgExe)) {
    throw "vcpkg.exe was not found at $vcpkgExe"
}

$env:VCPKG_ROOT = $VcpkgRoot
$vcpkgToolchainFile = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
$tripletFile = Join-Path $VcpkgRoot 'triplets\x64-windows.cmake'
if (-not (Test-Path $vcpkgToolchainFile)) {
    throw "vcpkg toolchain file was not found at $vcpkgToolchainFile"
}
if (-not (Test-Path $tripletFile)) {
    throw "vcpkg triplet file not found: $tripletFile"
}

if (-not (Select-String -Path $tripletFile -Pattern 'VCPKG_MAX_CONCURRENCY' -Quiet)) {
    Add-Content -Path $tripletFile -Value 'set(VCPKG_MAX_CONCURRENCY 2)'
}

if (-not [string]::IsNullOrWhiteSpace($vcpkgPlatformToolset)) {
    $tripletContent = Get-Content -Path $tripletFile -Raw
    $toolsetLine = "set(VCPKG_PLATFORM_TOOLSET $vcpkgPlatformToolset)"

    if ($tripletContent -match 'set\(VCPKG_PLATFORM_TOOLSET\s+([^)]+)\)') {
        if ($Matches[1].Trim() -ne $vcpkgPlatformToolset) {
            $updatedTripletContent = [regex]::Replace(
                $tripletContent,
                'set\(VCPKG_PLATFORM_TOOLSET\s+([^)]+)\)',
                $toolsetLine
            )
            Set-Content -Path $tripletFile -Value $updatedTripletContent
        }
    } else {
        Add-Content -Path $tripletFile -Value $toolsetLine
    }
}

New-Item -ItemType Directory -Force -Path $PackageOutputDirectory | Out-Null

$configureArguments = @(
    '-B', $BuildDirectory,
    '-S', $ProjectRoot,
    '-G', 'Ninja',
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchainFile",
    "-DCMAKE_BUILD_TYPE=$Configuration",
    '-DBUILD_PORTABLE=ON',
    '-DBUILD_PYTHON_STUBS=OFF',
    '-DCUDA_DEVICE_DEBUG=OFF'
)

$configureCommand = 'cmake ' + (Join-CmdArguments -Arguments $configureArguments)
$retryablePatterns = @(
    'status code 5\d\d',
    'timed out',
    'timeout',
    'connection reset',
    'failed to connect',
    'temporarily unavailable',
    'tls',
    'ssl'
)

Write-Section 'Configure'
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Write-Host "Configure attempt $attempt/3"
        Invoke-VcCommand -VcVarsPath $vcVarsPath -WorkingDirectory $ProjectRoot -Command $configureCommand -ToolsetVersion $msvcToolsetVersion -WindowsSdkInfo $windowsSdkInfo
        break
    } catch {
        $logPath = Join-Path $BuildDirectory 'vcpkg-manifest-install.log'
        $shouldRetry = $false

        if (Test-Path $logPath) {
            foreach ($pattern in $retryablePatterns) {
                if (Select-String -Path $logPath -Pattern $pattern -Quiet) {
                    $shouldRetry = $true
                    break
                }
            }
        }

        if (-not $shouldRetry -or $attempt -eq 3) {
            throw
        }

        Write-Host 'Retryable configure failure detected. Cleaning build directory before retry.' -ForegroundColor Yellow
        if (Test-Path $BuildDirectory) {
            Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
        }
        Start-Sleep -Seconds (15 * $attempt)
    }
}

Write-Section 'Build'
$buildArguments = @('--build', $BuildDirectory, '-j', '%NUMBER_OF_PROCESSORS%')
$buildCommand = 'cmake ' + (Join-CmdArguments -Arguments $buildArguments)
Invoke-VcCommand -VcVarsPath $vcVarsPath -WorkingDirectory $ProjectRoot -Command $buildCommand -ToolsetVersion $msvcToolsetVersion -WindowsSdkInfo $windowsSdkInfo

Write-Section 'Install'
$installArguments = @('--install', $BuildDirectory, '--prefix', $InstallDirectory)
$installCommand = 'cmake ' + (Join-CmdArguments -Arguments $installArguments)
Invoke-VcCommand -VcVarsPath $vcVarsPath -WorkingDirectory $ProjectRoot -Command $installCommand -ToolsetVersion $msvcToolsetVersion -WindowsSdkInfo $windowsSdkInfo

$packagePath = $null
$checksumPath = $null

if (-not $SkipPackage) {
    Write-Section 'Package'
    $resolvedPackageVersion = Get-PackageVersionValue `
        -ProjectRoot $ProjectRoot `
        -RequestedPackageVersion $PackageVersion `
        -SelectedBuildChannel $BuildChannel `
        -RequestedStableVersion $StableVersion `
        -RequestedNightlyTargetVersion $NightlyTargetVersion

    $packageName = "LichtFeld-Studio-windows-v$resolvedPackageVersion.zip"
    $packagePath = Join-Path $PackageOutputDirectory $packageName
    $checksumPath = "$packagePath.sha256"

    if (-not (Test-Path $InstallDirectory)) {
        throw "Install directory does not exist: $InstallDirectory"
    }

    if (Test-Path $packagePath) {
        Remove-Item -LiteralPath $packagePath -Force
    }

    if (Test-Path $checksumPath) {
        Remove-Item -LiteralPath $checksumPath -Force
    }

    Compress-Archive -Path (Join-Path $InstallDirectory '*') -DestinationPath $packagePath

    $checksum = (Get-FileHash -Algorithm SHA256 -Path $packagePath).Hash.ToLowerInvariant()
    Set-Content -Path $checksumPath -Value "$checksum  $packageName" -Encoding ascii

    Write-Host "Package version: $resolvedPackageVersion"
    Write-Host "Package path: $packagePath"
    Write-Host "Checksum path: $checksumPath"
}

Write-Section 'Done'
Write-Host "Build completed successfully."
Write-Host "Installed files: $InstallDirectory"
if ($packagePath) {
    Write-Host "Zip package: $packagePath"
}
