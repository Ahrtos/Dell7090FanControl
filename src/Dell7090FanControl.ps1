param(
    [switch]$StartMinimized
)

# Dell OptiPlex 7090 Fan Control GUI v1.0
# Direct Dell LegacyDiags WMI/SMM fan control.
# Proven on the target OptiPlex 7090 Micro:
# Level 1 ~1140 RPM, Level 2 ~3970 RPM.
# State 3 is NOT used because it behaves as a firmware/magic state on this system.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Dell7090NativeIcon
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

function New-FanTrayIcon {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color
    )

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)

    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $outlineColor = [System.Drawing.Color]::FromArgb(210, 45, 45, 45)
        $outlinePen = New-Object System.Drawing.Pen($outlineColor, 1.4)
        $bladeBrush = New-Object System.Drawing.SolidBrush($Color)
        $centerBrush = New-Object System.Drawing.SolidBrush($Color)

        try {
            # Outer ring
            $g.DrawEllipse($outlinePen, 3, 3, 25, 25)

            # Four simple fan blades
            foreach ($angle in @(0, 90, 180, 270)) {
                $state = $g.Save()
                try {
                    $g.TranslateTransform(16, 16)
                    $g.RotateTransform([single]$angle)
                    $g.FillEllipse($bladeBrush, 1, -4, 11, 8)
                    $g.DrawEllipse($outlinePen, 1, -4, 11, 8)
                }
                finally {
                    $g.Restore($state)
                }
            }

            # Hub
            $g.FillEllipse($centerBrush, 11, 11, 10, 10)
            $g.DrawEllipse($outlinePen, 11, 11, 10, 10)
        }
        finally {
            $outlinePen.Dispose()
            $bladeBrush.Dispose()
            $centerBrush.Dispose()
        }

        $hIcon = $bmp.GetHicon()
        try {
            return ([System.Drawing.Icon]::FromHandle($hIcon)).Clone()
        }
        finally {
            [Dell7090NativeIcon]::DestroyIcon($hIcon) | Out-Null
        }
    }
    finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}


$ErrorActionPreference = 'Stop'
[System.Windows.Forms.Application]::EnableVisualStyles()

$TaskName = 'Dell7090FanControl'
$configPath = Join-Path $PSScriptRoot 'Dell7090FanControl.json'
$logPath    = Join-Path $PSScriptRoot 'Dell7090FanControl.log'

$CctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'

function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $logPath -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch {}
}


function Wait-Responsive {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Milliseconds
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(25)
    }
    $sw.Stop()
}

# --- Self-elevate ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`""
    )
    if ($StartMinimized) {
        $elevArgs += '-StartMinimized'
    }
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $elevArgs
    exit
}

$config = [ordered]@{
    SensorIndex   = 0
    LowThreshold  = 45
    HighThreshold = 55
    PollMs        = 1000
    AutoControl   = $false
}

if (Test-Path $configPath) {
    try {
        $loaded = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($p in @('SensorIndex','LowThreshold','HighThreshold','PollMs','AutoControl')) {
            if ($null -ne $loaded.$p) {
                $config[$p] = $loaded.$p
            }
        }
    } catch {
        Write-Log "Config load failed: $($_.Exception.Message)"
    }
}


# --- Dell Command Configure / MAX override ---
function Test-CctkAvailable {
    return (Test-Path $CctkPath)
}

function Invoke-Cctk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    if (-not (Test-CctkAvailable)) {
        throw "Dell Command | Configure wurde nicht gefunden: $CctkPath"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CctkPath
    $psi.Arguments = $Argument
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    if (-not $proc.Start()) {
        throw "cctk.exe konnte nicht gestartet werden."
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not $proc.HasExited) {
        if ([DateTime]::UtcNow -ge $deadline) {
            try { $proc.Kill() } catch {}
            throw "cctk.exe hat nach 8 Sekunden nicht geantwortet."
        }

        # Keep WinForms repainting (busy overlay/progress bar stays alive).
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(50)
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if ($exitCode -ne 0) {
        throw "cctk.exe Fehler (ExitCode $exitCode): $stderr $stdout"
    }

    return ($stdout + "`n" + $stderr).Trim()
}

function Get-FanOverrideEnabled {
    $text = Invoke-Cctk -Argument '--FanCtrlOvrd'

    if ($text -match 'FanCtrlOvrd=Enabled') {
        return $true
    }

    if ($text -match 'FanCtrlOvrd=Disabled') {
        return $false
    }

    throw "Unerwartete FanCtrlOvrd-Ausgabe: $text"
}

function Set-FanOverride {
    param([bool]$Enabled)

    $value = if ($Enabled) { 'Enabled' } else { 'Disabled' }
    $null = Invoke-Cctk -Argument "--FanCtrlOvrd=$value"

    Wait-Responsive -Milliseconds 350

    $actual = Get-FanOverrideEnabled
    if ($actual -ne $Enabled) {
        throw "FanCtrlOvrd wurde nicht korrekt übernommen. Erwartet: $value"
    }

    $script:persistentMaxKnown = [bool]$actual
    Write-Log "FanCtrlOvrd=$value verified"
}

function Ensure-MaxOverrideDisabled {
    # MAX is persistent. We verify it, and if necessary disable it up to 3 times.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $enabled = Get-FanOverrideEnabled

        if (-not $enabled) {
            $script:persistentMaxKnown = $false
$script:uiBusy = $false
            Write-Log "MAX override confirmed Disabled (attempt $attempt)"
            return
        }

        Write-Log "MAX override still Enabled; disabling (attempt $attempt)"
        Set-FanOverride -Enabled $false
        Wait-Responsive -Milliseconds 350
    }

    if (Get-FanOverrideEnabled) {
        throw "MAX Override konnte nicht dauerhaft deaktiviert werden."
    }
}

