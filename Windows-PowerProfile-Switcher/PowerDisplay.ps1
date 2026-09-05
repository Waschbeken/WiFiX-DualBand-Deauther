#Requires -Version 5.1
<#
    PowerDisplay.ps1

    Gemeinsame Funktionen rund um den Bildschirm: welche Bildwiederhol-
    raten das Panel anbietet, was gerade eingestellt ist, und Umschalten.

    Nutzt die Windows-eigene Anzeige-API (EnumDisplaySettings /
    ChangeDisplaySettingsEx) - kein Zusatzprogramm noetig. Bezieht sich
    immer auf den Hauptbildschirm.
#>

if (-not ('PowerProfileSwitcher.DisplayInfo' -as [type])) {
    Add-Type -Namespace PowerProfileSwitcher -Name DisplayInfo -MemberDefinition @'
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

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, int dwflags, IntPtr lParam);

public const int ENUM_CURRENT_SETTINGS = -1;
public const int CDS_UPDATEREGISTRY = 0x01;
public const int DM_DISPLAYFREQUENCY = 0x400000;

public static int CurrentRate() {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) { return 0; }
    return dm.dmDisplayFrequency;
}

public static string CurrentResolution() {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) { return "unbekannt"; }
    return dm.dmPelsWidth + " x " + dm.dmPelsHeight;
}

// Alle Frequenzen der aktuellen Aufloesung, aufsteigend.
public static int[] AvailableRates() {
    DEVMODE current = new DEVMODE();
    current.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref current)) { return new int[0]; }

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

public static int SetRate(int frequency) {
    DEVMODE dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) { return -999; }
    dm.dmDisplayFrequency = frequency;
    dm.dmFields = DM_DISPLAYFREQUENCY;
    return ChangeDisplaySettingsEx(null, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
}
'@ -UsingNamespace System.Runtime.InteropServices -ErrorAction SilentlyContinue
}

function Get-DisplayRates {
    try { return @([PowerProfileSwitcher.DisplayInfo]::AvailableRates()) } catch { return @() }
}

function Get-CurrentDisplayRate {
    try { return [PowerProfileSwitcher.DisplayInfo]::CurrentRate() } catch { return 0 }
}

function Get-CurrentDisplayResolution {
    try { return [PowerProfileSwitcher.DisplayInfo]::CurrentResolution() } catch { return 'unbekannt' }
}
