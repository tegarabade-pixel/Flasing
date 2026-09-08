param(
    [Parameter(Mandatory=$true)]
    [string]$ApiSecret
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($ApiSecret)) {
    throw "USB_API_SECRET is empty. Add it as a GitHub Actions secret."
}

$Version = "1.14.0"
$Work = Join-Path $env:RUNNER_TEMP "usb-cloud"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Write-Host "== Universal USB Cloud PoC =="

$zip = Join-Path $Work "sing-box.zip"
$url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-amd64.zip"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

Expand-Archive -Force $zip $Work
$exe = Get-ChildItem -Path $Work -Filter "sing-box.exe" -Recurse | Select-Object -First 1
if (-not $exe) { throw "sing-box.exe not found after extraction" }

$template = Join-Path $PSScriptRoot "..\config\sing-box-windows.template.json"
$configPath = Join-Path $Work "sing-box.json"

$cfg = Get-Content $template -Raw | ConvertFrom-Json
$api = $cfg.services | Where-Object { $_.type -eq "api" } | Select-Object -First 1
if (-not $api) { throw "API service missing from template" }
$api.secret = $ApiSecret
$cfg | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $configPath

Write-Host "Validating sing-box configuration..."
& $exe.FullName check -c $configPath
if ($LASTEXITCODE -ne 0) { throw "sing-box configuration check failed" }

Write-Host "Windows identity:"
whoami
Write-Host "Windows version:"
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber

$stdout = Join-Path $Work "sing-box.out.log"
$stderr = Join-Path $Work "sing-box.err.log"

Write-Host "Starting sing-box..."
$proc = Start-Process -FilePath $exe.FullName -ArgumentList @("run","-c",$configPath) `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

Start-Sleep 7
if ($proc.HasExited) {
    Write-Host "--- stdout ---"
    Get-Content $stdout -Tail 200 -ErrorAction SilentlyContinue
    Write-Host "--- stderr ---"
    Get-Content $stderr -Tail 200 -ErrorAction SilentlyContinue
    throw "sing-box exited early with code $($proc.ExitCode)"
}

Write-Host "Listening ports:"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 9090,3240 } |
    Format-Table -AutoSize

Write-Host "Current PnP devices:"
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -match "USB|DiskDrive|HIDClass|Ports|AndroidUsbDeviceClass" } |
    Sort-Object Class,FriendlyName |
    Format-Table -AutoSize

Write-Host ""
Write-Host "PoC service is running."
Write-Host "Connect the Android SFA Remote Control client to this runner on TCP 9090."
Write-Host "PID: $($proc.Id)"
Write-Host "Logs:"
Write-Host "  $stdout"
Write-Host "  $stderr"
