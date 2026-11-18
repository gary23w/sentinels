# Install garrett, the Sentinel agent, to run as SYSTEM at startup (a scheduled task named "garrett").
#
# The release bundle (garrett-windows.zip) carries the agent, one program file: double-click "Install garrett.cmd"
# in it. From this repository, build it first (cd rust; cargo build --release --locked), then run from an elevated
# PowerShell:
#   .\install-windows.ps1 [-Server https://your-service -EnrollKey <key>] [-Mode kill|decide|pause|report] [-Update off]
#
# With no -Server, garrett protects this machine by itself and keeps its cases here.
# A garrett.conf beside the installer (lines SERVER=, ENROLL_KEY=, MODE=, LABEL=) does the same as the options,
# so a management tool can install a whole fleet silently.
# The mode defaults to kill: a hostile program and everything it started is ended at once.
# Running as SYSTEM lets the agent read every process and, on a domain controller or server, the Security event
# log (Kerberoasting, DCSync, failed sign-in bursts, cleared logs, privileged group changes).
# Once installed, garrett installs each new version by itself, after checking that the project signed it
# (-Update off, or UPDATE=off in garrett.conf, turns that off).
# Remove it again with uninstall-windows.ps1.
param(
  [string]$Server = '',
  [string]$EnrollKey = '',
  [ValidateSet('', 'kill', 'decide', 'pause', 'report')][string]$Mode = '',
  [string]$Label = '',
  [ValidateSet('', 'on', 'off')][string]$Clean = '',
  [ValidateSet('', 'on', 'off')][string]$Update = ''
)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$root = Split-Path -Parent $PSScriptRoot
# Options left out are read from garrett.conf beside the installer, if there is one.
$conf = Join-Path $root 'garrett.conf'
if (Test-Path $conf) {
  foreach ($line in Get-Content $conf) {
    if ($line -match '^CLEAN=(on|off)\s*$' -and -not $Clean) { $Clean = $Matches[1] }
    if ($line -match '^UPDATE=(on|off)\s*$' -and -not $Update) { $Update = $Matches[1] }
    if ($line -match '^(SERVER|ENROLL_KEY|MODE|LABEL)=(.+)$') {
      switch ($Matches[1]) { 'SERVER' { if (-not $Server) { $Server = $Matches[2].Trim() } } 'ENROLL_KEY' { if (-not $EnrollKey) { $EnrollKey = $Matches[2].Trim() } } 'MODE' { if (-not $Mode) { $Mode = $Matches[2].Trim() } } 'LABEL' { if (-not $Label) { $Label = $Matches[2].Trim() } } }
    }
  }
}
if (-not $Mode) { $Mode = 'kill' }
if ($Mode -notin @('kill', 'decide', 'pause', 'report')) { throw 'The Sentinel mode is not valid.' }
# -Clean off: stop hostile programs but leave their files and startup entries alone.
if (-not $Clean) { $Clean = 'on' }
if (-not $Update) { $Update = 'on' }
if ([bool]$Server -ne [bool]$EnrollKey) { throw 'Give -Server and -EnrollKey together, or neither.' }
$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if (-not $windows -or -not $system32 -or -not $programFiles -or -not $programData) { throw 'The Windows system folders are not available.' }
$env:PATH = $system32 + ';' + $windows + ';' + (Join-Path $system32 'WindowsPowerShell\v1.0')
$icacls = Join-Path $system32 'icacls.exe'
$install = Join-Path $programFiles 'garrett'
$state = Join-Path $programData 'garrett'

function Lock-Directory([string]$path, [bool]$readable) {
  if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A Sentinel directory is a reparse point.' }
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
  if ($readable) { $grants += '*S-1-5-32-545:(OI)(CI)RX' }
  & $icacls $path /inheritance:r /grant:r $grants | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'A Sentinel directory could not be locked.' }
  & $icacls $path /setowner '*S-1-5-32-544' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'A Sentinel directory owner could not be locked.' }
  $acl = Get-Acl -LiteralPath $path
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'A Sentinel directory owner is not protected.' }
  $allowed = @('S-1-5-18', 'S-1-5-32-544') + $(if ($readable) { 'S-1-5-32-545' })
  $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  if (@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed }).Count) { throw 'A Sentinel directory allows another account to modify it.' }
}

