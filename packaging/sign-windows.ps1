# Sign the Windows agent in a packed release with the project's code-signing certificate (Authenticode), and put
# the signed file into everything that carries or names it. Run it on the machine that holds the certificate,
# after the release workflow (or assemble-release.sh) packed the release and before sign-release.sh:
#
#   powershell -File packaging\sign-windows.ps1 -Thumbprint <certificate thumbprint> <release folder>
#
# The certificate is one for code signing in the current user's or the machine's certificate store, with its
# private key: `Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert` lists them with their thumbprints. One on a
# hardware token or smart card is there once the token's driver is installed. Needs signtool from the Windows SDK
# ("Windows SDK Signing Tools for Desktop Apps"): in the Windows Kits folder, on PATH, or named by $env:SIGNTOOL.
#
# The signature is SHA-256, carries the certificate's chain, and is timestamped (RFC 3161, SHA-256) by the server
# named here, so it stays valid after the certificate expires. The signed file is checked the way Windows checks
# it; then packaging/signed-windows.py remakes the zip, the one-file installer, SHA256SUMS, the update list and
# the first-install scripts' pins from it.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Thumbprint,
  [Parameter(Mandatory = $true, Position = 0)][string]$Release,
  [string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Release = (Resolve-Path -LiteralPath $Release).ProviderPath
$file = Join-Path $Release 'dist\garrett-windows.exe'
if (-not (Test-Path -LiteralPath $file)) { throw "$Release has no dist\garrett-windows.exe." }
$Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
$store = $null
foreach ($candidate in 'CurrentUser', 'LocalMachine') {
  $found = @(Get-ChildItem "Cert:\$candidate\My" -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Thumbprint })
  if ($found.Count -gt 0) { $certificate = $found[0]; $store = $candidate; break }
}
if (-not $store) { throw "No certificate with thumbprint $Thumbprint is in the user's or the machine's certificate store." }
if (-not $certificate.HasPrivateKey) { throw "The private key of $($certificate.Subject) is not on this machine." }
if ($certificate.EnhancedKeyUsageList.ObjectId -notcontains '1.3.6.1.5.5.7.3.3') { throw "$($certificate.Subject) is not a code-signing certificate." }
if ($certificate.NotAfter -lt (Get-Date)) { throw "$($certificate.Subject) expired on $($certificate.NotAfter)." }
$signtool = if ($env:SIGNTOOL) { $env:SIGNTOOL } else { (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
if (-not $signtool) {
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
  $signtool = Get-ChildItem (Join-Path $kits 'bin\*\x64\signtool.exe'), (Join-Path $kits 'App Certification Kit\signtool.exe') -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $signtool) { throw 'signtool is not installed: it comes with the Windows SDK ("Windows SDK Signing Tools for Desktop Apps").' }
$storeSwitch = @(); if ($store -eq 'LocalMachine') { $storeSwitch = @('/sm') }
& $signtool sign /q /fd SHA256 /sha1 $Thumbprint @storeSwitch /tr $TimestampServer /td SHA256 $file
if ($LASTEXITCODE -ne 0) { throw "signtool could not sign garrett-windows.exe (exit $LASTEXITCODE)." }
$check = Get-AuthenticodeSignature -LiteralPath $file
if ($check.Status -ne 'Valid') { throw "garrett-windows.exe: $($check.Status): $($check.StatusMessage)" }
if (-not $check.TimeStamperCertificate) { throw 'garrett-windows.exe is signed, but its timestamp is missing.' }
"garrett-windows.exe: signed by $($check.SignerCertificate.Subject), timestamped by $($check.TimeStamperCertificate.Subject)"
$python = $null
foreach ($name in 'py', 'python3', 'python') { $command = Get-Command $name -ErrorAction SilentlyContinue; if ($command) { $python = $command.Source; break } }
if (-not $python) { throw 'Python 3 is not installed.' }
$arguments = @(); if ((Split-Path -Leaf $python) -eq 'py.exe') { $arguments += '-3' }
& $python @arguments -B (Join-Path $here 'signed-windows.py') $Release
if ($LASTEXITCODE -ne 0) { throw "signed-windows.py failed (exit $LASTEXITCODE)." }
