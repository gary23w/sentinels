# Remove garrett through its Windows Installer package: the agent, its scheduled task, its firewall rules, its
# program folder and its credential.
$ErrorActionPreference = 'Stop'
[array]$keys = Get-UninstallRegistryKey -SoftwareName 'garrett'
foreach ($key in $keys) {
  Uninstall-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType 'msi' -SilentArgs "$($key.PSChildName) /qn /norestart" -ValidExitCodes @(0, 3010, 1605, 1614, 1641) -File ''
}
