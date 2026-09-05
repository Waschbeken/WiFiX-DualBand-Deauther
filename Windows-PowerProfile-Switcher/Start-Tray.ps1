#Requires -Version 5.1
<#
    Start-Tray.ps1

    Symbol im Windows-Infobereich (Tray) mit Menue zum sofortigen
    Umschalten der Energieprofile. Laeuft OHNE Administratorrechte und
    loest nur die per Install.ps1 angelegten geplanten Aufgaben aus, die
    bereits erhoehte Rechte haben - daher kein UAC-Fenster beim Umschalten.

    Funktionen:
      - Umschalten per Menue oder Hotkey (Strg+Alt+1/2/3)
      - Live-Anzeige von Verbrauch (W) und Restlaufzeit
      - Protokolliert die Messwerte, um echte Durchschnittswerte je Profil
        zu bilden (power-log.csv)
      - Optionales automatisches Umschalten beim An-/Abstecken des Netzteils
      - Warnung bei 20 % / 10 % Akku mit geschaetzter Restlaufzeit
      - Diagnose-Bericht (Test-PowerProfile.ps1)

    Das Icon haelt sich selbst am Leben: ein Timer setzt regelmaessig
    "Visible = true" erneut, falls Windows das Icon nach einem
    Grafiktreiber-Reset oder einem Explorer-Neustart entfernt hat.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir   = $PSScriptRoot
$TaskPrefix  = 'PowerProfileSwitcher-'
$StateDir    = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile = Join-Path $StateDir 'current.json'
$SettingsFile= Join-Path $StateDir 'settings.json'
$LogCsv      = Join-Path $StateDir 'power-log.csv'
$HealthCsv   = Join-Path $StateDir 'battery-health.csv'
$StandbyCsv  = Join-Path $StateDir 'standby-log.csv'
$PauseFlag   = Join-Path $StateDir 'tray-paused.flag'
$LogFile     = Join-Path $StateDir 'tray.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Funktionen zur Verbrauchsmessung einbinden (Watt / Restlaufzeit).
$MetricsScript    = Join-Path $ScriptDir 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

# Profil-Definitionen einbinden (u.a. Mindest-Akku fuer das Gaming-Profil).
$GamingMinBatteryPercent = 40
$ProfilesScript = Join-Path $ScriptDir 'Profiles.ps1'
if (Test-Path $ProfilesScript) { . $ProfilesScript }

# Ein einzelner Fehler in einem Menü-/Timer-Handler soll das Tray-Icon
# nicht abstuerzen lassen - nur protokollieren und weiterlaufen.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($e.Exception)" | Add-Content -Path $LogFile -Encoding UTF8
    } catch {}
})

function E {
    param([int]$CodePoint)
    try { [char]::ConvertFromUtf32($CodePoint) } catch { '' }
}

function Write-TrayLog {
    param([string]$Text)
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) {
            Get-Content $LogFile -Tail 500 | Set-Content -Path $LogFile -Encoding UTF8
        }
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text" | Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

# Meldet das Icon zwangsweise neu bei der Taskleiste an.
# WICHTIG: "Visible = $true" allein reicht NICHT - WinForms bricht den
# Setter ab, wenn die Eigenschaft schon true ist, und schickt dann keine
# Neuanmeldung an die Shell. Nur das Aus-/Einschalten erzwingt sie.
function Restore-TrayIcon {
    param([string]$Reason = 'Routine')
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Visible = $true
        Write-TrayLog "Icon neu bei der Taskleiste angemeldet ($Reason)"
    } catch {
        Write-TrayLog "Icon konnte nicht neu angemeldet werden ($Reason): $_"
    }
}