function Enable-MaxOverride {
    # Manual MAX mode only.
    Set-FanOverride -Enabled $true

    if (-not (Get-FanOverrideEnabled)) {
        throw "MAX Override wurde nicht aktiviert."
    }

    $script:persistentMaxKnown = $true
}

# --- Dell WMI/SMM ---
try {
    $diag = Get-CimInstance -Namespace 'root\dcim\sysman\diagnostics' -ClassName LegacyDiags
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Dell LegacyDiags konnte nicht geöffnet werden.`r`n`r`n$($_.Exception.Message)",
        'Dell 7090 Fan Control',
        'OK',
        'Error'
    ) | Out-Null
    exit 1
}

function Invoke-DellSmm {
    param(
        [UInt32]$Eax,
        [UInt32]$Ebx = 0,
        [UInt32]$Ecx = 0,
        [UInt32]$Edx = 0
    )

    $cimArgs = @{
        EaxLen = [uint32]4
        EaxVal = [BitConverter]::GetBytes($Eax)
        EbxLen = [uint32]4
        EbxVal = [BitConverter]::GetBytes($Ebx)
        EcxLen = [uint32]4
        EcxVal = [BitConverter]::GetBytes($Ecx)
        EdxLen = [uint32]4
        EdxVal = [BitConverter]::GetBytes($Edx)
    }

    $r = Invoke-CimMethod -InputObject $diag -MethodName Execute -Arguments $cimArgs

    [PSCustomObject]@{
        ReturnValue = [bool]$r.ReturnValue
        EAX = [BitConverter]::ToUInt32([byte[]]$r.EaxVal, 0)
        EBX = [BitConverter]::ToUInt32([byte[]]$r.EbxVal, 0)
        ECX = [BitConverter]::ToUInt32([byte[]]$r.EcxVal, 0)
        EDX = [BitConverter]::ToUInt32([byte[]]$r.EdxVal, 0)
    }
}

function Test-DellSmm {
    $r = Invoke-DellSmm -Eax 0xFEA3
    return ($r.ReturnValue -and $r.EAX -eq 0x44494147 -and $r.EDX -eq 0x44454C4C)
}

function Get-FanState {
    $r = Invoke-DellSmm -Eax 0x00A3 -Ebx 0
    if (-not $r.ReturnValue) { throw 'Fan-State konnte nicht gelesen werden.' }
    return [int]($r.EAX -band 0xFF)
}

function Get-FanRPM {
    $r = Invoke-DellSmm -Eax 0x02A3 -Ebx 0
    if (-not $r.ReturnValue) { throw 'Fan-RPM konnte nicht gelesen werden.' }
    $rpm = [int]($r.EAX -band 0xFFFF)
    if ($rpm -eq 65535) { throw 'Ungültiger Fan-RPM-Wert.' }
    return $rpm
}

function Get-DellTemp {
    param([int]$Sensor = 0)
    $r = Invoke-DellSmm -Eax 0x10A3 -Ebx ([uint32]$Sensor)
    if (-not $r.ReturnValue) { throw 'Temperatur konnte nicht gelesen werden.' }

    $temp = [int]($r.EAX -band 0xFF)
    if ($temp -le 0 -or $temp -gt 127) {
        throw "Ungültige Temperatur: $temp"
    }
    return $temp
}

function Disable-BiosFanControl {
    $r = Invoke-DellSmm -Eax 0x30A3
    if (-not $r.ReturnValue) { throw 'Dell BIOS Fan Control konnte nicht deaktiviert werden.' }
}

