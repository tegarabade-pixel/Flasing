param(
  [Parameter(Mandatory=$true)]
  [string]$ApiSecret
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($ApiSecret)) {
  throw "USB_API_SECRET is empty."
}

$Version = "1.14.0"
$Work = Join-Path $env:RUNNER_TEMP "usb-cloud"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$zip = Join-Path $Work "sing-box.zip"
$url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-amd64.zip"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
Expand-Archive -Force $zip $Work

$exe = Get-ChildItem -Path $Work -Filter "sing-box.exe" -Recurse | Select-Object -First 1
if (-not $exe) { throw "sing-box.exe not found." }

$template = Join-Path $PSScriptRoot "..\config\sing-box-windows.template.json"
$configPath = Join-Path $Work "sing-box.json"
$cfg = Get-Content $template -Raw | ConvertFrom-Json
($cfg.services | Where-Object { $_.type -eq "api" } | Select-Object -First 1).secret = $ApiSecret
$cfg | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $configPath

& $exe.FullName check -c $configPath
if ($LASTEXITCODE -ne 0) { throw "sing-box configuration check failed." }

$stdout = Join-Path $Work "sing-box.out.log"
$stderr = Join-Path $Work "sing-box.err.log"
$proc = Start-Process -FilePath $exe.FullName -ArgumentList @("run","-c",$configPath) `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

Start-Sleep 7
if ($proc.HasExited) {
  Get-Content $stdout -Tail 200 -ErrorAction SilentlyContinue
  Get-Content $stderr -Tail 200 -ErrorAction SilentlyContinue
  throw "sing-box exited early with code $($proc.ExitCode)"
}

Write-Host "sing-box PID: $($proc.Id)"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 9090,3240 } |
  Format-Table -AutoSize
