# Runs INSIDE the VM as SYSTEM via a scheduled task (Windows Update refuses install
# requests from non-interactive / network logons such as SSH sessions).
# Writes progress to C:\WinTestEnv\wu.log and a final JSON status to C:\WinTestEnv\wu-status.json.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$dir    = 'C:\WinTestEnv'
$log    = "$dir\wu.log"
$status = "$dir\wu-status.json"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item $status -Force -ErrorAction SilentlyContinue
function Log($m) { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m" | Out-File $log -Append -Encoding utf8 }

$result = @{ finished = $false; installed = 0; failed = 0; rebootRequired = $false; error = '' }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        Log 'Installing PSWindowsUpdate module ...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
    }
    Import-Module PSWindowsUpdate
    Log 'Scanning for updates ...'
    $avail = @(Get-WindowsUpdate -IgnoreReboot -ErrorAction Stop)
    $titles = @($avail | ForEach-Object { $_.Title })
    Log "Found $($titles.Count) update(s): $($titles -join '; ')"
    if ($titles.Count -gt 0) {
        Log 'Downloading and installing (this can take a long time) ...'
        $res = Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false -ErrorAction Continue -Verbose 4>&1 |
               Tee-Object -FilePath "$dir\wu-install.log" -Append
        # PSWindowsUpdate emits the *same* object once per stage (Accepted, Downloaded, Installed/Failed) and
        # mutates its Result, so de-duplicate by title before counting.
        $items = @($res | Where-Object { $_.PSObject.Properties['Result'] } | Sort-Object -Property Title -Unique)
        $result.installed = @($items | Where-Object { $_.Result -eq 'Installed' }).Count
        $result.failed    = @($items | Where-Object { $_.Result -eq 'Failed' }).Count
        Log "Install pass done: installed=$($result.installed) failed=$($result.failed)"
    }
    $result.rebootRequired = [bool](Get-WURebootStatus -Silent)
    Log "Reboot required: $($result.rebootRequired)"
} catch {
    $result.error = "$_"
    Log "ERROR: $_"
}
$result.finished = $true
$result | ConvertTo-Json -Compress | Out-File $status -Encoding ascii
Log 'Task finished.'
