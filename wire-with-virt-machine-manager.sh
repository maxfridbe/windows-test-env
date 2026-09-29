#!/usr/bin/env bash
# Opens the VM's console in virt-viewer / remote-viewer (the viewer that ships with
# Virtual Machine Manager), or prints how to connect from elsewhere.
#
# Note: virt-manager itself only lists libvirt-managed domains, and this VM is a plain QEMU
# process inside a Docker container, so it cannot appear in virt-manager's VM list. Its VNC
# display is exposed instead, which remote-viewer / virt-viewer (and any VNC client) can open.
#
# Usage: ./wire-with-virt-machine-manager.sh [--vm <name>] [--restart] [--print]
#   --restart   if the running container was started without the VNC port, restart it now
#   --print     don't launch a viewer, just print the connection details
. "$(dirname "$0")/lib.sh"

RESTART=0; PRINT=0
for a in "${ARGS[@]}"; do
    case "$a" in
        --restart) RESTART=1 ;;
        --print) PRINT=1 ;;
        *) die "Unknown option: $a" ;;
    esac
done
VNC_PORT="${VNC_PORT:-5900}"
VNC_BIND="${VNC_BIND:-127.0.0.1}"

container_running || die "VM is not running. Start it with ./start-with-openssh.sh"
running_vm="$(container_vm)"; vm_exists "$running_vm" && set_vm "$running_vm" || true

# Is 5900 published on the host for this container?
mapped="$(docker port "$CONTAINER" 5900/tcp 2>/dev/null | head -1 || true)"
if [ -z "$mapped" ]; then
    warn "The running container was started without the VNC port mapping."
    if (( RESTART )); then
        [ -n "${VM_NAME:-}" ] || die "Cannot restart: running container is not tied to a known VM."
        log "Restarting VM '$VM_NAME' (graceful shutdown) to add the VNC port ..."
        "$ROOT/stop.sh"
        "$ROOT/start-with-openssh.sh" --vm "$VM_NAME"
        mapped="$(docker port "$CONTAINER" 5900/tcp 2>/dev/null | head -1 || true)"
        [ -n "$mapped" ] || die "VNC port still not mapped after restart."
    else
        die "Re-run with --restart (graceful shutdown + start), or ./stop.sh && ./start-with-openssh.sh. Don't do this mid-install."
    fi
fi
host_ip="${mapped%%:*}"; host_port="${mapped##*:}"
[ "$host_ip" = "0.0.0.0" ] && conn_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || conn_host="127.0.0.1"
URL="vnc://127.0.0.1:$host_port"

# A .vv file that remote-viewer (and virt-manager's viewer) can open directly.
VV="$WTE_HOME/${VM_NAME:-vm}.vv"
cat > "$VV" <<VV
[virt-viewer]
type=vnc
host=127.0.0.1
port=$host_port
title=windows-test-env ${VM_NAME:-}
delete-this-file=0
VV

cat <<INFO

  VM '${VM_NAME:-?}' console (QEMU VNC, no password, one viewer at a time - close the web viewer first)

  Local viewer:      remote-viewer $URL
                     virt-viewer   $URL
                     remote-viewer $VV
  Any VNC client:    127.0.0.1:$host_port
INFO
if [ "$host_ip" != "0.0.0.0" ]; then
cat <<INFO
  From another PC:   ssh -N -L $host_port:127.0.0.1:$host_port $USER@$(hostname -I 2>/dev/null | awk '{print $1}')
                     then open vnc://127.0.0.1:$host_port there (or set VNC_BIND=0.0.0.0 in .env to expose it on the LAN)
INFO
else
cat <<INFO
  From another PC:   vnc://$conn_host:$host_port   (VNC_BIND=0.0.0.0 - no auth, keep it on a trusted network)
INFO
fi
echo

(( PRINT )) && exit 0
for v in remote-viewer virt-viewer; do
    if command -v "$v" >/dev/null 2>&1; then
        log "Launching $v ..."
        nohup "$v" "$URL" >/dev/null 2>&1 &
        exit 0
    fi
done
warn "No virt-viewer/remote-viewer on this machine. Install with: sudo apt install virt-viewer   (or use the commands above from your desktop)"
