#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a Windows Toast Notification asking if the user is Happy or Sad,
    then logs their response to a file.

.DESCRIPTION
    Displays an interactive toast with "Happy" and "Sad" buttons. Each button
    launches a small hidden PowerShell command that writes the choice to a
    temp file. The main script watches for that file to appear, reads it, then
    logs the result.

.PARAMETER LogPath
    Path to the log file. Defaults to "MoodLog.txt" in the same folder as
    this script.
#>

[CmdletBinding()]
param (
    [string]$LogPath = (Join-Path $PSScriptRoot "MoodLog.txt")
)

# ---------------------------------------------------------------------------
# 1. Load WinRT types
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,     ContentType = WindowsRuntime]

# ---------------------------------------------------------------------------
# 2. Set up a temp file as the response bridge
#    Each toast button runs a hidden PowerShell process that writes to this file.
# ---------------------------------------------------------------------------
$responsePath = Join-Path $env:TEMP "ToastMoodResponse_$PID.txt"

# Clean up any leftover file from a previous run
if (Test-Path $responsePath) { Remove-Item $responsePath -Force }

# Build the per-button launch commands (written into the toast XML arguments)
# powershell.exe -WindowStyle Hidden -Command "Set-Content -Path '<file>' -Value 'Happy'"
$happyCmd = "powershell.exe -WindowStyle Hidden -NonInteractive -Command `"Set-Content -Path '$responsePath' -Value 'Happy'`""
$sadCmd   = "powershell.exe -WindowStyle Hidden -NonInteractive -Command `"Set-Content -Path '$responsePath' -Value 'Sad'`""

# ---------------------------------------------------------------------------
# 3. Build the toast XML
#    activationType="protocol" launches the arguments string as a URI/command.
#    We use the special ms-toast-action:// workaround via a .cmd launcher instead
#    — the most reliable cross-version method is activationType="background" with
#    a registered COM server, but the simplest approach that actually works for
#    plain PowerShell is to use a temporary .cmd file per button.
# ---------------------------------------------------------------------------

# Write tiny .cmd launchers for each button
$happyCmd_path = Join-Path $env:TEMP "ToastHappy_$PID.cmd"
$sadCmd_path   = Join-Path $env:TEMP "ToastSad_$PID.cmd"

Set-Content -Path $happyCmd_path -Value "@echo off`npowershell.exe -WindowStyle Hidden -NonInteractive -Command `"Set-Content -Path '$responsePath' -Value 'Happy'`"" -Encoding ASCII
Set-Content -Path $sadCmd_path   -Value "@echo off`npowershell.exe -WindowStyle Hidden -NonInteractive -Command `"Set-Content -Path '$responsePath' -Value 'Sad'`""   -Encoding ASCII

$toastXml = @"
<toast activationType="protocol" launch="$happyCmd_path">
  <visual>
    <binding template="ToastGeneric">
      <text>How are you feeling right now?</text>
      <text>Please let us know your current mood.</text>
    </binding>
  </visual>
  <actions>
    <action
      content="Happy 😊"
      arguments="$happyCmd_path"
      activationType="protocol" />
    <action
      content="Sad 😢"
      arguments="$sadCmd_path"
      activationType="protocol" />
  </actions>
</toast>
"@

# ---------------------------------------------------------------------------
# 4. Show the toast
# ---------------------------------------------------------------------------
$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
$xmlDoc.LoadXml($toastXml)

$toast    = New-Object Windows.UI.Notifications.ToastNotification($xmlDoc)
$AppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)

try {
    $notifier.Show($toast)
    Write-Host "Toast displayed. Waiting for response (up to 30s)..."
}
catch {
    Write-Error "Failed to display toast: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# 5. Poll for the temp response file (written by whichever button was clicked)
# ---------------------------------------------------------------------------
$timeout = 30
$elapsed = 0

while (-not (Test-Path $responsePath) -and $elapsed -lt $timeout) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

# ---------------------------------------------------------------------------
# 6. Read the response
# ---------------------------------------------------------------------------
if (Test-Path $responsePath) {
    $logEntry = (Get-Content $responsePath -Raw).Trim()
} else {
    $logEntry = "No response (timed out)"
}

# ---------------------------------------------------------------------------
# 7. Log the result
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logLine   = "$timestamp | User: $env:USERNAME | Response: $logEntry"

$logDir = Split-Path $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Add-Content -Path $LogPath -Value $logLine -Encoding UTF8

Write-Host ""
Write-Host "Response  : $logEntry"
Write-Host "Logged to : $LogPath"
Write-Host "Log entry : $logLine"

# ---------------------------------------------------------------------------
# 8. Clean up temp files
# ---------------------------------------------------------------------------
Remove-Item $responsePath  -Force -ErrorAction SilentlyContinue
Remove-Item $happyCmd_path -Force -ErrorAction SilentlyContinue
Remove-Item $sadCmd_path   -Force -ErrorAction SilentlyContinue