function Get-CurrentState {
    if (-not (Test-Path $CurrentFile)) { return $null }
    try { return (Get-Content $CurrentFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-CurrentMode {
    $state = Get-CurrentState
    if ($state) { return $state.Mode }
    return $null
}

# "Unterwegs seit 1 h 20 min - 18 % Akku verbraucht"
function Get-ProfileRuntimeText {
    param($Reading)

    # Format-Duration stammt aus PowerMetrics.ps1
    if (-not $MetricsAvailable) { return '' }

    $state = Get-CurrentState
    if (-not $state -or -not $state.Timestamp) { return '' }

    $started = $null
    if ($state.Timestamp -is [datetime]) {
        $started = $state.Timestamp
    } else {
        try {
            $started = [datetime]::Parse([string]$state.Timestamp, $Invariant,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch { return '' }
    }

    $elapsed = (Get-Date) - $started
    if ($elapsed.TotalSeconds -lt 0) { return '' }

    $label = 'Profil'
    if ($state.Mode -and $ShortLabels.ContainsKey($state.Mode)) { $label = $ShortLabels[$state.Mode] }
    $text = '{0} seit {1}' -f $label, (Format-Duration -Hours $elapsed.TotalHours)

    $startPercent = 0
    if ($state.PSObject.Properties.Name -contains 'StartPercent') {
        try { $startPercent = [int]$state.StartPercent } catch { }
    }
    if ($Reading -and $startPercent -gt 0 -and $Reading.Percent -gt 0) {
        $delta = $startPercent - $Reading.Percent
        if ($delta -gt 0)     { $text += " - $delta % Akku verbraucht" }
        elseif ($delta -lt 0) { $text += " - {0} % geladen" -f [Math]::Abs($delta) }
    }
    return $text
}

# --- Einstellungen (persistent) -----------------------------------------
function Load-Settings {
    $defaults = @{ AutoSwitch = $false; Hotkeys = $false }
    if (Test-Path $SettingsFile) {
        try {
            $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $defaults[$p.Name] = $p.Value }
        } catch { }
    }
    return $defaults
}

function Save-Settings {
    try { [pscustomobject]$Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

$Settings = Load-Settings

# Der Tray laeuft wieder - eine frueher gesetzte Pause ist damit erledigt.
Remove-Item $PauseFlag -Force -ErrorAction SilentlyContinue

# Globale Hotkeys sind ab Werk AUS (siehe Abschnitt weiter unten).
$hotkeysWanted = $false
try { $hotkeysWanted = [bool]$Settings.Hotkeys } catch { }

# --- Farbige Punkt-Icons je Profil erzeugen (kein externes .ico noetig) ---
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, 2, 2, 28, 28)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
        $g.DrawEllipse($pen, 2, 2, 28, 28)
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}

if (-not ('PowerProfileSwitcher.IconUtil' -as [type])) {
    Add-Type -Namespace PowerProfileSwitcher -Name IconUtil -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyIcon(IntPtr handle);
'@ -UsingNamespace System.Runtime.InteropServices -ErrorAction SilentlyContinue
}

# Icon mit der aktuellen Wattzahl darin - so sieht man den Verbrauch, ohne
# das Menue zu oeffnen. Wird laufend neu erzeugt, deshalb wird das alte
# GDI-Handle jedes Mal wieder freigegeben (siehe Update-TrayState).
function New-WattIcon {
    param([System.Drawing.Color]$Color, [int]$Watt)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, 0, 0, 31, 31)

        $text = if ($Watt -gt 99) { '99' } else { [string]$Watt }
        $fontSize = if ($text.Length -ge 2) { 17 } else { 21 }
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF 0, 0, 32, 32
        $g.DrawString($text, $font, [System.Drawing.Brushes]::White, $rect, $format)
        $font.Dispose()

        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}

$DynamicIcon = $null   # zuletzt selbst gezeichnetes Icon (mit Wattzahl)

$Icons = @{
    Gaming   = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(230, 70, 50))
    Balanced = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(60, 130, 220))
    Travel   = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(60, 170, 90))
    Video    = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(150, 90, 200))
    Unknown  = [System.Drawing.SystemIcons]::Information
}

# Farben zum Nachzeichnen des Icons mit Wattzahl
$IconColors = @{
    Gaming   = [System.Drawing.Color]::FromArgb(230, 70, 50)
    Balanced = [System.Drawing.Color]::FromArgb(60, 130, 220)
    Travel   = [System.Drawing.Color]::FromArgb(60, 170, 90)
    Video    = [System.Drawing.Color]::FromArgb(150, 90, 200)
}

$Labels = @{
    Gaming   = 'Gaming (Hoechstleistung)'
    Balanced = 'Ausgeglichen'
    Travel   = 'Unterwegs (Akku sparen)'
    Video    = 'Video / Streaming'
}

$ShortLabels = @{
    Gaming   = 'Gaming'
    Balanced = 'Ausgeglichen'
    Travel   = 'Unterwegs'
    Video    = 'Video'
}

# Gleitender Mittelwert der letzten Messpunkte fuer die Live-Anzeige.
$DrawSamples    = @()
$MaxDrawSamples = 8
$LastOnAc       = $null
$WarnedLevels   = @()
$PendingGaming  = $false   # Gaming beim Anstecken gewuenscht, aber Akku noch zu leer
$LastTickTime    = Get-Date
$LastTickPercent = -1
$LastStandbyText = ''

function Get-PreviousMode {
    $state = Get-CurrentState
    if ($state -and $state.PSObject.Properties.Name -contains 'Previous') { return $state.Previous }
    return $null
}

# Reihenfolge fuer das Durchschalten per Hotkey.
$ProfileOrder = @('Gaming', 'Balanced', 'Travel', 'Video')

function Invoke-NextProfile {
    $current = Get-CurrentMode
    $index = [Array]::IndexOf($ProfileOrder, $current)
    for ($step = 1; $step -le $ProfileOrder.Count; $step++) {
        $next = $ProfileOrder[(($index + $step) % $ProfileOrder.Count)]
        # Gesperrtes Gaming-Profil beim Durchschalten ueberspringen
        if ($next -eq 'Gaming') {
            $reading = $null
            if ($MetricsAvailable) { $reading = Get-BatteryReading }
            if (-not (Test-GamingAllowed -Reading $reading)) { continue }
        }
        Invoke-Profile -Name $next
        return
    }
}