function Enable-BiosFanControl {
    $r = Invoke-DellSmm -Eax 0x31A3
    if (-not $r.ReturnValue) { throw 'Dell BIOS Fan Control konnte nicht aktiviert werden.' }
}

function Set-FanLevel {
    param(
        [ValidateSet(1,2)]
        [int]$Level
    )

    $ebx = [uint32]($Level -shl 8)
    $r = Invoke-DellSmm -Eax 0x01A3 -Ebx $ebx

    if (-not $r.ReturnValue) {
        throw "Fan-Level $Level konnte nicht gesetzt werden."
    }
}

try {
    if (-not (Test-DellSmm)) {
        throw 'Dell-SMM Signaturtest fehlgeschlagen.'
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'Dell 7090 Fan Control',
        'OK',
        'Error'
    ) | Out-Null
    exit 1
}

# --- Autostart / Scheduled Task ---
function Test-Autostart {
    try {
        return $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Enable-Autostart {
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -StartMinimized"

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Dell OptiPlex 7090 Fan Control - startet minimiert im Tray' `
        -Force | Out-Null

    Write-Log 'Autostart task enabled'
}

function Disable-Autostart {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log 'Autostart task disabled'
    } catch {
        if (Test-Autostart) { throw }
    }
}

# --- GUI ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Dell 7090 Fan Control'
$form.Size = New-Object System.Drawing.Size(560, 610)
$form.MinimumSize = New-Object System.Drawing.Size(560, 610)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.MaximizeBox = $false

$lblTempTitle = New-Object System.Windows.Forms.Label
$lblTempTitle.Text = 'Sensor 0'
$lblTempTitle.Location = New-Object System.Drawing.Point(25, 20)
$lblTempTitle.AutoSize = $true
$form.Controls.Add($lblTempTitle)

$lblTemp = New-Object System.Windows.Forms.Label
$lblTemp.Text = '-- °C'
$lblTemp.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 24)
$lblTemp.Location = New-Object System.Drawing.Point(22, 43)
$lblTemp.Size = New-Object System.Drawing.Size(160, 50)
$form.Controls.Add($lblTemp)

$lblRpmTitle = New-Object System.Windows.Forms.Label
$lblRpmTitle.Text = 'Lüfter'
$lblRpmTitle.Location = New-Object System.Drawing.Point(200, 20)
$lblRpmTitle.AutoSize = $true
$form.Controls.Add($lblRpmTitle)

$lblRpm = New-Object System.Windows.Forms.Label
$lblRpm.Text = '-- RPM'
$lblRpm.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 24)
$lblRpm.Location = New-Object System.Drawing.Point(197, 43)
$lblRpm.Size = New-Object System.Drawing.Size(220, 50)
$form.Controls.Add($lblRpm)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = 'Status: Dell BIOS Auto'
$lblState.Location = New-Object System.Drawing.Point(25, 98)
$lblState.Size = New-Object System.Drawing.Size(480, 25)
$form.Controls.Add($lblState)

$lblOverride = New-Object System.Windows.Forms.Label
$lblOverride.Text = 'Persistent MAX Override: wird geprüft...'
$lblOverride.Location = New-Object System.Drawing.Point(25, 119)
$lblOverride.Size = New-Object System.Drawing.Size(480, 20)
$lblOverride.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblOverride)

$groupAuto = New-Object System.Windows.Forms.GroupBox
$groupAuto.Text = 'Automatische 2-Stufen-Regelung'
$groupAuto.Location = New-Object System.Drawing.Point(20, 150)
$groupAuto.Size = New-Object System.Drawing.Size(505, 145)
$form.Controls.Add($groupAuto)

$lblHigh = New-Object System.Windows.Forms.Label
$lblHigh.Text = 'Level 1 → Level 2 ab:'
$lblHigh.Location = New-Object System.Drawing.Point(18, 32)
$lblHigh.Size = New-Object System.Drawing.Size(220, 24)
$groupAuto.Controls.Add($lblHigh)

$numHigh = New-Object System.Windows.Forms.NumericUpDown
$numHigh.Location = New-Object System.Drawing.Point(255, 29)
$numHigh.Size = New-Object System.Drawing.Size(75, 25)
$numHigh.Minimum = 20
$numHigh.Maximum = 110
$numHigh.Value = [decimal]$config.HighThreshold
$groupAuto.Controls.Add($numHigh)

$lblHighC = New-Object System.Windows.Forms.Label
$lblHighC.Text = '°C'
$lblHighC.Location = New-Object System.Drawing.Point(340, 32)
$lblHighC.AutoSize = $true
$groupAuto.Controls.Add($lblHighC)

