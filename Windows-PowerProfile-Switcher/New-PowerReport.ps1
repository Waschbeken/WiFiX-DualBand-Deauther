#Requires -Version 5.1
<#
    New-PowerReport.ps1

    Baut aus dem laufend mitgeschriebenen Verbrauchsprotokoll
    (power-log.csv) einen HTML-Bericht mit Verlaufsdiagramm, Durchschnitts-
    werten je Profil und je Tag.

    Das Diagramm ist reines Inline-SVG - keine Bibliothek, kein Internet,
    die Datei laesst sich also auch offline oder per Mail weitergeben.

    Aufruf direkt oder ueber das Tray-Menue ("Verbrauchs-Bericht anzeigen").
#>

param(
    # Zeitraum in Tagen, der ausgewertet wird (0 = alles).
    [int]$Days = 7,

    # Bericht nur erzeugen, nicht im Browser oeffnen.
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'

$StateDir   = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$LogCsv     = Join-Path $StateDir 'power-log.csv'
$ReportFile = Join-Path $StateDir 'verbrauch.html'
$Invariant  = [System.Globalization.CultureInfo]::InvariantCulture

$MetricsScript = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
if (Test-Path $MetricsScript) { . $MetricsScript }

$Colors = @{
    Gaming    = '#e64632'
    Balanced  = '#3c82dc'
    Travel    = '#3caa5a'
    Video     = '#965ac8'
    unbekannt = '#9aa0a6'
}
$Names = @{
    Gaming    = 'Gaming'
    Balanced  = 'Ausgeglichen'
    Travel    = 'Unterwegs'
    Video     = 'Video'
    unbekannt = 'Unbekannt'
}

function Get-ProfileColor { param([string]$Name) ; if ($Colors.ContainsKey($Name)) { $Colors[$Name] } else { $Colors.unbekannt } }
function Get-ProfileName  { param([string]$Name) ; if ($Names.ContainsKey($Name))  { $Names[$Name]  } else { $Name } }

function Format-Hours {
    param([double]$Hours)
    if ($Hours -le 0 -or [double]::IsInfinity($Hours) -or [double]::IsNaN($Hours)) { return '-' }
    $total = [int][Math]::Round($Hours * 60)
    return ('{0} h {1:00} min' -f [int]($total / 60), ($total % 60))
}

function Encode-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# --- Daten einlesen ------------------------------------------------------
if (-not (Test-Path $LogCsv)) {
    $msg = 'Es wurde noch kein Verbrauchsprotokoll angelegt. Das Tray-Icon schreibt Messwerte nur im Akkubetrieb mit - bitte den Laptop eine Weile ohne Netzteil nutzen.'
    Write-Warning $msg
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($msg, 'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch { }
    exit 0
}

$samples = @()
foreach ($row in (Import-Csv -Path $LogCsv -Delimiter ';')) {
    try {
        $time = [datetime]::ParseExact($row.Zeit, 'yyyy-MM-dd HH:mm:ss', $Invariant)
        $watt = [double]::Parse($row.Watt, $Invariant)
    } catch { continue }
    if ($watt -le 0) { continue }
    if ($Days -gt 0 -and $time -lt (Get-Date).AddDays(-$Days)) { continue }

    $percent = 0
    try { $percent = [int]$row.Prozent } catch { }

    $samples += [pscustomobject]@{
        Zeit    = $time
        Profil  = $(if ($row.Profil) { $row.Profil } else { 'unbekannt' })
        Watt    = $watt
        Prozent = $percent
    }
}

if ($samples.Count -eq 0) {
    $msg = "Im gewaehlten Zeitraum ($Days Tage) liegen noch keine Messwerte vor."
    Write-Warning $msg
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($msg, 'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch { }
    exit 0
}

$samples = $samples | Sort-Object Zeit

# --- Auf eine zeichenbare Menge eindampfen -------------------------------
# Es wird nur im Akkubetrieb protokolliert, die Zeitachse zeigt also die
# tatsaechliche Akku-Nutzung, nicht die Kalenderzeit.
$maxBars   = 500
$bucketSize = [Math]::Max(1, [int][Math]::Ceiling($samples.Count / $maxBars))
$buckets = @()
for ($i = 0; $i -lt $samples.Count; $i += $bucketSize) {
    $slice = $samples[$i..([Math]::Min($i + $bucketSize - 1, $samples.Count - 1))]
    $dominant = ($slice | Group-Object Profil | Sort-Object Count -Descending | Select-Object -First 1).Name
    $buckets += [pscustomobject]@{
        Zeit   = $slice[0].Zeit
        Watt   = [Math]::Round((($slice | Measure-Object Watt -Average).Average), 2)
        Profil = $dominant
    }
}

# --- Diagramm als SVG ----------------------------------------------------
$chartW = 1000; $chartH = 300
$padL = 55; $padR = 20; $padT = 20; $padB = 42
$plotW = $chartW - $padL - $padR
$plotH = $chartH - $padT - $padB

$maxWatt = ($buckets | Measure-Object Watt -Maximum).Maximum
$yMax = [Math]::Ceiling($maxWatt / 5.0) * 5
if ($yMax -le 0) { $yMax = 5 }

$svg = New-Object System.Text.StringBuilder
[void]$svg.AppendLine("<svg viewBox=`"0 0 $chartW $chartH`" width=`"100%`" role=`"img`" aria-label=`"Verbrauchsverlauf in Watt`">")

# Gitternetz + Y-Beschriftung
for ($g = 0; $g -le 4; $g++) {
    $value = $yMax * $g / 4.0
    $y = $padT + $plotH - ($plotH * $g / 4.0)
    [void]$svg.AppendLine(("  <line x1=`"$padL`" y1=`"{0:0.#}`" x2=`"{1}`" y2=`"{0:0.#}`" class=`"grid`" />" -f $y, ($padL + $plotW)))
    [void]$svg.AppendLine(("  <text x=`"{0}`" y=`"{1:0.#}`" class=`"ylab`">{2:N0} W</text>" -f ($padL - 8), ($y + 4), $value))
}

# Balken je Messpunkt
$barW = [Math]::Max(1.0, $plotW / [double]$buckets.Count)
for ($i = 0; $i -lt $buckets.Count; $i++) {
    $b = $buckets[$i]
    $h = $plotH * ($b.Watt / $yMax)
    if ($h -lt 1) { $h = 1 }
    $x = $padL + ($plotW * $i / [double]$buckets.Count)
    $y = $padT + $plotH - $h
    $color = Get-ProfileColor -Name $b.Profil
    $title = '{0}  -  {1:N1} W  ({2})' -f $b.Zeit.ToString('dd.MM. HH:mm'), $b.Watt, (Get-ProfileName -Name $b.Profil)
    [void]$svg.AppendLine(("  <rect x=`"{0:0.##}`" y=`"{1:0.##}`" width=`"{2:0.##}`" height=`"{3:0.##}`" fill=`"{4}`"><title>{5}</title></rect>" -f `
        $x, $y, [Math]::Max(0.8, $barW - 0.3), $h, $color, (Encode-Html $title)))
}

# Achsen und X-Beschriftung
[void]$svg.AppendLine(("  <line x1=`"$padL`" y1=`"{0}`" x2=`"{1}`" y2=`"{0}`" class=`"axis`" />" -f ($padT + $plotH), ($padL + $plotW)))
$firstLabel = $buckets[0].Zeit.ToString('dd.MM. HH:mm')
$lastLabel  = $buckets[$buckets.Count - 1].Zeit.ToString('dd.MM. HH:mm')
$midLabel   = $buckets[[int]($buckets.Count / 2)].Zeit.ToString('dd.MM. HH:mm')
[void]$svg.AppendLine(("  <text x=`"$padL`" y=`"{0}`" class=`"xlab`">{1}</text>" -f ($chartH - 14), $firstLabel))
[void]$svg.AppendLine(("  <text x=`"{0}`" y=`"{1}`" class=`"xlab mid`">{2}</text>" -f ($padL + $plotW / 2), ($chartH - 14), $midLabel))
[void]$svg.AppendLine(("  <text x=`"{0}`" y=`"{1}`" class=`"xlab end`">{2}</text>" -f ($padL + $plotW), ($chartH - 14), $lastLabel))
[void]$svg.AppendLine('</svg>')

# --- Auswertungen --------------------------------------------------------
$battery = $null
if (Get-Command Get-BatteryReading -ErrorAction SilentlyContinue) { $battery = Get-BatteryReading }
$fullWh = 0.0
if ($battery -and $battery.FullWh -gt 0) { $fullWh = $battery.FullWh }

$byProfile = foreach ($group in ($samples | Group-Object Profil)) {
    $stats = $group.Group | Measure-Object Watt -Average -Minimum -Maximum
    [pscustomobject]@{
        Profil   = $group.Name
        Mittel   = [Math]::Round($stats.Average, 1)
        Min      = [Math]::Round($stats.Minimum, 1)
        Max      = [Math]::Round($stats.Maximum, 1)
        Anzahl   = $group.Count
        Laufzeit = $(if ($fullWh -gt 0 -and $stats.Average -gt 0) { Format-Hours ($fullWh / $stats.Average) } else { '-' })
    }
}
$byProfile = $byProfile | Sort-Object Mittel

$byDay = foreach ($group in ($samples | Group-Object { $_.Zeit.ToString('yyyy-MM-dd') })) {
    [pscustomobject]@{
        Tag    = $group.Name
        Mittel = [Math]::Round((($group.Group | Measure-Object Watt -Average).Average), 1)
        Anzahl = $group.Count
    }
}
$byDay = $byDay | Sort-Object Tag -Descending | Select-Object -First 14

$overall  = [Math]::Round((($samples | Measure-Object Watt -Average).Average), 1)
$measured = [Math]::Round($samples.Count * 15.0 / 3600.0, 1)   # Herzschlag = 15 s

# --- HTML zusammenbauen --------------------------------------------------
$html = New-Object System.Text.StringBuilder
[void]$html.AppendLine(@'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PowerProfile Switcher - Verbrauchsbericht</title>
<style>
  :root {
    --bg: #f6f7f9; --card: #ffffff; --text: #1c1f23; --muted: #5d646d;
    --line: #e2e5e9; --grid: #eceff2;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #16181c; --card: #1e2126; --text: #e8eaed; --muted: #9aa0a6;
            --line: #2c3037; --grid: #262a30; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 32px 20px; background: var(--bg); color: var(--text);
         font: 15px/1.5 "Segoe UI", system-ui, sans-serif; }
  .wrap { max-width: 1060px; margin: 0 auto; }
  h1 { font-size: 24px; margin: 0 0 4px; }
  .sub { color: var(--muted); margin: 0 0 28px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
          padding: 22px; margin-bottom: 22px; }
  .cards { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 22px; }
  .kpi { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
         padding: 16px 20px; flex: 1 1 180px; }
  .kpi .v { font-size: 26px; font-weight: 600; }
  .kpi .l { color: var(--muted); font-size: 13px; margin-top: 2px; }
  h2 { font-size: 16px; margin: 0 0 14px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: right; padding: 9px 10px; border-bottom: 1px solid var(--line); }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--muted); font-weight: 600; font-size: 13px; }
  tbody tr:last-child td { border-bottom: none; }
  .dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; }
  .legend { display: flex; gap: 18px; flex-wrap: wrap; color: var(--muted);
            font-size: 13px; margin-top: 12px; }
  .grid { stroke: var(--grid); stroke-width: 1; }
  .axis { stroke: var(--line); stroke-width: 1; }
  .ylab { fill: var(--muted); font-size: 11px; text-anchor: end; }
  .xlab { fill: var(--muted); font-size: 11px; }
  .xlab.mid { text-anchor: middle; }
  .xlab.end { text-anchor: end; }
  .note { color: var(--muted); font-size: 13px; margin-top: 14px; }
  .scroll { overflow-x: auto; }
</style>
</head>
<body>
<div class="wrap">
'@)

[void]$html.AppendLine("<h1>Verbrauchsbericht</h1>")
$zeitraum = if ($Days -gt 0) { "letzte $Days Tage" } else { 'gesamter Zeitraum' }
[void]$html.AppendLine(("<p class=`"sub`">Erstellt am {0} &middot; {1} &middot; {2:N0} Messpunkte</p>" -f `
    (Get-Date -Format 'dd.MM.yyyy HH:mm'), $zeitraum, $samples.Count))

[void]$html.AppendLine('<div class="cards">')
[void]$html.AppendLine(("  <div class=`"kpi`"><div class=`"v`">{0:N1} W</div><div class=`"l`">Durchschnitt gesamt</div></div>" -f $overall))
$bestProfile = $byProfile | Select-Object -First 1
if ($bestProfile) {
    [void]$html.AppendLine(("  <div class=`"kpi`"><div class=`"v`">{0:N1} W</div><div class=`"l`">Sparsamstes Profil: {1}</div></div>" -f `
        $bestProfile.Mittel, (Encode-Html (Get-ProfileName -Name $bestProfile.Profil))))
}
[void]$html.AppendLine(("  <div class=`"kpi`"><div class=`"v`">{0:N1} h</div><div class=`"l`">Aufgezeichneter Akkubetrieb</div></div>" -f $measured))
if ($fullWh -gt 0) {
    [void]$html.AppendLine(("  <div class=`"kpi`"><div class=`"v`">{0:N1} Wh</div><div class=`"l`">Akkukapazitaet aktuell</div></div>" -f $fullWh))
}
[void]$html.AppendLine('</div>')

[void]$html.AppendLine('<div class="card">')
[void]$html.AppendLine('<h2>Verlauf (Watt, farbig nach Profil)</h2>')
[void]$html.AppendLine('<div class="scroll">')
[void]$html.AppendLine($svg.ToString())
[void]$html.AppendLine('</div>')
[void]$html.AppendLine('<div class="legend">')
foreach ($key in 'Gaming', 'Balanced', 'Travel', 'Video') {
    [void]$html.AppendLine(("  <span><span class=`"dot`" style=`"background:{0}`"></span>{1}</span>" -f `
        (Get-ProfileColor -Name $key), (Get-ProfileName -Name $key)))
}
[void]$html.AppendLine('</div>')
[void]$html.AppendLine('<p class="note">Aufgezeichnet wird nur im Akkubetrieb - am Netzteil laesst sich kein Entladestrom messen. Die Zeitachse zeigt daher aneinandergereihte Akku-Phasen, nicht die durchgehende Kalenderzeit.</p>')
[void]$html.AppendLine('</div>')

[void]$html.AppendLine('<div class="card">')
[void]$html.AppendLine('<h2>Durchschnitt je Profil</h2>')
[void]$html.AppendLine('<div class="scroll"><table><thead><tr><th>Profil</th><th>Mittel</th><th>Minimum</th><th>Maximum</th><th>Laufzeit bei vollem Akku</th><th>Messpunkte</th></tr></thead><tbody>')
foreach ($p in $byProfile) {
    [void]$html.AppendLine(("<tr><td><span class=`"dot`" style=`"background:{0}`"></span>{1}</td><td>{2:N1} W</td><td>{3:N1} W</td><td>{4:N1} W</td><td>{5}</td><td>{6:N0}</td></tr>" -f `
        (Get-ProfileColor -Name $p.Profil), (Encode-Html (Get-ProfileName -Name $p.Profil)),
        $p.Mittel, $p.Min, $p.Max, (Encode-Html $p.Laufzeit), $p.Anzahl))
}
[void]$html.AppendLine('</tbody></table></div>')
if ($byProfile.Count -ge 2) {
    $cheap = $byProfile[0]; $pricey = $byProfile[$byProfile.Count - 1]
    if ($cheap.Mittel -gt 0 -and $pricey.Mittel -gt 0) {
        $saving = [int][Math]::Round(100.0 * (1 - ($cheap.Mittel / $pricey.Mittel)))
        [void]$html.AppendLine(("<p class=`"note`">{0} verbraucht im Mittel <strong>{1} %</strong> weniger als {2} - bei vollem Akku entspricht das etwa {3} statt {4}.</p>" -f `
            (Encode-Html (Get-ProfileName -Name $cheap.Profil)), $saving,
            (Encode-Html (Get-ProfileName -Name $pricey.Profil)),
            (Encode-Html $cheap.Laufzeit), (Encode-Html $pricey.Laufzeit)))
    }
}
[void]$html.AppendLine('</div>')

# --- Leistungstest, falls vorhanden --------------------------------------
$benchFile = Join-Path $StateDir 'benchmark.json'
if (Test-Path $benchFile) {
    try {
        $bench = Get-Content $benchFile -Raw | ConvertFrom-Json
        $benchRows = @()
        foreach ($key in 'Gaming', 'Balanced', 'Travel', 'Video') {
            if ($bench.PSObject.Properties.Name -notcontains $key) { continue }
            $benchRows += [pscustomobject]@{ Key = $key; Data = $bench.$key }
        }
        if ($benchRows.Count -gt 0) {
            $bestMulti = ($benchRows | ForEach-Object { [double]$_.Data.Multi } | Measure-Object -Maximum).Maximum
            [void]$html.AppendLine('<div class="card">')
            [void]$html.AppendLine('<h2>Leistungstest je Profil</h2>')
            [void]$html.AppendLine('<div class="scroll"><table><thead><tr><th>Profil</th><th>Leistung</th><th>Alle Kerne</th><th>Einkern</th><th>Verbrauch dabei</th><th>Effizienz</th><th>Gemessen</th></tr></thead><tbody>')
            foreach ($row in $benchRows) {
                $e = $row.Data
                $rel = 0
                if ($bestMulti -gt 0) { $rel = [int][Math]::Round(100.0 * [double]$e.Multi / $bestMulti) }
                $wattText = if ([double]$e.Watt -gt 0) { '{0:N1} W' -f [double]$e.Watt } else { '-' }
                $effText  = if ([double]$e.Watt -gt 0) { '{0:N2} /W' -f ([double]$e.Multi / [double]$e.Watt) } else { '-' }
                [void]$html.AppendLine(("<tr><td><span class=`"dot`" style=`"background:{0}`"></span>{1}</td><td>{2} %</td><td>{3:N2}</td><td>{4:N2}</td><td>{5}</td><td>{6}</td><td>{7}</td></tr>" -f `
                    (Get-ProfileColor -Name $row.Key), (Encode-Html (Get-ProfileName -Name $row.Key)),
                    $rel, [double]$e.Multi, [double]$e.Single,
                    (Encode-Html $wattText), (Encode-Html $effText), (Encode-Html ([string]$e.When))))
            }
            [void]$html.AppendLine('</tbody></table></div>')
            [void]$html.AppendLine('<p class="note">100 % = bestes gemessenes Profil. Die Werte sind relativ und nur untereinander vergleichbar - fuer ein faires Bild den Test in jedem Profil unter gleichen Bedingungen starten (gleiche Stromquelle, nichts anderes aktiv).</p>')
            [void]$html.AppendLine('</div>')
        }
    } catch { }
}

[void]$html.AppendLine('<div class="card">')
[void]$html.AppendLine('<h2>Durchschnitt je Tag</h2>')
[void]$html.AppendLine('<div class="scroll"><table><thead><tr><th>Tag</th><th>Mittel</th><th>Messpunkte</th></tr></thead><tbody>')
foreach ($d in $byDay) {
    $tag = ([datetime]::ParseExact($d.Tag, 'yyyy-MM-dd', $Invariant)).ToString('dd.MM.yyyy')
    [void]$html.AppendLine(("<tr><td>{0}</td><td>{1:N1} W</td><td>{2:N0}</td></tr>" -f $tag, $d.Mittel, $d.Anzahl))
}
[void]$html.AppendLine('</tbody></table></div>')
[void]$html.AppendLine('</div>')

# --- Standby-Verluste ----------------------------------------------------
$standbyCsv = Join-Path $StateDir 'standby-log.csv'
if (Test-Path $standbyCsv) {
    try {
        $standbyRows = @()
        foreach ($row in (Import-Csv -Path $standbyCsv -Delimiter ';')) {
            try {
                $standbyRows += [pscustomobject]@{
                    Ende     = [datetime]::ParseExact($row.Ende, 'yyyy-MM-dd HH:mm:ss', $Invariant)
                    Stunden  = [double]::Parse($row.Stunden, $Invariant)
                    Verlust  = [int]$row.ProzentVerlust
                    ProStd   = [double]::Parse($row.ProzentProStunde, $Invariant)
                }
            } catch { }
        }

        if ($standbyRows.Count -gt 0) {
            $standbyRows = $standbyRows | Sort-Object Ende -Descending
            $avgPerHour = [Math]::Round((($standbyRows | Measure-Object ProStd -Average).Average), 2)

            [void]$html.AppendLine('<div class="card">')
            [void]$html.AppendLine('<h2>Akkuverlust im Standby</h2>')
            [void]$html.AppendLine('<div class="scroll"><table><thead><tr><th>Aufgewacht am</th><th>Dauer</th><th>Verlust</th><th>je Stunde</th></tr></thead><tbody>')
            foreach ($r in ($standbyRows | Select-Object -First 15)) {
                [void]$html.AppendLine(("<tr><td>{0}</td><td>{1:N1} h</td><td>{2} %</td><td>{3:N2} %/h</td></tr>" -f `
                    $r.Ende.ToString('dd.MM.yyyy HH:mm'), $r.Stunden, $r.Verlust, $r.ProStd))
            }
            [void]$html.AppendLine('</tbody></table></div>')

            $projection = ''
            if ($avgPerHour -gt 0) {
                $nightLoss = [int][Math]::Round($avgPerHour * 8)
                $projection = " Bei diesem Schnitt kostet eine Nacht (8 h) etwa <strong>$nightLoss %</strong> Akku."
            }
            [void]$html.AppendLine(("<p class=`"note`">Durchschnitt: {0:N2} % pro Stunde Standby.{1} Gemessen wird die Luecke zwischen zwei Messpunkten - Modern Standby zieht auf vielen Laptops mehr, als man erwartet.</p>" -f `
                $avgPerHour, $projection))
            [void]$html.AppendLine('</div>')
        }
    } catch { }
}

# --- Akku-Gesundheitsverlauf ---------------------------------------------
$healthCsv = Join-Path $StateDir 'battery-health.csv'
if (Test-Path $healthCsv) {
    try {
        $healthRows = @()
        foreach ($row in (Import-Csv -Path $healthCsv -Delimiter ';')) {
            try {
                $healthRows += [pscustomobject]@{
                    Datum   = [datetime]::ParseExact($row.Datum, 'yyyy-MM-dd', $Invariant)
                    Voll    = [double]::Parse($row.KapazitaetWh, $Invariant)
                    Neu     = [double]::Parse($row.NeuzustandWh, $Invariant)
                    Zyklen  = [int]$row.Ladezyklen
                }
            } catch { }
        }

        if ($healthRows.Count -gt 0) {
            $healthRows = $healthRows | Sort-Object Datum
            $first = $healthRows[0]
            $last  = $healthRows[$healthRows.Count - 1]

            [void]$html.AppendLine('<div class="card">')
            [void]$html.AppendLine('<h2>Akku-Zustand im Verlauf</h2>')

            # Kleines Balkendiagramm der Kapazitaet
            $hw = 1000; $hh = 160; $hpadL = 55; $hpadR = 20; $hpadT = 14; $hpadB = 30
            $hplotW = $hw - $hpadL - $hpadR
            $hplotH = $hh - $hpadT - $hpadB
            $hMax = ($healthRows | Measure-Object Voll -Maximum).Maximum
            if ($last.Neu -gt $hMax) { $hMax = $last.Neu }
            if ($hMax -le 0) { $hMax = 1 }

            $hsvg = New-Object System.Text.StringBuilder
            [void]$hsvg.AppendLine("<svg viewBox=`"0 0 $hw $hh`" width=`"100%`" role=`"img`" aria-label=`"Akkukapazitaet im Verlauf`">")
            for ($g = 0; $g -le 2; $g++) {
                $val = $hMax * $g / 2.0
                $yy = $hpadT + $hplotH - ($hplotH * $g / 2.0)
                [void]$hsvg.AppendLine(("  <line x1=`"$hpadL`" y1=`"{0:0.#}`" x2=`"{1}`" y2=`"{0:0.#}`" class=`"grid`" />" -f $yy, ($hpadL + $hplotW)))
                [void]$hsvg.AppendLine(("  <text x=`"{0}`" y=`"{1:0.#}`" class=`"ylab`">{2:N0} Wh</text>" -f ($hpadL - 8), ($yy + 4), $val))
            }
            $hbarW = [Math]::Max(2.0, $hplotW / [double]$healthRows.Count)
            for ($i = 0; $i -lt $healthRows.Count; $i++) {
                $r = $healthRows[$i]
                $bh = $hplotH * ($r.Voll / $hMax)
                if ($bh -lt 1) { $bh = 1 }
                $bx = $hpadL + ($hplotW * $i / [double]$healthRows.Count)
                $by = $hpadT + $hplotH - $bh
                $tt = '{0}  -  {1:N1} Wh' -f $r.Datum.ToString('dd.MM.yyyy'), $r.Voll
                [void]$hsvg.AppendLine(("  <rect x=`"{0:0.##}`" y=`"{1:0.##}`" width=`"{2:0.##}`" height=`"{3:0.##}`" fill=`"#3c82dc`"><title>{4}</title></rect>" -f `
                    $bx, $by, [Math]::Max(1.5, $hbarW - 0.5), $bh, (Encode-Html $tt)))
            }
            [void]$hsvg.AppendLine(("  <text x=`"$hpadL`" y=`"{0}`" class=`"xlab`">{1}</text>" -f ($hh - 8), $first.Datum.ToString('dd.MM.yyyy')))
            [void]$hsvg.AppendLine(("  <text x=`"{0}`" y=`"{1}`" class=`"xlab end`">{2}</text>" -f ($hpadL + $hplotW), ($hh - 8), $last.Datum.ToString('dd.MM.yyyy')))
            [void]$hsvg.AppendLine('</svg>')
            [void]$html.AppendLine('<div class="scroll">')
            [void]$html.AppendLine($hsvg.ToString())
            [void]$html.AppendLine('</div>')

            $healthPercent = 0
            if ($last.Neu -gt 0) { $healthPercent = [int][Math]::Round(100.0 * $last.Voll / $last.Neu) }
            $lossText = ''
            if ($healthRows.Count -gt 1 -and $first.Voll -gt 0) {
                $diff = [Math]::Round($first.Voll - $last.Voll, 1)
                $days = [int](($last.Datum - $first.Datum).TotalDays)
                if ($days -gt 0) {
                    $lossText = ' In {0} Tagen Aufzeichnung: {1:N1} Wh Unterschied.' -f $days, $diff
                }
            }
            [void]$html.AppendLine(("<p class=`"note`">Aktuell {0:N1} Wh von {1:N1} Wh im Neuzustand - das sind <strong>{2} %</strong>.{3}{4}</p>" -f `
                $last.Voll, $last.Neu, $healthPercent, $lossText,
                $(if ($last.Zyklen -gt 0) { " Ladezyklen: $($last.Zyklen)." } else { '' })))
            [void]$html.AppendLine('<p class="note">Die Kapazitaet wird einmal taeglich festgehalten. Kurzfristige Schwankungen sind normal - aussagekraeftig wird die Kurve erst nach einigen Monaten.</p>')
            [void]$html.AppendLine('</div>')
        }
    } catch { }
}

[void]$html.AppendLine('</div></body></html>')

$html.ToString() | Set-Content -Path $ReportFile -Encoding UTF8
Write-Host "[PowerProfile] Bericht gespeichert: $ReportFile"

if (-not $NoOpen) {
    try { Start-Process $ReportFile } catch { Write-Warning "Bericht konnte nicht geoeffnet werden: $_" }
}
