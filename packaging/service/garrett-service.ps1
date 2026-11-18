# garrett-service: your own Sentinel service on this Windows machine.
#
#   garrett-service.ps1 install [-Port 8443] [-Address <name or address other machines reach this one by>] [-Memory neuron-db|off]
#                               [-Model crivo-sentinel-v1|off] [-Wizard]
#   garrett-service.ps1 join       the commands that join other machines to this service
#   garrett-service.ps1 devices    the machines that report here
#   garrett-service.ps1 cases      the open cases
#   garrett-service.ps1 setup      a few questions: which model decides (the one that comes with it, or your own), how much it may
#   garrett-service.ps1 token      the operator token, for the API described in the README
#   garrett-service.ps1 remove     remove the service, its model, its keys and its database
#
# Installed, the same commands are:  "C:\Program Files\garrett-service\garrett-service.cmd" join
# The service runs at startup as LOCAL SERVICE (a scheduled task named "garrett-service"), with the official
# Node.js from nodejs.org beside it, its own HTTPS certificate, and one inbound firewall rule for its port.
# Beside this file there may be, as the one-file installer (garrett-sentinels-windows.exe) carries them:
#   node.exe   the Node.js runtime; otherwise the official build is fetched from nodejs.org and checked
#   model\     the decision model that comes with Sentinels (crivo-sentinel-v1): the service runs it in its own
#              process and decides what happens to a frozen program with it, unless -Model off
#   agent\     the Sentinel agent for this machine: installed and joined to this service, so the machine that runs
#              the service is protected too (left alone when garrett is already installed)
# -Wizard asks a few questions first (the port and address, the model that decides or one of your own, how much it
# may decide) instead of taking the defaults.
# Installing again upgrades the program and keeps the keys, the certificate, the database and the settings; only
# what is asked for on the command line changes.
param(
  [ValidateSet('install', 'join', 'devices', 'cases', 'setup', 'token', 'remove')][string]$Command = 'install',
  [int]$Port = 0,
  [string]$Address = '',
  [ValidateSet('', 'neuron-db', 'off')][string]$Memory = '',
  [ValidateSet('', 'crivo-sentinel-v1', 'off')][string]$Model = '',
  [switch]$Wizard
)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$nodeVersion = 'v24.22.3'
$nodeSum = '86fc4785327db5f5c7558dc6156c543b433c313e813a222e088086222ab4afa6'
$base = if ($env:GARRETT_BASE) { $env:GARRETT_BASE } else { 'https://gary23w.github.io/sentinels' }
$install = Join-Path $env:ProgramFiles 'garrett-service'
$data = Join-Path $env:ProgramData 'garrett-service'
$conf = Join-Path $data 'service.conf'
$node = Join-Path $install 'node.exe'
$bundled = 'crivo-sentinel-v1'
$modelHome = Join-Path $install 'model'

function Get-Setting([string]$name) {
  $found = Get-Content $conf | Where-Object { $_ -match ('^' + $name + '=') } | Select-Object -Last 1
  if ($found) { return $found.Substring($name.Length + 1) }
  return ''
}
# The line NAME=value in the configuration file, replacing the one there or added at the end.
function Set-Setting([string]$name, [string]$value) {
  $lines = @(Get-Content $conf); $done = $false; $out = @()
  foreach ($line in $lines) { if ($line -match ('^' + $name + '=')) { if (-not $done) { $out += ($name + '=' + $value); $done = $true } } else { $out += $line } }
  if (-not $done) { $out += ($name + '=' + $value) }
  Set-Content -Path $conf -Encoding ascii -Value $out
}
function New-Key { $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes); return -join ($bytes | ForEach-Object { $_.ToString('x2') }) }
function Invoke-Service([string]$path) { & $node --disable-warning=ExperimentalWarning (Join-Path $install 'ask.mjs') $conf $path }
function Get-Pin {
  $pem = (Get-Content (Join-Path $data 'tls.crt') | Where-Object { $_ -notmatch '^-----' }) -join ''
  return -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($pem)) | ForEach-Object { $_.ToString('x2') })
}
function Show-Join {
  $server = 'https://' + (Get-Setting 'ADDRESS') + ':' + (Get-Setting 'PORT')
  $key = (Get-Setting 'ENROLL_KEY') + '.' + (Get-Pin)
  Write-Output 'Join a Linux or macOS machine (run on that machine):'
  Write-Output ''
  Write-Output "  curl -fsSL $base/install.sh | sudo sh -s -- --server $server --key $key"
  Write-Output ''
  Write-Output 'Join a Windows machine (elevated PowerShell on that machine):'
  Write-Output ''
  Write-Output "  `$env:GARRETT_SERVER='$server'; `$env:GARRETT_KEY='$key'; irm $base/install.ps1 | iex"
  Write-Output ''
  Write-Output 'Anyone who has these commands can add a machine to your service, so keep them private.'
  Write-Output "Machines must be able to reach $server. If they know this machine by another name or address, edit ADDRESS in $conf and run join again."
  Write-Output ('See what they report:  "' + (Join-Path $install 'garrett-service.cmd') + '" devices')
}