$lblLow = New-Object System.Windows.Forms.Label
$lblLow.Text = 'Level 2 → Level 1 unter:'
$lblLow.Location = New-Object System.Drawing.Point(18, 67)
$lblLow.Size = New-Object System.Drawing.Size(220, 24)
$groupAuto.Controls.Add($lblLow)

$numLow = New-Object System.Windows.Forms.NumericUpDown
$numLow.Location = New-Object System.Drawing.Point(255, 64)
$numLow.Size = New-Object System.Drawing.Size(75, 25)
$numLow.Minimum = 20
$numLow.Maximum = 100
$numLow.Value = [decimal]$config.LowThreshold
$groupAuto.Controls.Add($numLow)

$lblLowC = New-Object System.Windows.Forms.Label
$lblLowC.Text = '°C'
$lblLowC.Location = New-Object System.Drawing.Point(340, 67)
$lblLowC.AutoSize = $true
$groupAuto.Controls.Add($lblLowC)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Eigene Regelung aktiv'
$chkAuto.Location = New-Object System.Drawing.Point(18, 105)
$chkAuto.AutoSize = $true
$groupAuto.Controls.Add($chkAuto)

$groupManual = New-Object System.Windows.Forms.GroupBox
$groupManual.Text = 'Manuell'
$groupManual.Location = New-Object System.Drawing.Point(20, 310)
$groupManual.Size = New-Object System.Drawing.Size(505, 80)
$form.Controls.Add($groupManual)

$btnL1 = New-Object System.Windows.Forms.Button
$btnL1.Text = 'Level 1'
$btnL1.Location = New-Object System.Drawing.Point(12, 29)
$btnL1.Size = New-Object System.Drawing.Size(95, 34)
$groupManual.Controls.Add($btnL1)

$btnL2 = New-Object System.Windows.Forms.Button
$btnL2.Text = 'Level 2'
$btnL2.Location = New-Object System.Drawing.Point(116, 29)
$btnL2.Size = New-Object System.Drawing.Size(95, 34)
$groupManual.Controls.Add($btnL2)

$btnMax = New-Object System.Windows.Forms.Button
$btnMax.Text = 'MAX ~5800'
$btnMax.Location = New-Object System.Drawing.Point(220, 29)
$btnMax.Size = New-Object System.Drawing.Size(115, 34)
$groupManual.Controls.Add($btnMax)

$btnBios = New-Object System.Windows.Forms.Button
$btnBios.Text = 'Dell BIOS Auto'
$btnBios.Location = New-Object System.Drawing.Point(344, 29)
$btnBios.Size = New-Object System.Drawing.Size(145, 34)
$groupManual.Controls.Add($btnBios)

$groupSystem = New-Object System.Windows.Forms.GroupBox
$groupSystem.Text = 'Windows / Tray'
$groupSystem.Location = New-Object System.Drawing.Point(20, 403)
$groupSystem.Size = New-Object System.Drawing.Size(505, 75)
$form.Controls.Add($groupSystem)

$chkStartup = New-Object System.Windows.Forms.CheckBox
$chkStartup.Text = 'Mit Windows starten (minimiert im Tray)'
$chkStartup.Location = New-Object System.Drawing.Point(18, 29)
$chkStartup.AutoSize = $true
$chkStartup.Checked = Test-Autostart
$groupSystem.Controls.Add($chkStartup)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Einstellungen speichern'
$btnSave.Location = New-Object System.Drawing.Point(20, 493)
$btnSave.Size = New-Object System.Drawing.Size(190, 34)
$form.Controls.Add($btnSave)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = '1 s | X/Minimieren = Tray | Regelung läuft weiter'
$lblInfo.Location = New-Object System.Drawing.Point(225, 497)
$lblInfo.Size = New-Object System.Drawing.Size(310, 30)
$form.Controls.Add($lblInfo)

$lblBranding = New-Object System.Windows.Forms.Label
$lblBranding.Text = 'Powered by Ahrtos – www.ahrtos.de | assisted by ChatGPT'
$lblBranding.Location = New-Object System.Drawing.Point(20, 540)
$lblBranding.Size = New-Object System.Drawing.Size(505, 22)
$lblBranding.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$lblBranding.ForeColor = [System.Drawing.Color]::DimGray
$lblBranding.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($lblBranding)

