#!/usr/bin/env bash
# Interactive PowerShell over SSH, or run a single command: ./ssh.sh 'Get-Process | Select -First 5'
. "$(dirname "$0")/lib.sh"
set -- "${ARGS[@]}"
if [ $# -eq 0 ]; then
    exec ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$WIN_USERNAME@127.0.0.1"
else
    wssh "$@"
fi
