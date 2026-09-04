#Requires -Version 5.1
<#
    Test-PowerPerformance.ps1

    Misst, wie viel Rechenleistung das aktuell aktive Profil liefert - und
    gleichzeitig, was es dabei verbraucht. Damit laesst sich beurteilen, ob
    die Drosselung im Unterwegs-Profil gut eingestellt ist oder ob sie zu
    viel Leistung fuer zu wenig Ersparnis kostet.

    Der Test laeuft rein rechnerisch (Gleitkomma-Schleife in .NET), einmal
    einkernig und einmal ueber alle Kerne. Gemessen wird der Durchsatz
    (Durchlaeufe je Sekunde) - ein relativer Wert, der nur im Vergleich der
    Profile untereinander Sinn ergibt, nicht als absolute Kennzahl.

    Ergebnisse landen in %LOCALAPPDATA%\PowerProfileSwitcher\benchmark.json
    und erscheinen im Verbrauchs-Bericht.

    Sinnvoll ist: Profil aktivieren -> Test starten -> naechstes Profil.
#>

param(
    # Dauer je Teiltest in Sekunden.
    [int]$Seconds = 6,

    # Ergebnis nur zurueckgeben, kein Fenster anzeigen.
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$StateDir      = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile   = Join-Path $StateDir 'current.json'
$BenchmarkFile = Join-Path $StateDir 'benchmark.json'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

$MetricsScript    = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

$Labels = @{ Gaming = 'Gaming'; Balanced = 'Ausgeglichen'; Travel = 'Unterwegs'; Video = 'Video' }

function Get-CurrentMode {
    if (-not (Test-Path $CurrentFile)) { return $null }
    try { return (Get-Content $CurrentFile -Raw | ConvertFrom-Json).Mode } catch { return $null }
}

function Show-Result {
    param([string]$Text)
    Write-Host $Text
    if ($Quiet) { return }
    try {
        [System.Windows.Forms.MessageBox]::Show($Text, 'PowerProfile Switcher - Leistungstest',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch { }
}

. (Join-Path $PSScriptRoot 'PowerBench.ps1')

$mode = Get-CurrentMode
if (-not $mode) { $mode = 'unbekannt' }
$modeLabel = if ($Labels.ContainsKey($mode)) { $Labels[$mode] } else { $mode }

Write-Host "[Benchmark] Profil '$modeLabel' wird getestet (etwa $($Seconds * 2 + 4) Sekunden) ..."

# Vorher-Werte
$wattSamples = @()
$mhzSamples  = @()

function Add-Sample {
    if ($MetricsAvailable) {
        $r = Get-BatteryReading
        if ($r -and $r.DrawWatt -gt 0) { $script:wattSamples += $r.DrawWatt }
    }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu.CurrentClockSpeed -gt 0) { $script:mhzSamples += [double]$cpu.CurrentClockSpeed }
    } catch { }
}

$singleScore = [PowerProfileSwitcher.Bench]::SingleThread($Seconds * 1000)
Add-Sample

# Mehrkern-Test in drei Abschnitten, damit der Verbrauch waehrend der Last
# gemessen werden kann und nicht erst danach (die Akku-Firmware meldet den
# Wert ohnehin leicht verzoegert).
$multiScore = Invoke-BenchmarkRun -Milliseconds ($Seconds * 1000) -Chunks 3 -OnSample { Add-Sample }

$avgWatt = 0.0
if ($wattSamples.Count -gt 0) {
    $avgWatt = [Math]::Round((($wattSamples | Measure-Object -Average).Average), 1)
}
$avgMhz = 0
if ($mhzSamples.Count -gt 0) {
    $avgMhz = [int][Math]::Round((($mhzSamples | Measure-Object -Average).Average))
}

$singleScore = [Math]::Round($singleScore, 2)
$multiScore  = [Math]::Round($multiScore, 2)

# --- Ergebnis speichern --------------------------------------------------
$data = @{}
if (Test-Path $BenchmarkFile) {
    try {
        $existing = Get-Content $BenchmarkFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) { $data[$prop.Name] = $prop.Value }
    } catch { }
}
$data[$mode] = [pscustomobject]@{
    Single = $singleScore
    Multi  = $multiScore
    Watt   = $avgWatt
    Mhz    = $avgMhz
    Kerne  = [Environment]::ProcessorCount
    When   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
}
try {
    [pscustomobject]$data | ConvertTo-Json | Set-Content -Path $BenchmarkFile -Encoding UTF8
} catch {
    Write-Warning "Ergebnis konnte nicht gespeichert werden: $_"
}

# --- Ausgabe mit Vergleich -----------------------------------------------
$lines = @()
$lines += "Profil: $modeLabel"
$lines += ''
$lines += ('Einkern-Leistung   : {0:N2} Durchlaeufe/s' -f $singleScore)
$lines += ('Alle Kerne ({0})    : {1:N2} Durchlaeufe/s' -f [Environment]::ProcessorCount, $multiScore)
if ($avgMhz -gt 0)  { $lines += ('CPU-Takt (Mittel)  : {0} MHz' -f $avgMhz) }
if ($avgWatt -gt 0) {
    $lines += ('Verbrauch dabei    : {0:N1} W' -f $avgWatt)
    $lines += ('Effizienz          : {0:N2} Durchlaeufe/s je Watt' -f ($multiScore / $avgWatt))
} else {
    $lines += 'Verbrauch          : am Netzteil nicht messbar'
}

$others = @($data.Keys | Where-Object { $_ -ne $mode })
if ($others.Count -gt 0) {
    $lines += ''
    $lines += 'Vergleich mit frueheren Messungen:'
    $best = ($data.Values | ForEach-Object { [double]$_.Multi } | Measure-Object -Maximum).Maximum
    foreach ($key in 'Gaming', 'Balanced', 'Travel', 'Video') {
        if (-not $data.ContainsKey($key)) { continue }
        $e = $data[$key]
        $relative = 0
        if ($best -gt 0) { $relative = [int][Math]::Round(100.0 * [double]$e.Multi / $best) }
        $wattText = if ([double]$e.Watt -gt 0) { '{0:N1} W' -f [double]$e.Watt } else { '- W' }
        $lines += ('  {0,-13} {1,4} % Leistung   {2,7}   ({3})' -f `
            $Labels[$key], $relative, $wattText, $e.When)
    }
    $lines += ''
    $lines += 'Hinweis: 100 % = bestes gemessenes Profil. Fuer einen fairen Vergleich'
    $lines += 'den Test in jedem Profil einmal unter gleichen Bedingungen laufen lassen'
    $lines += '(gleiche Stromquelle, keine anderen Programme aktiv).'
} else {
    $lines += ''
    $lines += 'Fuer den Vergleich den Test auch in den anderen Profilen einmal starten.'
}

Show-Result -Text ($lines -join "`n")
