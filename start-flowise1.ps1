<#
.SYNOPSIS
    Startet vorhandene Flowise-/PostgreSQL-Container dauerhaft in der
    Rootful-Podman-Maschine, die auch Podman Desktop verwenden soll.
.DESCRIPTION
    Keine vorhandenen Pods, Container oder Volumes werden geloescht.
    Ein Image-Wechsel wird nur gemeldet, nicht automatisch durchgefuehrt.
    Ein Podman-Desktop-Anzeigeproblem kann nicht allein durch dieses
    Skript behoben werden; Hinweise werden am Ende ausgegeben.
.EXAMPLE
    .\start-flowise-podman-desktop.ps1
#>
param(
    [string]$Version = '3.1.4',
    [string]$DbPassword = 'flowise',
    [int]$Port = 3000,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$Machine       = 'podman-machine-default'
$Connection    = 'podman-machine-default-root'
$PodName       = 'flowise-pod'
$DbContainer   = 'flowise-db'
$AppContainer  = 'flowise'
$DbVolume      = 'flowise-pg'
$HomeVolume    = 'flowise-home'
$SecretName    = 'flowise-key'
$DbImage       = 'docker.io/library/postgres:16'
$AppImage      = "docker.io/flowiseai/flowise:$Version"

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info([string]$msg) { Write-Host "    $msg" }
function Warn([string]$msg) { Write-Host "    WARNUNG: $msg" -ForegroundColor Yellow }

function Invoke-Podman {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    # stderr kann bei Podman auch harmlose Warnungen enthalten.
    $output = & podman @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $s = [string]$line
        if ($s -notmatch 'screen size is bogus') { Write-Host "    $s" }
    }
    if ($exitCode -ne 0) {
        throw "podman $($Arguments -join ' ') fehlgeschlagen (Exit-Code $exitCode)."
    }
}

function Exists([string]$kind, [string]$name) {
    & podman $kind exists $name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    throw 'podman.exe nicht gefunden. Podman muss installiert und im PATH sein.'
}

Step 'Verwende vorhandene Podman-Maschine'
$machineJson = & podman machine inspect $Machine 2>$null
if ($LASTEXITCODE -ne 0 -or -not $machineJson) {
    throw "Podman-Maschine '$Machine' nicht gefunden. Keine neue Maschine wird automatisch angelegt."
}
$machineInfo = ($machineJson | Out-String | ConvertFrom-Json)[0]
if ($machineInfo.State -ne 'running') {
    Info "Starte vorhandene Maschine '$Machine' ..."
    Invoke-Podman machine start $Machine
} else {
    Info "Maschine '$Machine' laeuft."
}

Step 'Stelle Rootful-Verbindung fuer CLI und Podman Desktop ein'
# Die vorhandenen Flowise-Container wurden unter dieser Rootful-Verbindung angelegt.
$connections = & podman system connection list --format json
if ($LASTEXITCODE -ne 0) { throw 'Podman-Verbindungsliste kann nicht gelesen werden.' }
$connectionList = $connections | ConvertFrom-Json
if (@($connectionList | Where-Object { $_.Name -eq $Connection }).Count -eq 0) {
    throw "Erforderliche Verbindung '$Connection' existiert nicht. Bestehende Konfiguration nicht automatisch ersetzen."
}
Invoke-Podman system connection default $Connection
# Rootful machine mode war in der bisherigen Installation bereits aktiviert.
$machineInfo = ((& podman machine inspect $Machine | Out-String) | ConvertFrom-Json)[0]
if (-not $machineInfo.Rootful) {
    throw "Maschine ist nicht im Rootful-Modus. Um Daten-/Kontextwechsel zu vermeiden, keine automatische Umstellung. Bitte erst 'podman machine set --rootful=true' kontrolliert pruefen."
}
Invoke-Podman info --format '{{.Host.RemoteSocket.Path}}'

Step 'Pruefe persistente Volumes'
foreach ($v in @($DbVolume, $HomeVolume)) {
    if (Exists volume $v) {
        Info "Volume '$v' vorhanden."
    } else {
        Info "Lege fehlendes Volume '$v' an."
        Invoke-Podman volume create $v
    }
}

