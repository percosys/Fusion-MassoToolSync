# rebuild_notify.ps1
#
# Shown while the gadget rebuilds its tool-groups cache via sqlite3.
# VCarve's Lua is single-threaded so it can't animate a progress
# indicator during the blocking subprocess call, but this separate
# PowerShell process runs in parallel and shows a proper "please wait"
# dialog that auto-dismisses when the gadget writes the signal file.
#
# Parameters:
#   -FlagFile  path to a sentinel file; when it appears, the dialog closes
#              (the gadget writes it once the sqlite3 query returns)

param([string]$FlagFile)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text             = 'MASSO Tool Sync'
$form.ClientSize       = New-Object System.Drawing.Size(440, 120)
$form.StartPosition    = 'CenterScreen'
$form.FormBorderStyle  = 'FixedDialog'
$form.MinimizeBox      = $false
$form.MaximizeBox      = $false
$form.ControlBox       = $false
$form.TopMost          = $true

$label = New-Object System.Windows.Forms.Label
$label.Text      = "Rebuilding tool database cache...`n`nThis window will close automatically when finished."
$label.AutoSize  = $false
$label.Size      = New-Object System.Drawing.Size(400, 80)
$label.Location  = New-Object System.Drawing.Point(20, 20)
$label.TextAlign = 'MiddleCenter'
$label.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($label)

$script:startTime = Get-Date

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    if ([string]::IsNullOrEmpty($FlagFile)) { return }
    if (Test-Path $FlagFile) {
        $timer.Stop()
        Remove-Item $FlagFile -ErrorAction SilentlyContinue
        $form.Close()
        return
    }
    # Safety: self-destruct after 60 s so we never leak a zombie window
    # if the gadget crashed before writing the flag file.
    if (((Get-Date) - $script:startTime).TotalSeconds -gt 60) {
        $timer.Stop()
        $form.Close()
    }
})
$timer.Start()

[void]$form.ShowDialog()
