#Requires -Version 5.1
<#
    Profiles.ps1

    Zentrale Definition der drei Energieprofile. Sowohl Set-PowerProfile.ps1
    (setzt die Werte) als auch Test-PowerProfile.ps1 (prueft, ob sie wirklich
    angekommen sind) arbeiten mit genau dieser einen Liste - so koennen
    Soll- und Ist-Werte nicht auseinanderlaufen.

    Aufbau eines Eintrags in "Settings":
        Label    = Klartextname fuer Meldungen/Diagnose
        SubGroup = ein oder mehrere Kandidaten (Alias und/oder GUID)
        Setting  = ein oder mehrere Kandidaten (Alias und/oder GUID)
        Ac       = Wert im Netzbetrieb   (-1 = nicht setzen)
        Dc       = Wert im Akkubetrieb   (-1 = nicht setzen)

    Zeitwerte (DISKIDLE, VIDEOIDLE, STANDBYIDLE, HIBERNATEIDLE) sind
    Sekunden, 0 bedeutet "nie".
#>

# Versionsnummer dieser Fassung - wird von Update-PowerProfile.ps1 mit der
# Version im GitHub-Repository verglichen. Bei Aenderungen hochzaehlen.
$PowerProfileVersion = '2.0.0'

# Mindest-Ladestand fuer das Gaming-Profil: Liegt der Akku darunter, wird
# Gaming NICHT aktiviert (auch nicht am Netzteil) - so laedt der Akku bei
# niedrigem Stand erst wieder auf, statt unter Volllast zu haengen.
# 0 = Regel abschalten.
$GamingMinBatteryPercent = 40

# Dienste, die im Unterwegs-Profil pausiert und danach wieder gestartet
# werden ("Hintergrund-Bremse"). Es werden ausschliesslich Dienste wieder
# gestartet, die die App selbst gestoppt hat.
#   WSearch = Windows-Suchindizierung, DoSvc = Update-Auslieferungsoptimierung
$BackgroundServices = @('WSearch', 'DoSvc')

# Zusaetzliche Programme, die im Unterwegs-Profil beendet werden sollen.
# Bewusst leer - OneDrive o.ae. nur eintragen, wenn du das wirklich willst,
# z.B. @('OneDrive'). Beendete Programme startet die App NICHT wieder.
$BackgroundProcesses = @()

# "Wireless Adapter Settings" -> "Power Saving Mode"
# 0 = Maximale Leistung, 1 = Niedrig, 2 = Mittel, 3 = Maximale Einsparung
$WirelessSubGroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WirelessSetting  = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

# Energiesparmodus-Untergruppe (Alias bzw. GUID als Rueckfallebene)
$EnergySaverSubGroup = @('SUB_ENERGYSAVER', 'de830923-a562-41af-a086-e622ac0d2c1d')