Step "Pruefe Pod '$PodName'"
if (-not (Exists pod $PodName)) {
    Invoke-Podman pod create --name $PodName -p "${Port}:3000"
} else {
    Info 'Vorhandener Pod wird weiterverwendet.'
}

Step "Pruefe PostgreSQL-Container '$DbContainer'"
if (-not (Exists container $DbContainer)) {
    Invoke-Podman run -d --restart=unless-stopped --pod $PodName --name $DbContainer `
        -e 'POSTGRES_USER=flowise' `
        -e "POSTGRES_PASSWORD=$DbPassword" `
        -e 'POSTGRES_DB=flowise' `
        -v "${DbVolume}:/var/lib/postgresql/data" `
        $DbImage
} else {
    # Restart-Policy auch bei bereits existierenden Containern setzen.
    Invoke-Podman update --restart=unless-stopped $DbContainer
    $running = & podman inspect --format '{{.State.Running}}' $DbContainer
    if (([string]$running).Trim() -ne 'true') { Invoke-Podman start $DbContainer }
}

Info 'Warte auf PostgreSQL ...'
$dbReady = $false
for ($i = 0; $i -lt 30; $i++) {
    & podman exec $DbContainer pg_isready -U flowise 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $dbReady = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $dbReady) { throw "PostgreSQL nicht bereit. Diagnose: podman logs $DbContainer" }

Step "Pruefe Flowise-Container '$AppContainer'"
if (Exists container $AppContainer) {
    $currentImage = ((& podman inspect --format '{{.ImageName}}' $AppContainer) | Out-String).Trim()
    if ($currentImage -ne $AppImage) {
        Warn "Vorhandenes Image '$currentImage', gewuenscht '$AppImage'. Kein automatisches Update/Loeschen."
    }
    Invoke-Podman update --restart=unless-stopped $AppContainer
    $running = & podman inspect --format '{{.State.Running}}' $AppContainer
    if (([string]$running).Trim() -ne 'true') { Invoke-Podman start $AppContainer }
} else {
    $runArgs = @(
        'run', '-d', '--restart=unless-stopped', '--pod', $PodName, '--name', $AppContainer,
        '-e', 'DATABASE_TYPE=postgres',
        '-e', 'DATABASE_HOST=localhost',
        '-e', 'DATABASE_PORT=5432',
        '-e', 'DATABASE_NAME=flowise',
        '-e', 'DATABASE_USER=flowise',
        '-e', "DATABASE_PASSWORD=$DbPassword",
        '-v', "${HomeVolume}:/home/node/.flowise"
    )
    if (Exists secret $SecretName) {
        $runArgs += @('--secret', "$SecretName,type=env,target=FLOWISE_SECRETKEY_OVERWRITE")
    } else {
        Warn "Podman-Secret '$SecretName' fehlt; vorhandene Flowise-Volume-Schluessel werden verwendet."
    }
    $runArgs += $AppImage
    Invoke-Podman @runArgs
}

Step 'Kontrolliere Container und Pod'
& podman pod ps
& podman ps --filter "name=flowise"

Step "Warte auf Flowise unter http://127.0.0.1:$Port"
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        $up = $true
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}
if (-not $up) {
    & podman logs --tail 30 $AppContainer
    throw 'Flowise hat innerhalb des Pruefzeitraums nicht geantwortet.'
}

Write-Host "`nFlowise erreichbar: http://127.0.0.1:$Port" -ForegroundColor Green
Info "Aktive Podman-Verbindung: $Connection (Rootful)"
Info 'Persistente Container: flowise, flowise-db'
Warn 'Podman Desktop kann nur Container anzeigen, wenn es selbst die Podman-Engine erkennt.'
Info 'Bei "No Container Engine": Podman Desktop als normaler Benutzer (nicht als Administrator) starten.'
Info 'In Podman Desktop: Troubleshooting -> Reconnect providers; ggf. Desktop beenden und neu starten.'
Info 'Keine weitere Podman-Maschine erstellen und keine Volumes loeschen.'
if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port" }
