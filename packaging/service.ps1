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
$releaseUri = $null
if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$releaseUri) -or $releaseUri.Scheme -cne 'https' -or -not $releaseUri.Host -or $releaseUri.UserInfo -or $releaseUri.Query -or $releaseUri.Fragment) { throw 'The release site must be an HTTPS address without credentials or a query.' }
$base = $releaseUri.AbsoluteUri.TrimEnd('/')

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
  $zip = Join-Path $work 'garrett-service-windows.zip'
  Invoke-WebRequest -UseBasicParsing -Uri "$base/garrett-service-windows.zip" -OutFile $zip
  $have = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
  if ($pinnedServiceZip -ne $have) { throw 'The download failed its pinned hash check. Nothing was installed.' }
  Expand-Archive -Path $zip -DestinationPath $work
  $arguments = @{ Command = 'install' }
  if ($env:GARRETT_PORT) { $arguments.Port = [int]$env:GARRETT_PORT }
  if ($env:GARRETT_ADDRESS) { $arguments.Address = $env:GARRETT_ADDRESS }
  & (Join-Path $work 'garrett-service\garrett-service.ps1') @arguments
} finally {
  if ($work.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
