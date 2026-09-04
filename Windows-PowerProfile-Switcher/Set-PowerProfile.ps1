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

    [switch]$NoNotify,

    # Laesst die dedizierte GPU unangetastet - wird vom automatischen
    # Umschalten benutzt, damit beim Ausstecken des Netzteils nicht jedes
    # Mal eine Neustart-Abfrage aufpoppt.
    [switch]$SkipGpu,

    # Laesst die Bildwiederholrate unveraendert.
    [switch]$SkipDisplay
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

# Profil-Definitionen (Sollwerte) einbinden.
. (Join-Path $PSScriptRoot 'Profiles.ps1')

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

$def = $ProfileDefinitions[$Mode]

if ($def.UseBaseDirectly) {
    # Windows-Standardschema unveraendert verwenden (dient als 'Reset')
    $guid = $def.BaseScheme
} else {
    $guid = Get-OrCreateScheme -Key $Mode -BaseSchemeAlias $def.BaseScheme -FriendlyName $def.FriendlyName
}

foreach ($s in $def.Settings) {
    Set-PowerValue -SchemeGuid $guid -SubGroup $s.SubGroup -Setting $s.Setting -Ac $s.Ac -Dc $s.Dc
}

powercfg /setactive $guid 2>&1 | Out-Null

if ($def.Brightness -gt 0) { Set-Brightness -Percent $def.Brightness }

if ($def.Hertz -gt 0) {
    if ($SkipDisplay) {
        Write-Info 'Bildwiederholrate bleibt unveraendert (-SkipDisplay).'
    } else {
        Set-RefreshRate -Hertz $def.Hertz
    }
}

if ($null -ne $def.DiscreteGpu) {
    if ($SkipGpu) {
        Write-Info 'GPU-Umschaltung uebersprungen (-SkipGpu).'
    } else {
        Set-DiscreteGpuState -Enable $def.DiscreteGpu
    }
}

Show-Notification -Title "$(E $def.NotifyIcon) $($def.DisplayName) aktiv" -Message $def.NotifyText
Write-Info "Profil '$Mode' aktiviert."

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