if ($Command -eq 'remove') {
  # The agent this installer put on the machine goes with it; one installed any other way stays.
  $agentRemove = Join-Path $install 'agent\deploy\uninstall-windows.ps1'
  if ((Test-Path (Join-Path $data 'agent-installed')) -and (Test-Path $agentRemove)) { try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agentRemove | Out-Null } catch { } }
  if (Get-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'garrett-service' -Confirm:$false }
  Get-NetFirewallRule -DisplayName 'garrett-service' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Start-Sleep -Seconds 2
  if (Test-Path $data) { Remove-Item -Recurse -Force $data }
  if (Test-Path $install) {
    # This may be running from garrett-service.cmd in that folder, which cmd must still find when this returns:
    # everything else goes now, the folder itself a few seconds later.
    Get-ChildItem -Force $install | Where-Object { $_.Name -ne 'garrett-service.cmd' } | Remove-Item -Recurse -Force
    Start-Process cmd.exe -ArgumentList '/c', ('ping -n 3 127.0.0.1 >nul & rmdir /s /q "' + $install + '"') -WindowStyle Hidden -WorkingDirectory $env:SystemRoot
  }
  Write-Output 'The Sentinel service, its model, its keys and its database were removed. Machines that reported to it protect themselves alone until they are enrolled somewhere else.'
  return
}
if ($Command -ne 'install') {
  if (-not (Test-Path $conf)) { throw 'The Sentinel service is not installed on this machine.' }
  switch ($Command) {
    'join' { Show-Join }
    'devices' { Invoke-Service '/v1/devices' }
    'cases' { Invoke-Service '/v1/cases?state=open' }
    'token' { Get-Setting 'ADMIN_TOKEN' }
    'setup' {
      & $node --disable-warning=ExperimentalWarning (Join-Path $install 'setup.mjs') $conf
      if ($LASTEXITCODE -ne 0) { throw 'Setup was not completed. Nothing was changed.' }
      # The model that comes with Sentinels lives where this installer put it.
      if ((Get-Setting 'AI_MODEL') -eq $bundled -and (Get-Setting 'AI_PROVIDER') -eq 'decision') {
        if (-not (Test-Path (Join-Path $modelHome 'model.onnx'))) { Set-Setting 'AI_PROVIDER' 'none'; Set-Setting 'AI_MODEL' ''; throw 'The decision model is not on this machine: install it with the one-file installer, garrett-sentinels-windows.exe.' }
        Set-Setting 'MODEL_DIR' $modelHome
      }
      if (Get-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Start-ScheduledTask -TaskName 'garrett-service' }
      Write-Output 'The service was restarted with these settings.'
    }
  }
  return
}

