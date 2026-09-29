#!/usr/bin/env bash
# 1. Pulls the latest dockurr/windows image and recreates the container if it changed.
# 2. Runs Windows Update inside the VM (via PSWindowsUpdate in a SYSTEM scheduled task),
#    rebooting and repeating until no updates remain.
# Usage: ./update.sh [--vm <name>] [--image-only] [--windows-only] [--max-rounds N]
. "$(dirname "$0")/lib.sh"

DO_IMAGE=1; DO_WIN=1; MAX_ROUNDS=5
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --image-only)   DO_WIN=0 ;;
        --windows-only) DO_IMAGE=0 ;;
        --max-rounds)   shift; MAX_ROUNDS="$1" ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

require_vm
ensure_container_matches_vm
ensure_keys

# ---------- 1. container image ----------
if (( DO_IMAGE )); then
    before="$(docker image inspect -f '{{.Id}}' dockurr/windows 2>/dev/null || true)"
    log "Pulling latest dockurr/windows image ..."
    docker compose pull
    after="$(docker image inspect -f '{{.Id}}' dockurr/windows 2>/dev/null || true)"
    if [ "$before" != "$after" ]; then
        log "Image updated ($before -> $after)."
        if container_running; then
            log "Recreating container on the new image (graceful Windows shutdown first) ..."
            docker compose down
        fi
    else
        log "Image already up to date."
    fi
    docker image prune -f --filter "dangling=true" >/dev/null 2>&1 || true
fi

(( DO_WIN )) || exit 0

# ---------- 2. Windows Update ----------
if ! container_running; then
    log "Container not running - starting it ..."
    docker compose up -d
fi
log "Waiting for SSH ..."
wait_for_ssh 900 || die "SSH not reachable; is Windows installed? Try ./start-with-openssh.sh"

REMOTE_DIR='C:/WinTestEnv'
run_round() {
    wssh "New-Item -ItemType Directory -Force -Path '$REMOTE_DIR' | Out-Null; Remove-Item '$REMOTE_DIR/wu-status.json','$REMOTE_DIR/wu.log' -Force -ErrorAction SilentlyContinue"
    wscp oem/wu-task.ps1 "win:$REMOTE_DIR/wu-task.ps1"
    # Register (or replace) a scheduled task running as SYSTEM and kick it off now.
    wssh "\$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\\WinTestEnv\\wu-task.ps1'; \$p = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest; \$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Register-ScheduledTask -TaskName 'WinTestEnvUpdate' -Action \$a -Principal \$p -Settings \$s -Force | Out-Null; Start-ScheduledTask -TaskName 'WinTestEnvUpdate'"

    # Poll the status file, echoing new log lines as they appear.
    local lines=0 start=$SECONDS status=""
    while :; do
        sleep 20
        local out
        out="$(wssh "if (Test-Path '$REMOTE_DIR/wu.log') { Get-Content '$REMOTE_DIR/wu.log' }" 2>/dev/null || true)"
        local total; total="$(printf '%s\n' "$out" | grep -c . || true)"
        if (( total > lines )); then
            printf '%s\n' "$out" | tail -n +"$((lines + 1))" | sed 's/^/    | /' >&2   # stdout is captured by the caller
            lines=$total
        fi
        status="$(wssh "if (Test-Path '$REMOTE_DIR/wu-status.json') { Get-Content '$REMOTE_DIR/wu-status.json' -Raw }" 2>/dev/null || true)"
        [ -n "$status" ] && break
        if (( SECONDS - start > 4*3600 )); then die "Windows Update round timed out after 4h"; fi
        # If SSH drops mid-task, Windows rebooted on its own; wait for it and re-kick the task if it died.
        if ! ssh_up; then
            warn "SSH dropped - waiting for VM to come back"
            wait_for_ssh 1800 || die "VM did not return"
            state="$(wssh "(Get-ScheduledTask -TaskName 'WinTestEnvUpdate' -ErrorAction SilentlyContinue).State" 2>/dev/null || true)"
            has_status="$(wssh "Test-Path '$REMOTE_DIR/wu-status.json'" 2>/dev/null || true)"
            if [ "$state" != "Running" ] && [ "$has_status" != "True" ]; then
                warn "Update task did not survive the reboot - starting it again"
                wssh "Start-ScheduledTask -TaskName 'WinTestEnvUpdate'" || true
                lines=0
            fi
        fi
    done
    printf '%s\n' "$status"
}

json_field() { # json_field <json> <field>
    printf '%s' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p" | tr -d '" '
}

for (( round = 1; round <= MAX_ROUNDS; round++ )); do
    log "Windows Update round $round/$MAX_ROUNDS"
    status="$(run_round)"
    installed="$(json_field "$status" installed)"
    failed="$(json_field "$status" failed)"
    reboot="$(json_field "$status" rebootRequired)"
    err="$(json_field "$status" error)"
    [ -n "$err" ] && warn "Update task reported: $err"
    log "Round $round result: installed=${installed:-0} failed=${failed:-0} rebootRequired=${reboot:-false}"

    if [ "$reboot" = "true" ]; then
        log "Rebooting Windows (finishing the update install can take a while before it actually restarts) ..."
        boot_before="$(wssh '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' 2>/dev/null || true)"
        wssh 'Restart-Computer -Force' || true
        # Wait until SSH answers from a *new* boot (boot time changed), not just until it answers.
        start=$SECONDS
        while :; do
            if ssh_up; then
                boot_now="$(wssh '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' 2>/dev/null || true)"
                [ -n "$boot_now" ] && [ "$boot_now" != "$boot_before" ] && break
            fi
            (( SECONDS - start > 2400 )) && die "VM did not come back from reboot within 40 minutes"
            container_running || die "Container stopped during reboot"
            sleep 15
        done
        log "VM is back (rebooted)."
        continue
    fi
    if [ "${failed:-0}" != "0" ]; then
        warn "$failed update(s) failed this round (details: C:\\WinTestEnv\\wu-install.log inside the VM). Retrying."
        continue
    fi
    if [ "${installed:-0}" = "0" ]; then
        log "No more updates available. Windows is up to date."
        break
    fi
done

log "Windows version:"
# ProductName still says "Windows 10" on Windows 11 (known registry quirk), so derive the name from the build.
wssh '$v = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; $n = $v.ProductName; if ([int]$v.CurrentBuild -ge 22000 -and $n -like "Windows 10*") { $n = $n -replace "Windows 10", "Windows 11" }; "$n $($v.DisplayVersion) build $($v.CurrentBuild).$($v.UBR)"' || true
log "Update finished."