# Energy Performance Preference (Alias bzw. GUID als Rueckfallebene)
$EppSetting = @('PERFEPP', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863')

$ProfileDefinitions = [ordered]@{

    Gaming = @{
        DisplayName  = 'Gaming (Hoechstleistung)'
        ShortcutName = 'Gaming - Hoechstleistung'
        FriendlyName = 'XMG Gaming (Hoechstleistung)'
        BaseScheme   = 'SCHEME_MIN'
        UseBaseDirectly = $false
        Brightness   = 100
        Hertz        = 240
        DiscreteGpu  = $true          # $true = an, $false = aus, $null = nicht anfassen
        NotifyIcon   = 0x1F3AE
        PauseBackground = $false
        NotifyText   = 'Hoechstleistung: CPU voll frei, Turbo aggressiv, 240 Hz, dedizierte GPU aktiv, WLAN auf maximale Leistung.'
        Settings = @(
            @{ Label = 'CPU Minimum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMIN';  Ac = 100; Dc = 20 }
            @{ Label = 'CPU Maximum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMAX';  Ac = 100; Dc = 100 }
            @{ Label = 'Turbo/Boost-Modus';        SubGroup = 'SUB_PROCESSOR';    Setting = 'PERFBOOSTMODE';    Ac = 2;   Dc = 1 }
            @{ Label = 'Boost-Bereitschaft (%)';   SubGroup = 'SUB_PROCESSOR';    Setting = 'PERFBOOSTPOL';     Ac = 100; Dc = 60 }
            @{ Label = 'EPP (0=Leistung)';         SubGroup = 'SUB_PROCESSOR';    Setting = $EppSetting;        Ac = 0;   Dc = 25 }
            @{ Label = 'Core Parking min (%)';     SubGroup = 'SUB_PROCESSOR';    Setting = 'CPMINCORES';       Ac = 100; Dc = 20 }
            @{ Label = 'Core Parking max (%)';     SubGroup = 'SUB_PROCESSOR';    Setting = 'CPMAXCORES';       Ac = 100; Dc = 100 }
            @{ Label = 'Festplatte aus nach (s)';  SubGroup = 'SUB_DISK';         Setting = 'DISKIDLE';         Ac = 0;   Dc = 600 }
            @{ Label = 'Bildschirm aus nach (s)';  SubGroup = 'SUB_VIDEO';        Setting = 'VIDEOIDLE';        Ac = 0;   Dc = 600 }
            @{ Label = 'Standby nach (s)';         SubGroup = 'SUB_SLEEP';        Setting = 'STANDBYIDLE';      Ac = 0;   Dc = 1200 }
            @{ Label = 'Ruhezustand nach (s)';     SubGroup = 'SUB_SLEEP';        Setting = 'HIBERNATEIDLE';    Ac = 0;   Dc = 1800 }
            @{ Label = 'Aufwachtimer';             SubGroup = 'SUB_SLEEP';        Setting = 'RTCWAKE';          Ac = 1;   Dc = 1 }
            @{ Label = 'Energiesparmodus ab (%)';  SubGroup = $EnergySaverSubGroup; Setting = 'ESBATTTHRESHOLD'; Ac = 0;  Dc = 20 }
            @{ Label = 'PCIe Stromsparen';         SubGroup = 'SUB_PCIEXPRESS';   Setting = 'ASPM';             Ac = 0;   Dc = 1 }
            @{ Label = 'USB Selektiv-Suspend';     SubGroup = 'SUB_USB';          Setting = 'USBSELECTSUSPEND'; Ac = 0;   Dc = 1 }
            @{ Label = 'WLAN-Sparmodus';           SubGroup = $WirelessSubGroup;  Setting = $WirelessSetting;   Ac = 0;   Dc = 1 }
        )
    }

    Balanced = @{
        DisplayName  = 'Ausgeglichen'
        ShortcutName = 'Ausgeglichen'
        FriendlyName = $null
        BaseScheme   = 'SCHEME_BALANCED'
        UseBaseDirectly = $true       # unveraendertes Windows-Standardschema als 'Reset'
        Brightness   = 60
        Hertz        = 0              # 0 = Bildwiederholrate nicht aendern
        DiscreteGpu  = $null          # GPU nicht anfassen
        NotifyIcon   = 0x2696
        PauseBackground = $false
        NotifyText   = 'Windows-Standardeinstellungen (Ausbalanciert).'
        Settings     = @()
    }

    Travel = @{
        DisplayName  = 'Unterwegs (Akku sparen)'
        ShortcutName = 'Unterwegs - Akku sparen'
        FriendlyName = 'XMG Unterwegs (Akku sparen)'
        BaseScheme   = 'SCHEME_MAX'
        UseBaseDirectly = $false
        Brightness   = 35
        Hertz        = 60
        DiscreteGpu  = $false
        NotifyIcon   = 0x1F50B
        PauseBackground = $true
        NotifyText   = 'Akku sparen: CPU gedrosselt, Turbo aus, 60 Hz, nur integrierte Grafik, Energiesparmodus an, WLAN im Sparmodus.'
        Settings = @(
            @{ Label = 'CPU Minimum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMIN';  Ac = 5;   Dc = 5 }
            @{ Label = 'CPU Maximum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMAX';  Ac = 100; Dc = 60 }
            @{ Label = 'Turbo/Boost-Modus';        SubGroup = 'SUB_PROCESSOR';    Setting = 'PERFBOOSTMODE';    Ac = 1;   Dc = 0 }
            @{ Label = 'Boost-Bereitschaft (%)';   SubGroup = 'SUB_PROCESSOR';    Setting = 'PERFBOOSTPOL';     Ac = 50;  Dc = 0 }
            @{ Label = 'EPP (100=Effizienz)';      SubGroup = 'SUB_PROCESSOR';    Setting = $EppSetting;        Ac = 50;  Dc = 100 }
            @{ Label = 'Core Parking min (%)';     SubGroup = 'SUB_PROCESSOR';    Setting = 'CPMINCORES';       Ac = 10;  Dc = 5 }
            @{ Label = 'Core Parking max (%)';     SubGroup = 'SUB_PROCESSOR';    Setting = 'CPMAXCORES';       Ac = 100; Dc = 50 }
            @{ Label = 'Festplatte aus nach (s)';  SubGroup = 'SUB_DISK';         Setting = 'DISKIDLE';         Ac = 600; Dc = 180 }
            @{ Label = 'Bildschirm aus nach (s)';  SubGroup = 'SUB_VIDEO';        Setting = 'VIDEOIDLE';        Ac = 300; Dc = 120 }
            @{ Label = 'Standby nach (s)';         SubGroup = 'SUB_SLEEP';        Setting = 'STANDBYIDLE';      Ac = 900; Dc = 300 }
            @{ Label = 'Ruhezustand nach (s)';     SubGroup = 'SUB_SLEEP';        Setting = 'HIBERNATEIDLE';    Ac = 1800; Dc = 900 }
            @{ Label = 'Aufwachtimer';             SubGroup = 'SUB_SLEEP';        Setting = 'RTCWAKE';          Ac = 1;   Dc = 0 }
            @{ Label = 'Energiesparmodus ab (%)';  SubGroup = $EnergySaverSubGroup; Setting = 'ESBATTTHRESHOLD'; Ac = 0;  Dc = 100 }
            @{ Label = 'Energiesparmodus Helligkeit'; SubGroup = $EnergySaverSubGroup; Setting = 'ESBRIGHTNESS'; Ac = 100; Dc = 100 }
            @{ Label = 'PCIe Stromsparen';         SubGroup = 'SUB_PCIEXPRESS';   Setting = 'ASPM';             Ac = 1;   Dc = 2 }
            @{ Label = 'USB Selektiv-Suspend';     SubGroup = 'SUB_USB';          Setting = 'USBSELECTSUSPEND'; Ac = 1;   Dc = 1 }
            @{ Label = 'WLAN-Sparmodus';           SubGroup = $WirelessSubGroup;  Setting = $WirelessSetting;   Ac = 2;   Dc = 3 }
        )
    }

    # Viertes Profil: Film schauen / Praesentation. Der Bildschirm geht nie
    # von selbst aus, die CPU laeuft trotzdem sparsam, die GPU wird nicht
    # angefasst (kein Neustart-Dialog).
    Video = @{
        DisplayName  = 'Video / Streaming'
        ShortcutName = 'Video - Bildschirm bleibt an'
        FriendlyName = 'XMG Video (Bildschirm bleibt an)'
        BaseScheme   = 'SCHEME_BALANCED'
        UseBaseDirectly = $false
        Brightness   = 55
        Hertz        = 60
        DiscreteGpu  = $null
        NotifyIcon   = 0x1F3AC
        PauseBackground = $false
        NotifyText   = 'Video: Bildschirm bleibt an, CPU sparsam ohne Turbo, 60 Hz.'
        Settings = @(
            @{ Label = 'CPU Minimum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMIN';  Ac = 5;   Dc = 5 }
            @{ Label = 'CPU Maximum (%)';          SubGroup = 'SUB_PROCESSOR';    Setting = 'PROCTHROTTLEMAX';  Ac = 100; Dc = 80 }
            @{ Label = 'Turbo/Boost-Modus';        SubGroup = 'SUB_PROCESSOR';    Setting = 'PERFBOOSTMODE';    Ac = 1;   Dc = 0 }
            @{ Label = 'EPP (100=Effizienz)';      SubGroup = 'SUB_PROCESSOR';    Setting = $EppSetting;        Ac = 40;  Dc = 70 }
            @{ Label = 'Festplatte aus nach (s)';  SubGroup = 'SUB_DISK';         Setting = 'DISKIDLE';         Ac = 0;   Dc = 900 }
            @{ Label = 'Bildschirm aus nach (s)';  SubGroup = 'SUB_VIDEO';        Setting = 'VIDEOIDLE';        Ac = 0;   Dc = 0 }
            @{ Label = 'Standby nach (s)';         SubGroup = 'SUB_SLEEP';        Setting = 'STANDBYIDLE';      Ac = 0;   Dc = 1800 }
            @{ Label = 'Ruhezustand nach (s)';     SubGroup = 'SUB_SLEEP';        Setting = 'HIBERNATEIDLE';    Ac = 0;   Dc = 3600 }
            @{ Label = 'Aufwachtimer';             SubGroup = 'SUB_SLEEP';        Setting = 'RTCWAKE';          Ac = 1;   Dc = 1 }
            @{ Label = 'PCIe Stromsparen';         SubGroup = 'SUB_PCIEXPRESS';   Setting = 'ASPM';             Ac = 1;   Dc = 2 }
            @{ Label = 'USB Selektiv-Suspend';     SubGroup = 'SUB_USB';          Setting = 'USBSELECTSUSPEND'; Ac = 1;   Dc = 1 }
            @{ Label = 'WLAN-Sparmodus';           SubGroup = $WirelessSubGroup;  Setting = $WirelessSetting;   Ac = 1;   Dc = 2 }
        )
    }
}

# --------------------------------------------------------------------------
# Benutzer-Anpassungen aus dem Konfigurationsfenster (Show-PowerSettings.ps1)
# ueberschreiben die obigen Vorgaben. So bleiben Aenderungen bei einem Update
# erhalten und es muss nichts im Skript editiert werden.
# --------------------------------------------------------------------------
$ProfileOverrideFile = Join-Path (Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher') 'profile-overrides.json'

function Set-SettingValue {
    param($Definition, [string]$SettingName, [string]$Field, $Value)
    foreach ($entry in $Definition.Settings) {
        if ($entry.Setting -contains $SettingName) {
            $entry[$Field] = [int]$Value
            return
        }
    }
}

if (Test-Path $ProfileOverrideFile) {
    try {
        $overrides = Get-Content $ProfileOverrideFile -Raw | ConvertFrom-Json

        if ($overrides.PSObject.Properties.Name -contains 'GamingMinBatteryPercent') {
            $GamingMinBatteryPercent = [int]$overrides.GamingMinBatteryPercent
        }

        foreach ($modeName in 'Gaming', 'Balanced', 'Travel', 'Video') {
            if ($overrides.PSObject.Properties.Name -notcontains $modeName) { continue }
            $o = $overrides.$modeName
            $def = $ProfileDefinitions[$modeName]
            if (-not $def -or -not $o) { continue }

            foreach ($field in 'Brightness', 'Hertz') {
                if ($o.PSObject.Properties.Name -contains $field) { $def[$field] = [int]$o.$field }
            }
            if ($o.PSObject.Properties.Name -contains 'PauseBackground') {
                $def.PauseBackground = [bool]$o.PauseBackground
            }
            if ($o.PSObject.Properties.Name -contains 'DiscreteGpu') {
                if ($null -eq $o.DiscreteGpu) { $def.DiscreteGpu = $null }
                else { $def.DiscreteGpu = [bool]$o.DiscreteGpu }
            }
            if ($o.PSObject.Properties.Name -contains 'CpuMaxAc') { Set-SettingValue $def 'PROCTHROTTLEMAX' 'Ac' $o.CpuMaxAc }
            if ($o.PSObject.Properties.Name -contains 'CpuMaxDc') { Set-SettingValue $def 'PROCTHROTTLEMAX' 'Dc' $o.CpuMaxDc }
            if ($o.PSObject.Properties.Name -contains 'BoostAc')  { Set-SettingValue $def 'PERFBOOSTMODE'   'Ac' $o.BoostAc }
            if ($o.PSObject.Properties.Name -contains 'BoostDc')  { Set-SettingValue $def 'PERFBOOSTMODE'   'Dc' $o.BoostDc }
        }
    } catch {
        Write-Warning "Benutzer-Anpassungen konnten nicht gelesen werden: $_"
    }
}
