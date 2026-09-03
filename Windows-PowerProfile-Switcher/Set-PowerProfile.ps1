#Requires -Version 5.1
<#
    Set-PowerProfile.ps1

    Schaltet mit einem Aufruf zwischen drei Windows-Energieprofilen um:
      - Gaming     : maximale Leistung (fuer Zuhause / an der Steckdose)
      - Balanced   : Windows-Standardverhalten ("Ausbalanciert")
      - Travel     : maximale Akkulaufzeit (unterwegs)

    Aendert nur Einstellungen, die Windows selbst anbietet (powercfg, WMI-
    Bildschirmhelligkeit). Luefterkurven / RGB / Akku-Ladelimit bleiben der
    XMG Control Center App vorbehalten - dafuer gibt es keine offizielle,
    von aussen ansteuerbare Schnittstelle.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Gaming', 'Balanced', 'Travel')]
    [string]$Mode,

    [switch]$NoNotify
)

$ErrorActionPreference = 'Continue'

function E {
    param([int]$CodePoint)
    try { [char]::ConvertFromUtf32($CodePoint) } catch { '' }
}

$StateDir  = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$StateFile = Join-Path $StateDir 'schemes.json'
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

# --------------------------------------------------------------------------
# Hilfsfunktionen
# --------------------------------------------------------------------------

function Write-Info($Text) { Write-Host "[PowerProfile] $Text" }

function Set-PowerValue {
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubGroup,
        [Parameter(Mandatory = $true)][string]$Setting,
        [int]$Ac = -1,
        [int]$Dc = -1
    )
    try {
        if ($Ac -ge 0) {
            powercfg /setacvalueindex $SchemeGuid $SubGroup $Setting $Ac 2>&1 | Out-Null
        }
        if ($Dc -ge 0) {
            powercfg /setdcvalueindex $SchemeGuid $SubGroup $Setting $Dc 2>&1 | Out-Null
        }
    } catch {
        Write-Warning "Konnte Einstellung $SubGroup/$Setting nicht setzen: $_"
    }
}

function Get-GuidFromText {
    param([string]$Text)
    $m = [regex]::Match($Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Load-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
    }
    return [pscustomobject]@{}
}

function Save-State($StateObj) {
    $StateObj | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Test-SchemeExists {
    param([string]$Guid)
    if (-not $Guid) { return $false }
    $list = powercfg /list 2>&1 | Out-String
    return ($list -match [regex]::Escape($Guid))
}

# Legt bei Bedarf ein eigenes Energieschema an (Kopie eines Windows-
# Basisschemas) und merkt sich die GUID, damit beim naechsten Aufruf nicht
# erneut dupliziert wird.
function Get-OrCreateScheme {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$BaseSchemeAlias,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )

    $state = Load-State
    $existingGuid = $null
    if ($state.PSObject.Properties.Name -contains $Key) {
        $existingGuid = $state.$Key
    }

    if ($existingGuid -and (Test-SchemeExists -Guid $existingGuid)) {
        return $existingGuid
    }

    Write-Info "Lege Energieschema '$FriendlyName' an ..."
    $output = powercfg /duplicatescheme $BaseSchemeAlias 2>&1 | Out-String
    $newGuid = Get-GuidFromText -Text $output
    if (-not $newGuid) {
        Write-Warning "Konnte kein neues Energieschema erstellen, verwende Basisschema."
        return $BaseSchemeAlias
    }

    powercfg /changename $newGuid "$FriendlyName" "Automatisch erstellt von PowerProfile Switcher" 2>&1 | Out-Null

    $stateHash = @{}
    foreach ($p in $state.PSObject.Properties) { $stateHash[$p.Name] = $p.Value }
    $stateHash[$Key] = $newGuid
    Save-State ([pscustomobject]$stateHash)

    return $newGuid
}

function Set-Brightness {
    param([int]$Percent)
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    try {
        $monitor = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction Stop
        $monitor.WmiSetBrightness(1, $Percent) | Out-Null
    } catch {
        Write-Warning "Helligkeit konnte nicht gesetzt werden (z.B. bei externem Monitor nicht unterstuetzt)."
    }
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    if ($NoNotify) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.ShowBalloonTip(4000)
        Start-Sleep -Milliseconds 4200
        $icon.Dispose()
    } catch {
        # Keine GUI verfuegbar (z.B. Remote-Session ohne Desktop) - einfach ignorieren.
    }
}

