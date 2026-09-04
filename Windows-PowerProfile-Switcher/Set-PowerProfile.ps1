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

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# P/Invoke-Hilfsklasse zum Setzen der Bildwiederholrate ueber die
# Windows-eigene ChangeDisplaySettingsEx-API (kein Zusatzprogramm noetig).
if (-not ('PowerProfileSwitcher.DisplayHelper' -as [type])) {
    Add-Type -Namespace PowerProfileSwitcher -Name DisplayHelper -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX;
    public int dmPositionY;
    public int dmDisplayOrientation;
    public int dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel;
    public int dmPelsWidth;
    public int dmPelsHeight;
    public int dmDisplayFlags;
    public int dmDisplayFrequency;
    public int dmICMMethod;
    public int dmICMIntent;
    public int dmMediaType;
    public int dmDitherType;
    public int dmReserved1;
    public int dmReserved2;
    public int dmPanningWidth;
    public int dmPanningHeight;
}

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, int dwflags, IntPtr lParam);

public const int ENUM_CURRENT_SETTINGS = -1;
public const int CDS_UPDATEREGISTRY = 0x01;
public const int DM_DISPLAYFREQUENCY = 0x400000;

public static int SetRefreshRate(int frequency) {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) {
        return -999;
    }
    dm.dmDisplayFrequency = frequency;
    dm.dmFields = DM_DISPLAYFREQUENCY;
    return ChangeDisplaySettingsEx(null, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
}

public static int GetCurrentRefreshRate() {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) {
        return -1;
    }
    return dm.dmDisplayFrequency;
}
'@ -UsingNamespace System.Runtime.InteropServices -ErrorAction SilentlyContinue
}

$StateDir  = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$StateFile = Join-Path $StateDir 'schemes.json'
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

# Funktionen zur Verbrauchsmessung (Watt / Restlaufzeit) einbinden.
$MetricsScript = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

# --------------------------------------------------------------------------
# Hilfsfunktionen
# --------------------------------------------------------------------------

function Write-Info($Text) { Write-Host "[PowerProfile] $Text" }

# Setzt einen Wert im Energieschema fuer Netz- (Ac) und/oder Akkubetrieb (Dc).
# SubGroup/Setting duerfen mehrere Kandidaten enthalten (Alias-Name und/oder
# GUID) - es wird der erste genommen, den powercfg auf diesem System
# akzeptiert. Nicht unterstuetzte Einstellungen werden uebersprungen, ohne
# den Rest des Profils zu blockieren.
function Set-PowerValue {
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string[]]$SubGroup,
        [Parameter(Mandatory = $true)][string[]]$Setting,
        [int]$Ac = -1,
        [int]$Dc = -1
    )
    foreach ($sub in $SubGroup) {
        foreach ($set in $Setting) {
            try {
                $ok = $true
                if ($Ac -ge 0) {
                    powercfg /setacvalueindex $SchemeGuid $sub $set $Ac 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { $ok = $false }
                }
                if ($ok -and $Dc -ge 0) {
                    powercfg /setdcvalueindex $SchemeGuid $sub $set $Dc 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { $ok = $false }
                }
                if ($ok) { return }
            } catch {
                # naechsten Kandidaten probieren
            }
        }
    }
    Write-Warning "Einstellung '$($Setting[0])' wird von diesem System nicht unterstuetzt - uebersprungen."
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

