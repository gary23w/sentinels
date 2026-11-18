# Turn this Windows machine into your own Sentinel service, in one line. Free: it runs on your machine, nothing is
# sent anywhere else, and there is no account. From an elevated PowerShell:
#   irm https://gary23w.github.io/sentinels/service.ps1 | iex
# It prints the command that joins your other machines (Windows, Linux, macOS) to it.
# To choose the port or the address other machines reach this one by, set these first in the same window:
#   $env:GARRETT_PORT = '8443'; $env:GARRETT_ADDRESS = 'sentinel.example.internal'
# It downloads garrett-service-windows.zip, checks it against this script's pinned SHA-256, and runs its installer.
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$base = if ($env:GARRETT_BASE) { $env:GARRETT_BASE } else { 'https://gary23w.github.io/sentinels' }
$pinnedServiceZip = '800af7e73dbe2e2bb19ecec0a6a4532e1fc4a8c87935d354388827070384dd9a'
$work = Join-Path ([IO.Path]::GetTempPath()) ('garrett-service-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $zip = Join-Path $work 'garrett-service-windows.zip'
  Invoke-WebRequest -UseBasicParsing -Uri "$base/garrett-service-windows.zip" -OutFile $zip
  $have = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
  if ($pinnedServiceZip -ne $have) { throw 'The download failed its pinned hash check. Nothing was installed.' }
  Expand-Archive -Path $zip -DestinationPath $work
  $arguments = @{ Command = 'install' }
  if ($env:GARRETT_PORT) { $arguments.Port = [int]$env:GARRETT_PORT }
  if ($env:GARRETT_ADDRESS) { $arguments.Address = $env:GARRETT_ADDRESS }
  & (Join-Path $work 'garrett-service\garrett-service.ps1') @arguments
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
