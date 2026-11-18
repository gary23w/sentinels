# Install garrett from the release's Windows Installer package, after checking its SHA-256. The package puts the
# agent in C:\Program Files\garrett and starts it as SYSTEM at every boot.
$ErrorActionPreference = 'Stop'
$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'msi'
  url64bit       = '@MSI_URL@'
  checksum64     = '@SHA_garrett-windows.msi@'
  checksumType64 = 'sha256'
  silentArgs     = "/qn /norestart /l*v `"$($env:TEMP)\$($env:ChocolateyPackageName).$($env:ChocolateyPackageVersion).MsiInstall.log`""
  validExitCodes = @(0, 3010, 1641)
  softwareName   = 'garrett'
}
Install-ChocolateyPackage @packageArgs