# install
$here = $PSScriptRoot
$engine = Join-Path $here 'node_modules\@gary23w\neuron-db'
$carriesModel = Test-Path (Join-Path $here 'model\model.onnx')
if ($Memory -eq 'neuron-db' -and -not (Test-Path (Join-Path $engine 'neuron_core.wasm'))) { throw 'This bundle was built without neuron-db, so -Memory neuron-db cannot be used.' }
if ($Model -eq $bundled -and -not $carriesModel) { throw 'This bundle does not carry the decision model. The one-file installer, garrett-sentinels-windows.exe, does.' }
if (Get-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName 'garrett-service' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
New-Item -ItemType Directory -Force -Path $install, (Join-Path $install 'src'), $data | Out-Null
if ($here -ne $install) {
  Copy-Item -Force (Join-Path $here 'serve.mjs'), (Join-Path $here 'sqlite.mjs'), (Join-Path $here 'ask.mjs'), (Join-Path $here 'setup.mjs'), (Join-Path $here 'schema.sql'), (Join-Path $here 'LICENSE'), (Join-Path $here 'garrett-service.ps1') $install
  Copy-Item -Force (Join-Path $here 'src\*.mjs') (Join-Path $install 'src')
  # The packages the bundle carries: the optional memory engine, and what runs the decision model in the service.
  $modules = Join-Path $install 'node_modules'
  if (Test-Path $modules) { Remove-Item -Recurse -Force $modules }
  if (Test-Path (Join-Path $here 'node_modules')) { Copy-Item -Recurse -Force (Join-Path $here 'node_modules') $modules }
  # The decision model, when it is beside this file.
  if ($carriesModel) {
    if (Test-Path $modelHome) { Remove-Item -Recurse -Force $modelHome }
    Copy-Item -Recurse -Force (Join-Path $here 'model') $modelHome
  }
  # The agent's installer and remover, kept for later.
  if (Test-Path (Join-Path $here 'agent\deploy')) {
    $agentHome = Join-Path $install 'agent'
    if (Test-Path $agentHome) { Remove-Item -Recurse -Force $agentHome }
    New-Item -ItemType Directory -Force -Path $agentHome | Out-Null
    Copy-Item -Recurse -Force (Join-Path $here 'agent\deploy') (Join-Path $agentHome 'deploy')
  }
}
Set-Content -Path (Join-Path $install 'garrett-service.cmd') -Encoding ascii -Value ('@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $install 'garrett-service.ps1') + '" %*')
# Node.js: the one this installer carries, else the official build from nodejs.org, checked against the SHA-256
# this installer was published with.
if (Test-Path (Join-Path $here 'node.exe')) {
  Copy-Item -Force (Join-Path $here 'node.exe') $node
} elseif (-not (Test-Path $node) -or (Get-FileHash -Algorithm SHA256 $node).Hash.ToLower() -ne $nodeSum) {
  Write-Output "Fetching Node.js $nodeVersion from nodejs.org ..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $fetched = Join-Path $install 'node.download'
  Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/$nodeVersion/win-x64/node.exe" -OutFile $fetched
  if ((Get-FileHash -Algorithm SHA256 $fetched).Hash.ToLower() -ne $nodeSum) { Remove-Item -Force $fetched; throw 'The Node.js download does not match its published checksum. Nothing was started.' }
  Move-Item -Force $fetched $node
}
# Only SYSTEM, Administrators and the account the service runs as may read its keys and database.
icacls $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)M' | Out-Null
# The wizard: its answers stand in for the command line, and its model lines go into the configuration below.
$answers = @{}
if ($Wizard) {
  $file = Join-Path $data 'setup.answers'
  $flags = @('--install', $file)
  if (-not (Test-Path (Join-Path $engine 'neuron_core.wasm'))) { $flags += '--no-memory' }
  & $node --disable-warning=ExperimentalWarning (Join-Path $install 'setup.mjs') @flags
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) { throw 'Setup was not completed. Nothing was changed.' }
  foreach ($line in Get-Content $file) { if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') { $answers[$matches[1]] = $matches[2] } }
  Remove-Item -Force $file
  if ($answers.PORT) { $Port = [int]$answers.PORT }
  if ($answers.ADDRESS) { $Address = $answers.ADDRESS }
  if ($answers.MEMORY) { $Memory = $answers.MEMORY }
  if ($answers.MODEL) { $Model = $answers.MODEL }
  if ($Model -eq $bundled -and -not (Test-Path (Join-Path $modelHome 'model.onnx'))) { throw 'This bundle does not carry the decision model; choose another model or none.' }
}
if (-not (Test-Path $conf)) {
  if (-not $Address) { $Address = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress }
  if (-not $Address) { $Address = $env:COMPUTERNAME }
  if (-not $Port) { $Port = 8443 }
  if (-not $Model) { $Model = if (Test-Path (Join-Path $modelHome 'model.onnx')) { $bundled } else { 'off' } }
  # The service's own certificate. Machines are given its SHA-256 with the join command and accept no other.
  $passphrase = New-Key
  $certificate = New-SelfSignedCertificate -Subject 'CN=garrett-service' -DnsName 'localhost', 'garrett-service' -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10) -CertStoreLocation 'Cert:\LocalMachine\My'
  try {
    Export-PfxCertificate -Cert $certificate -FilePath (Join-Path $data 'tls.pfx') -Password (ConvertTo-SecureString $passphrase -AsPlainText -Force) | Out-Null
    Set-Content -Path (Join-Path $data 'tls.crt') -Encoding ascii -Value @('-----BEGIN CERTIFICATE-----', [Convert]::ToBase64String($certificate.RawData, 'InsertLineBreaks'), '-----END CERTIFICATE-----')
  } finally { Remove-Item -Force ('Cert:\LocalMachine\My\' + $certificate.Thumbprint) }
  $modelLines = if ($Model -eq $bundled) { @('AI_PROVIDER=decision', "AI_MODEL=$bundled", "MODEL_DIR=$modelHome") } else { @('AI_PROVIDER=none') }
  Set-Content -Path $conf -Encoding ascii -Value (@(
    '# The Sentinel service on this machine. Restart the scheduled task "garrett-service" after a change.',
    "PORT=$Port", "ADDRESS=$Address",
    ('DATABASE=' + (Join-Path $data 'sentinel.db')),
    ('TLS_PFX=' + (Join-Path $data 'tls.pfx')), "TLS_PASSPHRASE=$passphrase", ('TLS_CERT=' + (Join-Path $data 'tls.crt')),
    '# Lets a machine enrol. The join command carries it.', ('ENROLL_KEY=' + (New-Key)),
    '# Lets you read cases and decide. Keep it to yourself.', ('ADMIN_TOKEN=' + (New-Key)),
    '# Encrypts case evidence in the database. Lose it and stored evidence cannot be read.', ('DATA_KEY=' + (New-Key)),
    '# What machines do about a hostile program: kill (the default), pause or report. See the README for the rest.', 'RESPONSE_MODE=',
    "# Remember operators' verdicts and show a new case the nearest ones: neuron-db, or off (the default).", ('MEMORY=' + $(if ($Memory) { $Memory } else { 'off' })),
    '# The model that decides what happens to a frozen program:  garrett-service.cmd setup  changes it, or edit these.') + $modelLines)
} else {
  # An upgrade keeps everything; only what was asked for on the command line changes.
  if ($Memory) { Set-Setting 'MEMORY' $Memory }
  if ($Port) { Set-Setting 'PORT' $Port }
  if ($Address) { Set-Setting 'ADDRESS' $Address }
  if ($Model -eq $bundled) { Set-Setting 'AI_PROVIDER' 'decision'; Set-Setting 'AI_MODEL' $bundled; Set-Setting 'MODEL_DIR' $modelHome; Set-Setting 'AI_BASE_URL' ''; Set-Setting 'AI_CA_CERT' '' }
  elseif ($Model -eq 'off') { Set-Setting 'AI_PROVIDER' 'none'; Set-Setting 'AI_MODEL' ''; Set-Setting 'MODEL_DIR' '' }
}
# Every model line the wizard wrote, as it wrote it; the model that comes with Sentinels lives where it was put.
foreach ($name in $answers.Keys) { if ($name -match '^(AI_|MODEL_DIR|DECISION_|RESPONSE_MODE)') { Set-Setting $name $answers[$name] } }
if ((Get-Setting 'AI_MODEL') -eq $bundled -and (Get-Setting 'AI_PROVIDER') -eq 'decision') { Set-Setting 'MODEL_DIR' $modelHome }
$Port = [int](Get-Setting 'PORT')
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount
$run = New-ScheduledTaskAction -Execute $node -Argument ('--disable-warning=ExperimentalWarning "' + (Join-Path $install 'serve.mjs') + '" "' + $conf + '"')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'garrett-service' -Action $run -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
Get-NetFirewallRule -DisplayName 'garrett-service' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'garrett-service' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program $node | Out-Null
Start-ScheduledTask -TaskName 'garrett-service'
$ready = $false
foreach ($attempt in 1..60) {
  Start-Sleep -Seconds 1
  $ErrorActionPreference = 'Continue'
  Invoke-Service '/v1/pulse' 2>$null | Out-Null
  $ErrorActionPreference = 'Stop'
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}
if (-not $ready) { throw 'The service did not start. Look at the scheduled task "garrett-service" in Task Scheduler.' }
Write-Output ''
Write-Output 'Your Sentinel service is running on this machine.'
if ((Get-Setting 'AI_MODEL') -eq $bundled) { Write-Output "Its decision model, $bundled, decides what happens to a program a machine freezes. To change that, or plug in a model of your own:  garrett-service.cmd setup" }
# The agent for this machine, when the installer carries it: installed and joined to this service.
$agentInstall = Join-Path $here 'agent\deploy\install-windows.ps1'
if (Test-Path $agentInstall) {
  if ((Get-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $data 'agent-installed'))) {
    Write-Output 'garrett is already on this machine; join it to this service with the command below.'
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agentInstall -Server ('https://127.0.0.1:' + $Port) -EnrollKey ((Get-Setting 'ENROLL_KEY') + '.' + (Get-Pin))
    if ($LASTEXITCODE -ne 0) { throw 'The agent did not install; the service is running without it.' }
    Set-Content -Path (Join-Path $data 'agent-installed') -Encoding ascii -Value 'installed by garrett-service'
    Write-Output 'This machine is protected by garrett and reports to this service.'
  }
}
Write-Output ''
Show-Join