function Invoke-Profile {
    param(
        [string]$Name,
        [string]$TaskSuffix = ''
    )
    $taskName = "$TaskPrefix$Name$TaskSuffix"
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $script:PendingGaming = $false
        $script:DrawSamples = @()   # alte Messwerte gelten fuer das alte Profil
        $script:kickTimer.Stop()
        $script:kickTimer.Start()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Konnte Profil '$Name' nicht aktivieren (Aufgabe '$taskName' fehlt).`nBitte Install.ps1 als Administrator ausfuehren.",
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

# --- Messwerte protokollieren (fuer Langzeit-Durchschnitt) ---------------
function Write-PowerLog {
    param($Reading, [string]$ModeName)
    if (-not $Reading -or $Reading.DrawWatt -le 0) { return }
    try {
        if (-not (Test-Path $LogCsv)) {
            'Zeit;Profil;Watt;Prozent' | Set-Content -Path $LogCsv -Encoding UTF8
        } elseif ((Get-Item $LogCsv).Length -gt 2MB) {
            # Protokoll kurz halten: nur die juengsten Zeilen behalten
            $keep = Get-Content $LogCsv -Tail 8000
            'Zeit;Profil;Watt;Prozent' | Set-Content -Path $LogCsv -Encoding UTF8
            $keep | Where-Object { $_ -notlike 'Zeit;*' } | Add-Content -Path $LogCsv -Encoding UTF8
        }

        $line = '{0};{1};{2};{3}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $(if ($ModeName) { $ModeName } else { 'unbekannt' }),
            $Reading.DrawWatt.ToString($Invariant),
            $Reading.Percent
        $line | Add-Content -Path $LogCsv -Encoding UTF8
    } catch { }
}

# Haelt einmal pro Tag die Akkukapazitaet fest, damit sich die Alterung
# ueber Monate im Bericht zeigen laesst.
function Write-BatteryHealth {
    param($Reading)
    if (-not $Reading -or $Reading.FullWh -le 0) { return }
    try {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        if (Test-Path $HealthCsv) {
            $last = Get-Content $HealthCsv -Tail 1 -ErrorAction SilentlyContinue
            if ($last -and $last.StartsWith($today)) { return }
        } else {
            'Datum;KapazitaetWh;NeuzustandWh;Ladezyklen' | Set-Content -Path $HealthCsv -Encoding UTF8
        }
        ('{0};{1};{2};{3}' -f $today,
            $Reading.FullWh.ToString($Invariant),
            $Reading.DesignWh.ToString($Invariant),
            $Reading.CycleCount) | Add-Content -Path $HealthCsv -Encoding UTF8
    } catch { }
}

# Erkennt Schlafphasen daran, dass zwischen zwei Messungen deutlich mehr
# Zeit vergangen ist als der 15-Sekunden-Takt - waehrend Standby laeuft der
# Timer nicht. Daraus laesst sich ausrechnen, wie viel Akku der Standby
# gekostet hat (Modern Standby zieht auf vielen Laptops erstaunlich viel).
function Test-StandbyGap {
    param($Reading)

    $now = Get-Date
    $gapMinutes = ($now - $script:LastTickTime).TotalMinutes
    $previousPercent = $script:LastTickPercent

    $script:LastTickTime = $now
    if ($Reading) { $script:LastTickPercent = $Reading.Percent }

    # Unter 4 Minuten ist es der normale Takt (oder eine kurze Verzoegerung).
    if ($gapMinutes -lt 4) { return }
    if (-not $Reading -or $previousPercent -lt 0) { return }

    $hours = [Math]::Round($gapMinutes / 60.0, 2)
    $lost  = $previousPercent - $Reading.Percent

    if ($lost -le 0) {
        # Im Standby geladen - interessant, aber kein Verlust.
        Write-TrayLog ("Standby erkannt: {0:N2} h, dabei geladen ({1} % -> {2} %)." -f $hours, $previousPercent, $Reading.Percent)
        return
    }

    $perHour = 0.0
    if ($hours -gt 0) { $perHour = [Math]::Round($lost / $hours, 2) }

    $script:LastStandbyText = ('{0} - {1:N1} h Standby, {2} % verbraucht ({3:N2} %/h)' -f `
        $now.ToString('dd.MM. HH:mm'), $hours, $lost, $perHour)
    Write-TrayLog "Standby ausgewertet: $script:LastStandbyText"

    try {
        if (-not (Test-Path $StandbyCsv)) {
            'Ende;Stunden;ProzentVerlust;ProzentProStunde' | Set-Content -Path $StandbyCsv -Encoding UTF8
        }
        ('{0};{1};{2};{3}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'),
            $hours.ToString($Invariant), $lost, $perHour.ToString($Invariant)) |
            Add-Content -Path $StandbyCsv -Encoding UTF8
    } catch { }

    Show-Balloon -Title "$(E 0x1F4A4) Standby ausgewertet" `
        -Text ('{0:N1} Stunden Standby haben {1} % Akku gekostet ({2:N2} % pro Stunde).' -f $hours, $lost, $perHour)
}

# Durchschnittsverbrauch je Profil ueber das gesamte Protokoll.
function Get-LogStatistics {
    if (-not (Test-Path $LogCsv)) { return @() }
    try {
        $rows = Import-Csv -Path $LogCsv -Delimiter ';'
    } catch { return @() }
    if (-not $rows) { return @() }

    $result = @()
    foreach ($group in ($rows | Group-Object Profil)) {
        $watts = @()
        foreach ($row in $group.Group) {
            try { $watts += [double]::Parse($row.Watt, $Invariant) } catch { }
        }
        if ($watts.Count -eq 0) { continue }
        $result += [pscustomobject]@{
            Profil = $group.Name
            Watt   = [Math]::Round((($watts | Measure-Object -Average).Average), 1)
            Anzahl = $watts.Count
        }
    }
    return $result
}

# Liest den Akku aus, pflegt den gleitenden Mittelwert und liefert kurze
# Texte fuer Menue und Tooltip.
function Get-PowerStatusText {
    param($Reading)
    if (-not $MetricsAvailable) { return @{ Menu = 'Verbrauchsmessung nicht verfuegbar'; Tip = ''; Watt = 0 } }
    if (-not $Reading) { return @{ Menu = 'Kein Akku erkannt'; Tip = ''; Watt = 0 } }

    if ($Reading.DrawWatt -gt 0) {
        $script:DrawSamples += $Reading.DrawWatt
        if ($script:DrawSamples.Count -gt $MaxDrawSamples) {
            $script:DrawSamples = @($script:DrawSamples | Select-Object -Last $MaxDrawSamples)
        }
    } elseif ($Reading.OnAc) {
        $script:DrawSamples = @()
    }

    if ($script:DrawSamples.Count -eq 0) {
        if ($Reading.OnAc) {
            return @{ Menu = "Am Netzteil - Akku $($Reading.Percent) %"; Tip = "Netz - $($Reading.Percent) %"; Watt = 0 }
        }
        return @{ Menu = "Akku $($Reading.Percent) % - Verbrauch wird gemessen ..."; Tip = "$($Reading.Percent) %"; Watt = 0 }
    }

    $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
    $rest = Format-Duration -Hours ($Reading.RemainingWh / $avg)

    return @{
        Menu = ('{0:N1} W - Akku {1} %, noch ca. {2}' -f $avg, $Reading.Percent, $rest)
        Tip  = ('{0:N1} W, ~{1}' -f $avg, $rest)
        Watt = $avg
    }
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    try {
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText  = $Text
        $notifyIcon.ShowBalloonTip(6000)
    } catch { }
}

# Gaming ist erst ab einem Mindest-Ladestand erlaubt. Ohne verlaessliche
# Akku-Werte (z.B. Desktop-PC) gilt die Regel nicht.
function Test-GamingAllowed {
    param($Reading)
    if ($GamingMinBatteryPercent -le 0) { return $true }
    if (-not $Reading) { return $true }
    if ($Reading.FullWh -le 0 -or $Reading.Percent -le 0) { return $true }
    return ($Reading.Percent -ge $GamingMinBatteryPercent)
}

# --- Automatisches Umschalten beim An-/Abstecken -------------------------
function Invoke-AutoSwitch {
    param($Reading)
    if (-not $Reading) { return }

    $previous = $script:LastOnAc
    $script:LastOnAc = $Reading.OnAc

    if (-not $Settings.AutoSwitch) {
        $script:PendingGaming = $false
        return
    }

    $changed = ($null -ne $previous -and $previous -ne $Reading.OnAc)
    $current = Get-CurrentMode

    if (-not $Reading.OnAc) {
        $script:PendingGaming = $false
        if ($changed -and $current -ne 'Travel') {
            # Ohne GPU-Umschaltung, damit beim Ausstecken keine Neustart-Abfrage kommt.
            Invoke-Profile -Name 'Travel' -TaskSuffix '-NoGpu'
            Show-Balloon -Title 'Netzteil getrennt' -Text 'Automatisch auf Unterwegs (Akku sparen) umgeschaltet. Die dedizierte GPU bleibt an - zum Abschalten das Profil einmal von Hand waehlen.'
        }
        return
    }

    # Netzbetrieb: beim Anstecken Gaming vormerken ...
    if ($changed -and $current -ne 'Gaming') {
        $script:PendingGaming = $true
        if (-not (Test-GamingAllowed -Reading $Reading)) {
            Show-Balloon -Title 'Netzteil angeschlossen' `
                -Text ("Akku bei {0} % - Gaming folgt automatisch, sobald {1} % erreicht sind." -f $Reading.Percent, $GamingMinBatteryPercent)
        }
    }

    # ... und erst aktivieren, wenn der Akku weit genug geladen ist.
    if ($script:PendingGaming -and (Test-GamingAllowed -Reading $Reading)) {
        $script:PendingGaming = $false
        if ($current -ne 'Gaming') {
            Invoke-Profile -Name 'Gaming'
            Show-Balloon -Title 'Netzteil angeschlossen' -Text 'Automatisch auf Gaming (Hoechstleistung) umgeschaltet.'
        }
    }
}

