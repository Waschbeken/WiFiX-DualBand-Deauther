#Requires -Version 5.1
<#
    Start-PowerSetup.ps1

    Einrichtungs-Assistent: liest die tatsaechliche Hardware aus (welche
    Bildwiederholraten das Panel wirklich kann, ob eine dedizierte GPU da
    ist, wie gross der Akku ist, wie viele Kerne die CPU hat) und leitet
    daraus passende Startwerte fuer die Profile ab.

    Damit stehen dort gemessene statt geratener Werte - z.B. 240 Hz nur
    dann, wenn das Panel das auch anbietet.

    Speichert wie das Einstellungsfenster nach profile-overrides.json.
    Braucht keine Administratorrechte.
#>

param(
    # Wird vom Tray beim ersten Start verwendet: nur anzeigen, wenn noch
    # keine Einrichtung stattgefunden hat.
    [switch]$OnlyIfFirstRun
)

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$OverrideFile = Join-Path $StateDir 'profile-overrides.json'
$SetupMarker  = Join-Path $StateDir 'setup-done.txt'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

if ($OnlyIfFirstRun -and (Test-Path $SetupMarker)) { exit 0 }

. (Join-Path $PSScriptRoot 'Profiles.ps1')

$MetricsScript = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
if (Test-Path $MetricsScript) { . $MetricsScript }

# --- Hardware auslesen ---------------------------------------------------
if (-not ('PowerProfileSetup.Display' -as [type])) {
    Add-Type -Namespace PowerProfileSetup -Name Display -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
    public short dmDriverExtra; public int dmFields;
    public int dmPositionX; public int dmPositionY;
    public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution;
    public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel;
    public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
    public int dmDitherType; public int dmReserved1; public int dmReserved2;
    public int dmPanningWidth; public int dmPanningHeight;
}

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

// Alle Bildwiederholraten der aktuellen Aufloesung, aufsteigend sortiert.
public static int[] GetRates() {
    DEVMODE current = new DEVMODE();
    current.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref current)) { return new int[0]; }

    System.Collections.Generic.List<int> rates = new System.Collections.Generic.List<int>();
    DEVMODE probe = new DEVMODE();
    probe.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    for (int i = 0; EnumDisplaySettings(null, i, ref probe); i++) {
        if (probe.dmPelsWidth == current.dmPelsWidth &&
            probe.dmPelsHeight == current.dmPelsHeight &&
            probe.dmDisplayFrequency > 20 &&
            !rates.Contains(probe.dmDisplayFrequency)) {
            rates.Add(probe.dmDisplayFrequency);
        }
    }
    rates.Sort();
    return rates.ToArray();
}

public static string GetResolution() {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) { return "unbekannt"; }
    return dm.dmPelsWidth + " x " + dm.dmPelsHeight;
}
'@ -UsingNamespace System.Runtime.InteropServices -ErrorAction SilentlyContinue
}

$rates = @()
$resolution = 'unbekannt'
try {
    $rates = @([PowerProfileSetup.Display]::GetRates())
    $resolution = [PowerProfileSetup.Display]::GetResolution()
} catch { }

$maxHz = 0
$lowHz = 0
if ($rates.Count -gt 0) {
    $maxHz = ($rates | Measure-Object -Maximum).Maximum
    # Niedrigste Rate ab 48 Hz - darunter flackert es auf vielen Panels
    $lowCandidates = $rates | Where-Object { $_ -ge 48 }
    if ($lowCandidates) { $lowHz = ($lowCandidates | Measure-Object -Minimum).Minimum }
    else { $lowHz = $maxHz }
}

$cpuName = 'unbekannt'; $cores = [Environment]::ProcessorCount
try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cpuName = $cpu.Name.Trim()
} catch { }

$gpuName = $null
try {
    $gpuName = (Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
                Select-Object -First 1).FriendlyName
} catch { }

$battery = $null
if (Get-Command Get-BatteryReading -ErrorAction SilentlyContinue) { $battery = Get-BatteryReading }

# --- Vorschlaege ableiten ------------------------------------------------
$suggest = @{
    Gaming   = @{ Hertz = $(if ($maxHz -gt 0) { $maxHz } else { [int]$ProfileDefinitions.Gaming.Hertz }); Brightness = 100 }
    Balanced = @{ Hertz = 0;  Brightness = 60 }
    Travel   = @{ Hertz = $(if ($lowHz -gt 0) { $lowHz } else { 60 }); Brightness = 35 }
    Video    = @{ Hertz = $(if ($lowHz -gt 0) { $lowHz } else { 60 }); Brightness = 55 }
}

