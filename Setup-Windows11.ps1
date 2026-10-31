#Requires -RunAsAdministrator
# ============================================================
#  Windows 11 - standard post-format setup
#  Run through Run-Setup.bat (as Administrator), while logged in
#  as the user account that will be used by the customer.
# ============================================================

$ErrorActionPreference = 'Continue'
try { Start-Transcript -Path "$env:ProgramData\Setup-Windows11.log" -Append | Out-Null } catch {}   # log of everything the script did
$ProgressPreference    = 'SilentlyContinue'     # much faster downloads in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Failed = @()

# ---- Options ----
$FirefoxLang     = 'en-US'     # e.g. 'el' for Greek Firefox
$AnyDeskAutoStart = $false     # $true = AnyDesk starts with Windows
$AutoDefaults     = $true      # set Chrome + Acrobat as defaults automatically (SetUserFTA, see step 10)
$VerifyChromeAbp  = $true      # start Chrome at the end, check Adblock Plus got installed, else open its store page
$InstallUpdates   = $true      # enable Microsoft Update + install all updates incl. optional/drivers
$RestartAtEnd     = $true      # restart the PC (after a 60 sec countdown) when everything is done

# ---- Apps to REMOVE (wildcards allowed) ----
$Remove = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather',
    'Microsoft.Copilot', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.MicrosoftSolitaireCollection',
    'MSTeams', 'MicrosoftTeams',
    'Microsoft.YourPhone', '*MicrosoftFamily*', '*QuickAssist*',
    'Clipchamp.Clipchamp', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps', 'Microsoft.People', 'Microsoft.MicrosoftStickyNotes',
    'Microsoft.Todos', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsSoundRecorder',
    'Microsoft.PowerAutomateDesktop',
    # Camera, Snipping Tool (note: Win+Shift+S stops working without it)
    'Microsoft.WindowsCamera', 'Microsoft.ScreenSketch',
    # Bing, Start Experiences, Web Media Extensions
    'Microsoft.BingSearch', 'Microsoft.Bing', 'Microsoft.StartExperiencesApp', 'Microsoft.WebMediaExtensions',
    # Promo / third-party apps
    '*Spotify*', '*Disney*', '*PrimeVideo*', '*Netflix*', '*Instagram*', '*Facebook*',
    '*TikTok*', '*LinkedIn*', '*WhatsApp*', '*Dropbox*',
    '*CandyCrush*', '*Twitter*', '*Hulu*', '*Duolingo*', '*Pinterest*'
)