function Lock-File([string]$path) {
  if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A Sentinel program file is a reparse point.' }
  & $icacls $path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' '*S-1-5-32-545:RX' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'A Sentinel program file could not be locked.' }
  & $icacls $path /setowner '*S-1-5-32-544' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'A Sentinel program file owner could not be locked.' }
  $acl = Get-Acl -LiteralPath $path
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'A Sentinel program file owner is not protected.' }
  $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  if (@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545') }).Count) { throw 'A Sentinel program file allows another account to modify it.' }
}
# The agent: beside the installer in the release bundle, or built in this checkout.
$source = @((Join-Path $root 'garrett.exe'), (Join-Path $root 'rust\target\release\garrett.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $source) { throw 'garrett.exe was not found. Use the release bundle, or build it first: cd rust; cargo build --release --locked' }
if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The Sentinel program source is a reparse point.' }
Lock-Directory $install $true
Lock-Directory $state $false
$known = @('garrett.exe', 'garrett.cmd', 'garrett-old.exe', 'garrett-new.exe', 'LICENSE', 'NOTICES.md')
foreach ($item in Get-ChildItem -LiteralPath $install -Force) {
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Name -notin $known) { throw 'The Sentinel program directory contains an unexpected file.' }
}
if (Get-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
$agent = Join-Path $install 'garrett.exe'
foreach ($name in $known) {
  $old = Join-Path $install $name
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
}
Copy-Item -LiteralPath $source -Destination $agent
Lock-File $agent
foreach ($notice in 'LICENSE', 'NOTICES.md') {
  $sourceNotice = Join-Path $root $notice
  if (Test-Path -LiteralPath $sourceNotice) {
    $targetNotice = Join-Path $install $notice
    Copy-Item -LiteralPath $sourceNotice -Destination $targetNotice
    Lock-File $targetNotice
  }
}
# The command people type: "C:\Program Files\garrett\garrett.cmd" cases
Set-Content -Path (Join-Path $install 'garrett.cmd') -Encoding ascii -Value ('@"' + $agent + '" --state-dir "' + $state + '" %*')
Lock-File (Join-Path $install 'garrett.cmd')
# This binary locks and checks every existing state entry before it reads the saved credential.
& $agent --state-dir $state status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The Sentinel state could not be protected.' }
if ($Server -and -not (Test-Path (Join-Path $state 'agent.json'))) {
  $env:SENTINEL_ENROLL_KEY = $EnrollKey
  $arguments = @('--state-dir', $state, 'enroll', '--patient', '--server', $Server, '--mode', $Mode)
  if ($Label) { $arguments += @('--label', $Label) }
  try { & $agent @arguments } finally { Remove-Item Env:SENTINEL_ENROLL_KEY }
  if ($LASTEXITCODE -ne 0) { throw 'Enrolment failed. Check the service address and the enrolment key.' }
}
$system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$run = New-ScheduledTaskAction -Execute $agent -Argument ("--state-dir `"$state`" run --mode $Mode --clean $Clean --update $Update")
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
# It starts with the machine. It is also asked to start every ten minutes, which does nothing while it runs and
# brings it back if it ever stopped, for instance between an update and the new version starting.
$often = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'garrett' -Action $run -Trigger (New-ScheduledTaskTrigger -AtStartup), $often -Principal $system -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'garrett'
if ($Server) { Write-Output "garrett is running as SYSTEM and reporting to $Server." }
else { Write-Output ('garrett is running as SYSTEM and protecting this machine by itself. See what it finds: "' + (Join-Path $install 'garrett.cmd') + '" cases') }
