# Turn this Windows machine into your own Sentinel service, in one line. Free: it runs on your machine, nothing is
# sent anywhere else, and there is no account. From an elevated PowerShell:
#   irm https://gary23w.github.io/sentinels/service.ps1 | iex
# It downloads one file from the project's GitHub release, garrett-sentinels-windows.exe, checks it against the
# SHA-256 pinned here, and runs it. The service, its decision model (crivo-sentinel-v1) and the Sentinel agent for
# this machine are inside that file, so nothing else is fetched. The service and the agent run at every startup
# from then on. It prints the command that joins your other machines (Windows, Linux, macOS) to it.
# To choose the port or the address other machines reach this one by, set these first in the same window:
#   $env:GARRETT_PORT = '8443'; $env:GARRETT_ADDRESS = 'sentinel.example.internal'
# To remember operators' verdicts and show a new case the nearest ones (off by default):  $env:GARRETT_MEMORY = 'neuron-db'
# Without the decision model (on by default):  $env:GARRETT_MODEL = 'off'
# A few questions first (the model that decides, or one of your own, and how much it may decide):  $env:GARRETT_WIZARD = '1'
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$base = if ($env:GARRETT_BASE) { $env:GARRETT_BASE } else { 'https://gary23w.github.io/sentinels' }
$releaseVersion = '1.9.1'
$release = if ($env:GARRETT_RELEASE) { $env:GARRETT_RELEASE } else { 'https://github.com/gary23w/sentinels/releases/download/v' + $releaseVersion }
$pinnedInstaller = '44bded204442e03c9ed30856690fe9b6b28b18d45a77118911167ba00895342f'
foreach ($address in @($base, $release)) {
  $uri = $null
  if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'The release addresses must be HTTPS addresses without credentials or a query.' }
}
$base = $base.TrimEnd('/'); $release = $release.TrimEnd('/')

$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
if (-not $windows -or -not $system32 -or -not $programFiles) { throw 'The Windows system folders are not available.' }
$env:PATH = $system32 + ';' + $windows + ';' + (Join-Path $system32 'WindowsPowerShell\v1.0')
$stageRoot = [IO.Path]::GetFullPath($programFiles).TrimEnd('\')
$work = [IO.Path]::GetFullPath((Join-Path $stageRoot ('garrett-service-bootstrap-' + [Guid]::NewGuid().ToString('N'))))
if (-not $work.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The staging directory is not valid.' }
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$security = [Security.AccessControl.DirectorySecurity]::new()
$security.SetAccessRuleProtection($true, $false)
$inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
foreach ($sid in @($systemSid, $adminSid)) {
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
}
$security.SetOwner($adminSid)
$createWithAcl = [IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [Security.AccessControl.DirectorySecurity]))
if ($createWithAcl) { [IO.Directory]::CreateDirectory($work, $security) | Out-Null }
else { [IO.FileSystemAclExtensions]::CreateDirectory($security, $work) | Out-Null }
try {
  # The access rules are applied when the directory is created, before any file can be staged.
  if ((Get-Item -LiteralPath $work -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The staging directory is a reparse point.' }
  $acl = Get-Acl -LiteralPath $work
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'The staging directory owner is not protected.' }
  $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  if (@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') }).Count) { throw 'The staging directory allows another account to modify it.' }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $installer = Join-Path $work 'garrett-sentinels-windows.exe'
  Write-Output 'Fetching garrett-sentinels-windows.exe ...'
  Invoke-WebRequest -UseBasicParsing -Uri "$release/garrett-sentinels-windows.exe" -OutFile $installer
  $have = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLower()
  if ($pinnedInstaller -ne $have) { throw 'The download failed its pinned hash check. Nothing was installed.' }
  $arguments = @('install')
  if ($env:GARRETT_PORT) { $arguments += @('-Port', [string][int]$env:GARRETT_PORT) }
  if ($env:GARRETT_ADDRESS) { $arguments += @('-Address', $env:GARRETT_ADDRESS) }
  if ($env:GARRETT_MEMORY) { $arguments += @('-Memory', $env:GARRETT_MEMORY) }
  if ($env:GARRETT_MODEL) { $arguments += @('-Model', $env:GARRETT_MODEL) }
  if ($env:GARRETT_WIZARD) { $arguments += '-Wizard' }
  $env:GARRETT_BASE = $base
  & $installer @arguments
  if ($LASTEXITCODE -ne 0) { throw 'The installer did not finish.' }
} finally {
  if ($work.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
