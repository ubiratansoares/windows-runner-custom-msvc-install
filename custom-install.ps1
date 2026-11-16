#requires -Version 7.3

# Test MSVC 14.53 preview while investigating #165953.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$vcvars_ver = 'preview'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    throw 'Run this script in a GitHub Actions step with GITHUB_ENV available.'
}

$installer_dir = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$vswhere = Join-Path $installer_dir 'vswhere.exe'
$setup = Join-Path $installer_dir 'setup.exe'
$vs_install = & $vswhere -latest -products '*' -version '[18.0,19.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vs_install)) {
    throw 'Visual Studio 2026 with the ARM64 build tools was not found.'
}
$vs_install = $vs_install.Trim()

# Preview tools can be added to the existing stable Visual Studio installation.
# Start-Process waits for setup.exe; the installer's --wait flag is bootstrapper-only.
Write-Host "Installing MSVC ARM64 preview and ATL into $vs_install"
$install_args = @(
    'modify'
    '--installPath', ('"{0}"' -f $vs_install)
    '--add', 'Microsoft.VisualStudio.Component.VC.Preview.ARM64'
    '--add', 'Microsoft.VisualStudio.Component.VC.Preview.ATL.ARM64'
    '--quiet'
    '--norestart'
)
$install = Start-Process -FilePath $setup -ArgumentList $install_args `
    -WorkingDirectory $env:TEMP -Wait -PassThru
if ($install.ExitCode -notin 0, 3010) {
    throw "Visual Studio Installer failed with exit code $($install.ExitCode). See $env:TEMP\dd_*.log."
}
if ($install.ExitCode -eq 3010) {
    Write-Warning 'Visual Studio Installer requested a reboot; continuing with toolset validation.'
}

$vcvarsall = Join-Path $vs_install 'VC\Auxiliary\Build\vcvarsall.bat'
# Print initialization diagnostics before capturing the environment in a fresh cmd process.
& $env:ComSpec /d /c "call `"$vcvarsall`" arm64 -vcvars_ver=$vcvars_ver"
$new = & $env:ComSpec /d /c "call `"$vcvarsall`" arm64 -vcvars_ver=$vcvars_ver > nul && set"
$new_env = @{}
foreach ($line in $new) {
    # Split at the first '=' and exclude cmd.exe's special '=C:' drive entries.
    if ($line -match '^([^=]+)=(.*)$') {
        $new_env[$Matches[1]] = $Matches[2]
    }
}

# The preview selector moves over time; never silently test a different release.
$toolset_version = $new_env['VCToolsVersion']
if ($toolset_version -notmatch '^14\.53\.\d+(\.\d+)?$') {
    throw "Expected MSVC 14.53 preview, but vcvarsall selected '$toolset_version'."
}
if ($new_env['VSCMD_ARG_HOST_ARCH'] -ne 'arm64' -or
    $new_env['VSCMD_ARG_TGT_ARCH'] -ne 'arm64') {
    throw 'Expected native ARM64 tools targeting ARM64.'
}

$toolset_dir = Join-Path $vs_install "VC\Tools\MSVC\$toolset_version"
$atl_include = Join-Path $toolset_dir 'atlmfc\include'
$atl_lib = Join-Path $toolset_dir 'atlmfc\lib\arm64'
$cl = Join-Path $toolset_dir 'bin\Hostarm64\arm64\cl.exe'
$link = Join-Path $toolset_dir 'bin\Hostarm64\arm64\link.exe'
foreach ($file in @($cl, $link, "$atl_include\atlbase.h", "$atl_lib\atls.lib")) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "The selected preview toolset is incomplete: $file is missing."
    }
}

# Keep LLVM's ATL dependency in the selected toolset, even with other versions installed.
$new_env['INCLUDE'] = "$atl_include;$($new_env['INCLUDE'])"
$new_env['LIB'] = "$atl_lib;$($new_env['LIB'])"
# Exercise LLVM built with this compiler instead of downloading a CI-built LLVM.
$new_env['NO_DOWNLOAD_CI_LLVM'] = '1'
$old_env = [Environment]::GetEnvironmentVariables('Process')
$updates = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $new_env.GetEnumerator()) {
    if ($old_env[$entry.Key] -cne $entry.Value) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        $updates.Add("$($entry.Key)=$($entry.Value)")
    }
}

# Validate PATH before exporting anything to subsequent Actions steps.
foreach ($expected in @($cl, $link)) {
    $command = Get-Command (Split-Path $expected -Leaf) -CommandType Application
    if ($command.Source -ine $expected) {
        throw "Expected '$expected' on PATH, but found '$($command.Source)'."
    }
    $version = (Get-Item -LiteralPath $expected).VersionInfo.FileVersion
    Write-Host "$($command.Source) (file version $version)"
}
Write-Host "VCToolsVersion=$toolset_version; host=arm64; target=arm64"

# Export each variable's new value only, preserving the entire value after '='.
Add-Content -LiteralPath $env:GITHUB_ENV -Value $updates -Encoding utf8
