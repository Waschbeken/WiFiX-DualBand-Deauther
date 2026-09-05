#Requires -Version 5.1
<#
    Set-PowerBackground.ps1

    Schaltet den dauerhaft laufenden Teil der App (Tray-Icon und dessen
    Ueberwachung) komplett ab bzw. wieder an - ohne die App zu
    deinstallieren.

    Hintergrund: Das Tray-Icon ist ein dauerhaft laufender, versteckter
    PowerShell-Prozess. Solche Prozesse werden von Anti-Cheat-Systemen
    (besonders den kernelnahen wie Vanguard, EAC oder BattlEye) haeufig
    als verdaechtig eingestuft, weil Schadsoftware genauso aussieht.

    Ohne Hintergrunddienst funktionieren die Profile weiterhin - nur eben
    ueber die Verknuepfungen auf dem Desktop bzw. im Startmenue. Dabei
    laeuft nur fuer wenige Sekunden etwas, wenn du klickst.

    Braucht Administratorrechte (elevatiert sich selbst).
#>

param(
    [ValidateSet('Disable', 'Enable', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Show-Box {
    param([string]$Text, [string]$Icon = 'Information')
    Write-Host $Text
    try {
        $iconValue = [System.Windows.Forms.MessageBoxIcon]$Icon
        [System.Windows.Forms.MessageBox]::Show($Text, 'PowerProfile Switcher - Hintergrunddienst',
            [System.Windows.Forms.MessageBoxButtons]::OK, $iconValue) | Out-Null
    } catch { }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", '-Action', $Action
    )
    exit
}

$StateDir  = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$PauseFlag = Join-Path $StateDir 'tray-paused.flag'
$Tasks     = @('PowerProfileSwitcher-Tray', 'PowerProfileSwitcher-Watchdog')

function Stop-TrayProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

switch ($Action) {

    'Disable' {
        Stop-TrayProcess
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        (Get-Date).ToString('o') | Set-Content -Path $PauseFlag -Encoding UTF8

        $results = @()
        foreach ($task in $Tasks) {
            try {
                Disable-ScheduledTask -TaskName $task -ErrorAction Stop | Out-Null
                $results += "  - $task deaktiviert"
            } catch {
                $results += "  - $task nicht gefunden"
            }
        }

        Show-Box -Text (
            "Der Hintergrunddienst ist aus.`n`n" +
            ($results -join "`n") + "`n`n" +
            "Es laeuft jetzt dauerhaft KEIN Prozess dieser App mehr.`n" +
            "Profile umschalten geht weiterhin ueber die Verknuepfungen auf dem Desktop und im Startmenue - am besten vor dem Spielstart.`n`n" +
            "Wieder einschalten: dieses Skript mit -Action Enable ausfuehren."
        )
    }

    'Enable' {
        Remove-Item $PauseFlag -Force -ErrorAction SilentlyContinue

        $results = @()
        foreach ($task in $Tasks) {
            try {
                Enable-ScheduledTask -TaskName $task -ErrorAction Stop | Out-Null
                $results += "  - $task aktiviert"
            } catch {
                $results += "  - $task nicht gefunden (bitte Install.ps1 ausfuehren)"
            }
        }
        try { Start-ScheduledTask -TaskName 'PowerProfileSwitcher-Tray' -ErrorAction SilentlyContinue } catch { }

        Show-Box -Text ("Der Hintergrunddienst laeuft wieder.`n`n" + ($results -join "`n"))
    }

    'Status' {
        $lines = @('Zustand des Hintergrunddienstes:', '')
        foreach ($task in $Tasks) {
            try {
                $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
                $lines += ('  {0,-34} {1}' -f $task, $t.State)
            } catch {
                $lines += ('  {0,-34} nicht vorhanden' -f $task)
            }
        }
        $running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' }
        $lines += ''
        $lines += $(if ($running) { 'Das Tray-Icon laeuft gerade.' } else { 'Das Tray-Icon laeuft gerade nicht.' })
        if (Test-Path $PauseFlag) { $lines += 'Es ist bewusst pausiert (tray-paused.flag).' }
        Show-Box -Text ($lines -join "`n")
    }
}
