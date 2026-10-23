# SPDX-License-Identifier: GPL-3.0-only
param(
    [string]$SshTarget = 'xodus-mac',
    [string]$HostName,
    [string]$HostKeyAlias,
    [ValidatePattern('^xodus-app-tooling/[A-Za-z0-9_-]+$')]
    [string]$RemoteDirectory = 'xodus-app-tooling/app-foundation',
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$archive = Join-Path ([IO.Path]::GetTempPath()) ("xodus-public-app-" + [guid]::NewGuid() + ".tar")
$options = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=yes')
if ($HostName) { $options += @('-o', "HostName=$HostName") }
if ($HostKeyAlias) { $options += @('-o', "HostKeyAlias=$HostKeyAlias") }
Push-Location $root
try {
    python tools\sync_contract.py
    if ($LASTEXITCODE -ne 0) { throw 'Schema resource generation failed.' }
    python tools\sync_runtime_provider_contract.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Pinned runtime provider schema resource differs.' }
    & tar -cf $archive Package.swift Sources Tests tools docs README.md PRODUCT.md DESIGN.md LICENSE
    if ($LASTEXITCODE -ne 0) { throw 'Public source archive failed.' }
    & scp @options $archive "${SshTarget}:${RemoteDirectory}/xodus-public-app-transfer.tar"
    if ($LASTEXITCODE -ne 0) { throw 'Trusted SSH source transfer failed.' }
    $script = @"
set -eu
cd "`$HOME/$RemoteDirectory"
tar -xf xodus-public-app-transfer.tar
rm xodus-public-app-transfer.tar
python3 -c 'from pathlib import Path; [p.write_bytes(p.read_bytes().replace(b"\r\n", b"\n")) for p in Path("tools").glob("*.sh")]'
"@
    if ($Check) { $script += "`nsh tools/check.sh`n" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script.Replace("`r`n", "`n")))
    & ssh @options -T $SshTarget "printf '%s' '$encoded' | /usr/bin/base64 -D | /bin/sh"
    if ($LASTEXITCODE -ne 0) { throw 'Isolated Mac synchronization or checks failed.' }
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
}
