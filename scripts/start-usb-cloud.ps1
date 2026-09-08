param(
  [Parameter(Mandatory=$true)]
  [string]$ApiSecret,

  [Parameter(Mandatory=$true)]
  [string]$ApiListen
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($ApiSecret)) {
  throw "USB_API_SECRET is empty."
}
if ([string]::IsNullOrWhiteSpace($ApiListen)) {
  throw "ApiListen/Tailscale IP is empty."
}

$Version = "1.14.0"
$Work = Join-Path $env:RUNNER_TEMP "usb-cloud"

if (Test-Path $Work) {
  Remove-Item -Recurse -Force $Work
}
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Write-Host "== Universal USB Cloud PoC v0.1.2 =="
Write-Host "API bind address: $ApiListen"

$zip = Join-Path $Work "sing-box.zip"
$url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-amd64.zip"

Write-Host "Downloading sing-box $Version..."
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
Expand-Archive -Force $zip $Work

$exe = Get-ChildItem -Path $Work -Filter "sing-box.exe" -Recurse | Select-Object -First 1
if (-not $exe) {
  throw "sing-box.exe not found after extraction."
}

$template = Join-Path $PSScriptRoot "..\config\sing-box-windows.template.json"
$configPath = Join-Path $Work "sing-box.json"

$cfg = Get-Content $template -Raw | ConvertFrom-Json

$api = $cfg.services |
  Where-Object { $_.type -eq "api" } |
  Select-Object -First 1

if (-not $api) {
  throw "API service is missing from config template."
}

$api.secret = $ApiSecret
$api.listen = $ApiListen

# IMPORTANT:
# Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 BOM.
# sing-box's JSON parser rejects that BOM. Write explicit UTF-8 *without BOM*.
$json = $cfg | ConvertTo-Json -Depth 32
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)

# Sanity checks before sing-box sees the file.
$bytes = [System.IO.File]::ReadAllBytes($configPath)
if ($bytes.Length -ge 3 -and
    $bytes[0] -eq 0xEF -and
    $bytes[1] -eq 0xBB -and
    $bytes[2] -eq 0xBF) {
  throw "Generated sing-box.json unexpectedly contains UTF-8 BOM."
}

try {
  $null = Get-Content $configPath -Raw | ConvertFrom-Json
  Write-Host "JSON parse check: OK"
} catch {
  throw "Generated JSON is invalid: $($_.Exception.Message)"
}

$first = if ($bytes.Length -gt 8) { $bytes[0..7] } else { $bytes }
Write-Host ("First config bytes: " + (($first | ForEach-Object { $_.ToString("X2") }) -join " "))

Write-Host "Checking sing-box configuration..."
& $exe.FullName check -c $configPath
if ($LASTEXITCODE -ne 0) {
  # Do not print the config because it contains USB_API_SECRET.
  throw "sing-box configuration check failed."
}
Write-Host "sing-box config check: OK"

# Allow only Tailnet IPv4 clients to reach the API.
$ruleName = "Universal USB Cloud API 9090"
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule `
  -DisplayName $ruleName `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 9090 `
  -RemoteAddress "100.64.0.0/10" `
  -Profile Any | Out-Null

$stdout = Join-Path $Work "sing-box.out.log"
$stderr = Join-Path $Work "sing-box.err.log"

Write-Host "Starting sing-box..."
$proc = Start-Process `
  -FilePath $exe.FullName `
  -ArgumentList @("run", "-c", $configPath) `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
  -PassThru

Start-Sleep 7

if ($proc.HasExited) {
  Write-Host "--- sing-box stdout ---"
  Get-Content $stdout -Tail 200 -ErrorAction SilentlyContinue
  Write-Host "--- sing-box stderr ---"
  Get-Content $stderr -Tail 200 -ErrorAction SilentlyContinue
  throw "sing-box exited early with code $($proc.ExitCode)"
}

Write-Host "sing-box PID: $($proc.Id)"

Write-Host "`nListening ports:"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 9090,3240 } |
  Sort-Object LocalPort |
  Format-Table -AutoSize

$apiListen = Get-NetTCPConnection -State Listen -LocalPort 9090 -ErrorAction SilentlyContinue
if (-not $apiListen) {
  throw "API port 9090 is not listening after sing-box startup."
}

$usbListen = Get-NetTCPConnection -State Listen -LocalPort 3240 -ErrorAction SilentlyContinue
if (-not $usbListen) {
  throw "Local USB/IP port 3240 is not listening after sing-box startup."
}

Write-Host ""
Write-Host "USB Cloud backend is READY."