# --- Akku-Warnungen ------------------------------------------------------
function Test-BatteryWarning {
    param($Reading)
    if (-not $Reading) { return }

    if ($Reading.OnAc) {
        $script:WarnedLevels = @()
        return
    }

    foreach ($level in 20, 10) {
        if ($Reading.Percent -le $level -and $script:WarnedLevels -notcontains $level) {
            $script:WarnedLevels += $level
            $text = "Akku bei $($Reading.Percent) %."
            if ($script:DrawSamples.Count -gt 0) {
                $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
                $text += ' Bei aktuell {0:N1} W noch ca. {1}.' -f $avg, (Format-Duration -Hours ($Reading.RemainingWh / $avg))
            }
            Show-Balloon -Title "$(E 0x1F50B) Akku niedrig" -Text $text
            break
        }
    }
}

function Show-BatteryDetails {
    if (-not $MetricsAvailable) { return }

    $r = Get-BatteryReading
    if (-not $r) {
        [System.Windows.Forms.MessageBox]::Show(
            'Es wurde kein Akku gefunden - die Verbrauchsmessung funktioniert nur auf Geraeten mit Akku.',
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $lines = @()
    $mode = Get-CurrentMode
    if ($mode -and $Labels.ContainsKey($mode)) { $lines += "Aktives Profil: $($Labels[$mode])" }

    if ($r.OnAc) { $lines += 'Stromquelle: Netzteil' } else { $lines += 'Stromquelle: Akku' }
    $lines += ('Ladestand: {0} % ({1} von {2} Wh)' -f $r.Percent, $r.RemainingWh, $r.FullWh)

    if ($script:DrawSamples.Count -gt 0) {
        $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
        $lines += ''
        $lines += ('Aktueller Verbrauch: {0:N1} W (Mittel der letzten {1} Messungen)' -f $avg, $script:DrawSamples.Count)
        $lines += ('Restlaufzeit: ca. {0}' -f (Format-Duration -Hours ($r.RemainingWh / $avg)))
        $lines += ('Bei vollem Akku: ca. {0}' -f (Format-Duration -Hours ($r.FullWh / $avg)))
    } else {
        $lines += ''
        $lines += 'Verbrauch: am Netzteil nicht messbar (nur im Akkubetrieb).'
    }

    if ($r.DesignWh -gt 0 -and $r.FullWh -gt 0) {
        $health = [int][Math]::Round(100.0 * $r.FullWh / $r.DesignWh)
        $lines += ''
        $lines += ('Akku-Zustand: {0} % ({1} von {2} Wh im Neuzustand)' -f $health, $r.FullWh, $r.DesignWh)
    }
    if ($r.CycleCount -gt 0) { $lines += "Ladezyklen: $($r.CycleCount)" }

    # Langzeit-Durchschnitt aus dem Protokoll - aussagekraeftiger als die
    # kurze Messung direkt nach dem Umschalten.
    $stats = Get-LogStatistics
    if ($stats.Count -gt 0) {
        $lines += ''
        $lines += 'Durchschnitt aus dem Verbrauchsprotokoll:'
        foreach ($stat in $stats) {
            $name = $stat.Profil
            if ($ShortLabels.ContainsKey($name)) { $name = $ShortLabels[$name] }
            $runtimeText = '-'
            if ($r.FullWh -gt 0 -and $stat.Watt -gt 0) {
                $runtimeText = Format-Duration -Hours ($r.FullWh / $stat.Watt)
            }
            $lines += ('  {0,-13} {1,6:N1} W  ->  ca. {2} bei vollem Akku   ({3} Messungen)' -f `
                $name, $stat.Watt, $runtimeText, $stat.Anzahl)
        }
    }

    if ($script:LastStandbyText) {
        $lines += ''
        $lines += "Letzter Standby: $script:LastStandbyText"
    }

    $metrics = Get-ProfileMetrics
    if ($metrics) {
        $lines += ''
        $lines += 'Letzte Messung direkt nach dem Profilwechsel:'
        foreach ($key in 'Gaming', 'Balanced', 'Travel') {
            if ($metrics.PSObject.Properties.Name -notcontains $key) { continue }
            $entry = $metrics.$key
            if (-not $entry -or [double]$entry.Watt -le 0) { continue }
            $runtime = Format-Duration -Hours ([double]$entry.RuntimeFullH)
            $lines += ('  {0,-13} {1,6:N1} W  ->  ca. {2} bei vollem Akku   ({3})' -f `
                $ShortLabels[$key], [double]$entry.Watt, $runtime, $entry.When)
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        ($lines -join "`n"),
        'PowerProfile Switcher - Akku & Verbrauch',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# --------------------------------------------------------------------------
# Tray-Icon und Menue
# --------------------------------------------------------------------------

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $Icons.Unknown
$notifyIcon.Text = 'PowerProfile Switcher'
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# Kopfzeile mit Live-Verbrauch - Klick oeffnet die Detailansicht.
$itemStatus = $menu.Items.Add("$(E 0x26A1)  Verbrauch wird gemessen ...")
$itemStatus.Add_Click({ Show-BatteryDetails })

$itemRuntime = $menu.Items.Add("$(E 0x1F551)  Laufzeit wird ermittelt ...")
$itemRuntime.Add_Click({ Show-BatteryDetails })

$menu.Items.Add('-') | Out-Null

$itemGaming = $menu.Items.Add("$(E 0x1F3AE)  Gaming (Hoechstleistung)")
if ($hotkeysWanted) { $itemGaming.ShortcutKeyDisplayString = 'Strg+Alt+1' }
$itemGaming.Add_Click({ Invoke-Profile -Name 'Gaming' })

$itemBalanced = $menu.Items.Add("$(E 0x2696)  Ausgeglichen")
if ($hotkeysWanted) { $itemBalanced.ShortcutKeyDisplayString = 'Strg+Alt+2' }
$itemBalanced.Add_Click({ Invoke-Profile -Name 'Balanced' })

$itemTravel = $menu.Items.Add("$(E 0x1F50B)  Unterwegs (Akku sparen)")
if ($hotkeysWanted) { $itemTravel.ShortcutKeyDisplayString = 'Strg+Alt+3' }
$itemTravel.Add_Click({ Invoke-Profile -Name 'Travel' })

$itemVideo = $menu.Items.Add("$(E 0x1F3AC)  Video / Streaming")
if ($hotkeysWanted) { $itemVideo.ShortcutKeyDisplayString = 'Strg+Alt+4' }
$itemVideo.Add_Click({ Invoke-Profile -Name 'Video' })

$itemBack = $menu.Items.Add("$(E 0x21A9)  Zurueck zum vorherigen Profil")
$itemBack.Add_Click({
    $previous = Get-PreviousMode
    if ($previous) { Invoke-Profile -Name $previous }
})

$menu.Items.Add('-') | Out-Null

$itemAuto = $menu.Items.Add('Automatisch bei Netzteil ab/an umschalten')
$itemAuto.Checked = [bool]$Settings.AutoSwitch
$itemAuto.Add_Click({
    $Settings.AutoSwitch = -not [bool]$Settings.AutoSwitch
    $itemAuto.Checked = [bool]$Settings.AutoSwitch
    Save-Settings
})

$itemReport = $menu.Items.Add("$(E 0x1F4C8)  Verbrauchs-Bericht anzeigen")
$itemReport.Add_Click({
    $reportScript = Join-Path $ScriptDir 'New-PowerReport.ps1'
    if (Test-Path $reportScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$reportScript`""
        )
    }
}.GetNewClosure())

$itemBench = $menu.Items.Add("$(E 0x1F3C1)  Leistungstest fuer dieses Profil")
$itemBench.Add_Click({
    $benchScript = Join-Path $ScriptDir 'Test-PowerPerformance.ps1'
    if (Test-Path $benchScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$benchScript`""
        )
    }
}.GetNewClosure())

$itemStatus2 = $menu.Items.Add("$(E 0x1F50D)  Systemzustand & Vorschau")
$itemStatus2.Add_Click({
    $statusScript = Join-Path $ScriptDir 'Show-PowerStatus.ps1'
    if (Test-Path $statusScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$statusScript`""
        )
    }
}.GetNewClosure())

$itemCalibrate = $menu.Items.Add("$(E 0x1F4CF)  CPU-Grenze kalibrieren (Akkubetrieb)")
$itemCalibrate.Add_Click({
    $calScript = Join-Path $ScriptDir 'Invoke-PowerCalibration.ps1'
    if (Test-Path $calScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$calScript`""
        )
    }
}.GetNewClosure())

$itemSetup = $menu.Items.Add("$(E 0x1F527)  Einrichtung (Hardware erkennen)")
$itemSetup.Add_Click({
    $setupScript = Join-Path $ScriptDir 'Start-PowerSetup.ps1'
    if (Test-Path $setupScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$setupScript`""
        )
    }
}.GetNewClosure())

$itemSettings = $menu.Items.Add("$(E 0x2699)  Einstellungen ...")
$itemSettings.Add_Click({
    $settingsScript = Join-Path $ScriptDir 'Show-PowerSettings.ps1'
    if (Test-Path $settingsScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$settingsScript`""
        )
    }
}.GetNewClosure())

$itemBackup = $menu.Items.Add('Konfiguration sichern ...')
$itemBackup.Add_Click({
    $backupScript = Join-Path $ScriptDir 'Backup-PowerConfig.ps1'
    if (Test-Path $backupScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$backupScript`"", '-Action', 'Export'
        )
    }
}.GetNewClosure())

$itemRestore = $menu.Items.Add('Konfiguration wiederherstellen ...')
$itemRestore.Add_Click({
    $backupScript = Join-Path $ScriptDir 'Backup-PowerConfig.ps1'
    if (Test-Path $backupScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$backupScript`"", '-Action', 'Import'
        )
    }
}.GetNewClosure())

$itemReset = $menu.Items.Add("$(E 0x1F198)  Alles zuruecksetzen (Notfall)")
$itemReset.Add_Click({
    $resetScript = Join-Path $ScriptDir 'Reset-PowerProfile.ps1'
    if (Test-Path $resetScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$resetScript`""
        )
    }
}.GetNewClosure())

$itemUpdate = $menu.Items.Add('Nach Updates suchen')
$itemUpdate.Add_Click({
    $updateScript = Join-Path $ScriptDir 'Update-PowerProfile.ps1'
    if (Test-Path $updateScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$updateScript`""
        )
    }
}.GetNewClosure())

