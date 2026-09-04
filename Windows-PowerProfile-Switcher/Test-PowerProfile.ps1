#Requires -Version 5.1
<#
    Test-PowerProfile.ps1

    Selbsttest: liest mit "powercfg /query" zurueck, welche der in
    Profiles.ps1 definierten Einstellungen auf DIESEM Geraet tatsaechlich
    angekommen sind, und prueft ausserdem Bildwiederholrate, GPU-Erkennung,
    Akku-Messung und die geplanten Aufgaben.

    Braucht keine Administratorrechte. Ergebnis landet als Textdatei in
    %LOCALAPPDATA%\PowerProfileSwitcher\diagnose.txt und wird (sofern eine
    Oberflaeche vorhanden ist) direkt im Editor geoeffnet.
#>

param(
    # Bericht nur zurueckgeben, nicht im Editor oeffnen.
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Profiles.ps1')

$MetricsScript    = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

$StateDir   = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$StateFile  = Join-Path $StateDir 'schemes.json'
$ReportFile = Join-Path $StateDir 'diagnose.txt'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

$report = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text = '') ; $report.Add($Text) }

# Liest den tatsaechlich gespeicherten AC/DC-Wert einer Einstellung zurueck.
# powercfg gibt die beiden aktuellen Werte als letzte Hex-Zahlen aus - das
# ist unabhaengig von der Anzeigesprache von Windows.
function Get-PowerSettingValues {
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string[]]$SubGroup,
        [Parameter(Mandatory = $true)][string[]]$Setting
    )
    foreach ($sub in $SubGroup) {
        foreach ($set in $Setting) {
            $out = powercfg /query $SchemeGuid $sub $set 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { continue }
            $hex = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
            if ($hex.Count -lt 2) { continue }
            return [pscustomobject]@{
                Ac         = [Convert]::ToInt64($hex[$hex.Count - 2].Value, 16)
                Dc         = [Convert]::ToInt64($hex[$hex.Count - 1].Value, 16)
                Identifier = "$sub / $set"
            }
        }
    }
    return $null
}

function Get-SchemeGuidForMode {
    param([string]$ModeName)
    $def = $ProfileDefinitions[$ModeName]
    if ($def.UseBaseDirectly) { return $def.BaseScheme }
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            if ($state.PSObject.Properties.Name -contains $ModeName) { return $state.$ModeName }
        } catch { }
    }
    return $null
}

Add-Line '================================================================'
Add-Line ' PowerProfile Switcher - Diagnose'
Add-Line (' Erstellt am {0}' -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))
Add-Line '================================================================'
Add-Line ''

# --- System -------------------------------------------------------------
try {
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    Add-Line ('Geraet      : {0} {1}' -f $cs.Manufacturer, $cs.Model)
    Add-Line ('Prozessor   : {0}' -f $cpu.Name.Trim())
    Add-Line ('Windows     : {0} (Build {1})' -f $os.Caption, $os.BuildNumber)
    Add-Line ('PowerShell  : {0}' -f $PSVersionTable.PSVersion)
} catch {
    Add-Line 'Systeminformationen konnten nicht gelesen werden.'
}
Add-Line ''

# --- Aktives Schema -----------------------------------------------------
$activeOut = powercfg /getactivescheme 2>&1 | Out-String
Add-Line ('Aktives Energieschema: {0}' -f $activeOut.Trim())
Add-Line ''

# --- Einstellungen je Profil pruefen ------------------------------------
$totalOk = 0; $totalDiff = 0; $totalMissing = 0

