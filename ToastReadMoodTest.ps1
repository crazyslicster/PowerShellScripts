#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a Windows Toast Notification asking if the user is Happy or Sad,
    then logs their response to a file.

.DESCRIPTION
    Displays an interactive toast with "Happy" and "Sad" buttons. Each button
    triggers a VBScript file which silently launches PowerShell with no visible
    window at all, writing the mood choice to a temp file. The main script
    watches for that file, reads it, and logs the result.

.PARAMETER LogPath
    Path to the log file. Defaults to "MoodLog.txt" in the same folder as
    this script.
#>

[CmdletBinding()]
param (
    [string]$LogPath = "c:\temp\MoodTest.log"
)

# ---------------------------------------------------------------------------
# 1. Load WinRT types
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,     ContentType = WindowsRuntime]

# ---------------------------------------------------------------------------
# 2. Set up temp file paths
# ---------------------------------------------------------------------------
$responsePath  = Join-Path $env:TEMP "ToastMoodResponse_$PID.txt"
$happyVbs      = Join-Path $env:TEMP "ToastHappy_$PID.vbs"
$sadVbs        = Join-Path $env:TEMP "ToastSad_$PID.vbs"

# Clean up any leftovers from a previous run
foreach ($f in $responsePath, $happyVbs, $sadVbs) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---------------------------------------------------------------------------
# 3. Write VBScript launchers
#    WScript.Shell.Run() with windowStyle=0 (hidden) and bWaitOnReturn=False
#    launches PowerShell with absolutely no visible window — not even a flash.
# ---------------------------------------------------------------------------
$happyPs = "Set-Content -Path '$responsePath' -Value 'Happy'"
$sadPs   = "Set-Content -Path '$responsePath' -Value 'Sad'"

Set-Content -Path $happyVbs -Encoding ASCII -Value @"
Dim oShell
Set oShell = CreateObject("WScript.Shell")
oShell.Run "powershell.exe -WindowStyle Hidden -NonInteractive -Command ""$happyPs""", 0, False
Set oShell = Nothing
"@

Set-Content -Path $sadVbs -Encoding ASCII -Value @"
Dim oShell
Set oShell = CreateObject("WScript.Shell")
oShell.Run "powershell.exe -WindowStyle Hidden -NonInteractive -Command ""$sadPs""", 0, False
Set oShell = Nothing
"@

# ---------------------------------------------------------------------------
# 4. Build and show the toast
#    activationType="protocol" launches the .vbs via wscript.exe silently.
# ---------------------------------------------------------------------------
$toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>How are you feeling right now?</text>
      <text>Please let us know your current mood.</text>
    </binding>
  </visual>
  <actions>
    <action
      content="Happy 😊"
      arguments="$happyVbs"
      activationType="protocol" />
    <action
      content="Sad 😢"
      arguments="$sadVbs"
      activationType="protocol" />
  </actions>
</toast>
"@

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
# 5. Poll for the response file
# ---------------------------------------------------------------------------
$timeout = 30
$elapsed = 0

while (-not (Test-Path $responsePath) -and $elapsed -lt $timeout) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

# ---------------------------------------------------------------------------
# 6. Read, log, and clean up
# ---------------------------------------------------------------------------
if (Test-Path $responsePath) {
    $logEntry = (Get-Content $responsePath -Raw).Trim()
} else {
    $logEntry = "No response (timed out)"
}

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

# Clean up all temp files
Remove-Item $responsePath -Force -ErrorAction SilentlyContinue
Remove-Item $happyVbs     -Force -ErrorAction SilentlyContinue
Remove-Item $sadVbs       -Force -ErrorAction SilentlyContinue