# ---- Helpers ----
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Download-File($Url, $Dest) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop `
            -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        return (Test-Path $Dest)
    } catch {
        Write-Warning "Download failed: $Url"
        return $false
    }
}

# winget first (silent, winget source only); if it fails -> direct vendor download
function Install-App($Name, $WingetId, [scriptblock]$Fallback) {
    Write-Host "Installing $Name ..." -ForegroundColor Yellow
    $ok = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id $WingetId --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements
        # 0 = ok, -1978335135 = already installed, -1978335189 = nothing to upgrade
        $ok = (@(0, -1978335135, -1978335189) -contains $LASTEXITCODE)
    }
    if (-not $ok -and $Fallback) {
        Write-Host "winget failed for $Name -> trying direct download ..." -ForegroundColor Yellow
        $ok = [bool](& $Fallback)
    }
    if (-not $ok) { $script:Failed += $Name; Write-Warning "$Name FAILED to install." }
}

function Find-Lnk($Name) {
    $roots = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
               "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
    foreach ($r in $roots) {
        $f = Get-ChildItem -Path $r -Filter $Name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Remove-DesktopLnk($Pattern) {
    $dirs = @([Environment]::GetFolderPath('Desktop'),
              [Environment]::GetFolderPath('CommonDesktopDirectory'),
              "$env:PUBLIC\Desktop") | Select-Object -Unique
    foreach ($d in $dirs) {
        Get-ChildItem -Path $d -Filter $Pattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Start-Unelevated($Exe, $Arguments) {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $a  = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments
    $pr = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'TmpUnelevatedLaunch' -Action $a -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName 'TmpUnelevatedLaunch'
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName 'TmpUnelevatedLaunch' -Confirm:$false -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
Step "1/12  System Restore: disable + delete restore points"
try { Disable-ComputerRestore -Drive "$env:SystemDrive\" } catch { Write-Warning $_.Exception.Message }
vssadmin delete shadows /for=$env:SystemDrive /all /quiet 2>&1 | Out-Null
Write-Host "Done."

# ------------------------------------------------------------
Step "2/12  Taskbar: left, hide Widgets/Task View, turn off Resume"
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Reg $adv 'TaskbarAl' 0              # align left
Set-Reg $adv 'ShowTaskViewButton' 0     # hide Task View button
# hide Widgets button (per-user toggle, user can switch it back on in Settings > Taskbar)
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue   # old policy from earlier script versions
New-ItemProperty -Path $adv -Name 'TaskbarDa' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
if ((Get-ItemProperty -Path $adv -Name 'TaskbarDa' -ErrorAction SilentlyContinue).TaskbarDa -ne 0) {
    Write-Warning "Windows blocks turning the Widgets button off per-user on this build -> using policy (user cannot re-enable it from Settings)."
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
}
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsResumeAllowed' 0   # Resume off

# ------------------------------------------------------------
Step "3/12  Desktop icons: This PC, User folder, Recycle Bin (sorted by name)"
$hide = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
Set-Reg $hide '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0   # This PC
Set-Reg $hide '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 0   # User's Files
Set-Reg $hide '{645FF040-5081-101B-9F08-00AA002F954E}' 0   # Recycle Bin

$sortName = [byte[]](0,0,0,0,0,0,0,0,1,0,0,0,
                     0x30,0xF1,0x25,0xB7,0xEF,0x47,0x1A,0x10,0xA5,0xF1,0x02,0x60,0x8C,0x9E,0xEB,0xAC,
                     0x0A,0,0,0, 1,0,0,0)
Set-Reg 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop' 'Sort' $sortName 'Binary'

# ------------------------------------------------------------
Step "4/12  Start menu: folders, pinned apps, List view, recent items off"
$startKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'
$startPol = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
$expPol   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'

# 4a. Folders next to the Power button (per-user VisiblePlaces): Settings + File Explorer only
$places = @(
  @(0x86,0x08,0x73,0x52,0xAA,0x51,0x43,0x42,0x9F,0x7B,0x27,0x76,0x58,0x46,0x59,0xD4),   # Settings
  @(0xBC,0x24,0x8A,0x14,0x0C,0xD6,0x89,0x42,0xA0,0x80,0x6E,0xD9,0xBB,0xA2,0x48,0x82)    # File Explorer
)
Set-Reg $startKey 'VisiblePlaces' ([byte[]]($places[0] + $places[1])) 'Binary'
# remove the old per-folder policies if an earlier version of this script set them
foreach ($n in 'FileExplorer','Settings','Documents','Downloads','Music','Network','Personalfolder','Pictures','Videos') {
    Remove-ItemProperty -Path $startPol -Name "AllowPinnedFolder$n" -ErrorAction SilentlyContinue
}

# 4b. Pinned section: only Control Panel
$lnkDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $lnkDir 'Control Panel.lnk'))
$sc.TargetPath = "$env:SystemRoot\System32\control.exe"
$sc.Save()

$startPinsJson = '{"pinnedList":[{"desktopAppLink":"%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Control Panel.lnk"}]}'
# policy (24H2+ ADMX location)
Set-Reg $expPol 'ConfigureStartPinsJSON' 1
Set-Reg $expPol 'ConfigureStartPins' $startPinsJson 'String'
# policy (CSP location, 22H2/23H2)
Set-Reg $startPol 'ConfigureStartPins' $startPinsJson 'String'
Set-Reg $startPol 'ConfigureStartPins_ProviderSet' 1
Set-Reg $startPol 'ConfigureStartPins_WinningProvider' 'B5292708-1619-419B-9923-E5D9F3925E71' 'String'

# (existing Start pins are reset in the last step, together with the Explorer restart)
$lsDir = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"

# 4c. "All apps" view -> List  (0 = Category, 1 = Grid, 2 = List)
Set-Reg $startKey 'AllAppsViewMode' 2

# 4d. Layout options: recent / most used / recommendations OFF
Set-Reg $adv 'Start_TrackDocs' 0               # recently opened items (Start, Jump Lists, File Explorer)
Set-Reg $adv 'Start_TrackProgs' 0              # most used apps
Set-Reg $adv 'Start_IrisRecommendations' 0     # tips / shortcuts / new apps recommendations
Set-Reg $adv 'Start_AccountNotifications' 0
# remove the HideRecentlyAddedApps policy if an earlier script version set it (it locks the toggle)
Remove-ItemProperty -Path $expPol -Name 'HideRecentlyAddedApps' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'HideRecentlyAddedApps' -ErrorAction SilentlyContinue
Set-Reg $startKey 'ShowRecentList' 0           # Settings > Start: "Show recently added apps"
Set-Reg $startKey 'ShowFrequentList' 0         # Settings > Start: "Show most used apps"
# clear the existing recent-files / jump-list history of this user
Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0     # Quick access: recent files
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0   # Quick access: frequent folders

# ------------------------------------------------------------
Step "5/12  Power plan: High performance, screen never off, sleep never, hard disk never"
$hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'     # High performance
powercfg /setactive $hp 2>$null
if ($LASTEXITCODE -ne 0) {
    # plan is hidden on some PCs (Modern Standby) -> create it first
    $out = powercfg /duplicatescheme $hp
    if ($out -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { powercfg /setactive $Matches[1] }
}
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
Write-Host "Done."

# ------------------------------------------------------------
Step "6/12  Removing default Windows apps"
foreach ($p in $Remove) {
    Write-Host "Removing $p ..." -ForegroundColor Yellow
    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $p } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
}
Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'App.Support.QuickAssist*' -and $_.State -eq 'Installed' } |
    Remove-WindowsCapability -Online -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------
Step "7/12  OneDrive: disable startup"
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in 'OneDrive','OneDriveSetup') { Remove-ItemProperty -Path $run -Name $n -ErrorAction SilentlyContinue }
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' 'OneDrive' ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) 'Binary'
Write-Host "Done."

# ------------------------------------------------------------
Step "8/12  Installing applications (winget, with direct-download fallback)"
if (Get-Command winget -ErrorAction SilentlyContinue) { winget source update 2>&1 | Out-Null }

# Firefox
$ffId = if ($FirefoxLang -eq 'en-US') { 'Mozilla.Firefox' } else { "Mozilla.Firefox.$FirefoxLang" }
Install-App 'Firefox' $ffId {
    $f = Join-Path $env:TEMP 'FirefoxSetup.exe'
    if (-not (Download-File "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=$FirefoxLang" $f)) { return $false }
    Start-Process -FilePath $f -ArgumentList '/S' -Wait
    return (Test-Path "$env:ProgramFiles\Mozilla Firefox\firefox.exe")
}

# Chrome (winget often fails with "installer hash does not match" because Google
# replaces the file behind the same URL -> fallback = Google's own MSI)
Install-App 'Google Chrome' 'Google.Chrome' {
    $f = Join-Path $env:TEMP 'googlechromestandaloneenterprise64.msi'
    if (-not (Download-File 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' $f)) { return $false }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$f`" /qn /norestart" -Wait -PassThru
    return ((@(0, 3010) -contains $p.ExitCode) -and (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"))
}

# K-Lite
Install-App 'K-Lite Codec Pack' 'CodecGuide.K-LiteCodecPack.Standard' $null

# AnyDesk (same hash problem -> fallback = official AnyDesk.exe silent install)
Install-App 'AnyDesk' 'AnyDeskSoftwareGmbH.AnyDesk' {
    $f   = Join-Path $env:TEMP 'AnyDesk.exe'
    $dir = "${env:ProgramFiles(x86)}\AnyDesk"
    if (-not (Download-File 'https://download.anydesk.com/AnyDesk.exe' $f)) { return $false }
    $a = @('--install', "`"$dir`"", '--create-shortcuts', '--silent')
    if ($AnyDeskAutoStart) { $a += '--start-with-win' }
    Start-Process -FilePath $f -ArgumentList $a -Wait
    Start-Sleep -Seconds 5
    return (Test-Path "$dir\AnyDesk.exe")
}

# Adobe Acrobat Reader
Install-App 'Adobe Acrobat Reader' 'Adobe.Acrobat.Reader.64-bit' $null
Remove-DesktopLnk '*Acrobat*.lnk'
Remove-DesktopLnk '*Adobe*.lnk'

# ------------------------------------------------------------
Step "9/12  Browsers: Adblock Plus + no autostart (Chrome, Firefox, Edge)"

# --- Chrome: Adblock Plus (user can still disable it) + background mode / startup boost OFF
#     Written as "Recommended" policies: default is OFF, but the user can switch them on again in Chrome settings.
$chr = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
foreach ($n in 'BackgroundModeEnabled','StartupBoostEnabled') {       # old mandatory values from earlier versions
    Remove-ItemProperty -Path $chr -Name $n -ErrorAction SilentlyContinue
}
Remove-Item -Path "$chr\ExtensionInstallForcelist" -Recurse -Force -ErrorAction SilentlyContinue
Set-Reg "$chr\Recommended" 'BackgroundModeEnabled' 0
Set-Reg "$chr\Recommended" 'StartupBoostEnabled'   0
$abpChrome = '{"cfhdojbkjhnklbpkdaibdccddilifddb":{"installation_mode":"normal_installed","update_url":"https://clients2.google.com/service/update2/crx"}}'
Set-Reg $chr 'ExtensionSettings' $abpChrome 'String'

# --- Edge: startup boost / background mode OFF (recommended = user can change it)
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
foreach ($n in 'BackgroundModeEnabled','StartupBoostEnabled') {
    Remove-ItemProperty -Path $edge -Name $n -ErrorAction SilentlyContinue
}
Set-Reg "$edge\Recommended" 'BackgroundModeEnabled' 0
Set-Reg "$edge\Recommended" 'StartupBoostEnabled'   0

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
Step "10/12  Taskbar pins (File Explorer, Firefox, Chrome) + default apps (Chrome, Acrobat)"

# --- Taskbar pins: replaces the default pins (Edge / Store are unpinned)
$tbPins = @('<taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />')   # File Explorer (by AppID, no .lnk needed)
foreach ($n in 'Firefox.lnk','Google Chrome.lnk') {
    $p = Find-Lnk $n
    if ($p) { $tbPins += "<taskbar:DesktopApp DesktopApplicationLinkPath=`"$p`" />" }
    else    { Write-Warning "$n not found - it will not be pinned to the taskbar." }
}
$tb = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        $($tbPins -join "`n        ")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
$tbXml = "$env:ProgramData\TaskbarLayout.xml"
[System.IO.File]::WriteAllText($tbXml, $tb, (New-Object System.Text.UTF8Encoding($false)))
# per-user layout policy: switched on now, removed again after Explorer rebuilds the taskbar (last step)
$userExpPol = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
Set-Reg $userExpPol 'StartLayoutFile' $tbXml 'ExpandString'
Set-Reg $userExpPol 'LockedStartLayout' 1
Remove-Item "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\*" -Force -ErrorAction SilentlyContinue

# --- Default apps
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
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration' $xmlPath 'String'
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
Write-Host "Default-app policy written (works for new profiles; see the manual step at the end)."

# --- Automatic defaults: Chrome (http/https/htm/html) + Acrobat Reader (.pdf)
# Windows 11 protects these associations (UCPD driver), so scripts are blocked. The documented
# workaround is used: UCPD is switched off until the next sign-in, SetUserFTA (kolbi.cz) sets the
# defaults, then UCPD is switched back on automatically.
if ($AutoDefaults) {
    $ftaDir = "$env:ProgramData\SetUserFTA"
    New-Item $ftaDir -ItemType Directory -Force | Out-Null
    $applyCmd = $null     # PowerShell snippet that sets the defaults

    # source 1: SetUserFTA (kolbi.cz)
    $zip = Join-Path $env:TEMP 'SetUserFTA.zip'
    if (Download-File 'https://kolbi.cz/SetUserFTA.zip' $zip) {
        Expand-Archive -Path $zip -DestinationPath $ftaDir -Force
        $f = Get-ChildItem -Path $ftaDir -Filter 'SetUserFTA.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) {
            $cfg = "$ftaDir\config.txt"
            @('http, ChromeHTML', 'https, ChromeHTML', '.htm, ChromeHTML', '.html, ChromeHTML', '.pdf, Acrobat.Document.DC') |
                Set-Content -Path $cfg -Encoding ASCII
            $applyCmd = "& '$($f.FullName)' '$cfg'"
        }
    }
    # source 2: PS-SFTA (PowerShell script, GitHub)
    if (-not $applyCmd) {
        $sfta = "$ftaDir\SFTA.ps1"
        if (Download-File 'https://raw.githubusercontent.com/DanysysTeam/PS-SFTA/master/SFTA.ps1' $sfta) {
            $applyCmd = ". '$sfta'; Set-FTA 'Acrobat.Document.DC' '.pdf'; Set-FTA 'ChromeHTML' '.html'; " +
                        "Set-FTA 'ChromeHTML' '.htm'; Set-PTA 'ChromeHTML' 'http'; Set-PTA 'ChromeHTML' 'https'"
        }
    }

    if ($applyCmd) {
        $ucpdKey     = 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD'
        $ucpdRunning = [bool]((sc.exe query UCPD 2>&1) -match 'RUNNING')
        if (-not $ucpdRunning) {
            # protection driver not loaded -> set defaults right now
            Invoke-Expression $applyCmd
            Remove-Item $ftaDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Default apps set (Chrome, Acrobat Reader)."
        } else {
            $ucpdStart = (Get-ItemProperty -Path $ucpdKey -ErrorAction SilentlyContinue).Start
            if ($null -eq $ucpdStart -or $ucpdStart -eq 4) { $ucpdStart = 1 }
            Set-ItemProperty -Path $ucpdKey -Name Start -Value 4
            schtasks.exe /Change /Disable /TN "\Microsoft\Windows\AppxDeploymentClient\UCPD velocity" 2>&1 | Out-Null
            $me   = "$env:USERDOMAIN\$env:USERNAME"
            $cmd2 = "Start-Sleep 30; $applyCmd; " +
                    "Set-ItemProperty -Path '$ucpdKey' -Name Start -Value $ucpdStart; " +
                    "schtasks.exe /Change /Enable /TN '\Microsoft\Windows\AppxDeploymentClient\UCPD velocity'; " +
                    "Remove-Item '$ftaDir' -Recurse -Force -ErrorAction SilentlyContinue; " +
                    "Unregister-ScheduledTask -TaskName 'SetDefaultApps' -Confirm:`$false"
            $act2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd2`""
            $trg2 = New-ScheduledTaskTrigger -AtLogOn -User $me
            $prn2 = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName 'SetDefaultApps' -Action $act2 -Trigger $trg2 -Principal $prn2 -Force | Out-Null
            Write-Host "Chrome + Acrobat will be set as defaults ~30 sec after the next sign-in (after restart)."
        }
    } else {
        Write-Warning "Could not download SetUserFTA / PS-SFTA (check internet) - default apps were NOT set."
        $Failed += 'Default apps (Chrome/Acrobat)'
    }
}

# ------------------------------------------------------------
Step "11/12  Rebuilding taskbar + Start, restarting Explorer"
Remove-DesktopLnk '*Acrobat*.lnk'
Remove-DesktopLnk '*Adobe*.lnk'

Stop-Process -Name StartMenuExperienceHost, ShellExperienceHost -Force -ErrorAction SilentlyContinue
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# reset Start pins (or use a start2.bin template placed next to this script) and the taskbar pin cache
$bin = Join-Path $PSScriptRoot 'start2.bin'
if (Test-Path $bin) {
    Copy-Item $bin (Join-Path $lsDir 'start2.bin') -Force
    Write-Host "start2.bin template copied."
} else {
    Remove-Item (Join-Path $lsDir 'start.bin'), (Join-Path $lsDir 'start2.bin') -Force -ErrorAction SilentlyContinue
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Recurse -Force -ErrorAction SilentlyContinue

$t = 0
while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and $t -lt 15) { Start-Sleep -Seconds 1; $t++ }
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Start-Sleep -Seconds 15      # let Explorer build the taskbar from the layout file

# unlock: remove the temporary layout policy so the customer can pin/unpin freely
Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name StartLayoutFile,LockedStartLayout -ErrorAction SilentlyContinue
Remove-Item $tbXml -Force -ErrorAction SilentlyContinue


# --- Chrome: verify Adblock Plus (policy install needs Chrome to start once)
if ($VerifyChromeAbp) {
    $abpId = 'cfhdojbkjhnklbpkdaibdccddilifddb'
    $chromeExe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") |
                 Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($chromeExe) {
        Write-Host "`nStarting Chrome so Adblock Plus can install (waiting up to 90 sec) ..." -ForegroundColor Cyan
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinApi { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); }
'@
        Start-Unelevated $chromeExe '--no-first-run --no-default-browser-check'
        $extDir = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions\$abpId"
        $w = 0
        while (-not (Test-Path $extDir) -and $w -lt 90) {
            # keep every Chrome window minimized while waiting
            Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } |
                ForEach-Object { [WinApi]::ShowWindow($_.MainWindowHandle, 6) | Out-Null }
            Start-Sleep -Seconds 3; $w += 3
        }
        if (Test-Path $extDir) {
            Write-Host "Adblock Plus is installed in Chrome." -ForegroundColor Green
            # let Chrome finish writing the extension, then close it gracefully
            Start-Sleep -Seconds 10
            Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } |
                ForEach-Object { $_.CloseMainWindow() | Out-Null }
            Start-Sleep -Seconds 8
            Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Adblock Plus was not installed by policy. Opening its Chrome Web Store page - click 'Add to Chrome'."
            Start-Unelevated $chromeExe "https://chromewebstore.google.com/detail/$abpId"
        }
    }
}

