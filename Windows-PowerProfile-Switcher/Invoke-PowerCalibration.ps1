#Requires -Version 5.1
<#
    Invoke-PowerCalibration.ps1

    Sucht automatisch die sinnvollste CPU-Obergrenze fuer das Unterwegs-
    Profil: Statt einen Wert zu raten, probiert das Skript mehrere
    Prozentwerte durch und misst bei jedem, wie viel Leistung dabei
    herauskommt und wie viel Strom das kostet.

    Ergebnis ist eine Tabelle plus Empfehlung:
      - bester Wirkungsgrad (Leistung je Watt) -> Vorschlag fuer den Akku
      - "Knick" der Kurve (guenstigster Wert mit noch fast voller Leistung)

    Auf Wunsch wird der empfohlene Wert direkt als Anpassung gespeichert
    (profile-overrides.json), sonst bleibt alles wie vorher.

    Voraussetzung: Akkubetrieb - am Netzteil laesst sich der Verbrauch
    nicht messen. Braucht Administratorrechte (elevatiert sich selbst).
#>

param(
    # Welches Profil kalibriert wird.
    [ValidateSet('Gaming', 'Balanced', 'Travel', 'Video')]
    [string]$Mode = 'Travel',

    # Zu testende CPU-Obergrenzen in Prozent.
    [int[]]$Candidates = @(40, 50, 60, 70, 85, 100),

    # Messdauer je Kandidat in Sekunden.
    [int]$Seconds = 6
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Show-Box {
    param([string]$Text, [string]$Icon = 'Information')
    Write-Host $Text
    try {
        $iconValue = [System.Windows.Forms.MessageBoxIcon]$Icon
        [System.Windows.Forms.MessageBox]::Show($Text, 'PowerProfile Switcher - Kalibrierung',
            [System.Windows.Forms.MessageBoxButtons]::OK, $iconValue) | Out-Null
    } catch { }
}

# --- Selbst-Elevation (powercfg braucht erhoehte Rechte) -----------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", '-Mode', $Mode
    )
    exit
}

$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$SchemesFile  = Join-Path $StateDir 'schemes.json'
$OverrideFile = Join-Path $StateDir 'profile-overrides.json'

. (Join-Path $PSScriptRoot 'Profiles.ps1')
. (Join-Path $PSScriptRoot 'PowerBench.ps1')

$MetricsScript    = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

if (-not $MetricsAvailable) {
    Show-Box -Text 'PowerMetrics.ps1 fehlt - ohne Verbrauchsmessung ist keine Kalibrierung moeglich.' -Icon 'Warning'
    exit 1
}

$reading = Get-BatteryReading
if (-not $reading) {
    Show-Box -Text 'Kein Akku gefunden - die Kalibrierung braucht Akkubetrieb, um den Verbrauch messen zu koennen.' -Icon 'Warning'
    exit 1
}
if ($reading.OnAc) {
    Show-Box -Text 'Der Laptop haengt am Netzteil. Am Netz laesst sich kein Verbrauch messen - bitte das Netzteil abziehen und die Kalibrierung erneut starten.' -Icon 'Warning'
    exit 1
}
if ($reading.Percent -lt 30) {
    Show-Box -Text ("Der Akku ist bei {0} %. Die Kalibrierung dauert ein bis zwei Minuten unter Volllast - bitte erst auf mindestens 30 % laden." -f $reading.Percent) -Icon 'Warning'
    exit 1
}

# --- Schema des Profils finden -------------------------------------------
$def = $ProfileDefinitions[$Mode]
$guid = $null
if ($def.UseBaseDirectly) {
    Show-Box -Text "Das Profil '$($def.DisplayName)' nutzt das unveraenderte Windows-Schema und hat keine eigene CPU-Grenze zum Kalibrieren." -Icon 'Warning'
    exit 1
}
if (Test-Path $SchemesFile) {
    try {
        $state = Get-Content $SchemesFile -Raw | ConvertFrom-Json
        if ($state.PSObject.Properties.Name -contains $Mode) { $guid = $state.$Mode }
    } catch { }
}
if (-not $guid) {
    Show-Box -Text "Das Energieschema fuer '$($def.DisplayName)' wurde noch nicht angelegt. Bitte das Profil einmal aktivieren und die Kalibrierung dann erneut starten." -Icon 'Warning'
    exit 1
}