foreach ($modeName in $ProfileDefinitions.Keys) {
    $def = $ProfileDefinitions[$modeName]
    Add-Line '----------------------------------------------------------------'
    Add-Line (' Profil: {0}' -f $def.DisplayName)
    Add-Line '----------------------------------------------------------------'

    if ($def.Settings.Count -eq 0) {
        Add-Line '  (nutzt das unveraenderte Windows-Standardschema - nichts zu pruefen)'
        Add-Line ''
        continue
    }

    $guid = Get-SchemeGuidForMode -ModeName $modeName
    if (-not $guid) {
        Add-Line '  Energieschema wurde noch nicht angelegt - Profil einmal aktivieren,'
        Add-Line '  danach die Diagnose erneut ausfuehren.'
        Add-Line ''
        continue
    }
    Add-Line ('  Schema-GUID: {0}' -f $guid)
    Add-Line ''
    Add-Line ('  {0,-28} {1,12} {2,12}   {3}' -f 'Einstellung', 'Soll AC/DC', 'Ist AC/DC', 'Status')

    foreach ($s in $def.Settings) {
        $actual = Get-PowerSettingValues -SchemeGuid $guid -SubGroup $s.SubGroup -Setting $s.Setting

        if (-not $actual) {
            $status = 'NICHT UNTERSTUETZT'
            $istText = '-'
            $totalMissing++
        } else {
            $istText = '{0}/{1}' -f $actual.Ac, $actual.Dc
            $acOk = ($s.Ac -lt 0) -or ($actual.Ac -eq $s.Ac)
            $dcOk = ($s.Dc -lt 0) -or ($actual.Dc -eq $s.Dc)
            if ($acOk -and $dcOk) { $status = 'OK'; $totalOk++ }
            else { $status = 'ABWEICHUNG'; $totalDiff++ }
        }

        $sollText = '{0}/{1}' -f $s.Ac, $s.Dc
        Add-Line ('  {0,-28} {1,12} {2,12}   {3}' -f $s.Label, $sollText, $istText, $status)
    }
    Add-Line ''
}

