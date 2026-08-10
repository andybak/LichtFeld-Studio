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
    [string]$VcpkgInstalledDirectory,
    [string]$CudaPath,
    [string]$CudnnRoot,
    [switch]$Clean,
    [switch]$CleanDependencies,
    [switch]$SkipPackage,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Usage: .\build_windows_ci.ps1 [options]

CI-aligned local Windows build script for LichtFeld Studio.
It mirrors the GitHub nightly packaging workflow locally:
  1. Verifies CUDA, cuDNN, CMake, Ninja, Git, MSVC, and clang-cl
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
  -VcpkgInstalledDirectory <path>     Override vcpkg installed tree (default: VCPKG_INSTALLED_DIR or build\vcpkg_installed)
  -CudaPath <path>                    Override CUDA root path
  -CudnnRoot <path>                   Override cuDNN root path (default: CUDNN_ROOT_DIR or the selected CUDA root)
  -Clean                              Remove project build outputs and dist before building; preserves VCPKG_INSTALLED_DIR
  -CleanDependencies                  With -Clean, also remove VCPKG_INSTALLED_DIR
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

function Get-EnvironmentValue {
    param([string]$Name)

    $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $processValue
    }

    return [Environment]::GetEnvironmentVariable($Name, 'User')
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

function Get-ClangClPathForVcVarsPath {
    param([string]$VcVarsPath)

    $commandPath = Get-CommandPathOrNull -Name 'clang-cl'
    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        return $commandPath
    }

    $visualStudioRoot = Split-Path (Split-Path (Split-Path (Split-Path $VcVarsPath -Parent) -Parent) -Parent) -Parent
    $candidatePaths = @(
        (Join-Path $visualStudioRoot 'VC\Tools\Llvm\x64\bin\clang-cl.exe'),
        (Join-Path $visualStudioRoot 'VC\Tools\Llvm\bin\clang-cl.exe')
    )

    return $candidatePaths |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
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

    $configuredVcpkgRoot = Get-EnvironmentValue -Name 'VCPKG_ROOT'
    if (-not [string]::IsNullOrWhiteSpace($configuredVcpkgRoot)) {
        return [System.IO.Path]::GetFullPath($configuredVcpkgRoot)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ProjectRoot) 'vcpkg'))
}

function Get-EffectiveVcpkgInstalledDirectory {
    param(
        [string]$ProjectRoot,
        [string]$BuildDirectory,
        [string]$RequestedVcpkgInstalledDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedVcpkgInstalledDirectory)) {
        return Resolve-AbsolutePath -BasePath $ProjectRoot -Path $RequestedVcpkgInstalledDirectory
    }

    $configuredInstalledDirectory = Get-EnvironmentValue -Name 'VCPKG_INSTALLED_DIR'
    if (-not [string]::IsNullOrWhiteSpace($configuredInstalledDirectory)) {
        return [System.IO.Path]::GetFullPath($configuredInstalledDirectory)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BuildDirectory 'vcpkg_installed'))
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