# ------------------------------------------------------------
Step "12/12  Windows Update: Microsoft Update + optional updates"
if ($InstallUpdates) {
    # Settings > Windows Update > Advanced options > "Receive updates for other Microsoft products" = ON
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'AllowMUUpdateService' 1
    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $sm.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '') | Out-Null
        Write-Host "Microsoft Update enabled."
    } catch { Write-Warning "Could not enable Microsoft Update: $($_.Exception.Message)" }

    Start-Service wuauserv -ErrorAction SilentlyContinue
    $upgradesCat = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'     # skip whole-OS upgrades
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        for ($pass = 1; $pass -le 3; $pass++) {
            Write-Host "Searching for updates (pass $pass) ..." -ForegroundColor Yellow
            $searcher = $session.CreateUpdateSearcher()
            $searcher.ServerSelection = 3                                  # Microsoft Update
            $searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($type in 'Software', 'Driver') {
                $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='$type'")
                foreach ($u in $res.Updates) {
                    $isUpgrade = @($u.Categories | Where-Object { $_.CategoryID -eq $upgradesCat }).Count -gt 0
                    if ($isUpgrade -or $u.InstallationBehavior.CanRequestUserInput) { continue }
                    $dup = $false
                    foreach ($c in $coll) { if ($c.Identity.UpdateID -eq $u.Identity.UpdateID) { $dup = $true } }
                    if ($dup) { continue }
                    if (-not $u.EulaAccepted) { $u.AcceptEula() }
                    $coll.Add($u) | Out-Null
                    Write-Host "  + $($u.Title)"
                }
            }
            if ($coll.Count -eq 0) { Write-Host "No more updates."; break }

            Write-Host "Downloading $($coll.Count) update(s) ..." -ForegroundColor Yellow
            $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
            $dl.Download() | Out-Null
            $ready = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $coll) { if ($u.IsDownloaded) { $ready.Add($u) | Out-Null } }
            if ($ready.Count -eq 0) { Write-Warning "Nothing could be downloaded."; break }

            Write-Host "Installing $($ready.Count) update(s) - this can take a while ..." -ForegroundColor Yellow
            $inst = $session.CreateUpdateInstaller(); $inst.Updates = $ready
            $r = $inst.Install()
            Write-Host "Result code: $($r.ResultCode)  Reboot required: $($r.RebootRequired)"
            if ($r.RebootRequired) { break }       # remaining updates (if any) need the reboot first
        }
    } catch {
        Write-Warning "Windows Update step failed: $($_.Exception.Message)"
        $Failed += 'Windows Update'
    }
}

if ($Failed.Count -gt 0) {
    Write-Host "`nFAILED: $($Failed -join ', ')  (check internet / install manually)" -ForegroundColor Red
}

Write-Host "`nAll done." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
if ($RestartAtEnd) {
    Write-Host "Restarting in 60 seconds - Chrome + Acrobat defaults are applied ~30 sec after the next sign-in. (To cancel: shutdown /a)" -ForegroundColor Green
    shutdown.exe /r /t 60 /c "Setup finished - restarting to apply updates and settings"
} else {
    Write-Host "RESTART the PC once and sign in again so everything is applied." -ForegroundColor Green
}
