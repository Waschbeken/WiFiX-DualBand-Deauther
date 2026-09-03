#Requires -Version 5.1
<#
    Start-Tray.ps1

    Zeigt ein Symbol im Windows-Infobereich (Tray) mit einem Rechtsklick-
    Menue zum sofortigen Umschalten der Energieprofile. Das Skript selbst
    laeuft OHNE Administratorrechte - es loest lediglich die vorher per
    Install.ps1 angelegten geplanten Aufgaben aus, die bereits mit
    erhoehten Rechten laufen. Dadurch erscheint kein UAC-Fenster beim
    Umschalten.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function E {
    param([int]$CodePoint)
    try { [char]::ConvertFromUtf32($CodePoint) } catch { '' }
}

$TaskPrefix = 'PowerProfileSwitcher-'

function Invoke-Profile {
    param([string]$Name)
    try {
        Start-ScheduledTask -TaskName "$TaskPrefix$Name" -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Konnte Profil '$Name' nicht aktivieren. Bitte zuerst Install.ps1 (als Administrator) ausfuehren.",
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = 'PowerProfile Switcher'
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemGaming = $menu.Items.Add("$(E 0x1F3AE)  Gaming (Hoechstleistung)")
$itemGaming.Add_Click({ Invoke-Profile -Name 'Gaming' })

$itemBalanced = $menu.Items.Add("$(E 0x2696)  Ausgeglichen")
$itemBalanced.Add_Click({ Invoke-Profile -Name 'Balanced' })

$itemTravel = $menu.Items.Add("$(E 0x1F50B)  Unterwegs (Akku sparen)")
$itemTravel.Add_Click({ Invoke-Profile -Name 'Travel' })

$menu.Items.Add('-') | Out-Null

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$xmgCcPaths = @(
    "$env:ProgramFiles\XMG\XMG Control Center\XMG Control Center.exe",
    "${env:ProgramFiles(x86)}\XMG\XMG Control Center\XMG Control Center.exe",
    "$env:ProgramFiles\Tongfang\Control Center\Control Center.exe"
)
$xmgCcExe = $xmgCcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($xmgCcExe) {
    $itemCc = $menu.Items.Add('XMG Control Center oeffnen (Luefter/RGB)')
    $itemCc.Add_Click({ Start-Process -FilePath $xmgCcExe }.GetNewClosure())
    $menu.Items.Add('-') | Out-Null
}

$itemExit = $menu.Items.Add('Beenden')
$itemExit.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

[System.Windows.Forms.Application]::Run()