function Clear-BuildDirectory {
    param(
        [string]$BuildDirectory,
        [string]$VcpkgInstalledDirectory,
        [switch]$RemoveDependencies
    )

    if (-not (Test-Path $BuildDirectory)) {
        if ($RemoveDependencies -and -not [string]::IsNullOrWhiteSpace($VcpkgInstalledDirectory) -and (Test-Path $VcpkgInstalledDirectory)) {
            Write-Host "Removing $VcpkgInstalledDirectory"
            Remove-Item -LiteralPath $VcpkgInstalledDirectory -Recurse -Force
        }
        return
    }

    if ($RemoveDependencies) {
        Write-Host "Removing $BuildDirectory"
        Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
        if (-not [string]::IsNullOrWhiteSpace($VcpkgInstalledDirectory) -and (Test-Path $VcpkgInstalledDirectory)) {
            Write-Host "Removing $VcpkgInstalledDirectory"
            Remove-Item -LiteralPath $VcpkgInstalledDirectory -Recurse -Force
        }
        return
    }

    Write-Host "Removing project build outputs under $BuildDirectory"
    $localVcpkgInstalledDirectory = Join-Path $BuildDirectory 'vcpkg_installed'
    Get-ChildItem -LiteralPath $BuildDirectory -Force |
        Where-Object { $_.FullName -ne $localVcpkgInstalledDirectory } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
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
$VcpkgInstalledDirectory = Get-EffectiveVcpkgInstalledDirectory -ProjectRoot $ProjectRoot -BuildDirectory $BuildDirectory -RequestedVcpkgInstalledDirectory $VcpkgInstalledDirectory
$resolvedCudaPath = Get-ConfiguredCudaPath -RequestedCudaPath $CudaPath

Write-Section 'Environment'
Write-Host "Project root: $ProjectRoot"
Write-Host "Configuration: $Configuration"
Write-Host "Build channel: $BuildChannel"
Write-Host "Build directory: $BuildDirectory"
Write-Host "Install directory: $InstallDirectory"
Write-Host "Package output directory: $PackageOutputDirectory"
Write-Host "VCPKG_ROOT: $VcpkgRoot"
Write-Host "VCPKG_INSTALLED_DIR: $VcpkgInstalledDirectory"

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

$clangClPath = Get-ClangClPathForVcVarsPath -VcVarsPath $vcVarsPath
if ([string]::IsNullOrWhiteSpace($clangClPath)) {
    $selectedVisualStudioRoot = Split-Path (Split-Path (Split-Path (Split-Path $vcVarsPath -Parent) -Parent) -Parent) -Parent
    throw "clang-cl was not found. In Visual Studio Installer, modify '$selectedVisualStudioRoot' and add the 'C++ Clang Compiler for Windows' individual component."
}
Add-ToPathIfMissing -Entry (Split-Path -Parent $clangClPath)
Write-Host "clang-cl: $clangClPath"

if ($Clean) {
    Write-Section 'Clean'
    Clear-BuildDirectory -BuildDirectory $BuildDirectory -VcpkgInstalledDirectory $VcpkgInstalledDirectory -RemoveDependencies:$CleanDependencies
    if (Test-Path $InstallDirectory) {
        Write-Host "Removing $InstallDirectory"
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
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
$env:CUDA_PATH = $resolvedCudaPath
$env:CUDACXX = Join-Path $resolvedCudaPath 'bin\nvcc.exe'
Add-ToPathIfMissing -Entry (Join-Path $resolvedCudaPath 'bin')
Add-ToPathIfMissing -Entry (Join-Path $resolvedCudaPath 'bin\x64')
Add-ToPathIfMissing -Entry (Join-Path $resolvedCudaPath 'libnvvp')

$resolvedCudnnRoot = $null
if (-not [string]::IsNullOrWhiteSpace($CudnnRoot)) {
    $resolvedCudnnRoot = [System.IO.Path]::GetFullPath($CudnnRoot)
} else {
    $configuredCudnnRoot = Get-EnvironmentValue -Name 'CUDNN_ROOT_DIR'
    if (-not [string]::IsNullOrWhiteSpace($configuredCudnnRoot)) {
        $resolvedCudnnRoot = [System.IO.Path]::GetFullPath($configuredCudnnRoot)
    }
}
if ([string]::IsNullOrWhiteSpace($resolvedCudnnRoot) -and (Test-Path (Join-Path $resolvedCudaPath 'include\cudnn.h'))) {
    $resolvedCudnnRoot = $resolvedCudaPath
}

if ([string]::IsNullOrWhiteSpace($resolvedCudnnRoot) -or -not (Test-Path $resolvedCudnnRoot)) {
    throw 'cuDNN was not found. Pass -CudnnRoot or set CUDNN_ROOT_DIR to a cuDNN 9 installation.'
}
$env:CUDNN_ROOT_DIR = $resolvedCudnnRoot
Write-Host "cuDNN root: $resolvedCudnnRoot"

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
$env:VCPKG_INSTALLED_DIR = $VcpkgInstalledDirectory
$configuredBinarySources = Get-EnvironmentValue -Name 'VCPKG_BINARY_SOURCES'
if ([string]::IsNullOrWhiteSpace($configuredBinarySources)) {
    $vcpkgBinaryCacheDirectory = Join-Path $env:LOCALAPPDATA 'vcpkg\archives\lichtfeld-release'
    New-Item -ItemType Directory -Force -Path $vcpkgBinaryCacheDirectory | Out-Null
    $env:VCPKG_BINARY_SOURCES = "clear;files,$vcpkgBinaryCacheDirectory,readwrite"
} else {
    $env:VCPKG_BINARY_SOURCES = $configuredBinarySources
}
Write-Host "vcpkg binary sources: $($env:VCPKG_BINARY_SOURCES)"
$vcpkgBuildtreesDirectory = Join-Path $env:LOCALAPPDATA 'vcpkg\buildtrees\lichtfeld'
New-Item -ItemType Directory -Force -Path $vcpkgBuildtreesDirectory | Out-Null
Write-Host "vcpkg transient build trees: $vcpkgBuildtreesDirectory"
$vcpkgPackagesDirectory = Join-Path $env:LOCALAPPDATA 'vcpkg\packages\lichtfeld'
New-Item -ItemType Directory -Force -Path $vcpkgPackagesDirectory | Out-Null
Write-Host "vcpkg transient package staging: $vcpkgPackagesDirectory"
$vcpkgDownloadsDirectory = Join-Path $env:LOCALAPPDATA 'vcpkg\downloads\lichtfeld'
New-Item -ItemType Directory -Force -Path $vcpkgDownloadsDirectory | Out-Null
Write-Host "vcpkg downloads and tools: $vcpkgDownloadsDirectory"
$vcpkgTargetTriplet = 'x64-windows-release'
$vcpkgHostTriplet = 'x64-windows-release'
Write-Host "vcpkg target triplet: $vcpkgTargetTriplet"
Write-Host "vcpkg host triplet: $vcpkgHostTriplet"
$vcpkgToolchainFile = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path $vcpkgToolchainFile)) {
    throw "vcpkg toolchain file was not found at $vcpkgToolchainFile"
}

$vcpkgTripletsDirectory = Join-Path $BuildDirectory 'vcpkg-triplets'
New-Item -ItemType Directory -Force -Path $vcpkgTripletsDirectory | Out-Null
$tripletFile = Join-Path $vcpkgTripletsDirectory "$vcpkgTargetTriplet.cmake"
$tripletLines = @(
    'set(VCPKG_TARGET_ARCHITECTURE x64)',
    'set(VCPKG_CRT_LINKAGE dynamic)',
    'set(VCPKG_LIBRARY_LINKAGE dynamic)',
    'set(VCPKG_BUILD_TYPE release)'
)
if (-not [string]::IsNullOrWhiteSpace($vcpkgPlatformToolset)) {
    $tripletLines += "set(VCPKG_PLATFORM_TOOLSET $vcpkgPlatformToolset)"
}
Set-Content -LiteralPath $tripletFile -Value $tripletLines -Encoding utf8
Write-Host "vcpkg overlay triplet: $tripletFile"

New-Item -ItemType Directory -Force -Path $PackageOutputDirectory | Out-Null

$configureArguments = @(
    '-B', $BuildDirectory,
    '-S', $ProjectRoot,
    '-G', 'Ninja',
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchainFile",
    "-DVCPKG_INSTALLED_DIR=$VcpkgInstalledDirectory",
    "-DVCPKG_TARGET_TRIPLET=$vcpkgTargetTriplet",
    "-DVCPKG_HOST_TRIPLET=$vcpkgHostTriplet",
    "-DVCPKG_OVERLAY_TRIPLETS=$vcpkgTripletsDirectory",
    "-DCMAKE_BUILD_TYPE=$Configuration",
    "-DCMAKE_MAKE_PROGRAM=$ninjaPath",
    "-DCMAKE_CUDA_COMPILER=$($env:CUDACXX)",
    "-DCUDAToolkit_ROOT=$resolvedCudaPath",
    "-DCUDNN_ROOT_DIR=$resolvedCudnnRoot",
    '-DCMAKE_INSTALL_MESSAGE=LAZY',
    "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=$vcpkgBuildtreesDirectory;--x-packages-root=$vcpkgPackagesDirectory;--downloads-root=$vcpkgDownloadsDirectory;--clean-buildtrees-after-build;--clean-packages-after-build;--no-print-usage",
    '-DBUILD_PORTABLE=ON',
    '-DBUILD_PYTHON_STUBS=OFF',
    '-DCUDA_DEVICE_DEBUG=OFF'
)

$configureCommand = (Join-CmdArguments -Arguments @($cmakePath)) + ' ' + (Join-CmdArguments -Arguments $configureArguments)
$retryablePatterns = @(
    'status code 5\d\d',
    'timed out',
    'timeout',
    'connection reset',
    'failed to connect',
    'temporarily unavailable',
    'curl operation failed',
    'Download failed',
    'TLS (connection|handshake|certificate|error|failure)',
    'SSL (connection|handshake|certificate|error|failure)'
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

        Write-Host 'Retryable configure failure detected. Cleaning project build outputs before retry.' -ForegroundColor Yellow
        Clear-BuildDirectory -BuildDirectory $BuildDirectory -VcpkgInstalledDirectory $VcpkgInstalledDirectory
        Start-Sleep -Seconds (15 * $attempt)
    }
}