# GUIDs fuer "Wireless Adapter Settings" -> "Power Saving Mode".
# 0 = Maximale Leistung, 1 = Niedrige Einsparung, 2 = Mittlere Einsparung, 3 = Maximale Einsparung
$WirelessSubGroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WirelessSetting  = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

# --------------------------------------------------------------------------
# Profile anwenden
# --------------------------------------------------------------------------

switch ($Mode) {

    'Gaming' {
        $guid = Get-OrCreateScheme -Key 'Gaming' -BaseSchemeAlias 'SCHEME_MIN' -FriendlyName 'XMG Gaming (Hoechstleistung)'

        # Prozessor: volle Leistung, kein Herunterdrosseln im Leerlauf, aggressives Boosten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMIN -Ac 100 -Dc 20
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMAX -Ac 100 -Dc 100
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTMODE   -Ac 2   -Dc 1

        # Festplatte / Anzeige / Energiesparen: beim Spielen nichts abschalten (Netzbetrieb)
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_DISK  -Setting DISKIDLE      -Ac 0 -Dc 600
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_VIDEO -Setting VIDEOIDLE     -Ac 0 -Dc 600
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting STANDBYIDLE   -Ac 0 -Dc 1200
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting HIBERNATEIDLE -Ac 0 -Dc 1800

        # PCIe / USB: keine Sparmassnahmen, die Latenz/FPS kosten koennten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PCIEXPRESS -Setting ASPM              -Ac 0 -Dc 1
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_USB        -Setting USBSELECTSUSPEND  -Ac 0 -Dc 1

        # WLAN auf maximale Leistung (wichtig fuer Online-Gaming / Ping)
        Set-PowerValue -SchemeGuid $guid -SubGroup $WirelessSubGroup -Setting $WirelessSetting -Ac 0 -Dc 1

        powercfg /setactive $guid 2>&1 | Out-Null
        Set-Brightness -Percent 100

        Show-Notification -Title "$(E 0x1F3AE) Gaming-Profil aktiv" -Message "Hoechstleistung: CPU voll frei, Bildschirm bleibt an, WLAN auf maximale Leistung."
        Write-Info "Profil 'Gaming' aktiviert."
    }

    'Balanced' {
        # Bewusst unveraendertes Windows-Standardschema - dient als 'Reset'.
        powercfg /setactive SCHEME_BALANCED 2>&1 | Out-Null
        Set-Brightness -Percent 60

        Show-Notification -Title "$(E 0x2696) Ausgeglichenes Profil aktiv" -Message "Windows-Standardeinstellungen (Ausbalanciert)."
        Write-Info "Profil 'Balanced' aktiviert."
    }

    'Travel' {
        $guid = Get-OrCreateScheme -Key 'Travel' -BaseSchemeAlias 'SCHEME_MAX' -FriendlyName 'XMG Unterwegs (Akku sparen)'

        # Prozessor drosseln, um Akku zu schonen und Waerme/Luefterlaerm zu reduzieren
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMIN -Ac 5  -Dc 5
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMAX -Ac 100 -Dc 60
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTMODE   -Ac 1   -Dc 0

        # Bildschirm/Standby zuegig abschalten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_DISK  -Setting DISKIDLE      -Ac 600 -Dc 180
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_VIDEO -Setting VIDEOIDLE     -Ac 300 -Dc 120
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting STANDBYIDLE   -Ac 900 -Dc 300
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting HIBERNATEIDLE -Ac 1800 -Dc 900

        # PCIe / USB: maximale Sparmassnahmen
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PCIEXPRESS -Setting ASPM             -Ac 1 -Dc 2
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_USB        -Setting USBSELECTSUSPEND -Ac 1 -Dc 1

        # WLAN auf maximale Energieeinsparung
        Set-PowerValue -SchemeGuid $guid -SubGroup $WirelessSubGroup -Setting $WirelessSetting -Ac 2 -Dc 3

        powercfg /setactive $guid 2>&1 | Out-Null
        Set-Brightness -Percent 35

        Show-Notification -Title "$(E 0x1F50B) Unterwegs-Profil aktiv" -Message "Akku sparen: CPU gedrosselt, Bildschirm gedimmt, WLAN im Sparmodus."
        Write-Info "Profil 'Travel' aktiviert."
    }
}
