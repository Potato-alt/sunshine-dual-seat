# Architecture

## Sessions

| | Local session | Remote session |
|---|---|---|
| User | `@DESKTOP_USER@` (human at the machine) | `@OPERATOR_USER@` (uid `@OPERATOR_UID@`, created for streaming) |
| Compositor | KDE Plasma Wayland (KWin), seat0, autologin optional | Sway, `WLR_BACKENDS=headless,libinput`, **no seat** |
| Started by | SDDM | `sway-sunshine.service` (system unit, `PAMName=login`, `TTYPath=/dev/@SEAT_TTY@`) |
| Input | Physical keyboard/mouse + *nothing* from the stream (isolation, see below) | Sunshine's uinput passthrough devices + virtual pads |
| Audio | Default hardware sink | PipeWire **null sink** `sink-sunshine-stereo` — exists only for the stream |
| GPU | NVIDIA for the monitor (xorg conf pins SDDM to it) | Renders on the Intel iGPU; encodes there too |

Why a second compositor at all: Sunshine needs a display to capture, but must not capture
the local one. A second Wayland compositor on a virtual output gives a real, isolated
desktop (windows, steam, games) with zero on-screen presence.

## GPU routing

- `sway-sunshine.service` and `sunshine-stream.service` both export
  `__GLX_VENDOR_LIBRARY_NAME=nvidia` → GLX apps (Steam, OpenGL games) launched inside the
  remote session render on the discrete NVIDIA GPU. Vulkan apps pick the NVIDIA card
  automatically (the only ICD installed).
- sway itself renders through EGL on the Intel iGPU (default Mesa behavior on the Intel
  render node — do **not** pin sway's EGL to NVIDIA; NVIDIA EGL fails under wlroots).
- `sunshine-stream.service` pins `__EGL_VENDOR_LIBRARY_FILENAMES=50_mesa.json` so Sunshine
  imports the dmabuf frames with Mesa EGL (same vendor as sway — mixed-vendor dmabuf import
  fails with "Frame capture failed" spam).
- Sunshine encodes with VAAPI on the Intel iGPU (`encoder = vaapi`,
  `adapter_name = @RENDER_NODE@`). Intel is the safe encoder here; see gotchas §2.2 for why
  NVENC is banned.

Do not connect a monitor to the iGPU unless you also pin SDDM: if the local X session lands
on the Intel card, the encoder competes with the desktop. `server/xorg/10-nvidia-primary.conf`
keeps X on NVIDIA.

## Data flow

- **Video:** sway (HEADLESS-1) → wlroots screencopy w/ damage → Sunshine (wlgrab, Mesa EGL
  dmabuf import) → VAAPI encode (iGPU) → LAN → Moonlight.
- **Audio:** apps in the remote session target `sink-sunshine-stereo` (unit env
  `PULSE_SINK` forces defaults; the sink is defined in
  `configs/pipewire/sunshine-null-sink.conf` with `monitor.channel-volumes = true` so the
  150 % volume boost actually reaches the stream) → Sunshine → Opus → client.
  The local speakers never carry the remote session's audio.
- **Input:** client → Sunshine → kernel uinput devices (`48879:57005:*_passthrough`,
  plus per-session pads) → sway (config enables only these devices; everything else
  disabled). The local compositor is prevented from reading them — gotchas §1.
- **Control plane:** Moonlight tile → Sunshine `apps.json` → detached scripts (games keep
  running when the stream ends; `KillMode=process` is deliberate).
  `set-resolution.sh`/`reset-resolution.sh` run as prep-cmd and resize the virtual output
  to the client's window using `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS`.
- **Server Control tile:** kitty + bash menu; privileged actions go through
  `sudoers/game-admin` (NOPASSWD limited to `stream-restart`, `reboot`, `poweroff`).
- **Clipboard bridge (optional):** client `clip-in`/`clip-out` → SSH as the *local* user →
  sudoers `arm-clipboard` → `game-clip-in`/`game-clip-out` (as root) → `sudo -u` into the
  remote session's `wl-copy`/`wl-paste`. The detour through root exists because the local
  user may not `sudo -u` the remote user directly.

## Isolation matrix

| Path | Mechanism | File/script |
|---|---|---|
| Remote input → local KWin (Wayland) | `kcminputrc` `[Libinput][vid][pid][name] Enabled=false` + runtime D-Bus disable | `scripts/sunshine-isolate-inputs` |
| Remote input → local X11 (SDDM greeter) | Xorg InputClass `Ignore` | `xorg/50-ignore-sunshine-input.conf` |
| Local input → remote sway | sway `input * events disabled` + explicit passthrough enables | `configs/sway-sunshine.config` |
| Remote audio → local speakers | dedicated PipeWire null sink as the only sink of the session | `configs/pipewire/…` |
| Local GPU load → stream | Sunshine renders/encodes on iGPU; NVIDIA busy only with games | unit env, `xorg/10-nvidia-primary.conf` |

## Tested versions

CachyOS (Arch-based), 2026-10:

| Package | Version |
|---|---|
| sunshine | 2026.724.5619-1 (**in IgnorePkg** — do not let it float) |
| sway | 1:1.9-5 |
| wlroots0.17 | 0.17.x |
| kwin | 6.7.5-1.1 |
| pipewire | 1.6.9 |
| sddm | 0.21.0 |
| kernel | CachyOS lts 7.2.x |

`IgnorePkg = sunshine sway wlroots0.17` — Sunshine builds differ wildly between versions
(input device names changed between builds), and the whole isolation chain matches on
device names. After any forced upgrade, re-check identifiers and re-run the isolate helper.

## Design decisions and their costs

- **Headless sway, not nested Hyprland/gamescope:** only wlroots compositors run without a
  logind session (gotchas §3.1). Cost: sway, not your favorite WM, in the remote session.
- **uinput for input, not Wayland virtual-input protocols:** Sunshine's input stack creates
  kernel devices; both compositors therefore see them, and isolation must be done per
  consumer. Cost: gotchas §1 exists at all.
- **System units (not user units) with PAMName:** gives the session a stable boot-time
  lifecycle independent of anyone logging in. Cost: boot races (§3.6) and ordering-cycle
  traps (§3.5).
- **KillMode=process:** detached games survive Sunshine crashes/updates. Cost: restarts
  must kill orphans explicitly (§3.4).