$itemDiag = $menu.Items.Add('Diagnose ausfuehren (Bericht oeffnen)')
$itemDiag.Add_Click({
    $diagScript = Join-Path $ScriptDir 'Test-PowerProfile.ps1'
    if (-not (Test-Path $diagScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Test-PowerProfile.ps1 wurde nicht gefunden. Bitte Install.ps1 erneut ausfuehren.',
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$diagScript`""
    )
}.GetNewClosure())

$xmgCcPaths = @(
    "$env:ProgramFiles\XMG\XMG Control Center\XMG Control Center.exe",
    "${env:ProgramFiles(x86)}\XMG\XMG Control Center\XMG Control Center.exe",
    "$env:ProgramFiles\Tongfang\Control Center\Control Center.exe"
)
$xmgCcExe = $xmgCcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($xmgCcExe) {
    $itemCc = $menu.Items.Add('XMG Control Center oeffnen (Luefter/RGB)')
    $itemCc.Add_Click({ Start-Process -FilePath $xmgCcExe }.GetNewClosure())
}

$menu.Items.Add('-') | Out-Null

function Stop-Tray {
    param([switch]$KeepPaused)
    try {
        if ($KeepPaused) {
            # Markierung setzen, damit der Watchdog den Tray nicht sofort
            # wieder startet. Bei der naechsten Anmeldung laeuft er normal.
            (Get-Date).ToString('o') | Set-Content -Path $PauseFlag -Encoding UTF8
            Write-TrayLog 'Tray beendet und pausiert (kein Hintergrundprozess bis zur naechsten Anmeldung).'
        } else {
            Write-TrayLog 'Tray beendet.'
        }
    } catch { }
    if ($script:hotkeyWindow) { try { $script:hotkeyWindow.Dispose() } catch { } }
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$itemNoBackground = $menu.Items.Add("$(E 0x1F6E1)  Hintergrunddienst dauerhaft abschalten ...")
$itemNoBackground.Add_Click({
    $bgScript = Join-Path $ScriptDir 'Set-PowerBackground.ps1'
    if (Test-Path $bgScript) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$bgScript`"", '-Action', 'Disable'
        )
    }
}.GetNewClosure())

