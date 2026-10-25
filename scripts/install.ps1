#Requires -Version 5.1
<#
.SYNOPSIS
    Install the Codex overload relay (cockpit-tools edition) as a hidden,
    auto-restarting background process.

.DESCRIPTION
    Finds Python, writes hidden VBS launchers into %LOCALAPPDATA%\codex-overload-fix,
    registers a watchdog under HKCU\...\Run (no admin rights), then prints the
    exact config.toml block for the mode you chose.

    -Cockpit  puts the relay in front of cockpit-tools (default here: upstream
              http://127.0.0.1:8888, provider name codex_local_access_retry).
              Use this if Codex already goes through cockpit-tools.
    (default) uses the original layout: relay in front of chatgpt.com.

.PARAMETER CockpitPort
    cockpit-tools' local port. Default 8888.

.PARAMETER Port
    Local port for the relay. Default 8788 in cockpit mode, 8787 otherwise.
    8787 is avoided in cockpit mode because workbuddy2api already uses it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Cockpit
#>
[CmdletBinding()]
param(
    [switch]$Cockpit,
    [int]$Port = 0,
    [int]$CockpitPort = 8888,
    [string]$Proxy = "",
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!!] $msg" -ForegroundColor Yellow }

if ($Port -eq 0) { $Port = if ($Cockpit) { 8788 } else { 8787 } }

Write-Host ""
Write-Host "Codex Overload Fix - cockpit edition - installer" -ForegroundColor Cyan
Write-Host "------------------------------------------------" -ForegroundColor DarkGray
if ($Cockpit) {
    Write-Step "mode: in front of cockpit-tools (127.0.0.1:$CockpitPort)"
} else {
    Write-Step "mode: in front of chatgpt.com (original layout)"
}

# ---------------------------------------------------------------- locations
$root     = Split-Path -Parent $PSScriptRoot
$relayPy  = Join-Path $root 'relay\relay.py'
$stateDir = Join-Path $env:LOCALAPPDATA 'codex-overload-fix'
$logPath  = Join-Path $stateDir 'relay.log'
$startVbs = Join-Path $stateDir 'start-relay.vbs'
$watchVbs = Join-Path $stateDir 'watch-relay.vbs'
$runKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName  = 'CodexOverloadRelay'

if (-not (Test-Path $relayPy)) {
    throw "relay.py not found at $relayPy - run this from the repository's scripts\ folder."
}
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# ---------------------------------------------------------------- port clash
function Test-PortBusy([int]$p) {
    try {
        return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop)
    } catch {
        return [bool](netstat -ano | Select-String ":$p\s" | Select-String 'LISTENING')
    }
}
if (Test-PortBusy $Port) {
    $owner = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
              Select-Object -First 1).OwningProcess
    $name = if ($owner) { (Get-Process -Id $owner -ErrorAction SilentlyContinue).ProcessName } else { 'unknown' }
    Write-Warn2 "port $Port is already in use by '$name'"
    Write-Warn2 "pass -Port <free port> and use the same port in the config snippet"
    if ($name -match 'cockpit') {
        throw "refusing to put the relay on the cockpit port itself ($Port)."
    }
}

