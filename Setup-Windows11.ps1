#Requires -RunAsAdministrator
# ============================================================
#  Windows 11 - standard post-format setup
#  Run through Run-Setup.bat (as Administrator), while logged in
#  as the user account that will be used by the customer.
# ============================================================

$ErrorActionPreference = 'Continue'

# ---- Apps to install (winget IDs) - edit freely ----
$Apps = @(
    'Mozilla.Firefox',                        # Greek version: 'Mozilla.Firefox.el'
    'Google.Chrome',
    'CodecGuide.K-LiteCodecPack.Standard',    # or .Basic / .Full / .Mega
    'AnyDeskSoftwareGmbH.AnyDesk',
    'Adobe.Acrobat.Reader.64-bit'
)

# ---- Apps to REMOVE (wildcards allowed) ----
$Remove = @(
    # News, Weather
    'Microsoft.BingNews', 'Microsoft.BingWeather',
    # Copilot, Microsoft 365 / Office
    'Microsoft.Copilot', 'Microsoft.MicrosoftOfficeHub',
    # Xbox
    'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxSpeechToTextOverlay',
    # Solitaire
    'Microsoft.MicrosoftSolitaireCollection',
    # Teams
    'MSTeams', 'MicrosoftTeams',
    # Phone Link, Family, Quick Assist
    'Microsoft.YourPhone', '*MicrosoftFamily*', '*QuickAssist*',
    # Clipchamp, Media Player, Movies & TV
    'Clipchamp.Clipchamp', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
    # Get Help, Tips, Feedback Hub
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsFeedbackHub',
    # Maps, People, Sticky Notes, To Do, Alarms, Sound Recorder
    'Microsoft.WindowsMaps', 'Microsoft.People', 'Microsoft.MicrosoftStickyNotes',
    'Microsoft.Todos', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsSoundRecorder',
    # Power Automate
    'Microsoft.PowerAutomateDesktop',
    # Camera  (Snipping Tool is kept on purpose: Win+Shift+S needs it.
    #          To remove it too, add 'Microsoft.ScreenSketch' here)
    'Microsoft.WindowsCamera',
    # Promo / third-party apps
    '*Spotify*', '*Disney*', '*PrimeVideo*', '*Netflix*', '*Instagram*', '*Facebook*',
    '*TikTok*', '*LinkedIn*', '*WhatsApp*', '*Dropbox*',
    '*CandyCrush*', '*Twitter*', '*Hulu*', '*Duolingo*', '*Pinterest*'
)

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# ------------------------------------------------------------
Step "1/11  System Restore: disable + delete restore points"
try { Disable-ComputerRestore -Drive "$env:SystemDrive\" } catch { Write-Warning $_.Exception.Message }
vssadmin delete shadows /for=$env:SystemDrive /all /quiet 2>&1 | Out-Null
Write-Host "Done."

# ------------------------------------------------------------
Step "2/11  Taskbar alignment: Left"
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0

# ------------------------------------------------------------
Step "3/11  Desktop icons: This PC, User folder, Recycle Bin"
$hide = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
Set-Reg $hide '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0   # This PC
Set-Reg $hide '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 0   # User's Files
Set-Reg $hide '{645FF040-5081-101B-9F08-00AA002F954E}' 0   # Recycle Bin

# ------------------------------------------------------------
Step "4/11  Start menu: folders next to Power, pinned apps, List view"

# 4a. Folders next to the Power button: File Explorer + Settings only (1 = show, 0 = hide)
$startPol = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
Set-Reg $startPol 'AllowPinnedFolderFileExplorer' 1
Set-Reg $startPol 'AllowPinnedFolderSettings'     1
foreach ($n in 'Documents','Downloads','Music','Network','Personalfolder','Pictures','Videos') {
    Set-Reg $startPol "AllowPinnedFolder$n" 0
}

# 4b. Pinned section: only Control Panel
$lnkDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
$lnk    = Join-Path $lnkDir 'Control Panel.lnk'
$ws     = New-Object -ComObject WScript.Shell
$sc     = $ws.CreateShortcut($lnk)
$sc.TargetPath = "$env:SystemRoot\System32\control.exe"
$sc.Save()

$pins = '{"pinnedList":[{"desktopAppLink":"%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Control Panel.lnk"}]}'
Set-Reg $startPol 'ConfigureStartPins' $pins 'String'
Set-Reg $startPol 'ConfigureStartPins_ProviderSet' 1
Set-Reg $startPol 'ConfigureStartPins_WinningProvider' 'B5292708-1619-419B-9923-E5D9F3925E71' 'String'

# Optional fallback: if a "start2.bin" (exported from a reference PC with only
# Control Panel pinned) sits next to this script, copy it into the profile.
$bin = Join-Path $PSScriptRoot 'start2.bin'
if (Test-Path $bin) {
    $dest = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
    if (Test-Path $dest) { Copy-Item $bin (Join-Path $dest 'start2.bin') -Force; Write-Host "start2.bin copied." }
}

# 4c. "All apps" view -> List  (0 = Category, 1 = Grid, 2 = List)
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'AllAppsViewMode' 2

# ------------------------------------------------------------
Step "5/11  Power plan: display 30 min, sleep never, hard disk never (AC + battery)"
powercfg /change monitor-timeout-ac 30
powercfg /change monitor-timeout-dc 30
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
Write-Host "Done."

# ------------------------------------------------------------
Step "6/11  Removing default Windows apps"
foreach ($p in $Remove) {
    Write-Host "Removing $p ..." -ForegroundColor Yellow
    # installed for existing users
    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    # provisioned (so it does not come back for new users)
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $p } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
}
# Quick Assist can also be a Windows capability
Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'App.Support.QuickAssist*' -and $_.State -eq 'Installed' } |
    Remove-WindowsCapability -Online -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------
