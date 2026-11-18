# Put garrett on every machine of an Active Directory domain, with Group Policy.
#
# Run it once, as a domain administrator, on a domain controller (or any machine with the Group Policy and Active
# Directory PowerShell modules), from the unpacked release bundle (garrett-windows.zip):
#   .\deploy\domain-rollout.ps1 [-Server https://your-service -EnrollKey <key>] [-Mode kill|decide|pause|report]
#                               [-Update on|off] [-Target "OU=Servers,DC=example,DC=org"] [-Name garrett]
#   .\deploy\domain-rollout.ps1 -Remove
#
# What it does:
#   1. copies the agent and its installer to the domain's own share, \\<domain>\SYSVOL\<domain>\scripts\garrett,
#      which every domain controller carries, with a garrett.conf holding the options above;
#   2. lets only the domain's computers and its administrators read that folder, because the enrolment key is in it;
#   3. makes a Group Policy object named "garrett" whose one setting is a startup script (domain-startup.ps1);
#   4. links it to the whole domain, or to the -Target you give.
# Each machine then installs garrett the next time it starts, domain controllers included, and reports to the
# service if you gave one. A machine that already has garrett is left alone: it keeps itself up to date.
# With no -Server every machine protects itself and keeps its cases to itself.
#
# -Remove takes the policy and the share away again. It does not uninstall garrett from machines that have it:
# use uninstall-windows.ps1 on those.
param(
  [string]$Server = '',
  [string]$EnrollKey = '',
  [ValidateSet('', 'kill', 'decide', 'pause', 'report')][string]$Mode = '',
  [ValidateSet('', 'on', 'off')][string]$Update = '',
  [string]$Target = '',
  [string]$Name = 'garrett',
  [switch]$Remove
)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
if ([bool]$Server -ne [bool]$EnrollKey) { throw 'Give -Server and -EnrollKey together, or neither.' }
if ($Server -and $Server -notmatch '^https://[^/\s]+$') { throw "Give the service's address only, for example https://sentinel.example.org" }
foreach ($module in 'GroupPolicy', 'ActiveDirectory') { if (-not (Get-Module -ListAvailable -Name $module)) { throw "The $module PowerShell module is not installed here. Run this on a domain controller." } }
Import-Module GroupPolicy, ActiveDirectory
$domain = Get-ADDomain
$dns = $domain.DNSRoot
if (-not $Target) { $Target = $domain.DistinguishedName }
$share = "\\$dns\SYSVOL\$dns\scripts\garrett"
$system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)

if ($Remove) {
  $old = Get-GPO -Name $Name -ErrorAction SilentlyContinue
  if ($old) { Remove-GPO -Guid $old.Id; Write-Output "The policy $Name was removed." }
  if (Test-Path -LiteralPath $share) { Remove-Item -LiteralPath $share -Recurse -Force; Write-Output "The share $share was removed." }
  Write-Output 'Machines that have garrett keep it. Remove it from a machine with uninstall-windows.ps1.'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
$agent = @((Join-Path $root 'garrett.exe'), (Join-Path $root 'rust\target\release\garrett.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $agent) { throw 'garrett.exe was not found. Use the release bundle, or build it first: cd rust; cargo build --release --locked' }
foreach ($file in 'install-windows.ps1', 'domain-startup.ps1') { if (-not (Test-Path (Join-Path $PSScriptRoot $file))) { throw "$file was not found beside this script." } }

# 1 and 2. The share. Its permissions are set before anything is put in it.
New-Item -ItemType Directory -Force -Path (Join-Path $share 'deploy') | Out-Null
$sid = $domain.DomainSID.Value
# SYSTEM, the built-in and the domain's administrators: everything. Domain computers and domain controllers: read.
& (Join-Path $system32 'icacls.exe') $share /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$sid-512:(OI)(CI)F" "*$sid-515:(OI)(CI)RX" "*$sid-516:(OI)(CI)RX" '*S-1-5-9:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The share could not be locked.' }
Copy-Item -LiteralPath $agent -Destination (Join-Path $share 'garrett.exe') -Force
foreach ($file in 'install-windows.ps1', 'domain-startup.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $share "deploy\$file") -Force }
foreach ($file in 'LICENSE', 'NOTICES.md') { $from = @((Join-Path $root $file), (Join-Path $root "rust\$file")) | Where-Object { Test-Path $_ } | Select-Object -First 1; if ($from) { Copy-Item -LiteralPath $from -Destination (Join-Path $share $file) -Force } }
$lines = @()
if ($Server) { $lines += "SERVER=$Server"; $lines += "ENROLL_KEY=$EnrollKey" }
if ($Mode) { $lines += "MODE=$Mode" }
if ($Update) { $lines += "UPDATE=$Update" }
Set-Content -LiteralPath (Join-Path $share 'garrett.conf') -Value $lines -Encoding ascii

# 3. The policy: one computer startup script. Group Policy keeps startup scripts in a file inside the policy's
# folder (Machine\Scripts\scripts.ini), names the part of Windows that reads it on the policy object, and counts
# changes in a version number kept in two places. All three are written here.
$gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $Name -Comment 'Installs garrett, the Sentinel agent, on each machine at startup.' }
$id = '{' + $gpo.Id.ToString().ToUpper() + '}'
$folder = "\\$dns\SYSVOL\$dns\Policies\$id"
foreach ($sub in 'Machine\Scripts\Startup', 'Machine\Scripts\Shutdown') { New-Item -ItemType Directory -Force -Path (Join-Path $folder $sub) | Out-Null }
$ini = Join-Path $folder 'Machine\Scripts\scripts.ini'
$script = "$share\deploy\domain-startup.ps1"
if (Test-Path -LiteralPath $ini) { (Get-Item -LiteralPath $ini -Force).Attributes = 'Normal' }
Set-Content -LiteralPath $ini -Encoding Unicode -Value @('', '[Startup]', '0CmdLine=powershell.exe', "0Parameters=-NoProfile -ExecutionPolicy Bypass -File `"$script`"")
(Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden'
$object = "CN=$id,CN=Policies,CN=System,$($domain.DistinguishedName)"
$version = [int](Get-ADObject -Identity $object -Properties versionNumber).versionNumber + 1   # the low half counts computer settings
Set-ADObject -Identity $object -Replace @{ gPCMachineExtensionNames = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'; versionNumber = $version }
Set-Content -LiteralPath (Join-Path $folder 'GPT.INI') -Encoding ascii -Value @('[General]', "Version=$version", "displayName=$Name")

# 4. The link.
$linked = (Get-GPInheritance -Target $Target).GpoLinks | Where-Object { $_.GpoId -eq $gpo.Id }
if (-not $linked) { New-GPLink -Guid $gpo.Id -Target $Target -LinkEnabled Yes | Out-Null }
Write-Output "The policy $Name is linked to $Target. Each machine there installs garrett at its next start."
Write-Output "The agent and its options are in $share, readable by the domain's computers and administrators only."
if ($Server) { Write-Output "Machines will report to $Server." } else { Write-Output 'No service was given: every machine protects itself and keeps its cases to itself.' }
