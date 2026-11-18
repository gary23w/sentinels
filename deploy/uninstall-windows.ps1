# Remove garrett from this machine: the scheduled task, its firewall rules, its program folder and its credential.
# Run from an elevated PowerShell:   .\uninstall-windows.ps1
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
$system32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if (-not $system32 -or -not $programFiles -or -not $programData) { throw 'The Windows system folders are not available.' }
$netsh = Join-Path $system32 'netsh.exe'
if (Get-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName 'garrett' -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName 'garrett' -Confirm:$false
}
# Whatever addresses the agent refused are let through again.
& $netsh advfirewall firewall delete rule name="Garrett fleet block" | Out-Null
$global:LASTEXITCODE = 0  # netsh reports "no rules matched" as a failure; having none to delete is not one
Start-Sleep -Seconds 2
function Remove-GarrettFolder([string]$parent) {
  $base = [IO.Path]::GetFullPath($parent).TrimEnd('\')
  $folder = [IO.Path]::GetFullPath((Join-Path $base 'garrett'))
  if (-not $folder.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($folder) -cne 'garrett') { throw 'The Garrett removal path is not valid.' }
  if (-not (Test-Path -LiteralPath $folder)) { return }
  $pending = New-Object 'System.Collections.Generic.Stack[string]'
  $files = New-Object 'System.Collections.Generic.List[string]'
  $directories = New-Object 'System.Collections.Generic.List[string]'
  $pending.Push($folder)
  $count = 0
  while ($pending.Count -gt 0) {
    $path = $pending.Pop()
    if (++$count -gt 8192) { throw 'The Garrett folder has too many entries to remove safely.' }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The Garrett folder contains a reparse point. Remove it manually.' }
    if ($item.PSIsContainer) {
      $directories.Add($path)
      foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) {
        if ($count + $pending.Count -ge 8192) { throw 'The Garrett folder has too many entries to remove safely.' }
        $pending.Push($child)
      }
    } else { $files.Add($path) }
  }
  foreach ($path in $files) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The Garrett folder changed during removal.' }
    Remove-Item -LiteralPath $path -Force
  }
  for ($at = $directories.Count - 1; $at -ge 0; $at--) {
    $path = $directories[$at]
    $item = Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The Garrett folder changed during removal.' }
    Remove-Item -LiteralPath $path -Force
  }
}
Remove-GarrettFolder $programFiles
Remove-GarrettFolder $programData
Write-Output 'garrett was removed. If this machine was enrolled, remove it on the service as well: POST /v1/devices/<id>/revoke'