$itemExitForGame = $menu.Items.Add("$(E 0x1F3AE)  Beenden fuers Spielen (kein Hintergrundprozess)")
$itemExitForGame.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Das Tray-Icon wird beendet und startet auch nicht automatisch neu - erst wieder bei der naechsten Anmeldung.`n`nDamit laeuft waehrend des Spielens kein Hintergrundprozess dieser App, was Anti-Cheat-Systeme stoeren kann.`n`nProfile umschalten geht weiterhin ueber die Verknuepfungen auf dem Desktop - am besten VOR dem Spielstart.",
        'PowerProfile Switcher',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    Stop-Tray -KeepPaused
})

$itemExit = $menu.Items.Add('Beenden')
$itemExit.Add_Click({ Stop-Tray -KeepPaused })

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

# NotifyIcon.Text ist auf 63 Zeichen begrenzt - laengere Texte wuerden
# eine Ausnahme werfen.
function Set-TrayTooltip {
    param([string]$Text)
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '...' }
    $notifyIcon.Text = $Text
}

# Aktuelles Profil im Icon/Tooltip/Menue widerspiegeln, Messwert aufnehmen
# und das Icon in der Taskleiste "am Leben halten".
$TickCount = 0

function Update-TrayState {
    $mode = Get-CurrentMode
    $tooltip = 'PowerProfile Switcher'
    if ($mode -and $ShortLabels.ContainsKey($mode)) { $tooltip = $ShortLabels[$mode] }

    $itemGaming.Checked   = ($mode -eq 'Gaming')
    $itemBalanced.Checked = ($mode -eq 'Balanced')
    $itemTravel.Checked   = ($mode -eq 'Travel')
    $itemVideo.Checked    = ($mode -eq 'Video')

    $previousMode = Get-PreviousMode
    if ($previousMode -and $ShortLabels.ContainsKey($previousMode) -and $previousMode -ne $mode) {
        $itemBack.Text    = "$(E 0x21A9)  Zurueck zu $($ShortLabels[$previousMode])"
        $itemBack.Visible = $true
    } else {
        $itemBack.Visible = $false
    }

    $reading = $null
    if ($MetricsAvailable) { $reading = Get-BatteryReading }

    # Gaming erst ab Mindest-Ladestand anbieten
    if (Test-GamingAllowed -Reading $reading) {
        $itemGaming.Enabled = $true
        $itemGaming.Text    = "$(E 0x1F3AE)  Gaming (Hoechstleistung)"
    } else {
        $itemGaming.Enabled = $false
        $itemGaming.Text    = "$(E 0x1F3AE)  Gaming - erst ab $GamingMinBatteryPercent % Akku"
    }

    $status = Get-PowerStatusText -Reading $reading

    # Icon: mit Wattzahl, sobald ein Messwert vorliegt, sonst der farbige Punkt
    $newDynamic = $null
    if ($status.Watt -gt 0 -and $mode -and $IconColors.ContainsKey($mode)) {
        try { $newDynamic = New-WattIcon -Color $IconColors[$mode] -Watt ([int][Math]::Round($status.Watt)) } catch { }
    }
    if ($newDynamic) {
        $notifyIcon.Icon = $newDynamic
    } elseif ($mode -and $Icons.ContainsKey($mode)) {
        $notifyIcon.Icon = $Icons[$mode]
    } else {
        $notifyIcon.Icon = $Icons.Unknown
    }
    # altes selbst gezeichnetes Icon erst nach dem Wechsel freigeben
    if ($script:DynamicIcon) {
        try {
            [PowerProfileSwitcher.IconUtil]::DestroyIcon($script:DynamicIcon.Handle) | Out-Null
            $script:DynamicIcon.Dispose()
        } catch { }
    }
    $script:DynamicIcon = $newDynamic

    $itemStatus.Text = "$(E 0x26A1)  $($status.Menu)"
    if ($status.Tip) { $tooltip = "$tooltip - $($status.Tip)" }
    Set-TrayTooltip -Text $tooltip

    $runtimeText = Get-ProfileRuntimeText -Reading $reading
    if ($runtimeText) {
        $itemRuntime.Text    = "$(E 0x1F551)  $runtimeText"
        $itemRuntime.Visible = $true
    } else {
        $itemRuntime.Visible = $false
    }

    Test-StandbyGap -Reading $reading

    if ($reading) {
        Write-PowerLog -Reading $reading -ModeName $mode
        Write-BatteryHealth -Reading $reading
        Test-BatteryWarning -Reading $reading
        Invoke-AutoSwitch -Reading $reading
    }
}

