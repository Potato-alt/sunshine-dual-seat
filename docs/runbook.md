# Runbook — installing sunshine-dual-seat

Written for an agent executing on the target machine. **Every step ends with a Gate** —
run the gate command; if the expectation does not match, stop and read
[gotchas.md](gotchas.md) before improvising.

Conventions:
- `@DESKTOP_USER@` — existing local (desktop) user.
- `@OPERATOR_USER@` / `@OPERATOR_UID@` — dedicated user for the remote session.
- All files referenced below are in this repository; `install.sh` substitutes the
  `@VARS@` and copies them into place, but the runbook explains *what* is being done
  so you can do it by hand or adapt it.

## Step 0 — Collect facts

```bash
lspci | grep -Ei 'vga|3d'            # expect: NVIDIA + Intel (or AMD) iGPU
ls -la /dev/dri/                     # note render nodes: card0/card1, renderD12x
loginctl list-sessions
id '@OPERATOR_USER@' 2>/dev/null || echo 'operator user missing (ok on fresh install)'
```

**Gate:** exactly one GPU drives the monitor; you know which render node belongs to the
iGPU that will encode (`ls -la /dev/dri/by-path/ | grep render`, cross-check with
`udevadm info` / `lspci`). Write it down — it becomes `adapter_name`.

## Step 1 — Packages

Arch-based:

```bash
pacman -S --needed sway sunshine pipewire wireplumber polkit kitty btop \
  pavucontrol wofi steam wl-clipboard python
```

Pin the versions once everything works (`/etc/pacman.conf`):

```ini
IgnorePkg = sunshine sway wlroots0.17
```

**Gate:** `sway -v`, `sunshine --version` print without errors.
**Warning:** Sunshine builds differ wildly between versions; the whole input-isolation
chain matches device names. Do not let it float (gotchas §4).

## Step 2 — Remote user

```bash
useradd -m -u 1001 -G input,video,render @OPERATOR_USER@
loginctl enable-linger @OPERATOR_USER@
passwd -l @OPERATOR_USER@   # no password login; access only via Sunshine
```

**Gate:** `id @OPERATOR_USER@` shows `input`, `video`, `render` groups; `loginctl show-user @OPERATOR_USER@ -p Linger` = `yes`.

## Step 3 — Audio sink

Copy `configs/pipewire/sunshine-null-sink.conf` to
`~@OPERATOR_USER@/.config/pipewire/pipewire.conf.d/`.

**Gate:** as `@OPERATOR_USER@` (with `XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@`):
`pactl list short sinks | grep sink-sunshine-stereo`.
(If empty, re-check after Step 4 — the sink appears once the user manager runs.)

## Step 4 — Headless sway session (systemd unit)

Fill variables in `units/sway-sunshine.service` (`@OPERATOR_USER@`, `@OPERATOR_UID@`,
`@SEAT_TTY@` — a VT *not* used by the local display manager) and install to
`/etc/systemd/system/`. Key points (why is in gotchas §3):

- `PAMName=login` + `TTYPath` — gives the session a real lifecycle at boot.
- `LIBSEAT_BACKEND=noop` — sway dies silently within ~10 s without it.
- `WLR_BACKENDS=headless,libinput`, `WLR_LIBINPUT_NO_DEVICES=1`, `WLR_RENDERER=gles2`.
- **No `After=graphical.target`** — it creates an ordering cycle that silently deletes the
  Sunshine unit's start job at boot.
- `ExecStartPre=-rm -f …/sway-sunshine.sock` — stale socket cleanup.

Copy `configs/sway-sunshine.config` to `~@OPERATOR_USER@/.config/sway-sunshine/config`
and `scripts/ticker.sh` next to it. The config:

