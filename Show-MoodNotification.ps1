#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a Windows Toast Notification asking if the user is Happy or Sad,
    then logs their response to a file.

.DESCRIPTION
    Registers a custom AppUserModelId and a custom URI scheme (ps-toast-response://)
    in the current user's registry. Toast buttons use activationType="protocol" with
    the custom URI, so when clicked Windows re-launches this script with the URI as
    an argument. That second instance writes the response to a temp file and exits.
    The main instance polls for the temp file, reads it, and logs the result.

    Run with -Register to set up the registry keys before first use.
    Run with -Unregister to clean up all registry keys.

.PARAMETER LogPath
    Path to the log file. Defaults to "MoodLog.txt" beside this script.

.PARAMETER Register
    Registers the AppUserModelId and URI scheme in the registry then exits.

.PARAMETER Unregister
    Removes all registry keys created by this script and exits.

.PARAMETER UriResponse
    Internal parameter — populated automatically when Windows re-launches this
    script via the ps-toast-response:// URI scheme. Do not pass manually.

.EXAMPLE
    # Step 1: register once
    .\Show-MoodNotification.ps1 -Register

    # Step 2: run normally from then on
    .\Show-MoodNotification.ps1

    # Optional: clean up registry when done
    .\Show-MoodNotification.ps1 -Unregister
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param (
    [Parameter(ParameterSetName = 'Run')]
    [string]$LogPath = "c:\temp\mood.log",

    [Parameter(ParameterSetName = 'Register')]
    [switch]$Register,

    [Parameter(ParameterSetName = 'Unregister')]
    [switch]$Unregister,

    [Parameter(ParameterSetName = 'UriHandler')]
    [string]$UriResponse = ''
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$AppId      = 'MyCompany.MoodTracker'
$AppDisplay = 'Mood Tracker'
$UriScheme  = 'ps-toast-response'
$AppRegPath = "HKCU:\SOFTWARE\Classes\AppUserModelId\$AppId"
$UriRegPath = "HKCU:\SOFTWARE\Classes\$UriScheme"

# Shared temp file — the URI handler instance writes here, the main instance reads it
$ResponseFile = Join-Path $env:TEMP "ToastMoodResponse.txt"

# ---------------------------------------------------------------------------
# BRANCH A: URI handler — launched silently by Windows when a button is clicked
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'UriHandler') {
    # Parse value from URI e.g. ps-toast-response://response?value=Happy
    if ($UriResponse -match '[?&]value=([^&]+)') {
        $value = [Uri]::UnescapeDataString($Matches[1])
    } else {
        $value = $UriResponse
    }
    Set-Content -Path $ResponseFile -Value $value -Encoding UTF8
    exit 0
}

# ---------------------------------------------------------------------------
# BRANCH B: -Register
# ---------------------------------------------------------------------------
if ($Register) {
    Write-Host "Registering AppUserModelId '$AppId'..."
    if (-not (Test-Path $AppRegPath)) { New-Item -Path $AppRegPath -Force | Out-Null }
    Set-ItemProperty -Path $AppRegPath -Name 'DisplayName' -Value $AppDisplay

    Write-Host "Registering URI scheme '$($UriScheme)://'..."
    if (-not (Test-Path $UriRegPath)) { New-Item -Path $UriRegPath -Force | Out-Null }
    Set-ItemProperty -Path $UriRegPath -Name '(Default)'    -Value "URL:$UriScheme Protocol"
    Set-ItemProperty -Path $UriRegPath -Name 'URL Protocol' -Value ''

    $cmdPath = "$UriRegPath\shell\open\command"
    if (-not (Test-Path $cmdPath)) { New-Item -Path $cmdPath -Force | Out-Null }

    # When the URI fires, Windows runs this command — the script handles it via -UriResponse
    $handler = "powershell.exe -WindowStyle Hidden -NonInteractive -File `"$PSCommandPath`" -UriResponse `"%1`""
    Set-ItemProperty -Path $cmdPath -Name '(Default)' -Value $handler

    Write-Host ""
    Write-Host "Registration complete. You can now run the script without -Register."
    exit 0
}

# ---------------------------------------------------------------------------
# BRANCH C: -Unregister
# ---------------------------------------------------------------------------
if ($Unregister) {
    foreach ($path in $AppRegPath, $UriRegPath) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force
            Write-Host "Removed: $path"
        } else {
            Write-Host "Not found (skipping): $path"
        }
    }
    Write-Host "Unregistration complete."
    exit 0
}

# ---------------------------------------------------------------------------
# BRANCH D: Normal run — show the toast and wait for a response
# ---------------------------------------------------------------------------

# Verify registry is set up
if (-not (Test-Path $AppRegPath) -or -not (Test-Path $UriRegPath)) {
    Write-Warning "Registry keys not found. Run with -Register first:"
    Write-Warning "  .\Show-MoodNotification.ps1 -Register"
    exit 1
}

# Clean up any leftover response file from a previous run
if (Test-Path $ResponseFile) { Remove-Item $ResponseFile -Force }

# ---------------------------------------------------------------------------
# Load WinRT types
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,     ContentType = WindowsRuntime]

# ---------------------------------------------------------------------------
# Build and show the toast
# ---------------------------------------------------------------------------
$toastXml = @"
<toast activationType="protocol" launch="${UriScheme}://response?value=default">
  <visual>
    <binding template="ToastGeneric">
      <text>How are you feeling right now?</text>
      <text>Please let us know your current mood.</text>
    </binding>
  </visual>
  <actions>
    <action
      content="Happy 😊"
      arguments="${UriScheme}://response?value=Happy"
      activationType="protocol" />
    <action
      content="Sad 😢"
      arguments="${UriScheme}://response?value=Sad"
      activationType="protocol" />
  </actions>
</toast>
"@

$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
$xmlDoc.LoadXml($toastXml)

$toast    = New-Object Windows.UI.Notifications.ToastNotification($xmlDoc)
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
# Poll for the response file written by the URI handler instance
# ---------------------------------------------------------------------------
$timeout = 30
$elapsed = 0

while (-not (Test-Path $ResponseFile) -and $elapsed -lt $timeout) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

# ---------------------------------------------------------------------------
# Read, log, and clean up
# ---------------------------------------------------------------------------
if (Test-Path $ResponseFile) {
    $logEntry = (Get-Content $ResponseFile -Raw).Trim()
    Remove-Item $ResponseFile -Force -ErrorAction SilentlyContinue
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