Step "7/11  OneDrive: disable startup"
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in 'OneDrive','OneDriveSetup') { Remove-ItemProperty -Path $run -Name $n -ErrorAction SilentlyContinue }
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' 'OneDrive' ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) 'Binary'
Write-Host "Done."

# ------------------------------------------------------------
Step "8/11  Installing applications (winget)"
if (Get-Command winget -ErrorAction SilentlyContinue) {
    foreach ($id in $Apps) {
        Write-Host "Installing $id ..." -ForegroundColor Yellow
        winget install --id $id --exact --silent `
            --accept-package-agreements --accept-source-agreements
    }
} else {
    Write-Warning "winget not found. Update 'App Installer' from Microsoft Store and run again."
}

# ------------------------------------------------------------
Step "9/11  Browsers: Adblock Plus + no autostart (Chrome, Firefox, Edge)"

# --- Chrome: Adblock Plus + no background / startup boost
$chr = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
Set-Reg $chr 'BackgroundModeEnabled' 0
Set-Reg $chr 'StartupBoostEnabled'   0
$abpChrome = '{"cfhdojbkjhnklbpkdaibdccddilifddb":{"installation_mode":"normal_installed","update_url":"https://clients2.google.com/service/update2/crx"}}'
Set-Reg $chr 'ExtensionSettings' $abpChrome 'String'

# --- Edge: no startup boost / background mode
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-Reg $edge 'StartupBoostEnabled'   0
Set-Reg $edge 'BackgroundModeEnabled' 0

# --- Firefox: Adblock Plus via policies.json (needs Firefox already installed)
$ffDir = "$env:ProgramFiles\Mozilla Firefox"
if (Test-Path $ffDir) {
    New-Item "$ffDir\distribution" -ItemType Directory -Force | Out-Null
    $json = @'
{
  "policies": {
    "DisableDefaultBrowserAgent": true,
    "ExtensionSettings": {
      "{d10d0bf8-f5b5-c8b4-a8b2-2b9879e08c5d}": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/adblock-plus/latest.xpi"
      }
    }
  }
}
'@
    [System.IO.File]::WriteAllText("$ffDir\distribution\policies.json", $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Firefox policies.json written."
} else {
    Write-Warning "Firefox not found - Adblock Plus for Firefox was not configured."
}

# --- Remove any browser autostart entries
foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    if (Test-Path $rk) {
        (Get-Item $rk).Property |
            Where-Object { $_ -match 'MicrosoftEdgeAutoLaunch|GoogleChromeAutoLaunch|Firefox' } |
            ForEach-Object { Remove-ItemProperty -Path $rk -Name $_ -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------
Step "10/11  Default apps: Chrome (browser) + Acrobat Reader (.pdf)"
$xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".pdf"  ProgId="Acrobat.Document.DC" ApplicationName="Adobe Acrobat" />
  <Association Identifier="http"  ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".htm"  ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
</DefaultAssociations>
'@
$xmlPath = "$env:ProgramData\DefaultAssociations.xml"
[System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UTF8Encoding($false)))

# Applied at the next logon of the current user
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration' $xmlPath 'String'
# Also for any NEW user profile created later
dism /Online /Import-DefaultAppAssociations:"$xmlPath" | Out-Null

# One-time cleanup after the next logon, so the customer can change defaults later
$cmd = "Start-Sleep 120; " +
       "Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name DefaultAssociationsConfiguration -ErrorAction SilentlyContinue; " +
       "Remove-Item '$xmlPath' -Force -ErrorAction SilentlyContinue; " +
       "Unregister-ScheduledTask -TaskName 'CleanupDefaultApps' -Confirm:`$false"
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
$trg = New-ScheduledTaskTrigger -AtLogOn
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'CleanupDefaultApps' -Action $act -Trigger $trg -Principal $prn -Force | Out-Null
Write-Host "Defaults will be applied at the next sign-in."

# ------------------------------------------------------------
Step "11/11  Restarting Explorer to apply changes"
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }

Write-Host "`nAll done. RESTART the PC once so default apps and Start menu settings are applied." -ForegroundColor Green
