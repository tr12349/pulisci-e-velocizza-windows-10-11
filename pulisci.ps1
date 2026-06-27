<#
.SYNOPSIS
    Pulizia sicura file temporanei Windows 10/11 con auto-aggiornamento da GitHub.
.NOTES
    Versione: 1.0.0
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate
)

$ScriptVersion = [Version]"1.0.0"

# UR raw del file su GitHub (branch main)
$RemoteScriptUrl  = "https://raw.githubusercontent.com/tr12349/pulisci.ps1/main/pulisci.ps1"
# URL API per leggere l'ultimo commit del file
$RemoteCommitApi  = "https://api.github.com/repos/tr12349/pulisci.ps1/commits?path=pulisci.ps1&per_page=1"
# Commit di riferimento (quello indicato dall'utente)
$KnownCommitSha   = "b3483c0ad4b0b3b5e8eeeab428410bb817974532"

$ScriptPath = $MyInvocation.MyCommand.Path
$LocalShaFile = if ($ScriptPath) { Join-Path (Split-Path $ScriptPath) ".pulisci.sha" } else { $null }

function Write-Section($Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# AUTO-UPDATE
# ---------------------------------------------------------------------------
function Invoke-SelfUpdate {
    if ($SkipUpdate -or -not $ScriptPath) { return }

    Write-Section "Controllo aggiornamenti"
    try {
        $headers = @{ "User-Agent" = "pulisci-ps1"; "Accept" = "application/vnd.github+json" }
        $commits = Invoke-RestMethod -Uri $RemoteCommitApi -Headers $headers -TimeoutSec 15
        if (-not $commits -or $commits.Count -eq 0) {
            Write-Host "Nessun commit trovato, salto aggiornamento." -ForegroundColor Yellow
            return
        }
        $latestSha = $commits[0].sha
        $latestMsg = $commits[0].commit.message
        $latestDate = $commits[0].commit.author.date

        $currentSha = if (Test-Path $LocalShaFile) { Get-Content $LocalShaFile -Raw } else { $KnownCommitSha }
        $currentSha = $currentSha.Trim()

        Write-Host "Versione locale  : $currentSha"
        Write-Host "Versione remota  : $latestSha"

        if ($latestSha -eq $currentSha) {
            Write-Host "Script già aggiornato, nessuna azione." -ForegroundColor Green
            return
        }

        Write-Host "Trovata nuova versione del $latestDate" -ForegroundColor Yellow
        Write-Host "Note commit: $latestMsg" -ForegroundColor Yellow

        $tmp = "$ScriptPath.new"
        Invoke-WebRequest -Uri $RemoteScriptUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30

        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100) {
            throw "Download fallito o file vuoto."
        }

        # Backup
        Copy-Item $ScriptPath "$ScriptPath.bak" -Force
        Move-Item $tmp $ScriptPath -Force
        Set-Content -Path $LocalShaFile -Value $latestSha -Encoding ASCII

        Write-Host "Aggiornamento completato. Riavvio script..." -ForegroundColor Green
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -SkipUpdate
        exit
    }
    catch {
        Write-Host "Controllo aggiornamenti fallito: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Proseguo con la versione locale." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# PULIZIA SICURA
# ---------------------------------------------------------------------------
function Get-FolderSizeMB($Path) {
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0 }
        [math]::Round($bytes / 1MB, 2)
    } catch { 0 }
}

function Clear-FolderSafe {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { return 0 }

    $sizeBefore = Get-FolderSizeMB $Path
    Write-Host ("-> {0,-40} {1,8} MB" -f $Label, $sizeBefore)

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            # File in uso: ignora in sicurezza
        }
    }

    $sizeAfter = Get-FolderSizeMB $Path
    return ($sizeBefore - $sizeAfter)
}

function Invoke-Cleanup {
    Write-Section "Pulizia file temporanei (sicura)"

    if (-not (Test-Admin)) {
        Write-Host "Suggerimento: esegui come Amministratore per pulire anche le cartelle di sistema." -ForegroundColor Yellow
    }

    $targets = @(
        @{ Path = $env:TEMP;                                       Label = "Temp utente" }
        @{ Path = "$env:LOCALAPPDATA\Temp";                        Label = "LocalAppData Temp" }
        @{ Path = "C:\Windows\Temp";                               Label = "Windows Temp" }
        @{ Path = "C:\Windows\Prefetch";                           Label = "Prefetch" }
        @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Label = "IE/Edge INetCache" }
        @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\WebCache";  Label = "WebCache" }
        @{ Path = "$env:LOCALAPPDATA\CrashDumps";                  Label = "Crash Dumps" }
        @{ Path = "C:\Windows\SoftwareDistribution\Download";      Label = "Windows Update cache" }
        @{ Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache";   Label = "Edge cache" }
        @{ Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache";    Label = "Chrome cache" }
        @{ Path = "$env:APPDATA\Mozilla\Firefox\Profiles";         Label = "Firefox profiles cache" }
    )

    $totalFreed = 0
    foreach ($t in $targets) {
        $totalFreed += Clear-FolderSafe -Path $t.Path -Label $t.Label
    }

    # Cestino
    try {
        Write-Host "-> Svuoto Cestino..."
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    } catch {}

    # DISM component cleanup (solo se admin)
    if (Test-Admin) {
        Write-Section "DISM /StartComponentCleanup (sicuro, no /ResetBase)"
        try {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
            Write-Host "DISM completato." -ForegroundColor Green
        } catch {
            Write-Host "DISM non eseguito: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Section "Risultato"
    Write-Host ("Spazio liberato stimato: {0} MB" -f [math]::Round($totalFreed,2)) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-Host "pulisci.ps1 v$ScriptVersion" -ForegroundColor Cyan
Invoke-SelfUpdate
Invoke-Cleanup