# ---------------------------------------------------------------- find python
Write-Step 'Looking for Python...'
$python = $null
foreach ($candidate in @('py -3', 'python', 'python3')) {
    $parts = $candidate.Split(' ')
    $exe = $parts[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    try {
        $out = & $exe @($parts[1..($parts.Count - 1)] | Where-Object { $_ }) -c "import sys;print(sys.executable)" 2>$null
    } catch { continue }
    if (-not $out) { continue }
    $path = ($out | Select-Object -First 1).Trim()
    if (-not $path -or -not (Test-Path $path)) { continue }
    if ($path -match 'WindowsApps') { continue }
    $ver = & $path -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null
    if (-not $ver) { continue }
    $major, $minor = $ver.Trim().Split('.')
    if ([int]$major -lt 3 -or ([int]$major -eq 3 -and [int]$minor -lt 9)) {
        Write-Warn2 "$path is Python $ver (need 3.9+)"
        continue
    }
    $python = $path
    Write-Ok "Python $ver at $python"
    break
}
if (-not $python) {
    throw 'No usable Python 3.9+ found. Install from https://python.org and re-run.'
}

# ---------------------------------------------------------------- build command
if ($Cockpit) {
    $upstream = "http://127.0.0.1:$CockpitPort"
} else {
    $upstream = 'chatgpt.com/backend-api/codex'
}

$argList = @(
    "--port $Port",
    "--upstream `"$upstream`"",
    "--log `"$logPath`"",
    '--max-attempts 30',
    '--max-conn-attempts 3',
    '--conn-budget 15',
    '--backoff-base 1',
    '--backoff-max 8',
    '--total-budget 300',
    '--commit-deadline 120',
    '--max-concurrent 4',
    '--retries-per-sec 2'
)
if ($Cockpit) { $argList += '--cooling-wait 5' }
if ($Proxy)   { $argList += "--proxy $Proxy" }
$innerCmd = '"' + $python + '" "' + $relayPy + '" ' + ($argList -join ' ')
$vbsCmd = $innerCmd.Replace('"', '""')

# ---------------------------------------------------------------- launcher
$startContent = @"
' Codex Overload Fix - hidden launcher. Generated by install.ps1, do not edit.
Set sh = CreateObject("WScript.Shell")
sh.Run "$vbsCmd", 0, False
"@
Set-Content -Path $startVbs -Value $startContent -Encoding ASCII
Write-Ok "launcher  $startVbs"

# ---------------------------------------------------------------- watchdog
$checkCmd = "cmd /c netstat -ano | findstr ""LISTENING"" | findstr "":$Port "" >nul 2>&1"
$watchContent = @"
' Codex Overload Fix - watchdog. Generated by install.ps1, do not edit.
' Runs forever with no window (wscript.exe is a GUI-subsystem host).
Set sh = CreateObject("WScript.Shell")
check = "$($checkCmd.Replace('"','""'))"
cmd   = "$vbsCmd"

Do
  rc = sh.Run(check, 0, True)
  If rc <> 0 Then
    sh.Run cmd, 0, True
    WScript.Sleep 3000
  Else
    WScript.Sleep 30000
  End If
Loop
"@
Set-Content -Path $watchVbs -Value $watchContent -Encoding ASCII
Write-Ok "watchdog  $watchVbs"

# ---------------------------------------------------------------- autostart
if (-not $NoAutostart) {
    $entry = 'wscript.exe "' + $watchVbs + '"'
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name $runName -Value $entry
    Write-Ok "registered $runName in HKCU Run"
}

# ---------------------------------------------------------------- start now
Write-Step 'Starting the relay...'
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $watchVbs + '"') -WindowStyle Hidden
Start-Sleep -Seconds 4
if (Test-PortBusy $Port) {
    Write-Ok "listening on 127.0.0.1:$Port"
} else {
    Write-Warn2 "not listening yet - check $logPath"
}

# ---------------------------------------------------------------- config
$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
Write-Host ""
Write-Host "Add this to $configPath" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkGray

if ($Cockpit) {
    # Reuse the existing bearer token and cockpit headers so account rotation,
    # session affinity and image generation keep working unchanged.
    $existing = $null
    if (Test-Path $configPath) {
        $text = Get-Content -Raw -Path $configPath
        $m = [regex]::Match($text,
            '(?ms)^\[model_providers\.codex_local_access\](.*?)(?=^\[|\Z)')
        if ($m.Success) { $existing = $m.Groups[1].Value }
    }
    $snippet = @"
model_provider = "codex_local_access_retry"

[model_providers.codex_local_access_retry]
name = "Codex API Service (retry)"
base_url = "http://127.0.0.1:$Port/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
stream_max_retries = 20
request_max_retries = 10
"@
    if ($existing) {
        $carry = @()
        foreach ($line in ($existing -split "`n")) {
            $t = $line.Trim()
            if ($t -match '^(experimental_bearer_token|http_headers)\s*=') { $carry += $t }
        }
        if ($carry.Count -gt 0) {
            $snippet += "`n" + ($carry -join "`n")
            Write-Step "carried over the token/headers from [model_providers.codex_local_access]"
        }
    } else {
        Write-Warn2 "copy experimental_bearer_token + http_headers from your existing"
        Write-Warn2 "[model_providers.codex_local_access] block by hand - they are required"
    }
} else {
    $snippet = @"
model_provider = "openai-retry"

[model_providers.openai-retry]
name = "OpenAI (retry)"
base_url = "http://127.0.0.1:$Port"
wire_api = "responses"
requires_openai_auth = true
stream_max_retries = 20
request_max_retries = 10
"@
}

Write-Host $snippet -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Keep a backup of config.toml before editing." -ForegroundColor Yellow
Write-Host "Then fully quit and restart Codex (tray icon -> Quit, not just close)." -ForegroundColor Yellow
Write-Host ""
Write-Host "Verify the relay is actually in the path:" -ForegroundColor Cyan
Write-Host "  python tools\relayctl.py path" -ForegroundColor White
Write-Host "  python tools\relayctl.py status" -ForegroundColor White
Write-Host ""
Write-Host "Log:     $logPath" -ForegroundColor DarkGray
Write-Host "Stop:    powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1" -ForegroundColor DarkGray
Write-Host ""