# --- Globale Hotkeys (standardmaessig AUS) --------------------------------
# Global registrierte Tastenkombinationen sind ein typisches Merkmal von
# Cheat-Software (Makros, Triggerbots) und werden von Anti-Cheat-Systemen
# entsprechend beaeugt. Deshalb sind sie hier abschaltbar und ab Werk aus.
$hotkeyWindow = $null

try {
    if (-not $hotkeysWanted) { throw 'Hotkeys sind deaktiviert.' }
    if (-not ('PowerProfileSwitcher.HotkeyWindow' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PowerProfileSwitcher {
    public class HotkeyWindow : NativeWindow, IDisposable {
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern int RegisterWindowMessage(string message);

        private const int WM_HOTKEY = 0x0312;
        private const int WM_DISPLAYCHANGE = 0x007E;
        private static readonly int WM_TASKBARCREATED = RegisterWindowMessage("TaskbarCreated");

        public int LastId = 0;
        public event EventHandler HotkeyPressed;

        // Wird ausgeloest, wenn der Explorer die Taskleiste neu aufbaut oder
        // sich die Anzeige aendert (z.B. nach einem Grafiktreiber-Reset) -
        // genau dann verliert Windows die Symbole im Infobereich.
        public event EventHandler ShellRestarted;

        public HotkeyWindow() {
            CreateHandle(new CreateParams());
        }

        public bool Register(int id, uint modifiers, uint key) {
            return RegisterHotKey(this.Handle, id, modifiers, key);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY) {
                LastId = m.WParam.ToInt32();
                if (HotkeyPressed != null) { HotkeyPressed(this, EventArgs.Empty); }
            } else if (m.Msg == WM_TASKBARCREATED || m.Msg == WM_DISPLAYCHANGE) {
                if (ShellRestarted != null) { ShellRestarted(this, EventArgs.Empty); }
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            for (int i = 1; i <= 5; i++) { UnregisterHotKey(this.Handle, i); }
            DestroyHandle();
        }
    }
}
'@
    }

    $hotkeyWindow = New-Object PowerProfileSwitcher.HotkeyWindow

    # Taskleiste neu aufgebaut oder Anzeige gewechselt -> Icon neu anmelden.
    $hotkeyWindow.add_ShellRestarted({
        Restore-TrayIcon -Reason 'Taskleiste/Anzeige neu aufgebaut'
        Update-TrayState
    })

    $hotkeyWindow.add_HotkeyPressed({
        switch ($script:hotkeyWindow.LastId) {
            1 { Invoke-Profile -Name 'Gaming' }
            2 { Invoke-Profile -Name 'Balanced' }
            3 { Invoke-Profile -Name 'Travel' }
            4 { Invoke-Profile -Name 'Video' }
            5 { Invoke-NextProfile }
        }
    })

    # MOD_ALT (0x1) + MOD_CONTROL (0x2) = 3, Tasten '1'..'3' = 0x31..0x33
    $registered = @()
    if ($hotkeyWindow.Register(1, 3, 0x31)) { $registered += 'Strg+Alt+1' }
    if ($hotkeyWindow.Register(2, 3, 0x32)) { $registered += 'Strg+Alt+2' }
    if ($hotkeyWindow.Register(3, 3, 0x33)) { $registered += 'Strg+Alt+3' }
    if ($hotkeyWindow.Register(4, 3, 0x34)) { $registered += 'Strg+Alt+4' }
    if ($hotkeyWindow.Register(5, 3, 0x50)) { $registered += 'Strg+Alt+P' }

    if ($registered.Count -lt 5) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Nicht alle Hotkeys konnten registriert werden (belegt?): $($registered -join ', ')" |
            Add-Content -Path $LogFile -Encoding UTF8
    }
} catch {
    if ($hotkeysWanted) { Write-TrayLog "Hotkeys nicht verfuegbar: $_" }
    else { Write-TrayLog 'Hotkeys sind ausgeschaltet (Einstellungen -> Globale Hotkeys).' }
}

