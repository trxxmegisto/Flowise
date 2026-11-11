<#
.SYNOPSIS
    Starts Flowise 3.1.4 with PostgreSQL 16 using Docker Compose.
.DESCRIPTION
    Creates a .env with random secrets only on first run and reuses named
    volumes on subsequent runs. Requires Docker Desktop (Linux containers).
    Does NOT import existing Podman data.
#>
param([switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function New-HexSecret {
    param([int]$Bytes = 32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object byte[] $Bytes
        $rng.GetBytes($buffer)
        return ([BitConverter]::ToString($buffer)).Replace('-', '').ToLowerInvariant()
    } finally { $rng.Dispose() }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI not found. Install/start Docker Desktop first.'
}
& docker info --format '{{.OSType}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker Engine unavailable. Start Docker Desktop and enable Linux containers.' }
$engineType = (& docker info --format '{{.OSType}}').Trim()
if ($engineType -ne 'linux') { throw 'Switch Docker Desktop to Linux containers.' }

& docker compose version
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose plugin not available.' }

if (-not (Test-Path -LiteralPath '.\compose.yaml')) { throw 'compose.yaml missing in the script directory.' }
if (-not (Test-Path -LiteralPath '.\.env')) {
    $password = New-HexSecret
    $secret = New-HexSecret
    $envText = "POSTGRES_PASSWORD=$password`nFLOWISE_SECRETKEY_OVERWRITE=$secret`n"
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot '.env'), $envText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Created .env with unique database password and Flowise encryption key.' -ForegroundColor Green
    Write-Host 'Back up this .env securely; losing its key can make saved credentials unreadable.' -ForegroundColor Yellow
}

$existing = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host 'Note: Port 3000 is already listening. If Docker Compose fails to bind it, stop the old app first.' -ForegroundColor Yellow
}
Write-Host 'Pulling pinned images...' -ForegroundColor Cyan
& docker compose pull
if ($LASTEXITCODE -ne 0) { throw 'docker compose pull failed.' }
Write-Host 'Starting containers...' -ForegroundColor Cyan
& docker compose up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed; inspect logs with docker compose logs --tail=100.' }
& docker compose ps
Write-Host 'Flowise URL: http://localhost:3000' -ForegroundColor Green
Write-Host 'View logs: docker compose logs -f flowise' -ForegroundColor Cyan
if (-not $NoBrowser) { Start-Process 'http://localhost:3000' }
