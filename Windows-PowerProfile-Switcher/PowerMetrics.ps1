#Requires -Version 5.1
<#
    PowerMetrics.ps1

    Gemeinsame Hilfsfunktionen zum Messen des tatsaechlichen Akku-
    Verbrauchs (Watt) und zum Hochrechnen der voraussichtlichen
    Restlaufzeit. Wird von Set-PowerProfile.ps1 und Start-Tray.ps1 per
    Dot-Sourcing eingebunden.

    Datenquelle sind die Windows-eigenen WMI-Klassen im Namespace
    root\WMI (BatteryStatus, BatteryFullChargedCapacity,
    BatteryStaticData) - kein Zusatzprogramm, keine Adminrechte noetig.

    Messen ist nur im Akkubetrieb moeglich: am Netzteil fliesst kein
    Entladestrom, den man messen koennte.
#>

# Wartezeit nach einem Profilwechsel, bis sich der Verbrauch eingependelt
# hat, sowie Anzahl/Abstand der Messpunkte danach.
$MetricsSettleSeconds  = 4
$MetricsSampleCount    = 4
$MetricsSampleInterval = 2

$MetricsFile = Join-Path (Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher') 'metrics.json'

$BatteryStaticCache     = $null
$BatteryStaticCacheTime = [DateTime]::MinValue

# Kapazitaets-Eckdaten aendern sich praktisch nie - daher gecacht, damit
# das Tray-Icon nicht alle 15 Sekunden drei WMI-Abfragen ausloest.
function Get-BatteryStaticInfo {
    if ($script:BatteryStaticCache -and
        ((Get-Date) - $script:BatteryStaticCacheTime).TotalMinutes -lt 10) {
        return $script:BatteryStaticCache
    }

    $fullRaw   = 0.0
    $designRaw = 0.0
    $cycles    = 0

    try {
        $fc = Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity -ErrorAction Stop |
              Select-Object -First 1
        if ($fc -and $null -ne $fc.FullChargedCapacity) { $fullRaw = [double]$fc.FullChargedCapacity }
    } catch { }

    try {
        $sd = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction Stop |
              Select-Object -First 1
        if ($sd) {
            if ($null -ne $sd.DesignedCapacity) { $designRaw = [double]$sd.DesignedCapacity }
            if ($null -ne $sd.CycleCount)       { $cycles    = [int]$sd.CycleCount }
        }
    } catch { }

    $script:BatteryStaticCache = [pscustomobject]@{
        FullRaw    = $fullRaw
        DesignRaw  = $designRaw
        CycleCount = $cycles
    }
    $script:BatteryStaticCacheTime = Get-Date
    return $script:BatteryStaticCache
}

# Liefert eine Momentaufnahme des Akkus oder $null, wenn kein Akku da ist
# bzw. Windows keine Werte meldet.
function Get-BatteryReading {
    $status = $null
    try {
        $status = Get-CimInstance -Namespace root/WMI -ClassName BatteryStatus -ErrorAction Stop |
                  Select-Object -First 1
    } catch { return $null }
    if (-not $status) { return $null }

    $voltageMv = 0.0
    if ($null -ne $status.Voltage) { $voltageMv = [double]$status.Voltage }

    $remainingRaw = 0.0
    if ($null -ne $status.RemainingCapacity) { $remainingRaw = [double]$status.RemainingCapacity }

    # Entladerate: bevorzugt DischargeRate, sonst das vorzeichenbehaftete Rate-Feld.
    $rateRaw = 0.0
    if ($null -ne $status.DischargeRate -and [double]$status.DischargeRate -gt 0) {
        $rateRaw = [double]$status.DischargeRate
    } elseif ($null -ne $status.Rate -and [double]$status.Rate -lt 0) {
        $rateRaw = [Math]::Abs([double]$status.Rate)
    }

    $static    = Get-BatteryStaticInfo
    $fullRaw   = $static.FullRaw
    $designRaw = $static.DesignRaw
    $cycles    = $static.CycleCount

    # Die allermeisten Geraete melden mWh/mW. Meldet ein Geraet stattdessen
    # mAh/mA (erkennbar an unplausibel kleinen Kapazitaetswerten), wird
    # ueber die Akkuspannung in Wattstunden umgerechnet.
    $factor = 0.001
    if ($fullRaw -gt 0 -and ($fullRaw / 1000.0) -lt 25 -and $voltageMv -gt 5000) {
        $factor = $voltageMv / 1000000.0
    }

    $percent = 0
    if ($fullRaw -gt 0) {
        $percent = [int][Math]::Round(100.0 * $remainingRaw / $fullRaw)
    }

    return [pscustomobject]@{
        OnAc        = [bool]$status.PowerOnline
        Discharging = [bool]$status.Discharging
        DrawWatt    = [Math]::Round($rateRaw      * $factor, 1)
        RemainingWh = [Math]::Round($remainingRaw * $factor, 1)
        FullWh      = [Math]::Round($fullRaw      * $factor, 1)
        DesignWh    = [Math]::Round($designRaw    * $factor, 1)
        CycleCount  = $cycles
        Percent     = $percent
    }
}

# Mittelt den Verbrauch ueber mehrere Messpunkte, um kurze Lastspitzen
# auszugleichen. Gibt $null zurueck, wenn nicht messbar (z.B. am Netzteil).
function Measure-PowerDraw {
    param(
        [int]$Samples  = $MetricsSampleCount,
        [int]$Interval = $MetricsSampleInterval
    )

    $values = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $r = Get-BatteryReading
        if ($r -and $r.DrawWatt -gt 0) { $values += $r.DrawWatt }
        if ($i -lt ($Samples - 1)) { Start-Sleep -Seconds $Interval }
    }

    if ($values.Count -eq 0) { return $null }
    return [Math]::Round((($values | Measure-Object -Average).Average), 1)
}