# Regelmaessiger Herzschlag (alle 15s): Icon sichtbar halten, Messpunkt
# aufnehmen, Akku-Warnung und Auto-Umschaltung pruefen.
$heartbeat = New-Object System.Windows.Forms.Timer
$heartbeat.Interval = 15000
$heartbeat.Add_Tick({
    Update-TrayState
    $script:TickCount++

    # Alle 5 Minuten das Icon zwangsweise neu anmelden - faengt auch die
    # Faelle ab, in denen weder TaskbarCreated noch WM_DISPLAYCHANGE kommt.
    if (($script:TickCount % 20) -eq 0) { Restore-TrayIcon -Reason 'Routine (5 min)' }

    # Alle 30 Minuten ein Lebenszeichen ins Protokoll. Daran laesst sich
    # spaeter ablesen, ob der Prozess noch lief, als das Icon verschwand.
    if (($script:TickCount % 120) -eq 0) { Write-TrayLog 'Tray laeuft.' }
})
$heartbeat.Start()

# Einmaliger "Kick" ein paar Sekunden nach einem Profilwechsel, damit die
# Anzeige schneller aktualisiert wird als der naechste Herzschlag.
$kickTimer = New-Object System.Windows.Forms.Timer
$kickTimer.Interval = 4000
$kickTimer.Add_Tick({
    $kickTimer.Stop()
    Update-TrayState
})

Update-TrayState
Write-TrayLog 'Tray gestartet.'

# Beim allerersten Start einmalig die Einrichtung anbieten, damit die Werte
# zur tatsaechlichen Hardware passen statt geraten zu sein.
try {
    $setupScript = Join-Path $ScriptDir 'Start-PowerSetup.ps1'
    if ((Test-Path $setupScript) -and -not (Test-Path (Join-Path $StateDir 'setup-done.txt'))) {
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$setupScript`"", '-OnlyIfFirstRun'
        )
    }
} catch { }

[System.Windows.Forms.Application]::Run()
