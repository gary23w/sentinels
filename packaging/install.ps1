# Install garrett on this Windows machine from the published release bundle.
# From an elevated PowerShell:
#   irm https://gary23w.github.io/sentinels/install.ps1 | iex
# To join a fleet, set GARRETT_SERVER and GARRETT_KEY in that PowerShell first.
# The release build updates the pinned bundle hash below before publishing this script.
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$pinnedWindowsZip = '6cfb3fce55b4452bb59cbda7d8d00f5cfb3b964126cdac990dafbe0b883a659c'
$base = if ($env:GARRETT_BASE) { $env:GARRETT_BASE } else { 'https://gary23w.github.io/sentinels' }
$releaseUri = $null
if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$releaseUri) -or $releaseUri.Scheme -cne 'https' -or -not $releaseUri.Host -or $releaseUri.UserInfo -or $releaseUri.Query -or $releaseUri.Fragment) { throw 'The release site must be an HTTPS address without credentials or a query.' }
$base = $releaseUri.AbsoluteUri.TrimEnd('/')

$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
if (-not $windows -or -not $system32 -or -not $programFiles) { throw 'The Windows system folders are not available.' }
$env:PATH = $system32 + ';' + $windows + ';' + (Join-Path $system32 'WindowsPowerShell\v1.0')
$icacls = Join-Path $system32 'icacls.exe'
$stageRoot = [IO.Path]::GetFullPath($programFiles).TrimEnd('\')
$work = [IO.Path]::GetFullPath((Join-Path $stageRoot ('garrett-bootstrap-' + [Guid]::NewGuid().ToString('N'))))
if (-not $work.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The staging directory is not valid.' }
New-Item -ItemType Directory -Path $work | Out-Null
try {
  # The unelevated half of an administrator account must not be able to alter the bundle after verification.
  if ((Get-Item -LiteralPath $work -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The staging directory is a reparse point.' }
  & $icacls $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'The staging directory could not be locked.' }
  & $icacls $work /setowner '*S-1-5-32-544' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'The staging directory owner could not be locked.' }
  $acl = Get-Acl -LiteralPath $work
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'The staging directory owner is not protected.' }
  $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  if (@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') }).Count) { throw 'The staging directory allows another account to modify it.' }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $zip = Join-Path $work 'garrett-windows.zip'
  Invoke-WebRequest -UseBasicParsing -Uri ($base + '/garrett-windows.zip') -OutFile $zip
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -cne $pinnedWindowsZip) { throw 'The release bundle failed its pinned hash check. Nothing was installed.' }
  Expand-Archive -LiteralPath $zip -DestinationPath $work
  $arguments = @{}
  if ($env:GARRETT_SERVER) { $arguments.Server = $env:GARRETT_SERVER; $arguments.EnrollKey = $env:GARRETT_KEY }
  if ($env:GARRETT_MODE) { $arguments.Mode = $env:GARRETT_MODE }
  & (Join-Path $work 'garrett\deploy\install-windows.ps1') @arguments
} finally {
  if ($work.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
