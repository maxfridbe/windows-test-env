#!/usr/bin/env bash
# Manage the VMs stored in ~/.config/windows-test-env.
# Usage: ./vm.sh list | use <name> | current | rm <name> [-y] | path [<name>]
. "$(dirname "$0")/lib.sh"

cmd="${ARGS[0]:-list}"
case "$cmd" in
    list)
        cur="$(cat "$CURRENT_FILE" 2>/dev/null || true)"
        run="$(container_vm)"; container_running || run=""
        printf '%-2s %-28s %-8s %-10s %-10s %-11s %s\n' "" NAME VERSION DISK CHECKPOINT STATE CREATED
        for n in $(vm_list); do
            d="$WTE_HOME/$n"; v="$(sed -n 's/^VERSION=//p' "$d/vm.env" 2>/dev/null)"
            c="$(sed -n 's/^CREATED=//p' "$d/vm.env" 2>/dev/null | cut -c1-10)"
            disk="-"; [ -f "$d/storage/data.img" ] && disk="$(du -h "$d/storage/data.img" | cut -f1)"
            cp="-";   [ -f "$d/checkpoint/data.img" ] && cp="$(du -h "$d/checkpoint/data.img" | cut -f1)"
            state="stopped"; [ "$run" = "$n" ] && state="RUNNING"
            mark=" "; [ "$cur" = "$n" ] && mark="*"
            printf '%-2s %-28s %-8s %-10s %-10s %-11s %s\n' "$mark" "$n" "${v:-?}" "$disk" "$cp" "$state" "${c:-?}"
        done
        echo; echo "(* = current)   home: $WTE_HOME"
        ;;
    use)     use_vm "${ARGS[1]:?name required}"; log "Current VM is now '$VM_NAME'" ;;
    current) require_vm; echo "$VM_NAME" ;;
    path)    if [ -n "${ARGS[1]:-}" ]; then set_vm "${ARGS[1]}"; else require_vm; fi; echo "$VM_DIR" ;;
    rm)
        name="${ARGS[1]:?name required}"; vm_exists "$name" || die "No VM named '$name'"
        target="${WTE_HOME:?}/${name:?}"
        if container_running && [ "$(container_vm)" = "$name" ]; then die "VM '$name' is running - ./stop.sh first"; fi
        if [ "${ARGS[2]:-}" != "-y" ]; then
            read -r -p "Delete VM '$name' ($(du -sh "$target" | cut -f1)) permanently? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
        fi
        if ! rm -rf "${target:?}" 2>/dev/null; then
            docker run --rm -v "$target:/s" alpine sh -c 'rm -rf /s/* /s/.[!.]*'
            rm -rf "${target:?}"
        fi
        [ "$(cat "$CURRENT_FILE" 2>/dev/null)" = "$name" ] && rm -f "$CURRENT_FILE"
        log "Deleted VM '$name'"
        ;;
    *) die "Usage: ./vm.sh list | use <name> | current | rm <name> [-y] | path [<name>]" ;;
esac