Add-Line ('Zusammenfassung Einstellungen: {0} OK, {1} Abweichungen, {2} nicht unterstuetzt' -f `
    $totalOk, $totalDiff, $totalMissing)
Add-Line ''

# --- Bildschirm ---------------------------------------------------------
Add-Line '----------------------------------------------------------------'
Add-Line ' Bildschirm'
Add-Line '----------------------------------------------------------------'
try {
    Add-Type -Namespace PowerProfileDiag -Name Display -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

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

public static string Describe() {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) { return "unbekannt"; }
    string current = dm.dmPelsWidth + "x" + dm.dmPelsHeight + " @ " + dm.dmDisplayFrequency + " Hz";

    System.Collections.Generic.List<int> rates = new System.Collections.Generic.List<int>();
    DEVMODE probe = new DEVMODE();
    probe.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    for (int i = 0; EnumDisplaySettings(null, i, ref probe); i++) {
        if (probe.dmPelsWidth == dm.dmPelsWidth && probe.dmPelsHeight == dm.dmPelsHeight
            && !rates.Contains(probe.dmDisplayFrequency)) {
            rates.Add(probe.dmDisplayFrequency);
        }
    }
    rates.Sort();
    string list = "";
    for (int i = 0; i < rates.Count; i++) {
        if (i > 0) { list += ", "; }
        list += rates[i] + " Hz";
    }
    return current + "  |  moegliche Frequenzen: " + list;
}
'@ -UsingNamespace System.Runtime.InteropServices -ErrorAction Stop

    Add-Line ('  Hauptbildschirm: {0}' -f [PowerProfileDiag.Display]::Describe())

    foreach ($modeName in 'Gaming', 'Travel') {
        $wanted = $ProfileDefinitions[$modeName].Hertz
        if ($wanted -gt 0) {
            Add-Line ('  Profil {0} moechte {1} Hz - siehe Liste oben, ob der Wert dabei ist.' -f $modeName, $wanted)
        }
    }
} catch {
    Add-Line "  Bildschirminformationen konnten nicht gelesen werden: $_"
}
Add-Line ''

# --- Grafikkarten -------------------------------------------------------
Add-Line '----------------------------------------------------------------'
Add-Line ' Grafik'
Add-Line '----------------------------------------------------------------'
try {
    $displays = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop
    foreach ($d in $displays) {
        Add-Line ('  {0,-45} Status: {1}' -f $d.FriendlyName, $d.Status)
    }
    $discrete = $displays | Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
                Select-Object -First 1
    Add-Line ''
    if ($discrete) {
        Add-Line ('  Als dedizierte GPU erkannt: {0} (Status {1})' -f $discrete.FriendlyName, $discrete.Status)
        Add-Line '  -> Das Unterwegs-Profil wuerde genau dieses Geraet deaktivieren.'
    } else {
        Add-Line '  Keine dedizierte GPU erkannt - die GPU-Umschaltung wird uebersprungen.'
    }
} catch {
    Add-Line "  Grafikgeraete konnten nicht gelesen werden: $_"
}
Add-Line ''

# --- Akku / Verbrauchsmessung -------------------------------------------
Add-Line '----------------------------------------------------------------'
Add-Line ' Akku und Verbrauchsmessung'
Add-Line '----------------------------------------------------------------'
if (-not $MetricsAvailable) {
    Add-Line '  PowerMetrics.ps1 nicht gefunden - Messung nicht verfuegbar.'
} else {
    $r = Get-BatteryReading
    if (-not $r) {
        Add-Line '  Kein Akku gefunden (oder WMI liefert keine Werte).'
    } else {
        Add-Line ('  Stromquelle    : {0}' -f $(if ($r.OnAc) { 'Netzteil' } else { 'Akku' }))
        Add-Line ('  Ladestand      : {0} % ({1} von {2} Wh)' -f $r.Percent, $r.RemainingWh, $r.FullWh)
        if ($r.DesignWh -gt 0) {
            $health = [int][Math]::Round(100.0 * $r.FullWh / $r.DesignWh)
            Add-Line ('  Akku-Zustand   : {0} % (Neuzustand {1} Wh)' -f $health, $r.DesignWh)
        }
        if ($r.CycleCount -gt 0) { Add-Line ('  Ladezyklen     : {0}' -f $r.CycleCount) }

        if ($r.DrawWatt -gt 0) {
            Add-Line ('  Aktueller Verbrauch: {0:N1} W -> Restlaufzeit ca. {1}' -f `
                $r.DrawWatt, (Format-Duration -Hours ($r.RemainingWh / $r.DrawWatt)))
            Add-Line '  -> Verbrauchsmessung funktioniert auf diesem Geraet.'
        } elseif ($r.OnAc) {
            Add-Line '  Verbrauch: am Netzteil nicht messbar (normal). Fuer einen echten Test'
            Add-Line '  bitte das Netzteil abziehen und die Diagnose erneut ausfuehren.'
        } else {
            Add-Line '  ACHTUNG: Im Akkubetrieb, aber Windows meldet keine Entladerate.'
            Add-Line '  -> Die Wattanzeige bleibt auf diesem Geraet leer.'
        }
    }
}
Add-Line ''

# --- Geplante Aufgaben --------------------------------------------------
Add-Line '----------------------------------------------------------------'
Add-Line ' Geplante Aufgaben'
Add-Line '----------------------------------------------------------------'
foreach ($taskName in 'PowerProfileSwitcher-Gaming', 'PowerProfileSwitcher-Balanced',
                      'PowerProfileSwitcher-Travel', 'PowerProfileSwitcher-Travel-NoGpu',
                      'PowerProfileSwitcher-Tray') {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        $last = if ($info -and $info.LastRunTime) { $info.LastRunTime } else { 'nie' }
        Add-Line ('  {0,-38} {1,-10} zuletzt: {2}' -f $taskName, $task.State, $last)
    } catch {
        Add-Line ('  {0,-38} FEHLT - Install.ps1 erneut ausfuehren' -f $taskName)
    }
}
Add-Line ''
Add-Line 'Ende des Berichts.'

$text = $report -join "`r`n"
$text | Set-Content -Path $ReportFile -Encoding UTF8
Write-Output $text

if (-not $NoOpen) {
    try { Start-Process notepad.exe -ArgumentList "`"$ReportFile`"" } catch { }
}
