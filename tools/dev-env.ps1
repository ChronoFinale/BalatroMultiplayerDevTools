# One-command dev environment for the Balatro Multiplayer stack:
# containers -> API server -> N auto-login game windows.
#
#   .\tools\dev-env.ps1                  # server + 2 windows (Player001/002)
#   .\tools\dev-env.ps1 -Windows 4       # four windows (Player001..004)
#   .\tools\dev-env.ps1 -NoServer        # just the game windows
#
# The server console opens in its own window (leave it visible: match events,
# draft rolls and flagged draft facts all log there). Game windows auto-login
# via the instance slots -- first window Player001, second Player002, ...

param(
    [int]$Windows = 2,
    [string]$ServerDir = "D:\Things10\server\apps\server",
    [string]$GamePath = "D:\SteamLibrary\steamapps\common\Balatro\Balatro.exe",
    [string]$HealthUrl = "http://127.0.0.1:8788/health",
    [string[]]$Containers = @("bmp-emqx", "bmp-postgres"),
    [switch]$NoServer
)
$ErrorActionPreference = "Stop"

function Test-Health {
    try {
        (Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200
    } catch { $false }
}

if (-not $NoServer) {
    foreach ($c in $Containers) {
        $running = docker inspect -f '{{.State.Running}}' $c 2>$null
        if ($running -ne "true") {
            Write-Host "starting container $c..."
            docker start $c | Out-Null
        } else {
            Write-Host "container $c already running"
        }
    }

    if (Test-Health) {
        Write-Host "API server already healthy ($HealthUrl)"
    } else {
        Write-Host "starting API server in its own window ($ServerDir)..."
        Start-Process powershell -ArgumentList "-NoExit", "-Command",
            "Set-Location '$ServerDir'; pnpm dev"
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Health)) {
            if ((Get-Date) -gt $deadline) {
                throw "API server did not become healthy at $HealthUrl within 90s - check the server window"
            }
            Start-Sleep -Milliseconds 800
        }
        Write-Host "API server healthy"
    }
}

for ($i = 1; $i -le $Windows; $i++) {
    Write-Host "launching game window $i (instance slot $i)..."
    Start-Process $GamePath -WorkingDirectory (Split-Path $GamePath)
    # Stagger so slot claiming (and mod loading disk churn) stays orderly.
    if ($i -lt $Windows) { Start-Sleep -Seconds 4 }
}

Write-Host ""
Write-Host "dev environment up: $Windows game window(s)$(if (-not $NoServer) { ', server on :8788' })"
Write-Host "lovely logs: `$env:APPDATA\Balatro\Mods\lovely\log (newest file per window)"