# --- Busy overlay ----------------------------------------------------
# Shown only while a fan mode / persistent override is being changed.
$busyPanel = New-Object System.Windows.Forms.Panel
$busyPanel.Location = New-Object System.Drawing.Point(75, 218)
$busyPanel.Size = New-Object System.Drawing.Size(395, 105)
$busyPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$busyPanel.BackColor = [System.Drawing.Color]::WhiteSmoke
$busyPanel.Visible = $false
$form.Controls.Add($busyPanel)

$lblBusyTitle = New-Object System.Windows.Forms.Label
$lblBusyTitle.Text = 'Einstellungen werden übernommen ...'
$lblBusyTitle.Location = New-Object System.Drawing.Point(18, 14)
$lblBusyTitle.Size = New-Object System.Drawing.Size(355, 24)
$lblBusyTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$lblBusyTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$busyPanel.Controls.Add($lblBusyTitle)

$lblBusyDetail = New-Object System.Windows.Forms.Label
$lblBusyDetail.Text = 'Bitte warten.'
$lblBusyDetail.Location = New-Object System.Drawing.Point(18, 39)
$lblBusyDetail.Size = New-Object System.Drawing.Size(355, 20)
$lblBusyDetail.ForeColor = [System.Drawing.Color]::DimGray
$lblBusyDetail.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$busyPanel.Controls.Add($lblBusyDetail)

$progressBusy = New-Object System.Windows.Forms.ProgressBar
$progressBusy.Location = New-Object System.Drawing.Point(22, 70)
$progressBusy.Size = New-Object System.Drawing.Size(347, 18)
$progressBusy.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$progressBusy.MarqueeAnimationSpeed = 25
$busyPanel.Controls.Add($progressBusy)

# --- Tray icon ---
# Color meaning:
# Level 1 = green, Level 2 = orange, MAX = red, Dell BIOS Auto = white
$trayIconL1   = New-FanTrayIcon -Color ([System.Drawing.Color]::LimeGreen)
$trayIconL2   = New-FanTrayIcon -Color ([System.Drawing.Color]::DarkOrange)
$trayIconMax  = New-FanTrayIcon -Color ([System.Drawing.Color]::Red)
$trayIconBios = New-FanTrayIcon -Color ([System.Drawing.Color]::White)

$script:currentTrayMode = ''

