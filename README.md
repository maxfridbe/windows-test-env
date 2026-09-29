# windows-test-env

Disposable Windows VMs in Docker, built on [dockur/windows](https://github.com/dockur/windows), with
OpenSSH preinstalled so files can be copied in and out for testing, checkpoint/restore for quick resets,
and a web RDP console (Apache Guacamole) enabled by default.

## Requirements

- Linux host with KVM (`/dev/kvm` readable and writable by your user)
- Docker with the Compose plugin
- `ssh`, `scp`, `ssh-keygen` (OpenSSH client)
- Disk space: the Windows ISO (5-8 GB) plus the VM disk (default 64 GB, sparse) plus one checkpoint copy

## Quick start

```bash
./start-with-openssh.sh          # first run: creates a VM, downloads + installs Windows (15-40 min),
                                 # sets up OpenSSH, saves a baseline checkpoint, prints access info
./ssh.sh 'Get-ComputerInfo | Select-Object OsName, OsVersion'
./reset.sh -y                    # back to the checkpoint in a few minutes
./stop.sh
```

Watch the install at http://127.0.0.1:8006 or through Guacamole at http://127.0.0.1:8080.

## Scripts

| Script | What it does |
|---|---|
| `start-with-openssh.sh` | Starts the current VM and waits until SSH answers. `--new` creates a new VM (named `win<VERSION>_<date>`, or `--name x`). A fresh install is automatically saved as the baseline checkpoint. `--no-wait`, `--no-checkpoint`. |
| `stop.sh` | Graceful Windows shutdown. The disk is kept. |
| `reset.sh` | Restores the VM disk to its checkpoint (no reinstall). Falls back to a full reinstall if no checkpoint exists. `-y`, `--full`, `--no-start`, `--keep-shared`. |
| `checkpoint.sh` | Shuts Windows down cleanly and saves the disk as the checkpoint that `reset.sh` restores. Run it after installing whatever your baseline needs. `--no-restart`. |
| `update.sh` | Pulls the latest `dockurr/windows` image (recreating the container if it changed), then runs Windows Update inside the VM, rebooting and repeating until nothing is left. `--image-only`, `--windows-only`, `--max-rounds N`. |
| `vm.sh` | `list`, `use <name>`, `current`, `rm <name>`, `path [<name>]`. |
| `ssh.sh [cmd]` | Interactive PowerShell over SSH, or run one command. |
| `wire-with-virt-machine-manager.sh` | Opens the console in `remote-viewer`/`virt-viewer` over QEMU's VNC port, or prints the target plus an SSH tunnel command for another machine. `--restart`, `--print`. |

All scripts accept `--vm <name>` (or `VM=<name>` in the environment) to act on a VM other than the current one.

## Access

Defaults come from `.env` (Windows version for new VMs, credentials, RAM/CPU/disk, host ports).

| What | Where | Login |
|---|---|---|
| Web RDP (Guacamole) | http://127.0.0.1:8080 | `admin` / `admin` (`GUAC_USER` / `GUAC_PASSWORD`). Connections: RDP into Windows, and a VNC console for watching boots and installs. |
| Web console (noVNC) | http://127.0.0.1:8006 | none |
| RDP | `127.0.0.1:3389` | `Docker` / `admin` (`WIN_USERNAME` / `WIN_PASSWORD`) |
| SSH | `ssh -i ~/.config/windows-test-env/keys/id_ed25519 -p 2222 Docker@127.0.0.1` | key, or the Windows password |
| VNC (raw QEMU display) | `127.0.0.1:5900` | none; bound to localhost unless `VNC_BIND` is changed |

## SSH usage

The SSH default shell inside Windows is PowerShell, so every command you send is a PowerShell command.
`./ssh.sh` wraps `ssh` with the right key, port and user.

```bash
# interactive PowerShell session
./ssh.sh

# one-off commands
./ssh.sh 'hostname'
./ssh.sh 'Get-Service sshd, TermService | Select-Object Name, Status'
./ssh.sh 'Get-ChildItem C:\Users\Docker\Desktop'
./ssh.sh '(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion'

# run something you copied in, and read its exit code
./ssh.sh 'C:\Users\Docker\Desktop\mytool.exe --help; $LASTEXITCODE'

# run a local PowerShell script inside the VM (copy, run, clean up)
scp -i ~/.config/windows-test-env/keys/id_ed25519 -P 2222 ./check.ps1 Docker@127.0.0.1:C:/WinTestEnv/check.ps1
./ssh.sh 'powershell -ExecutionPolicy Bypass -File C:\WinTestEnv\check.ps1'

# reboot and wait for it to come back
./ssh.sh 'Restart-Computer -Force'; sleep 30; until ./ssh.sh 'exit 0' 2>/dev/null; do sleep 10; done
```

Plain `ssh`/`scp` work too (key or the Windows password):

```bash
K=~/.config/windows-test-env/keys/id_ed25519
ssh -i $K -p 2222 Docker@127.0.0.1
ssh -p 2222 Docker@127.0.0.1                 # password auth, "admin" by default

# copy in / copy out (Windows paths use forward slashes after the colon)
scp -i $K -P 2222 ./thing.exe Docker@127.0.0.1:C:/Users/Docker/Desktop/
scp -i $K -P 2222 -r ./testdata Docker@127.0.0.1:C:/WinTestEnv/
scp -i $K -P 2222 Docker@127.0.0.1:C:/Users/Docker/Desktop/result.log .
```

Quoting tip: keep the PowerShell command in single quotes on the bash side, and avoid ending it with a
backslash right before the closing quote (Windows treats `\'` as an escaped quote). `Test-Path 'C:/temp/'`
is safer than `Test-Path C:\temp\`.

The VM's `shared/` directory is also visible in Windows as `Z:` and as "Shared" on the desktop. `Z:` is a
per-user mapped drive, so from an SSH session use the UNC path `\\host.lan\Data` instead.

Guacamole, RDP and SSH listen on all host interfaces with the default passwords, so change them in `.env`
if the host is reachable from an untrusted network.

## Layout

```
project/
  .env                   settings
  docker-compose.yml     windows + guacd + guacamole; paths are injected by lib.sh
  lib.sh                 shared helpers (sourced by the scripts)
  oem/                   copied to C:\OEM at install time
    install.bat            runs at the end of the unattended install
    setup-ssh.ps1          installs/configures the OpenSSH server
    wu-task.ps1            Windows Update task used by update.sh
    authorized_keys        generated from the host keypair (git-ignored)

~/.config/windows-test-env/        (override with WTE_HOME)
  current                name of the selected VM
  keys/                  SSH keypair shared by all VMs
  guac/                  Guacamole user-mapping.xml, regenerated on every start
  win11_YYYY-MM-DD/
    vm.env               VERSION, credentials, creation date
    storage/             live VM disk (data.img) + ISO
    checkpoint/          sparse copy of storage/ (minus ISO) that reset.sh restores
    shared/              -> Z:\ inside Windows
```

## How it works

**OpenSSH.** `oem/` is bind-mounted as `/oem`; dockur copies it to `C:\OEM` and runs `install.bat` as the last
step of the unattended install. That runs `setup-ssh.ps1`, which installs the OpenSSH Server capability
(with a 10-minute cap, falling back to the Win32-OpenSSH MSI from GitHub), makes PowerShell the SSH default
shell, opens the firewall, and installs the host public key as `administrators_authorized_keys`.
Log inside the VM: `C:\OEM\setup-ssh.log`.

**Checkpoints.** A checkpoint is a sparse copy of every file in `storage/` except the ISO, taken while the
VM is shut down so the disk is consistent. `reset.sh` deletes the live disk files and copies the checkpoint
back. Time is proportional to the allocated size of the disk (a fresh install is roughly 12 GB).

**Windows Update.** Windows Update refuses install requests from SSH and other non-interactive logons, so
`update.sh` copies `oem/wu-task.ps1` into the VM and runs it as SYSTEM through a scheduled task, polling
`C:\WinTestEnv\wu.log` and `wu-status.json`. Reboots are detected by the boot time changing, and the task is
restarted if a reboot killed it. Cumulative updates often report "Failed" before their reboot and succeed on
the next round; that is expected.

**Web RDP.** `lib.sh` renders `~/.config/windows-test-env/guac/user-mapping.xml` from `.env` on every start.
Guacamole connects to the Windows container by service name over the compose network, and mounts the VM's
`shared/` directory into the RDP session as a drive.

**virt-manager.** Virtual Machine Manager only lists libvirt domains, and this VM is a plain QEMU process
inside a container, so it cannot appear there. Its VNC display is published instead, which the same
toolkit's `remote-viewer`/`virt-viewer` can open.

## Multiple VMs

```bash
VERSION=2022 ./start-with-openssh.sh --new       # new Server 2022 VM, becomes current
./vm.sh list
./vm.sh use win11_2026-01-15
./start-with-openssh.sh                          # only one VM runs at a time (fixed host ports)
./vm.sh rm win2022_2026-01-15
```
