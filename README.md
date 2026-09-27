# ros-containers

ROS development environments in Docker, on Fedora, that behave like the host:
same user, same network, same display, all hardware. Each environment is a
long-lived container managed by systemd and saved into its image automatically.

| Environment | Image | Service | Shell command |
|---|---|---|---|
| ROS1 Noetic (Ubuntu 20.04) | `ros1:latest` | `ros1.service` | `1` |
| ROS2 | *planned* | `ros2.service` | `2` |

Only one environment runs at a time: starting one stops the other.

---

## Contents

1. [Quick reference](#quick-reference)
2. [Layout](#layout)
3. [Host setup (one time)](#host-setup-one-time)
4. [Install, build, start](#install-build-start)
5. [Daily use](#daily-use)
6. [How saving works](#how-saving-works)
7. [Settings (`.env`)](#settings-env)
8. [Backup and restore (`sync.sh`)](#backup-and-restore-syncsh)
9. [What "like the host" means](#what-like-the-host-means)
10. [Company compose files and images](#company-compose-files-and-images)
11. [Changing the repo](#changing-the-repo)
12. [Troubleshooting](#troubleshooting)

---

## Quick reference

```bash
sudo systemctl start ros1        # start (automatic at boot if enabled)
1                                # shell in the container, in its home
1 rviz                           # run one command
1 --nvidia rviz                  # run it on the NVIDIA GPU
sudo systemctl reload ros1       # save now, keep running (shells stay open)
sudo systemctl restart ros1      # save, then start fresh (closes shells)
sudo systemctl stop ros1         # save and stop
systemctl status ros1            # state
journalctl -u ros1 -b            # log of this boot

./sync.sh export                 # image -> external drive
./sync.sh import                 # external drive -> image
```

Run `systemctl` and `sync.sh` on the **host**. Inside the container use `sudo`
for system changes (passwordless).

---

## Layout

```
/opt/ros-containers/
├── README.md
├── sync.sh                  # export/import images to external drives
└── ros1/
    ├── Dockerfile           # minimal image: user, sudo, locale, GL/Vulkan, name resolution, docker CLI
    ├── entrypoint.sh        # at start: links host services, grants device groups
    ├── compose.yaml         # how the container runs (network, GUI, hardware, folders)
    ├── compose.nvidia.yaml  # NVIDIA GPU add-on (enabled in .env)
    ├── compose.mongo.yaml   # MongoDB 6.0 for the simulation (enabled in .env)
    ├── .env                 # settings
    ├── ros1.service         # systemd unit (linked into /etc/systemd/system)
    ├── commit.sh            # save logic used by the service
    ├── enter.sh             # the `1` command (/usr/local/bin/1 links here)
    ├── build.sh             # build ros1:base from the Dockerfile
    ├── install.sh           # host checks, folders, links, SELinux labels
    └── setup/               # scripts to run INSIDE the container (at /opt/ros-setup)
        ├── install-deps-simulation.sh   # ROS Noetic + ANSCER simulation dependencies
        └── lazyvim-setup.sh             # Neovim + LazyVim
```

The repo must live at `/opt/ros-containers` (the unit file uses that path).

---

## Host setup (one time)

Fedora 44 with KDE Plasma (Wayland), AMD iGPU + NVIDIA dGPU.

### Docker

```bash
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"          # then log out and back in
```

**Storage format:** use the classic `overlay2` store. Docker's newer
containerd image store compresses every save on one CPU core, which made a
save take ~2 minutes even for tiny changes (overlay2: ~13 s).

```bash
echo '{ "features": { "containerd-snapshotter": false } }' | sudo tee /etc/docker/daemon.json
sudo systemctl enable --now docker
docker info --format '{{.Driver}}'       # overlay2
```

If `daemon.json` already has content, add the `features` key to it instead of
overwriting. Switching an existing install: export images first
(`docker save ... -o file.tar`), switch, restart Docker, `docker load` them.

### NVIDIA (optional)

Needs the NVIDIA driver (RPM Fusion `akmod-nvidia`) and the container toolkit:

```bash
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo dnf install nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list                       # shows nvidia.com/gpu=all
```

Re-run `cdi generate` after **every NVIDIA driver update** (or enable the
toolkit's `nvidia-cdi-refresh` unit if `systemctl list-unit-files | grep nvidia-cdi`
shows one). Without the GPU, remove `:compose.nvidia.yaml` from `COMPOSE_FILE` in `.env`.

### Fonts (for LazyVim and other icon-using tools)

Konsole on the host draws the characters, so icon fonts go on the host:

```bash
mkdir -p ~/.local/share/fonts/JetBrainsMonoNF && cd /tmp
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip -o JetBrainsMono.zip -d ~/.local/share/fonts/JetBrainsMonoNF && fc-cache -f
```

Konsole → Settings → Edit Current Profile → Appearance → **JetBrainsMono Nerd Font**.

---

## Install, build, start

```bash
sudo mkdir -p /opt/ros-containers && sudo chown "$USER:$USER" /opt/ros-containers
# put the repo there (git clone or extract), then:
cd /opt/ros-containers/ros1
./install.sh --enable      # checks, creates shared folders, links unit and `1`; --enable = start at boot
./build.sh                 # builds ros1:base and creates ros1:latest from it
sudo systemctl start ros1
1
```

**On another PC with an exported image:** run `./install.sh --enable`, then
`../sync.sh import` instead of `./build.sh`.

`install.sh` options: `--enable`, `--uninstall` (stops with a save, removes the
unit and `1`; images and repo are kept), `--help`. It is safe to re-run.

---

## Daily use

### Shells

- `1` opens a login shell as your user in the container's home (`/home/kd`),
  prompt `(ros1)kd@anscer`. Open as many as you like.
- `1 <command>` runs one command (GUI programs work).
- `1 --nvidia <command>` renders on the NVIDIA GPU (PRIME offload). Without it,
  programs use the AMD iGPU.

### The container's home

The container has **its own home directory**: its own `~/.bashrc`, `~/.config`,
`~/.local`, `~/.ssh`, `~/.gitconfig`, `~/.ros`. These are part of the image,
saved by commits and carried along by `sync.sh`.

Put ROS setup in the **container's** `~/.bashrc`, e.g.

```bash
source /opt/ros/noetic/setup.bash
source ~/anscer_ws/devel/setup.bash
export EDITOR=nvim VISUAL=nvim
```

Set your git identity once inside the container (`git config --global user.name/email`).

### Shared folders

These host folders appear at the same path inside the container:

`~/Projects`, `~/Downloads`, `~/Documents`, `~/anscer_ws`

- Files are shared live and owned by you on both sides.
- They are **never** part of the image, commits or exports: keep code there.
- Build ROS workspaces **inside the container** only (`build/`, `devel/` hold
  Ubuntu 20.04 binaries).
- Missing folders are created by `install.sh`. To add one, add a bind entry to
  `compose.yaml` (copy an existing one), run `./install.sh`, restart.

### MongoDB (simulation)

The ANSCER simulation stores robot data in MongoDB. `compose.mongo.yaml` runs
**MongoDB 6.0 as a separate container** (`ros1-mongo`) that starts and stops
with `ros1.service`.

- Connect from the container or the host: `mongodb://localhost:27017`.
- Shell: `docker exec -it ros1-mongo mongosh` (or `mongosh` inside `1`).
- Localhost only (not reachable from the network), no password.
- Data is in the Docker volume `ros1_mongo-data`: it survives restarts and image
  rebuilds, and is **not** part of saves or `sync.sh` exports. Back it up with
  `mongodump`; restore with `mongorestore`.
- Don't run `mongod` inside the ros1 container (port clash, and a live
  database would be baked into every save).
- Not needed? Remove `:compose.mongo.yaml` from `COMPOSE_FILE`.

### Setup scripts

`ros1/setup/` is mounted read-only in the container at `/opt/ros-setup`.
Run the scripts from a `1` shell (not with sudo), then `sudo systemctl restart ros1`
on the host to save:

```bash
bash /opt/ros-setup/install-deps-simulation.sh   # ROS Noetic + ANSCER simulation deps (long)
bash /opt/ros-setup/lazyvim-setup.sh             # Neovim + LazyVim
```

On a fresh `ros1:base` this rebuilds the environment without an exported image.
New scripts dropped into `ros1/setup/` appear in the container immediately.

### Installing software

Install inside the container with `sudo apt install ...`, then save
(`reload`, or it is saved at the next stop). Ubuntu 20.04's packages can be old;
for newer tools prefer official release binaries.

---

## How saving works

The container is disposable; the image is what persists.

| Image | What it is |
|---|---|
| `ros1:base` | Clean build of the Dockerfile. Never modified. Fallback. |
| `ros1:latest` | Your working image. Every save overwrites it. |

| Event | What happens |
|---|---|
| `systemctl start` | Fresh container from `ros1:latest`. A leftover container (power cut, crash) is saved first. |
| `systemctl reload` | Save while running. No freeze, shells stay open. |
| `systemctl stop` / `restart` / shutdown | Stop the container, save, remove it. |
| Nothing changed | No save (GPU/linker cache noise is ignored). |

Good to know:

- **A save contains everything changed since the container last started.**
  After a big install, `restart` once: later saves are then small and fast.
- `stop`/`restart` close all `1` shells.
- Every save adds an image layer (Docker's limit is ~125). When `ros1:latest`
  exceeds `ROS1_SQUASH_THRESHOLD` layers it is flattened on the next stop
  (not during shutdown). Manually: `sudo systemctl stop ros1 && ./commit.sh squash`.
- Only the latest state is kept. To start over from the clean base (loses all
  saved changes): `sudo systemctl stop ros1 && ./build.sh --reset`.
- Rebuilding the base (`./build.sh`) does **not** change `ros1:latest`.
- Keep the Dockerfile the source of truth for essentials: if something must
  survive a reset, add it there.

---

## Settings (`.env`)

| Setting | Meaning | After changing |
|---|---|---|
| `ROS1_USER`, `ROS1_UID`, `ROS1_GID` | Must match your host user (`id`). | `./build.sh --reset` |
| `ROS1_BASE_IMAGE` | Image the Dockerfile builds on (`ubuntu:20.04`, or a company image). | `./build.sh --reset` |
| `ROS1_SQUASH_THRESHOLD` | Layer count that triggers flattening (default 90, keep < 115). | nothing |
| `COMPOSE_FILE` | `compose.yaml:compose.nvidia.yaml:compose.mongo.yaml`; drop a part to disable the NVIDIA GPU or MongoDB. | `./install.sh`, then `sudo systemctl restart ros1` |

---

## Backup and restore (`sync.sh`)

```bash
cd /opt/ros-containers
./sync.sh export     # or: ./sync.sh export ros1
./sync.sh import
```

- Lists external drives, marks the best one (★): ext4/xfs/btrfs first, then
  exFAT/NTFS, then the fastest port. FAT32 is refused (4 GB file limit). Warns
  when a drive is on a USB 2 port.
- Mounts the drive without sudo if needed; offers to eject at the end.
- **Export** saves the running container first, then writes
  `<drive>/ros-containers/ros1.tar.zst` (`ros1:latest` + `ros1:base` + companion
  images such as `mongo:6.0`, zstd on all cores) and a `.sha256`. Database
  volumes are not included. It writes to `.partial` first, so an
  interrupted export never damages the previous one. One export per drive
  (overwritten each time).
- **Import** verifies the checksum, asks before replacing `ros1:latest` (the
  current container state is lost), loads the image, removes the replaced one,
  and restarts ros1 if it was running.

Restore tested: wiping all Docker images and cache, then `./sync.sh import`,
gives back the full environment.

---

## What "like the host" means

### Network

- Host network, IPC and hostname: same interfaces, IPs, routes, VPNs, ports and
  hostname. `ROS_MASTER_URI=http://localhost:11311` works in both directions.
- `/etc/hosts` is the host's (copied at each start). The host's own hostname
  and `*.local` (mDNS via the host's avahi) resolve inside the container.
- Works offline; the service does not wait for the network.
- Open-file limits match Fedora (soft 1024), which keeps rosmaster fast.

**Talking to robots (ROS1):** nodes connect back to each other on random ports,
and Fedora's firewall applies to the container too. If a robot sees your topics
but no data flows, trust the robot-facing interface or open the range:

```bash
sudo firewall-cmd --zone=trusted --change-interface=<iface> --permanent   # e.g. enp3s0
sudo firewall-cmd --reload
```

Also make your address reachable from the robot, e.g. in the container's
`~/.bashrc`: `export ROS_IP=<your IP on the robot network>`.

### GUI and audio

- Wayland/Xwayland sockets, auth and session D-Bus come from `/run/user/1000`
  and `/tmp/.X11-unix`; `1` forwards the live session variables.
- Qt and GTK use Xwayland (`QT_QPA_PLATFORM=xcb`, `GDK_BACKEND=x11`); Noetic-era
  toolkits are unreliable on native Wayland. Windows appear as normal Plasma windows.
- Audio via the host's PipeWire; clipboard via `wl-clipboard`/`xclip` (install
  in the container).
- Time zone is the host's (`/etc/localtime`).

### Hardware

- Privileged, with the **live** host `/dev`: USB serial, cameras, joysticks,
  CAN, GPUs, including devices plugged in later.
- Your user is added to every group that owns a device, so no sudo is needed.
  Group names inside may look odd (e.g. `39(irc)`); the numbers are what count.
  A device with an entirely new group needs a `restart`.
- Host services are linked in: system D-Bus (Bluetooth), udev (device info),
  avahi, the Docker socket.
- Kernel drivers come from the host: load/install kernel modules on Fedora.

### Security note

The container is privileged, has the host's devices and the Docker socket, and
your user has passwordless sudo inside. Treat it as root-equivalent on this PC,
and don't share the image with secrets (SSH keys, tokens) in it.

---

## Company compose files and images

**1. Their containers must talk to your ROS1 nodes.** Works as long as their
services also use host networking. Don't edit their file; add an override:

```yaml
# host-like.yaml
services:
  their_service:              # repeat for each service
    network_mode: host
    ipc: host
    privileged: true
    volumes:
      - /dev:/dev
      - /tmp/.X11-unix:/tmp/.X11-unix
    environment:
      DISPLAY: ${DISPLAY:-:0}
```

```bash
docker compose -f their-compose.yaml -f host-like.yaml up
```

Only one `roscore` at a time (port 11311): either `ros1` runs it or their stack does.

**2. They give you a ROS1 dev image.** Set `ROS1_BASE_IMAGE=<their image>` in
`.env` and `./build.sh --reset`: your user, `1`, GUI, hardware and saving are
layered on top. It must be Ubuntu/Debian based.

**3. Run their compose file from inside `ros1`.** The Docker CLI is in the
image and talks to the host's Docker: containers you start run next to `ros1`
on the host. Relative paths in their compose file resolve on the host, so keep
such projects in a shared folder (`~/Projects`, `~/anscer_ws`) where paths are
identical on both sides.

**4. Their services should start with `ros1`.** Give them their own systemd
unit with `After=ros1.service` / `Requires=ros1.service`.

---

## Changing the repo

- Edit files in place and commit with git.
- After copying in a new file (e.g. from `~/Downloads`), run `./install.sh`:
  it resets the **SELinux labels**. Files moved from your home keep a "home"
  label that systemd may not read (error: *SELinux is preventing systemd from
  read access on the file ros1.service*). Never fix that with `audit2allow`.
- After changing `ros1.service`: `sudo systemctl daemon-reload`.
- After changing `compose.yaml` or `.env`: `sudo systemctl restart ros1`.
- After changing `Dockerfile` or `entrypoint.sh`: `./build.sh` (base only) or
  `./build.sh --reset` (also replaces `ros1:latest`).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `1: the ros1 container is not running` | `sudo systemctl start ros1`; if it fails, `journalctl -u ros1 -b`. |
| `1: cannot talk to Docker` | Not in the `docker` group yet: `sudo usermod -aG docker $USER`, log out/in. |
| Start fails mentioning `nvidia.com/gpu` / CDI | NVIDIA driver updated: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, or drop the NVIDIA overlay in `.env`. |
| Start fails: a shared folder `does not exist` | Run `./install.sh` (creates them). |
| `Start request repeated too quickly` | 3 failed starts in 2 min. Fix the cause, then `sudo systemctl reset-failed ros1`. |
| Container shows `(Paused)` | An interrupted plain `docker commit`. `docker unpause ros1`. Use `systemctl reload` to save (it never pauses). |
| `apt: Permission denied` in the container | Use `sudo apt ...`. |
| Icons show as boxes in Neovim/LazyVim | Nerd Font missing on the **host** (see Fonts). |
| GUI program shows nothing | Run it via `1 <program>` from a desktop terminal so the session variables are current. |
| Robot sees topics but no data | Firewall / `ROS_IP`, see Network. |
| Start fails: `mongo:6.0` image not found | `./install.sh` downloads it (the service never downloads, so it also starts offline). |
| Simulation can't reach MongoDB | `docker ps` should list `ros1-mongo`; `docker logs ros1-mongo`. Nothing else may use port 27017. |
| Disk filling up | `docker system df`; `docker image prune` removes unnamed leftovers (keeps `ros1:*`). |
| Reload/stop is slow | Check `docker info --format '{{.Driver}}'` is `overlay2`. A save after a big install is large once; `restart` after big installs. |

Useful commands:

```bash
docker ps -s --format '{{.Names}}: {{.Size}}'   # changes since the container started
docker diff ros1 | head                         # what changed
docker image inspect -f '{{len .RootFS.Layers}}' ros1:latest   # layer count
systemctl show ros1 -p TimeoutStartUSec         # 15min (also the reload limit)
```

---

## Adding ROS2 later

Copy `ros1/` to `ros2/`, then change names (`ros1` → `ros2`, `ROS1_*` → `ROS2_*`,
`1` → `2`), set the base image (e.g. `ubuntu:24.04` for Jazzy), and add
`Conflicts=ros1.service` to `ros2.service` (ros1 already conflicts with ros2).
`sync.sh` works with it as `./sync.sh export ros2`.
