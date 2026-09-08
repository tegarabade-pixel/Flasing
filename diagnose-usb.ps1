Write-Host "=== USB Cloud Diagnostics ==="
Get-PnpDevice -PresentOnly |
  Where-Object { $_.Class -match "USB|DiskDrive|HIDClass|Ports|AndroidUsbDeviceClass" } |
  Sort-Object Class,FriendlyName |
  Format-Table -AutoSize

Write-Host "`nDisks:"
Get-Disk -ErrorAction SilentlyContinue | Format-Table -AutoSize

Write-Host "`nVolumes:"
Get-Volume -ErrorAction SilentlyContinue | Format-Table -AutoSize

Write-Host "`nListening:"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 9090,3240 } |
  Format-Table -AutoSize