- creates the virtual output `HEADLESS-1` (1920x1080@60 default);
- keeps the bar **visible** with the ticker (damage source for capture — gotchas §3.3);
- disables all input, re-enables only Sunshine passthrough devices;
- sets `us,ru` with `caps_toggle` (Alt+Shift collides with the client's own switcher).

**Gate:**

```bash
systemctl daemon-reload && systemctl start sway-sunshine.service
sleep 8
ls /run/user/@OPERATOR_UID@/wayland-*          # a socket + .lock exist
sudo -u @OPERATOR_USER@ env XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ \
  SWAYSOCK=/run/user/@OPERATOR_UID@/sway-sunshine.sock swaymsg -t get_outputs | grep HEADLESS-1
systemctl is-active sway-sunshine               # active after >30 s (not crash-looping)
```

## Step 5 — Sunshine (systemd unit + startup gate)

Fill variables in `units/sunshine-stream.service` and install. Key points:

- `Requires=`/`BindsTo=` sway-sunshine; `KillMode=process` so detached games survive
  restarts (cost: restarts need the ritual, gotchas §3.4);
- `__EGL_VENDOR_LIBRARY_FILENAMES=50_mesa.json` — dmabuf import with the same EGL vendor
  as sway (mixed vendor ⇒ "Frame capture failed" forever);
- `__GLX_VENDOR_LIBRARY_NAME=nvidia` — GLX games inside the session use the discrete GPU;
- `ExecStart` = `scripts/run-sunshine.sh` (waits for a *live* compositor: wayland socket
  whose `.lock` cannot be flocked + `HEADLESS-1` present; then finds the session's Xwayland
  display by socket owner uid).

Install scripts (executable, owned by `@OPERATOR_USER@` where noted):

```
~@OPERATOR_USER@/.config/sway-sunshine/run-sunshine.sh   (also referenced by the unit)
~@OPERATOR_USER@/.config/sway-sunshine/{set,resolution,reset-resolution}.sh
~@OPERATOR_USER@/.config/sway-sunshine/ticker.sh
/usr/local/bin/stream-restart        (root; see sudoers step)
```

Create `~@OPERATOR_USER@/.config/sunshine/sunshine.conf` from `configs/sunshine.conf`
(fill `@SERVER_IP@`, `@RENDER_NODE@`). **`system_tray = disabled` is not optional**
(tray D-Bus deadlock, gotchas §2.1). **`encoder = vaapi`, never `nvenc`** (§2.2).

**Gate:**

```bash
systemctl start sunshine-stream.service
sleep 5; systemctl is-active sunshine-stream     # active
journalctl -u sunshine-stream -n 50 | grep -E 'Found (H.264|HEVC) encoder'
# expect: h264/hevc_vaapi lines; av1 line is fine to be absent
ss -tlnp | grep -E ':(47984|47989|47990|48010)'  # ports listening
```

Pairing: open `https://@SERVER_IP@:47990` (accept the self-signed cert), set credentials,
then in Moonlight enter the PIN **quickly** — pending pairing requests expire in seconds.
Never restart Sunshine while a pairing dialog is open (the pairing session dies with it).

## Step 6 — Input isolation (do not skip; the default is LEAKY)

The remote session's virtual devices are readable by **every** compositor by default.
Three consumers to close:

1. **Sway (remote side):** already handled by the sway config from Step 4
   (`input * events disabled` + explicit passthrough enables).

   **Gate:** `swaymsg -t get_inputs` → all physical devices `send_events: disabled`,
   all `*_passthrough` devices `enabled`.

2. **Local Wayland session (KWin):** run `scripts/sunshine-isolate-inputs` **as the local
   user** (it uses `busctl --user` + `kwriteconfig6`). It writes
   `kcminputrc [Libinput][vid][pid][Name] Enabled=false` and disables the devices at
   runtime over D-Bus. KWin reads per-device config **only** from kcminputrc and the key
   is case-sensitive — see gotchas §1.1 before "simplifying" this.

   **Gate:** with the local Plasma session running:
   ```bash
   busctl --user get-property org.kde.KWin /org/kde/KWin/InputDevice/eventNN \
     org.kde.KWin.InputDevice enabled     # expect: b false for every passthrough device
   ```

3. **X11 sessions (SDDM greeter):** copy `xorg/50-ignore-sunshine-input.conf` to
   `/etc/X11/xorg.conf.d/`. Applies on next X start.

   **Gate:** restart SDDM (with nobody streaming) and grep the Xorg log for
   `Ignoring device from InputClass`.

Re-run the isolate script whenever new virtual devices appear — gamepads are created
per client session and are invisible to static rules (gotchas §1.4).

## Step 7 — Tiles, control menu, sudoers

- `configs/apps.json` → `~@OPERATOR_USER@/.config/sunshine/apps.json` (fill `@OPERATOR_HOME@`);
  remove/adjust the example game entries.
- `scripts/server-control*.sh` → `~@OPERATOR_USER@/.config/sway-sunshine/`.
- Optional GPU pinning for the local X session: `xorg/10-nvidia-primary.conf`.
- sudoers (install with `visudo -cf` check, then `install -m 440`):
  - `sudoers/game-admin` → `/etc/sudoers.d/` — lets `@OPERATOR_USER@` run only
    `stream-restart`, `reboot`, `poweroff` from the in-stream menu;
  - `sudoers/arm-clipboard` → `/etc/sudoers.d/` — lets `@DESKTOP_USER@` run the clipboard
    helpers (only if you want the clipboard bridge).

**Gate:** `visudo -c` clean; from the Moonlight client the app list shows the tiles.

## Step 8 — Client side (optional)

- `client/moonlight-hd` — wrapper: HEVC 1080p60 25 Mbit (fill `@SERVER_IP@`).
- `client/clip-{in,out}` — clipboard bridge (fill `@SERVER_IP@`, `@DESKTOP_USER@`,
  `@SSH_KEY@`; needs passwordless SSH to the local user and the sudoers entry from Step 7).
- Moonlight settings that matter: HEVC codec, 60 fps, 30–50 Mbit on wired LAN,
  V-Sync off for lower input latency.

**Gate:** `moonlight list @SERVER_IP@` shows the host and the tiles.

## Step 9 — End-to-end verification

```bash
server/verify.sh     # static checks
```

Then, with a human or agent at the client:

1. Stream **Desktop** — picture appears within ~5 s; resolution matches the client window
   (check `swaymsg -t get_outputs`).
2. Type and move the mouse **while someone watches the local monitor** — nothing may appear
   there. (Automated equivalent: gotchas §1.1 injection test.)
3. Launch a game tile, disconnect the client — the game keeps running in the headless
   session (check `pgrep -u @OPERATOR_USER@`).
4. Reboot the server; wait; `verify.sh` and a control stream — everything must come back
   on its own (if Sunshine is down after boot, gotchas §3.5).
