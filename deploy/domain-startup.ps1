# What each machine of a domain runs at startup, as SYSTEM, once domain-rollout.ps1 has set the policy up.
# It installs garrett from the domain's share when this machine does not have it, and does nothing when it does.
#
# garrett updates itself after that, so a machine that has it is never installed over from the share. A machine
# whose "garrett" task was removed or switched off gets it back at its next start.
# What happened is written to <Windows>\Temp\garrett-rollout.log on the machine.
$ErrorActionPreference = 'Stop'
$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$log = Join-Path $windows 'Temp\garrett-rollout.log'
function Say([string]$line) { try { Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z ' + $line) -Encoding utf8 } catch {} }
try {
  $share = Split-Path -Parent $PSScriptRoot
  $agent = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'garrett\garrett.exe'
  $task = Get-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue
  if ($task -and (Test-Path -LiteralPath $agent)) {
    if ([string]$task.State -eq 'Disabled') { Enable-ScheduledTask -TaskName 'garrett' | Out-Null; Start-ScheduledTask -TaskName 'garrett'; Say 'The garrett task was switched off. It was switched on again and started.' }
    exit 0
  }
  # The network is often not up yet when startup scripts run: the share is waited for, for up to three minutes.
  $source = Join-Path $share 'garrett.exe'
  $until = (Get-Date).AddMinutes(3)
  while (-not (Test-Path -LiteralPath $source) -and (Get-Date) -lt $until) { Start-Sleep -Seconds 5 }
  if (-not (Test-Path -LiteralPath $source)) { throw "The share $share could not be read." }
  # Installed from a copy only SYSTEM and administrators can read, removed afterwards: it holds the enrolment key.
  $staging = Join-Path $windows ('Temp\garrett-rollout-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    & (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'icacls.exe') $staging /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The staging folder could not be locked.' }
    New-Item -ItemType Directory -Path (Join-Path $staging 'deploy') | Out-Null
    foreach ($name in 'garrett.exe', 'garrett.conf', 'LICENSE', 'NOTICES.md', 'deploy\install-windows.ps1') {
      $from = Join-Path $share $name
      if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $staging $name) }
    }
    $said = & (Join-Path $staging 'deploy\install-windows.ps1') 2>&1 | Out-String
    Say ('Installed from ' + $share + '. ' + $said.Trim())
  } finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
} catch { Say ('Not installed: ' + $_.Exception.Message); exit 1 }