# Merkt sich das zuletzt aktivierte Profil, damit das Tray-Icon (Start-Tray.ps1)
# das passende Symbol/Tooltip anzeigen und den aktiven Menuepunkt markieren kann.
function Save-CurrentMode {
    param([string]$ModeName)
    try {
        $currentFile = Join-Path $StateDir 'current.json'
        [pscustomobject]@{ Mode = $ModeName; Timestamp = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -Path $currentFile -Encoding UTF8
    } catch {
        Write-Warning "Konnte aktuellen Modus nicht speichern: $_"
    }
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

function Set-RefreshRate {
    param([int]$Hertz)
    try {
        $current = [PowerProfileSwitcher.DisplayHelper]::GetCurrentRefreshRate()
        if ($current -eq $Hertz) {
            Write-Info "Bildwiederholrate ist bereits $Hertz Hz."
            return
        }
        $result = [PowerProfileSwitcher.DisplayHelper]::SetRefreshRate($Hertz)
        if ($result -eq 0) {
            Write-Info "Bildwiederholrate auf $Hertz Hz gesetzt."
        } else {
            Write-Warning "Bildwiederholrate $Hertz Hz wird vom Monitor/Treiber nicht unterstuetzt (Code $result)."
        }
    } catch {
        Write-Warning "Bildwiederholrate konnte nicht geaendert werden: $_"
    }
}

# Findet die dedizierte GPU (NVIDIA/AMD) unter den Anzeigegeraeten - die
# integrierte Intel-Grafik wird bewusst ausgeschlossen und nie angefasst.
function Get-DiscreteGpuDevice {
    try {
        Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
            Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

# Aktiviert/deaktiviert die dedizierte GPU per pnputil (Bordmittel, kein
# Zusatzprogramm). Beim Deaktivieren wird ein Neustart vorgeschlagen, da
# der Grafiktreiber die Ressourcen sonst oft erst nach einem Reboot
# vollstaendig freigibt.
function Set-DiscreteGpuState {
    param([Parameter(Mandatory = $true)][bool]$Enable)

    $gpu = Get-DiscreteGpuDevice
    if (-not $gpu) {
        Write-Warning 'Keine dedizierte GPU gefunden - GPU-Umschaltung wird uebersprungen.'
        return
    }

    if ($Enable -and $gpu.Status -eq 'OK') {
        Write-Info "Dedizierte GPU ist bereits aktiv: $($gpu.FriendlyName)"
        return
    }
    if (-not $Enable -and $gpu.Status -ne 'OK') {
        Write-Info "Dedizierte GPU ist bereits deaktiviert: $($gpu.FriendlyName)"
        return
    }

    $verb = if ($Enable) { '/enable-device' } else { '/disable-device' }
    Write-Info "$(if ($Enable) { 'Aktiviere' } else { 'Deaktiviere' }) dedizierte GPU: $($gpu.FriendlyName) ..."

    $output = & pnputil.exe $verb $gpu.InstanceId 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pnputil meldete einen Fehler beim Umschalten der GPU: $output"
        return
    }

    if (-not $Enable -and -not $NoNotify) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Die dedizierte Grafikkarte wurde deaktiviert - es ist nur noch die integrierte Grafik aktiv.`n`nFuer volle Wirkung (maximale Akkulaufzeit) wird ein Neustart empfohlen.`n`nJetzt in 60 Sekunden neu starten? ('shutdown /a' bricht ab)",
                'PowerProfile Switcher - Neustart empfohlen',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                shutdown.exe /r /t 60 /c 'PowerProfile Switcher: Neustart fuer GPU-Umschaltung (nur integrierte Grafik)'
            }
        } catch {
            Write-Warning 'Neustart-Abfrage konnte nicht angezeigt werden (keine interaktive Sitzung).'
        }
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

# Verhindert, dass zwei Profilwechsel gleichzeitig laufen (z.B. schnelles
# Klicken auf zwei Verknuepfungen) und sich gegenseitig ueberschreiben.
$applyMutex = New-Object System.Threading.Mutex($false, 'PowerProfileSwitcher.Apply')
$mutexHeld  = $false
try {
    $mutexHeld = $applyMutex.WaitOne(60000)
} catch [System.Threading.AbandonedMutexException] {
    # Vorheriger Lauf wurde hart beendet - wir besitzen die Sperre trotzdem.
    $mutexHeld = $true
} catch {
    $mutexHeld = $false
}

switch ($Mode) {

    'Gaming' {
        $guid = Get-OrCreateScheme -Key 'Gaming' -BaseSchemeAlias 'SCHEME_MIN' -FriendlyName 'XMG Gaming (Hoechstleistung)'

        # Prozessor: volle Leistung, kein Herunterdrosseln im Leerlauf, aggressives Boosten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMIN -Ac 100 -Dc 20
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMAX -Ac 100 -Dc 100

        # Turbo/Boost: 2 = Aggressiv (0=Aus, 1=Ein, 2=Aggressiv, 3/4 = effiziente Varianten)
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTMODE -Ac 2 -Dc 1
        # Boost-Bereitschaft in Prozent - wie schnell/oft der Turbo greift
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTPOL  -Ac 100 -Dc 60

        # EPP (Energy Performance Preference, moderne Intel-CPUs): 0 = maximale
        # Leistung, 100 = maximale Effizienz. Wirkt staerker als die reine
        # Prozent-Drosselung und ist der Regler hinter Windows' Leistungs-Schieber.
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR `
            -Setting @('PERFEPP', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863') -Ac 0 -Dc 25

        # Core Parking: im Netzbetrieb alle Kerne wach halten (kein Aufweck-Ruckler)
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting CPMINCORES -Ac 100 -Dc 20
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting CPMAXCORES -Ac 100 -Dc 100

        # Festplatte / Anzeige / Energiesparen: beim Spielen nichts abschalten (Netzbetrieb)
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_DISK  -Setting DISKIDLE      -Ac 0 -Dc 600
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_VIDEO -Setting VIDEOIDLE     -Ac 0 -Dc 600
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting STANDBYIDLE   -Ac 0 -Dc 1200
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting HIBERNATEIDLE -Ac 0 -Dc 1800

        # Aufwachtimer erlaubt (z.B. geplante Updates/Backups) - 1 = Ein
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting RTCWAKE -Ac 1 -Dc 1

        # Windows-Energiesparmodus erst spaet automatisch zuschalten (bei 20 %)
        Set-PowerValue -SchemeGuid $guid -SubGroup @('SUB_ENERGYSAVER', 'de830923-a562-41af-a086-e622ac0d2c1d') `
            -Setting ESBATTTHRESHOLD -Ac 0 -Dc 20

        # PCIe / USB: keine Sparmassnahmen, die Latenz/FPS kosten koennten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PCIEXPRESS -Setting ASPM              -Ac 0 -Dc 1
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_USB        -Setting USBSELECTSUSPEND  -Ac 0 -Dc 1

        # WLAN auf maximale Leistung (wichtig fuer Online-Gaming / Ping)
        Set-PowerValue -SchemeGuid $guid -SubGroup $WirelessSubGroup -Setting $WirelessSetting -Ac 0 -Dc 1

        powercfg /setactive $guid 2>&1 | Out-Null
        Set-Brightness -Percent 100
        Set-RefreshRate -Hertz 240
        Set-DiscreteGpuState -Enable $true

        Show-Notification -Title "$(E 0x1F3AE) Gaming-Profil aktiv" -Message "Hoechstleistung: CPU voll frei, Turbo aggressiv, 240 Hz, dedizierte GPU aktiv, WLAN auf maximale Leistung."
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

        # Turbo/Boost im Akkubetrieb komplett aus - spart am meisten Strom
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTMODE -Ac 1  -Dc 0
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PERFBOOSTPOL  -Ac 50 -Dc 0

        # EPP: im Akkubetrieb maximale Energieeffizienz
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR `
            -Setting @('PERFEPP', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863') -Ac 50 -Dc 100

        # Core Parking: im Akkubetrieb bis zur Haelfte der Kerne schlafen legen
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting CPMINCORES -Ac 10  -Dc 5
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting CPMAXCORES -Ac 100 -Dc 50

        # Bildschirm/Standby zuegig abschalten
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_DISK  -Setting DISKIDLE      -Ac 600 -Dc 180
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_VIDEO -Setting VIDEOIDLE     -Ac 300 -Dc 120
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting STANDBYIDLE   -Ac 900 -Dc 300
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting HIBERNATEIDLE -Ac 1800 -Dc 900

        # Keine Aufwachtimer im Akkubetrieb - der Laptop soll in der Tasche
        # nicht von selbst aufwachen (haeufigster Grund fuer leeren Akku + Hitze)
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_SLEEP -Setting RTCWAKE -Ac 1 -Dc 0

        # Windows-Energiesparmodus im Akkubetrieb dauerhaft aktiv (Schwelle 100 %),
        # aber ohne zusaetzliches Abdunkeln - die Helligkeit setzt das Skript selbst
        Set-PowerValue -SchemeGuid $guid -SubGroup @('SUB_ENERGYSAVER', 'de830923-a562-41af-a086-e622ac0d2c1d') `
            -Setting ESBATTTHRESHOLD -Ac 0 -Dc 100
        Set-PowerValue -SchemeGuid $guid -SubGroup @('SUB_ENERGYSAVER', 'de830923-a562-41af-a086-e622ac0d2c1d') `
            -Setting ESBRIGHTNESS -Ac 100 -Dc 100

        # PCIe / USB: maximale Sparmassnahmen
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PCIEXPRESS -Setting ASPM             -Ac 1 -Dc 2
        Set-PowerValue -SchemeGuid $guid -SubGroup SUB_USB        -Setting USBSELECTSUSPEND -Ac 1 -Dc 1

        # WLAN auf maximale Energieeinsparung
        Set-PowerValue -SchemeGuid $guid -SubGroup $WirelessSubGroup -Setting $WirelessSetting -Ac 2 -Dc 3

        powercfg /setactive $guid 2>&1 | Out-Null
        Set-Brightness -Percent 35
        Set-RefreshRate -Hertz 60
        Set-DiscreteGpuState -Enable $false

        Show-Notification -Title "$(E 0x1F50B) Unterwegs-Profil aktiv" -Message "Akku sparen: CPU gedrosselt, Turbo aus, 60 Hz, nur integrierte Grafik, Energiesparmodus an, WLAN im Sparmodus."
        Write-Info "Profil 'Travel' aktiviert."
    }
}

Save-CurrentMode -ModeName $Mode

# --------------------------------------------------------------------------
# Verbrauchsmessung: wie viel Watt zieht der Laptop mit diesem Profil und
# wie lange haelt der Akku damit ungefaehr? Nur im Akkubetrieb moeglich -
# am Netzteil fliesst kein Entladestrom, den man messen koennte.
# --------------------------------------------------------------------------
if ($MetricsAvailable) {
    $reading = Get-BatteryReading

    if (-not $reading) {
        Write-Info 'Kein Akku gefunden - Verbrauchsmessung uebersprungen.'
    } elseif ($reading.OnAc) {
        Write-Info 'Am Netzteil - Verbrauchsmessung nur im Akkubetrieb moeglich.'
    } else {
        # Kurz warten, bis sich der Verbrauch nach dem Umschalten eingependelt hat
        Start-Sleep -Seconds $MetricsSettleSeconds
        $watt = Measure-PowerDraw

        if (-not $watt) {
            Write-Warning 'Windows meldet keine Entladerate - Verbrauch nicht messbar.'
        } else {
            $after = Get-BatteryReading
            if (-not $after) { $after = $reading }

            $restText = Format-Duration -Hours ($after.RemainingWh / $watt)
            $fullText = Format-Duration -Hours ($after.FullWh / $watt)

            Save-ProfileMetrics -ModeName $Mode -Watt $watt -FullWh $after.FullWh

            $message = "{0:N1} W - Akku ({1} %) reicht noch ca. {2}, bei 100 % ca. {3}." -f `
                $watt, $after.Percent, $restText, $fullText

            $comparison = Get-MetricsComparison -ExcludeMode $Mode
            if ($comparison) { $message = "$message`n$comparison" }

            Write-Info $message
            Show-Notification -Title "$(E 0x26A1) Verbrauch: $watt W" -Message $message
        }
    }
}

if ($mutexHeld) {
    try { $applyMutex.ReleaseMutex() } catch { }
}
$applyMutex.Dispose()