function Set-TrayModeIcon {
    param(
        [ValidateSet('Level1','Level2','Max','Bios')]
        [string]$Mode
    )

    if ($script:currentTrayMode -eq $Mode) {
        return
    }

    switch ($Mode) {
        'Level1' { $notifyIcon.Icon = $trayIconL1 }
        'Level2' { $notifyIcon.Icon = $trayIconL2 }
        'Max'    { $notifyIcon.Icon = $trayIconMax }
        'Bios'   { $notifyIcon.Icon = $trayIconBios }
    }

    $script:currentTrayMode = $Mode
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $trayIconBios
$notifyIcon.Text = 'Dell 7090 Fan Control'
$notifyIcon.Visible = $true

$form.Icon = $trayIconBios

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$miShow = New-Object System.Windows.Forms.ToolStripMenuItem
$miShow.Text = 'Öffnen'
$trayMenu.Items.Add($miShow) | Out-Null

$miHide = New-Object System.Windows.Forms.ToolStripMenuItem
$miHide.Text = 'Minimieren'
$trayMenu.Items.Add($miHide) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miMax = New-Object System.Windows.Forms.ToolStripMenuItem
$miMax.Text = 'MAX ~5800 RPM'
$trayMenu.Items.Add($miMax) | Out-Null

$miBios = New-Object System.Windows.Forms.ToolStripMenuItem
$miBios.Text = 'Dell BIOS Auto'
$trayMenu.Items.Add($miBios) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = 'Beenden'
$trayMenu.Items.Add($miExit) | Out-Null

$notifyIcon.ContextMenuStrip = $trayMenu

$script:autoActive = $false
$script:manualActive = $false
$script:maxActive = $false
$script:currentLevel = $null
$script:suppressAutoEvent = $false
$script:persistentMaxKnown = $false

function Thresholds-Valid {
    return ([int]$numLow.Value -lt [int]$numHigh.Value)
}

function Show-MainWindow {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

function Hide-MainWindow {
    $form.ShowInTaskbar = $false
    $form.Hide()
}


function Set-UiBusy {
    param(
        [bool]$Busy,
        [string]$Message = 'Bitte warten...'
    )

    $script:uiBusy = $Busy

    foreach ($control in @(
        $btnL1, $btnL2, $btnMax, $btnBios,
        $chkAuto, $numHigh, $numLow,
        $chkStartup, $btnSave
    )) {
        if ($null -ne $control) {
            $control.Enabled = -not $Busy
        }
    }

    foreach ($item in @($miMax, $miBios, $miExit)) {
        if ($null -ne $item) {
            $item.Enabled = -not $Busy
        }
    }

    if ($Busy) {
        $lblBusyDetail.Text = $Message
        $busyPanel.Visible = $true
        $busyPanel.BringToFront()
        $form.UseWaitCursor = $true
    }
    else {
        $busyPanel.Visible = $false
        $form.UseWaitCursor = $false
    }

    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AutoCheckboxSilently {
    param([bool]$Checked)

    $script:suppressAutoEvent = $true
    try {
        $chkAuto.Checked = $Checked
    }
    finally {
        $script:suppressAutoEvent = $false
    }
}

function Switch-ToManualLevel {
    param(
        [ValidateSet(1,2)]
        [int]$Level
    )

    # Critical sequence:
    # 1) Persistent MAX OFF and verified.
    # 2) BIOS automatic SMM control OFF.
    # 3) Manual level set.
    # 4) Persistent MAX checked AGAIN, because it must not survive silently.
    Ensure-MaxOverrideDisabled
    Disable-BiosFanControl
    Set-FanLevel $Level
    Wait-Responsive -Milliseconds 300
    Ensure-MaxOverrideDisabled

    $script:autoActive = $false
    $script:manualActive = $true
    $script:maxActive = $false
    $script:currentLevel = $Level

    Write-Log "Switched to manual Level $Level; MAX verified Disabled"
}

function Switch-ToDellBiosAuto {
    # Do not trust a single write. MAX must be disabled before AND after EC/BIOS handoff.
    Ensure-MaxOverrideDisabled

    Enable-BiosFanControl
    Wait-Responsive -Milliseconds 400

    Ensure-MaxOverrideDisabled

    $script:autoActive = $false
    $script:manualActive = $false
    $script:maxActive = $false
    $script:currentLevel = $null

    Write-Log 'Switched to Dell BIOS Auto; MAX verified Disabled before/after handoff'
}

function Switch-ToCustomAuto {
    if (-not (Thresholds-Valid)) {
        throw 'Die untere Schwelle muss niedriger als die obere Schwelle sein.'
    }

    Ensure-MaxOverrideDisabled
    Disable-BiosFanControl
    Wait-Responsive -Milliseconds 200
    Ensure-MaxOverrideDisabled

    $script:autoActive = $true
    $script:manualActive = $false
    $script:maxActive = $false
    $script:currentLevel = $null

    Write-Log 'Custom 2-level auto enabled; MAX verified Disabled'
}

function Switch-ToMax {
    # Leave manual SMM mode first, then enable the persistent BIOS override.
    Enable-BiosFanControl
    Wait-Responsive -Milliseconds 250

    Enable-MaxOverride

    $script:autoActive = $false
    $script:manualActive = $false
    $script:maxActive = $true
    $script:currentLevel = $null

    Write-Log 'MAX override enabled and verified'
}

function Update-Status {
    try {
        $temp = Get-DellTemp -Sensor ([int]$config.SensorIndex)
        $rpm = Get-FanRPM
        $state = Get-FanState

        $lblTemp.Text = "$temp °C"
        $lblRpm.Text = "$rpm RPM"

        $persistentMax = [bool]$script:persistentMaxKnown
        if ($persistentMax) {
            $lblOverride.Text = 'Persistent MAX Override: ENABLED'
            $lblOverride.ForeColor = [System.Drawing.Color]::DarkRed
        }
        else {
            $lblOverride.Text = 'Persistent MAX Override: Disabled'
            $lblOverride.ForeColor = [System.Drawing.Color]::DarkGreen
        }

        if ($persistentMax -or $script:maxActive) {
            $script:autoActive = $false
            $script:manualActive = $false
            $script:maxActive = $true
            $script:currentLevel = $null
            $lblState.Text = "Status: MAX OVERRIDE AKTIV | ~$rpm RPM"
        }
        elseif ($script:autoActive) {
            $low = [int]$numLow.Value
            $high = [int]$numHigh.Value

            if (-not (Thresholds-Valid)) {
                $lblState.Text = 'Status: ungültige Schwellenwerte'
                return
            }

            if ($null -eq $script:currentLevel) {
                $script:currentLevel = if ($temp -ge $high) { 2 } else { 1 }
                Set-FanLevel $script:currentLevel
                Write-Log "Auto initial level $($script:currentLevel), temp $temp C"
            }
            elseif ($script:currentLevel -eq 1 -and $temp -ge $high) {
                Set-FanLevel 2
                $script:currentLevel = 2
                Write-Log "L1 -> L2 at $temp C"
            }
            elseif ($script:currentLevel -eq 2 -and $temp -le $low) {
                Set-FanLevel 1
                $script:currentLevel = 1
                Write-Log "L2 -> L1 at $temp C"
            }

            $lblState.Text = "Status: eigene Automatik | Level $($script:currentLevel) | Fan-State $state"
        }
        elseif ($script:manualActive) {
            $script:maxActive = $false
            $lblState.Text = "Status: manuell | Level $($script:currentLevel) | Fan-State $state"
        }
        else {
            $script:maxActive = $false
            $lblState.Text = "Status: Dell BIOS Auto | Fan-State $state"
        }

        if ($script:maxActive) {
            Set-TrayModeIcon -Mode 'Max'
        }
        elseif ($script:autoActive -or $script:manualActive) {
            if ($script:currentLevel -eq 2) {
                Set-TrayModeIcon -Mode 'Level2'
            }
            else {
                Set-TrayModeIcon -Mode 'Level1'
            }
        }
        else {
            Set-TrayModeIcon -Mode 'Bios'
        }

        $notifyIcon.Text = if ($script:maxActive) { "Dell 7090 - MAX - $temp °C - $rpm RPM" } else { "Dell 7090 - $temp °C - $rpm RPM" }
    }
    catch {
        Write-Log "Update error: $($_.Exception.Message)"
        $lblState.Text = "FEHLER: $($_.Exception.Message)"

        try {
            Ensure-MaxOverrideDisabled
            Disable-BiosFanControl
            Set-FanLevel 2
            $script:autoActive = $false
            $script:manualActive = $true
            $script:currentLevel = 2
            $lblState.Text += ' | Failsafe Level 2'
            Set-TrayModeIcon -Mode 'Level2'
            $notifyIcon.Text = 'Dell 7090 Fan Control - FAILSAFE Level 2'
        } catch {
            Write-Log "Failsafe error: $($_.Exception.Message)"
        }
    }
}

$btnL1.Add_Click({
    Set-UiBusy -Busy $true -Message 'Level 1 wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToManualLevel -Level 1
        Update-Status
    } catch {
        Write-Log "Level 1 error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Level 1 Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$btnL2.Add_Click({
    Set-UiBusy -Busy $true -Message 'Level 2 wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToManualLevel -Level 2
        Update-Status
    } catch {
        Write-Log "Level 2 error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Level 2 Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$btnMax.Add_Click({
    Set-UiBusy -Busy $true -Message 'MAX ~5800 RPM wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToMax
        Update-Status
    } catch {
        Write-Log "MAX error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MAX Override Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$btnBios.Add_Click({
    Set-UiBusy -Busy $true -Message 'Dell BIOS Auto wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToDellBiosAuto
        Update-Status
    } catch {
        Write-Log "Dell BIOS Auto error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Dell BIOS Auto Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$chkAuto.Add_CheckedChanged({
    if ($script:suppressAutoEvent) {
        return
    }

    $busyMessage = if ($chkAuto.Checked) {
        'Eigene 2-Stufen-Regelung wird aktiviert. Bitte warten ...'
    } else {
        'Dell BIOS Auto wird wiederhergestellt. Bitte warten ...'
    }

    Set-UiBusy -Busy $true -Message $busyMessage
    try {
        if ($chkAuto.Checked) {
            Switch-ToCustomAuto
            Update-Status
        }
        else {
            if ($script:autoActive) {
                Switch-ToDellBiosAuto
                Update-Status
            }
        }
    } catch {
        Write-Log "Auto toggle error: $($_.Exception.Message)"
        Set-AutoCheckboxSilently -Checked $false
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Automatik Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$chkStartup.Add_CheckedChanged({
    try {
        if ($chkStartup.Checked) {
            Enable-Autostart
        } else {
            Disable-Autostart
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Autostart konnte nicht geändert werden.`r`n`r`n$($_.Exception.Message)",
            'Autostart',
            'OK',
            'Error'
        ) | Out-Null

        # restore actual state without re-triggering wrong mutation
        $chkStartup.Checked = Test-Autostart
    }
})

$btnSave.Add_Click({
    if (-not (Thresholds-Valid)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Die untere Schwelle muss niedriger als die obere Schwelle sein.',
            'Ungültige Einstellung',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $save = [ordered]@{
        SensorIndex   = [int]$config.SensorIndex
        LowThreshold  = [int]$numLow.Value
        HighThreshold = [int]$numHigh.Value
        PollMs        = 1000
        AutoControl   = [bool]$chkAuto.Checked
    }

    $save | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
    Write-Log 'Settings saved'

    [System.Windows.Forms.MessageBox]::Show(
        'Einstellungen gespeichert.',
        'Dell 7090 Fan Control',
        'OK',
        'Information'
    ) | Out-Null
})

# Tray interactions
$miMax.Add_Click({
    if (-not $form.Visible) {
        $notifyIcon.BalloonTipTitle = 'Dell 7090 Fan Control'
        $notifyIcon.BalloonTipText = 'MAX ~5800 RPM wird aktiviert ...'
        $notifyIcon.ShowBalloonTip(1800)
    }

    Set-UiBusy -Busy $true -Message 'MAX ~5800 RPM wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToMax
        Update-Status
    } catch {
        Write-Log "Tray MAX error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MAX Override Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

$miBios.Add_Click({
    if (-not $form.Visible) {
        $notifyIcon.BalloonTipTitle = 'Dell 7090 Fan Control'
        $notifyIcon.BalloonTipText = 'Dell BIOS Auto wird aktiviert ...'
        $notifyIcon.ShowBalloonTip(1800)
    }

    Set-UiBusy -Busy $true -Message 'Dell BIOS Auto wird aktiviert. Bitte warten ...'
    try {
        Set-AutoCheckboxSilently -Checked $false
        Switch-ToDellBiosAuto
        Update-Status
    } catch {
        Write-Log "Tray BIOS Auto error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Dell BIOS Auto Fehler', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-UiBusy -Busy $false
    }
})

# Polling
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-Status })

# The tray/application context owns the process lifetime.
# The window can be hidden without ending the application.
$appContext = New-Object System.Windows.Forms.ApplicationContext
$script:shutdownDone = $false

function Shutdown-App {
    if ($script:shutdownDone) {
        return
    }

    $script:shutdownDone = $true

    try {
        $timer.Stop()
    } catch {}

    try {
        Ensure-MaxOverrideDisabled
        Enable-BiosFanControl
        Wait-Responsive -Milliseconds 250
        Ensure-MaxOverrideDisabled
        Write-Log 'Application exited; MAX verified Disabled and Dell BIOS Auto restored'
    } catch {
        Write-Log "Shutdown restore error: $($_.Exception.Message)"
    }

    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}

    foreach ($icon in @($trayIconL1, $trayIconL2, $trayIconMax, $trayIconBios)) {
        try {
            if ($null -ne $icon) {
                $icon.Dispose()
            }
        } catch {}
    }

    try {
        $form.Hide()
        $form.Dispose()
    } catch {}

    try {
        $appContext.ExitThread()
    } catch {}
}

# Tray menu
$miShow.Add_Click({
    Show-MainWindow
})

$miHide.Add_Click({
    Hide-MainWindow
})

$miExit.Add_Click({
    Shutdown-App
})

$notifyIcon.Add_DoubleClick({
    Show-MainWindow
})

# X does not exit. It only hides the window.
$form.Add_FormClosing({
    param($sender, $e)

    if (-not $script:shutdownDone -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-MainWindow
    }
})

# Minimizing does not exit. It only hides the window.
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        Hide-MainWindow
    }
})

# One-time startup initialization
try {
    $startupMax = $false
    try {
        $startupMax = Get-FanOverrideEnabled
    } catch {
        Write-Log "Startup override check failed: $($_.Exception.Message)"
    }

    $script:persistentMaxKnown = [bool]$startupMax

    if ($startupMax) {
        $script:maxActive = $true
        $script:autoActive = $false
        $script:manualActive = $false
        $script:currentLevel = $null
        Set-AutoCheckboxSilently -Checked $false
        Write-Log 'Startup detected persistent MAX override - not overwritten'
    }
    elseif ([bool]$config.AutoControl) {
        try {
            Set-UiBusy -Busy $true -Message 'Gespeicherte Lüfterregelung wird geladen. Bitte warten ...'
            Set-AutoCheckboxSilently -Checked $true
            Switch-ToCustomAuto
        } catch {
            Write-Log "Startup custom auto failed: $($_.Exception.Message)"
            Set-AutoCheckboxSilently -Checked $false
        }
        finally {
            Set-UiBusy -Busy $false
        }
    }

    Update-Status
    $timer.Start()

    if ($StartMinimized) {
        Hide-MainWindow
        Write-Log 'Started minimized in tray'
    }
    else {
        Show-MainWindow
    }

    [System.Windows.Forms.Application]::Run($appContext)
}
catch {
    Write-Log "Fatal application error: $($_.Exception.Message)"

    try {
        [System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`r`n`r`nDetails wurden in Dell7090FanControl.log geschrieben.",
            'Dell 7090 Fan Control - Fehler',
            'OK',
            'Error'
        ) | Out-Null
    } catch {}

    Shutdown-App
    exit 1
}