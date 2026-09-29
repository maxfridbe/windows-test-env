# Installs and configures the OpenSSH server inside the Windows VM.
# Runs elevated, once, from C:\OEM\install.bat at the end of the unattended install.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Start-Transcript -Path 'C:\OEM\setup-ssh.log' -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }

# --- 1. Install OpenSSH Server (Feature-on-Demand first, GitHub MSI as fallback) ---
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Log 'Trying Add-WindowsCapability OpenSSH.Server (10 minute limit, Windows Update can be slow) ...'
    try {
        $cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            $job = Start-Job -ScriptBlock { param($n) Add-WindowsCapability -Online -Name $n | Out-Null } -ArgumentList $cap.Name
            if (-not (Wait-Job $job -Timeout 600)) {
                Log 'Add-WindowsCapability timed out - stopping it and falling back to the MSI'
                Stop-Job $job -ErrorAction SilentlyContinue
            } else { Receive-Job $job -ErrorAction SilentlyContinue | Out-Null }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    } catch { Log "Add-WindowsCapability failed: $_" }
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
}
if (-not $svc) {
    Log 'Falling back to Win32-OpenSSH MSI from GitHub ...'
    try {
        $rel   = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -Headers @{ 'User-Agent' = 'windows-test-env' }
        $asset = $rel.assets | Where-Object name -like 'OpenSSH-Win64*.msi' | Select-Object -First 1
        $msi   = 'C:\OEM\OpenSSH-Win64.msi'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart ADDLOCAL=Server,Client" -Wait
    } catch { Log "MSI install failed: $_" }
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
}
if (-not $svc) { Log 'ERROR: sshd service not present after install attempts.'; Stop-Transcript; exit 1 }

# --- 2. Service: automatic start, start now (first start generates host keys + sshd_config) ---
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue

# --- 3. Default shell for SSH sessions = PowerShell ---
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# --- 4. Firewall ---
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
} else {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
}

# --- 5. Authorized keys (host-generated key from ./oem/authorized_keys) ---
$sshDir = 'C:\ProgramData\ssh'
$cfg    = Join-Path $sshDir 'sshd_config'
if (Test-Path 'C:\OEM\authorized_keys') {
    $adminKeys = Join-Path $sshDir 'administrators_authorized_keys'
    Copy-Item 'C:\OEM\authorized_keys' $adminKeys -Force
    # Required ACL: only Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18), no inheritance.
    icacls $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    # Also drop into the user's profile for non-admin fallback.
    $userSsh = Join-Path $env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Force -Path $userSsh | Out-Null
    Copy-Item 'C:\OEM\authorized_keys' (Join-Path $userSsh 'authorized_keys') -Force
    Log 'Installed authorized_keys'
}

# --- 6. sshd_config: make sure password + pubkey auth are on ---
if (Test-Path $cfg) {
    $c = Get-Content $cfg
    $c = $c -replace '^#?\s*PasswordAuthentication\s+.*', 'PasswordAuthentication yes'
    $c = $c -replace '^#?\s*PubkeyAuthentication\s+.*',   'PubkeyAuthentication yes'
    Set-Content $cfg $c -Encoding ASCII
}
Restart-Service sshd

# --- 7. Keep the VM awake ---
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null
powercfg /hibernate off | Out-Null

# --- 8. Best-effort: preinstall PSWindowsUpdate for update.sh (also done lazily later) ---
try {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
    Log 'PSWindowsUpdate installed'
} catch { Log "PSWindowsUpdate preinstall skipped: $_" }

New-Item -ItemType Directory -Force -Path 'C:\WinTestEnv' | Out-Null
Log "OpenSSH setup complete. sshd status: $((Get-Service sshd).Status)"
Stop-Transcript | Out-Null