$lines = @()
$lines += "Prozessor      : $cpuName ($cores logische Kerne)"
$lines += "Bildschirm     : $resolution"
if ($rates.Count -gt 0) {
    $lines += ("Frequenzen     : " + (($rates | ForEach-Object { "$_ Hz" }) -join ', '))
} else {
    $lines += 'Frequenzen     : konnten nicht ermittelt werden'
}
if ($gpuName) { $lines += "Dedizierte GPU : $gpuName" }
else          { $lines += 'Dedizierte GPU : keine erkannt (GPU-Umschaltung entfaellt)' }
if ($battery -and $battery.FullWh -gt 0) {
    $healthText = ''
    if ($battery.DesignWh -gt 0) {
        $healthText = ' - Zustand {0} %' -f [int][Math]::Round(100.0 * $battery.FullWh / $battery.DesignWh)
    }
    $lines += ("Akku           : {0} Wh{1}" -f $battery.FullWh, $healthText)
} else {
    $lines += 'Akku           : keine Angaben (Verbrauchsmessung eingeschraenkt)'
}

$lines += ''
$lines += 'Vorgeschlagene Werte:'
$lines += ('  Gaming       : {0} Hz, Helligkeit {1} %' -f $suggest.Gaming.Hertz, $suggest.Gaming.Brightness)
$lines += ('  Ausgeglichen : Bildwiederholrate unveraendert, Helligkeit {0} %' -f $suggest.Balanced.Brightness)
$lines += ('  Unterwegs    : {0} Hz, Helligkeit {1} %' -f $suggest.Travel.Hertz, $suggest.Travel.Brightness)
$lines += ('  Video        : {0} Hz, Helligkeit {1} %' -f $suggest.Video.Hertz, $suggest.Video.Brightness)

if ($maxHz -gt 0 -and $maxHz -ne [int]$ProfileDefinitions.Gaming.Hertz) {
    $lines += ''
    $lines += ('Hinweis: Bisher standen im Gaming-Profil {0} Hz, dein Panel meldet aber {1} Hz als Maximum.' -f `
        [int]$ProfileDefinitions.Gaming.Hertz, $maxHz)
}

$lines += ''
$lines += 'Die CPU-Grenzen bleiben unveraendert - dafuer gibt es die Kalibrierung'
$lines += 'im Tray-Menue, die den besten Wert misst statt ihn zu schaetzen.'

$message = ($lines -join "`n") + "`n`nDiese Werte jetzt uebernehmen?"

$answer = [System.Windows.Forms.MessageBox]::Show(
    $message, 'PowerProfile Switcher - Einrichtung',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)

# Auch bei "Nein" gilt die Einrichtung als erledigt, damit der Assistent
# nicht bei jeder Anmeldung erneut aufpoppt.
try { (Get-Date).ToString('o') | Set-Content -Path $SetupMarker -Encoding UTF8 } catch { }

if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

# --- Uebernehmen ---------------------------------------------------------
try {
    $overrides = @{}
    if (Test-Path $OverrideFile) {
        $existing = Get-Content $OverrideFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) { $overrides[$prop.Name] = $prop.Value }
    }

    foreach ($key in 'Gaming', 'Balanced', 'Travel', 'Video') {
        $entry = @{}
        if ($overrides.ContainsKey($key) -and $overrides[$key]) {
            foreach ($prop in $overrides[$key].PSObject.Properties) { $entry[$prop.Name] = $prop.Value }
        }
        $entry['Hertz']      = [int]$suggest[$key].Hertz
        $entry['Brightness'] = [int]$suggest[$key].Brightness
        $overrides[$key] = [pscustomobject]$entry
    }

    [pscustomobject]$overrides | ConvertTo-Json -Depth 4 | Set-Content -Path $OverrideFile -Encoding UTF8

    # Tray neu starten, damit die Werte sofort gelten
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-ScheduledTask -TaskName 'PowerProfileSwitcher-Tray' -ErrorAction SilentlyContinue
    } catch { }

    [System.Windows.Forms.MessageBox]::Show(
        "Uebernommen. Die Werte gelten ab dem naechsten Profilwechsel.`n`nTipp: Wenn du unterwegs bist, einmal die Kalibrierung im Tray-Menue laufen lassen - die misst die beste CPU-Grenze fuer deinen Akku.",
        'PowerProfile Switcher - Einrichtung',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show("Speichern fehlgeschlagen: $_", 'PowerProfile Switcher',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