$estimate = [int](($Candidates.Count * ($Seconds + 4)) / 60) + 1
$answer = [System.Windows.Forms.MessageBox]::Show(
    ("Die Kalibrierung testet {0} CPU-Obergrenzen ({1} %) und misst jeweils Leistung und Verbrauch.`n`nDauer: etwa {2} Minute(n) unter Volllast, der Luefter wird dabei hoerbar.`nDanach wird die urspruengliche Einstellung wiederhergestellt.`n`nJetzt starten?" -f `
        $Candidates.Count, ($Candidates -join ', '), $estimate),
    'PowerProfile Switcher - Kalibrierung',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

# --- Ausgangswert sichern -------------------------------------------------
$originalValue = 60
foreach ($entry in $def.Settings) {
    if ($entry.Setting -contains 'PROCTHROTTLEMAX') { $originalValue = [int]$entry.Dc }
}

$activeSchemeBefore = $null
try {
    $out = powercfg /getactivescheme 2>&1 | Out-String
    $m = [regex]::Match($out, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { $activeSchemeBefore = $m.Value }
} catch { }

function Set-CpuMax {
    param([int]$Percent)
    powercfg /setdcvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMAX $Percent 2>&1 | Out-Null
    powercfg /setactive $guid 2>&1 | Out-Null
}

$results = @()

try {
    foreach ($candidate in $Candidates) {
        Write-Host "[Kalibrierung] Teste $candidate % ..."
        Set-CpuMax -Percent $candidate
        Start-Sleep -Seconds 4      # einpendeln lassen

        $wattSamples = @()
        $score = Invoke-BenchmarkRun -Milliseconds ($Seconds * 1000) -Chunks 3 -OnSample {
            $r = Get-BatteryReading
            if ($r -and $r.DrawWatt -gt 0) { $script:wattSamples += $r.DrawWatt }
        }

        $watt = 0.0
        if ($wattSamples.Count -gt 0) {
            $watt = [Math]::Round((($wattSamples | Measure-Object -Average).Average), 1)
        }

        $results += [pscustomobject]@{
            Prozent    = $candidate
            Leistung   = [Math]::Round($score, 2)
            Watt       = $watt
            Wirkungsgrad = $(if ($watt -gt 0) { [Math]::Round($score / $watt, 2) } else { 0 })
        }
    }
} finally {
    # Ausgangszustand in jedem Fall wiederherstellen
    Write-Host "[Kalibrierung] Stelle urspruenglichen Wert ($originalValue %) wieder her ..."
    powercfg /setdcvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMAX $originalValue 2>&1 | Out-Null
    if ($activeSchemeBefore) { powercfg /setactive $activeSchemeBefore 2>&1 | Out-Null }
}

$measured = @($results | Where-Object { $_.Watt -gt 0 })
if ($measured.Count -lt 2) {
    Show-Box -Text 'Es konnten nicht genug Verbrauchswerte gemessen werden (meldet der Akku eine Entladerate?). Die Kalibrierung wurde abgebrochen, es wurde nichts geaendert.' -Icon 'Warning'
    exit 1
}

# --- Auswerten ------------------------------------------------------------
$bestEfficiency = ($measured | Sort-Object Wirkungsgrad -Descending | Select-Object -First 1)
$maxScore = ($measured | Measure-Object Leistung -Maximum).Maximum
# "Knick": kleinster Wert, der noch mindestens 95 % der Spitzenleistung bringt
$knee = ($measured | Where-Object { $_.Leistung -ge ($maxScore * 0.95) } | Sort-Object Prozent | Select-Object -First 1)

$lines = @()
$lines += "Kalibrierung fuer: $($def.DisplayName)"
$lines += ''
$lines += ('{0,-8} {1,12} {2,9} {3,14}' -f 'CPU max', 'Leistung', 'Watt', 'Leistung/Watt')
foreach ($r in $results) {
    $wattText = if ($r.Watt -gt 0) { '{0:N1}' -f $r.Watt } else { '-' }
    $effText  = if ($r.Watt -gt 0) { '{0:N2}' -f $r.Wirkungsgrad } else { '-' }
    $lines += ('{0,-8} {1,12:N2} {2,9} {3,14}' -f "$($r.Prozent) %", $r.Leistung, $wattText, $effText)
}
$lines += ''
$lines += ('Bester Wirkungsgrad : {0} %  ({1:N2} Leistung je Watt)' -f $bestEfficiency.Prozent, $bestEfficiency.Wirkungsgrad)
if ($knee) {
    $lines += ('Knick der Kurve     : {0} %  (ab hier bringt mehr kaum noch Leistung)' -f $knee.Prozent)
}
$lines += ('Bisher eingestellt  : {0} %' -f $originalValue)
$lines += ''
$lines += 'Empfehlung fuer den Akkubetrieb ist der beste Wirkungsgrad.'

Write-Host ($lines -join "`n")

$recommend = [int]$bestEfficiency.Prozent
$apply = [System.Windows.Forms.MessageBox]::Show(
    (($lines -join "`n") + "`n`nEmpfohlenen Wert ($recommend %) jetzt fuer '$($def.DisplayName)' uebernehmen?"),
    'PowerProfile Switcher - Kalibrierung',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)

if ($apply -ne [System.Windows.Forms.DialogResult]::Yes) {
    Write-Host '[Kalibrierung] Nichts geaendert.'
    exit 0
}

# --- Empfehlung als Anpassung speichern ----------------------------------
try {
    $overrides = @{}
    if (Test-Path $OverrideFile) {
        $existing = Get-Content $OverrideFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) { $overrides[$prop.Name] = $prop.Value }
    }

    $modeEntry = @{}
    if ($overrides.ContainsKey($Mode) -and $overrides[$Mode]) {
        foreach ($prop in $overrides[$Mode].PSObject.Properties) { $modeEntry[$prop.Name] = $prop.Value }
    }
    $modeEntry['CpuMaxDc'] = $recommend
    $overrides[$Mode] = [pscustomobject]$modeEntry

    [pscustomobject]$overrides | ConvertTo-Json -Depth 4 | Set-Content -Path $OverrideFile -Encoding UTF8

    Show-Box -Text ("Gespeichert: CPU-Maximum im Akkubetrieb fuer '{0}' steht jetzt auf {1} %.`n`nDer Wert gilt ab dem naechsten Profilwechsel - waehle das Profil einmal im Tray-Menue." -f $def.DisplayName, $recommend)
} catch {
    Show-Box -Text "Der empfohlene Wert konnte nicht gespeichert werden: $_" -Icon 'Warning'
}