# Formatiert Stunden als "3 h 45 min".
function Format-Duration {
    param([double]$Hours)
    if ($Hours -le 0 -or [double]::IsInfinity($Hours) -or [double]::IsNaN($Hours)) { return '?' }
    if ($Hours -gt 99) { return '> 99 h' }
    $totalMinutes = [int][Math]::Round($Hours * 60)
    return ('{0} h {1:00} min' -f [int]($totalMinutes / 60), ($totalMinutes % 60))
}

function Get-ProfileMetrics {
    if (-not (Test-Path $MetricsFile)) { return $null }
    try { return (Get-Content $MetricsFile -Raw | ConvertFrom-Json) } catch { return $null }
}

# Speichert das Messergebnis eines Profils, damit sich die Profile
# spaeter miteinander vergleichen lassen.
function Save-ProfileMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][double]$Watt,
        [double]$FullWh = 0
    )
    try {
        $runtimeFullH = 0
        if ($Watt -gt 0 -and $FullWh -gt 0) { $runtimeFullH = [Math]::Round($FullWh / $Watt, 2) }

        $data = @{}
        $existing = Get-ProfileMetrics
        if ($existing) {
            foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
        }
        $data[$ModeName] = [pscustomobject]@{
            Watt         = $Watt
            RuntimeFullH = $runtimeFullH
            When         = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        }

        $dir = Split-Path -Parent $MetricsFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]$data | ConvertTo-Json | Set-Content -Path $MetricsFile -Encoding UTF8
    } catch {
        Write-Warning "Konnte Messwerte nicht speichern: $_"
    }
}

# Baut eine Vergleichszeile gegen die zuletzt gemessenen anderen Profile,
# damit man sofort sieht, wie viel ein Profil tatsaechlich bringt.
function Get-MetricsComparison {
    param([Parameter(Mandatory = $true)][string]$ExcludeMode)

    $metrics = Get-ProfileMetrics
    if (-not $metrics) { return '' }

    $names = @{ Gaming = 'Gaming'; Balanced = 'Ausgeglichen'; Travel = 'Unterwegs' }
    $parts = @()
    foreach ($key in 'Gaming', 'Balanced', 'Travel') {
        if ($key -eq $ExcludeMode) { continue }
        if ($metrics.PSObject.Properties.Name -notcontains $key) { continue }
        $entry = $metrics.$key
        if (-not $entry -or [double]$entry.Watt -le 0) { continue }
        $parts += ('{0}: {1:N1} W' -f $names[$key], [double]$entry.Watt)
    }

    if ($parts.Count -eq 0) { return '' }
    return ('Zuletzt gemessen - ' + ($parts -join ', '))
}
