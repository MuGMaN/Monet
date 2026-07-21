<#
Build + sign the Windows NSIS installer for a Monet release.

This is the trusted-local-build counterpart to release-linux.sh / the macOS DMG
build: no CI runner, releases are cut by hand on a trusted Windows machine.

Prerequisites on the build machine:
  - Rust MSVC toolchain (rustup + VS Build Tools "Desktop development with C++")
  - cargo-tauri (cargo install tauri-cli), and the WebView2 runtime
  - The updater SIGNING KEY exported into the environment BEFORE running (the
    minisign keys from `cargo tauri signer generate`; the matching PUBLIC key is
    committed in tauri.conf.json -> plugins.updater.pubkey):
        $env:TAURI_SIGNING_PRIVATE_KEY = (Get-Content $HOME\.monet-signing\monet_updater.key -Raw).Trim()
        $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = (Get-Content $HOME\.monet-signing\monet_updater.pw -Raw).Trim()

Usage:
  desktop\scripts\release-windows.ps1 1.0.21   # no leading v

Outputs the per-user NSIS installer (.exe) and its detached .sig. Hand both to
the release coordinator (run on the Mac, which has the GitLab token) to upload to
the generic package registry and add the `windows-x86_64` entry to latest.json.
#>
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'

# desktop\src-tauri, resolved relative to this script (desktop\scripts\).
$srcTauri = Join-Path (Split-Path -Parent $PSScriptRoot) 'src-tauri'
Set-Location $srcTauri

# The bundle version must match the release version, or the updater's
# version comparison (manifest vs running app) will be wrong.
$cfgVer = (Get-Content tauri.conf.json -Raw | ConvertFrom-Json).version
if ($cfgVer -ne $Version) { throw "tauri.conf.json version ($cfgVer) != $Version" }
if (-not $env:TAURI_SIGNING_PRIVATE_KEY) { throw 'export TAURI_SIGNING_PRIVATE_KEY (+ _PASSWORD) first' }

# createUpdaterArtifacts=true + the signing env emits the detached <setup>.exe.sig.
& cargo-tauri build --bundles nsis
if ($LASTEXITCODE -ne 0) { throw 'cargo-tauri build failed' }

$exe = Get-ChildItem 'target\release\bundle\nsis\*-setup.exe' | Select-Object -First 1
$sig = "$($exe.FullName).sig"
if (-not $exe) { throw 'no setup.exe produced' }
if (-not (Test-Path $sig)) { throw 'no .sig — signing key not applied' }

Write-Output "installer: $($exe.FullName)"
Write-Output "signature: $sig"