Write-Section 'Build'
$buildArguments = @('--build', $BuildDirectory, '-j', '%NUMBER_OF_PROCESSORS%')
$buildCommand = (Join-CmdArguments -Arguments @($cmakePath)) + ' ' + (Join-CmdArguments -Arguments $buildArguments)
Invoke-VcCommand -VcVarsPath $vcVarsPath -WorkingDirectory $ProjectRoot -Command $buildCommand -ToolsetVersion $msvcToolsetVersion -WindowsSdkInfo $windowsSdkInfo

Write-Section 'Install'
$installArguments = @('--install', $BuildDirectory, '--prefix', $InstallDirectory)
$installCommand = (Join-CmdArguments -Arguments @($cmakePath)) + ' ' + (Join-CmdArguments -Arguments $installArguments)
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

Write-Section 'Dependency Cleanup'
foreach ($transientPath in @($vcpkgBuildtreesDirectory, $vcpkgPackagesDirectory, $vcpkgDownloadsDirectory)) {
    if (Test-Path -LiteralPath $transientPath) {
        Write-Host "Removing transient vcpkg data: $transientPath"
        Remove-Item -LiteralPath $transientPath -Recurse -Force
    }
}

Write-Section 'Done'
Write-Host "Build completed successfully."
Write-Host "Installed files: $InstallDirectory"
if ($packagePath) {
    Write-Host "Zip package: $packagePath"
}
