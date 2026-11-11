<#
.SYNOPSIS
    Startet Flowise mit PostgreSQL in einem Podman-Pod.
    Legt fehlende Teile (Pod, Container, Volumes) automatisch an und
    startet vorhandene, aber gestoppte Teile neu. Vorhandene Daten bleiben erhalten.

.EXAMPLE
    .\start-flowise.ps1
    .\start-flowise.ps1 -Version 3.1.5
#>
param(
    [string]$Version    = "3.1.4",
    [string]$DbPassword = "flowise",
    [int]   $Port       = 3000,
    [switch]$NoBrowser
)

# "Continue" statt "Stop": Windows PowerShell 5.1 behandelt sonst jede Zeile, die
# podman auf stderr schreibt (auch harmlose Warnungen), als abbrechenden Fehler.
# Fehler werden stattdessen ueber den Exit-Code von podman erkannt.
$ErrorActionPreference = "Continue"

$PodName       = "flowise-pod"
$DbContainer   = "flowise-db"
$AppContainer  = "flowise"
$DbVolume      = "flowise-pg"
$HomeVolume    = "flowise-home"
$SecretName    = "flowise-key"
$DbImage       = "docker.io/library/postgres:16"
$AppImage      = "docker.io/flowiseai/flowise:$Version"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }
function Warn($msg) { Write-Host "    WARNUNG: $msg" -ForegroundColor Yellow }

function Exists($kind, $name) {
    # podman <kind> exists <name> liefert Exit-Code 0 (ja) oder 1 (nein)
    & podman $kind exists $name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Podman {
    $out  = & podman @args 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            # stderr-Meldungen anzeigen, harmlose WSL-Terminalwarnung ausblenden
            if ("$line" -notmatch 'screen size is bogus') {
                Write-Host "    $line" -ForegroundColor DarkGray
            }
        } else {
            $line
        }
    }
    if ($code -ne 0) { throw "podman $($args -join ' ') ist fehlgeschlagen (Exit-Code $code)." }
}

# --- 1. Podman pruefen und VM starten -------------------------------------
Step "Pruefe Podman"
if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    throw "podman wurde nicht gefunden. Ist Podman installiert und im PATH?"
}

$state = (& podman machine inspect --format "{{.State}}" 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $state) {
    Warn "Keine Podman-Maschine gefunden. Lege eine neue an (podman machine init)."
    Invoke-Podman machine init --memory 4096
    $state = "stopped"
}
if ($state -ne "running") {
    Info "Starte Podman-Maschine ..."
    Invoke-Podman machine start
} else {
    Info "Podman-Maschine laeuft bereits."
}

# --- 2. Volumes -----------------------------------------------------------
Step "Pruefe Volumes"
foreach ($v in @($DbVolume, $HomeVolume)) {
    if (Exists volume $v) {
        Info "Volume '$v' vorhanden - vorhandene Daten werden weiterverwendet."
    } else {
        Warn "Volume '$v' fehlt und wird neu angelegt (leer)."
        Invoke-Podman volume create $v | Out-Null
    }
}

# --- 3. Pod ---------------------------------------------------------------
Step "Pruefe Pod '$PodName'"
if (-not (Exists pod $PodName)) {
    Info "Lege Pod an (Port $Port)."
    Invoke-Podman pod create --name $PodName -p "${Port}:3000" | Out-Null
} else {
    Info "Pod vorhanden."
}

# --- 4. Datenbank-Container -----------------------------------------------
Step "Pruefe Datenbank-Container '$DbContainer'"
if (-not (Exists container $DbContainer)) {
    Info "Lege Datenbank-Container an."
    Invoke-Podman run -d --pod $PodName --name $DbContainer `
        -e POSTGRES_USER=flowise `
        -e "POSTGRES_PASSWORD=$DbPassword" `
        -e POSTGRES_DB=flowise `
        -v "${DbVolume}:/var/lib/postgresql/data" `
        $DbImage | Out-Null
} else {
    Invoke-Podman start $DbContainer | Out-Null
    Info "Datenbank-Container gestartet."
}

Info "Warte, bis die Datenbank bereit ist ..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    & podman exec $DbContainer pg_isready -U flowise 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $ready) { throw "Die Datenbank ist nach 60 Sekunden nicht bereit. Pruefe: podman logs $DbContainer" }
Info "Datenbank bereit."

# --- 5. Flowise-Container -------------------------------------------------
Step "Pruefe Flowise-Container '$AppContainer'"
if (Exists container $AppContainer) {
    $currentImage = (& podman inspect --format "{{.ImageName}}" $AppContainer)
    if ($currentImage -ne $AppImage) {
        Info "Vorhandener Container nutzt '$currentImage', gewuenscht ist '$AppImage'. Erstelle neu."
        Invoke-Podman rm -f $AppContainer | Out-Null
    }
}

if (-not (Exists container $AppContainer)) {
    $runArgs = @(
        "run", "-d", "--pod", $PodName, "--name", $AppContainer,
        "-e", "DATABASE_TYPE=postgres",
        "-e", "DATABASE_HOST=localhost",
        "-e", "DATABASE_PORT=5432",
        "-e", "DATABASE_NAME=flowise",
        "-e", "DATABASE_USER=flowise",
        "-e", "DATABASE_PASSWORD=$DbPassword",
        "-v", "${HomeVolume}:/home/node/.flowise"
    )
    if (Exists secret $SecretName) {
        Info "Verwende Podman-Secret '$SecretName' als Verschluesselungsschluessel."
        $runArgs += @("--secret", "$SecretName,type=env,target=FLOWISE_SECRETKEY_OVERWRITE")
    } else {
        Warn "Kein Secret '$SecretName' gefunden. Flowise nutzt den Schluessel aus dem Volume '$HomeVolume'."
    }
    $runArgs += $AppImage

    Info "Lade Image (falls noetig) und lege Flowise-Container an ..."
    Invoke-Podman @runArgs | Out-Null
} else {
    Invoke-Podman start $AppContainer | Out-Null
    Info "Flowise-Container gestartet."
}

# --- 6. Auf Flowise warten ------------------------------------------------
Step "Warte auf Flowise unter http://127.0.0.1:$Port"
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        $up = $true; break
    } catch { Start-Sleep -Seconds 3 }
}

if ($up) {
    Write-Host ""
    Write-Host "Flowise laeuft: http://127.0.0.1:$Port" -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port" }
} else {
    Warn "Flowise antwortet nach 3 Minuten nicht. Letzte Log-Zeilen:"
    & podman logs --tail 30 $AppContainer
    exit 1
}