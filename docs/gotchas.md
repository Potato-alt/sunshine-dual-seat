# Gotchas — every landmine we stepped on

Ordered roughly by subsystem. Format: **Symptom → Cause → Fix**. These are all real
incidents from a production machine (CachyOS, Oct 2026, versions in
[architecture.md](architecture.md#tested-versions)).

## 1. Input isolation (the deepest hole)

### 1.1 KWin ignores per-device settings written to kwinrc — input leaks into the local session

- **Symptom:** everything the remote user types/clicks also happens in the local Plasma
  session (cursor moves, text appears on the local desktop). The SDDM login screen is
  *not* affected.
- **Cause:** KWin (Plasma 6.x, verified 6.7.5) reads per-device libinput config **only from
  `kcminputrc`**, not `kwinrc`. The group is **nested**:
  `[Libinput][<vendor>][<product>][<device name with spaces as-is>]`
  (source: `Connection::applyDeviceConfig`, `m_config->group("Libinput").group(vendor).group(product).group(name)`).
  And the key is **`Enabled`** with a capital E — **KConfig keys are case-sensitive**.
  The widely-circulated `kwinrc` + `[Libinput][vid:pid:Name_with_underscores]` +
  lowercase `enabled=false` recipe matches none of this and silently does nothing.
  Proof that case matters: after setting the property over D-Bus, KWin writes
  `Enabled=false` *next to* an existing lowercase `enabled=false` in the same group
  instead of updating it.
- **Fix:** disable the devices at runtime over D-Bus — KWin then persists the entry itself
  in the correct format:
  ```bash
  busctl --user set-property org.kde.KWin /org/kde/KWin/InputDevice/eventNN \
      org.kde.KWin.InputDevice enabled b false
  ```
  (`server/scripts/sunshine-isolate-inputs` does this for every Sunshine device and also
  writes the `kcminputrc` entry for future sessions.)
- **Also:** `qdbus6` **cannot introspect** KWin's input-device objects (`UnknownInterface`)
  while `busctl` works fine. D-Bus object paths are `/org/kde/KWin/InputDevice/eventNN`,
  not `/InputDevices/N`.
- **Verification trap:** to prove the cursor of the local session did not move, read the
  position with a KWin script (`console.info("CURSORPOS " + workspace.cursorPos…)` →
  `journalctl | grep CURSORPOS`). Klipper-based readback is unreliable and klipper is often
  not installed. If a human is sitting at the physical mouse, their movement contaminates
  measurements — use double injections into one absolute position and compare.

### 1.2 Why not strip the devices with udev?

- **Symptom (of the attempted fix):** remote session loses all input too.
- **Cause:** wlroots/libinput enumerates only devices that have `ID_INPUT` set; udev rules
  that strip it (by name or by `phys`) kill input for sway as well. Sunshine's uinput
  devices also have an empty `phys`, so the old `phys`-based rules don't match anyway.
- **Fix:** isolate at the **consumer** level (KWin/X11 config above; sway input filters),
  never at the udev level.

### 1.3 The SDDM greeter (X11) receives stream input — clicks can reboot the server

- **Symptom:** while nobody is logged in locally, remote mouse clicks move the greeter
  cursor; a click on the power button in the greeter **reboots the machine** mid-game.
- **Cause:** the greeter is an X11 session; it auto-adds all evdev devices.
- **Fix:** `server/xorg/50-ignore-sunshine-input.conf` — `InputClass` with
  `MatchProduct "passthrough"` / `MatchProduct "Sunshine"` / `MatchUSBID`, `Option "Ignore" "true"`.
  Verify in the Xorg log: `Ignoring device from InputClass`.
  (A `MatchUSBID "beef:dead"` fallback is fine, but note a typo there silently disables
  that one section while the `MatchProduct` sections still work.)

### 1.4 Gamepads are created per client session and are NOT covered by static rules

- **Symptom:** pad input appears in the local session.
- **Cause:** Sunshine creates virtual pad devices only when a client connects (PS5 pad =
  uhid Bluetooth device with touchpad + motion sensors, `1356:3302`; Switch `1406:8209`;
  XBox `1118:736`) — identifiers unknown in advance.
- **Fix:** after the first connect with a pad, run `server/scripts/sunshine-isolate-inputs`
  (it derives vendor:product:name from `/proc/bus/input/devices` and writes both the
  runtime D-Bus disable and the persistent kcminputrc entry).

### 1.5 Sway side: physical devices must be muted explicitly

- The remote sway session sees *all* evdev devices (it bypasses logind). The sway config
  therefore does `input * events disabled` and re-enables exactly the passthrough devices
  (plus `input type:joystick events enabled` for pads).
- **sway config syntax trap:** sway rejects **two input directives on one line** and throws
  the whole line away (only visible in sway's error output). One directive per line.
- `input type:keyboard xkb_layout …` does not reliably reach the uinput keyboard; set
  xkb options on the explicit `"48879:57005:Keyboard_passthrough"` identifier.
- Layout switching: `grp:alt_shift_toggle` collides with the client's own Alt+Shift switch;
  add `grp:caps_toggle` so CapsLock switches the *remote* layout only.

## 2. Sunshine core

### 2.1 Tray notification deadlock ("RTSP ANNOUNCE request failed: 110")

- **Symptom:** stream handshake dies ~10 s in: client shows an RTSP timeout, server log
  shows `New streaming session started`, audio starts, but no encoder line ever appears;
  ends with `Fatal: Hang detected!`.
- **Cause:** at session start Sunshine posts a desktop notification; without a system tray
  this becomes a **synchronous D-Bus call that blocks the main thread**, and the main
  thread serves RTSP. gdb showed the main thread stuck in
  `notify_notification_show → g_dbus_proxy_new_for_bus_sync`. The NVENC/CUDA stacks in
  thread dumps were a red herring (those threads were just waiting for a first frame that
  never came).
- **Fix:** `system_tray = disabled` in sunshine.conf **and** export a valid
  `DBUS_SESSION_BUS_ADDRESS` into Sunshine's environment.

### 2.2 NVENC hard-hangs the host

- **Symptom:** at NVENC session start the machine vanishes from the network (ARP INCOMPLETE,
  ping 100 % loss), WoL dead; only a physical power cycle helps. Reproduced twice.
- **Cause:** unresolved (driver 615-era NVIDIA + wayland dmabuf/CUDA path suspected; also
  possibly PSU trip). Journal shows a clean shutdown in one case (someone pressed the button).
- **Fix:** never use nvenc in this setup. Encode with `encoder = vaapi` on the Intel iGPU
  (`adapter_name` = Intel render node). Keep `sw_preset`/`min_threads` as software fallback.
- Same machine runs GLX games fine on the NVIDIA card with
  `__GLX_VENDOR_LIBRARY_NAME=nvidia` exported in **both** units (sway renders via EGL, so
  it is unaffected; Sunshine's own EGL is pinned to Mesa via
  `__EGL_VENDOR_LIBRARY_FILENAMES=50_mesa.json` for the dmabuf import).

### 2.3 Encoder choice and bitrate behavior (VAAPI)

- Intel VAAPI path uses VBR with single-frame VBV and honestly follows the client bitrate
  (measured: 10 Mbit requested ≈ 6.5 actual on a static desktop).
- "Quality got worse" complaints are almost always client-side bitrate/resolution, not the
  encoder. HEVC (`hevc_vaapi`) is noticeably sharper at the same bitrate; the codec is
  chosen per session by the client, no server restart needed.
- 1080p60 on an HD 530: VECS 17–23 %, GPU package ~2 W. The iGPU is nowhere near the limit.
- AV1 is impossible on HD 5xx (probe finds no AV1 encoder).

### 2.4 Software-encoder fallback

- x264 at 1080p60 starves a 4-core CPU (stutter/black bars under load). If you must:
  `sw_preset = ultrafast`, `min_threads = 4`, 1080p30 or 720p60.

## 3. Headless session plumbing

### 3.1 Hyprland cannot run here

- aquamarine (Hyprland's backend) requires a logind/seatd session with DRM: sessionless
  start fails with `CBackend::create() failed!`. Only wlroots compositors run without a
  seat — hence headless sway.

### 3.2 sway dies silently ~10 s after start

- **Cause:** without an active session, the VT is not activated; libseat gives up.
- **Fix:** `Environment=LIBSEAT_BACKEND=noop` in the sway unit (the unit runs as a system
  service with `User=`, `PAMName=login`, `TTYPath=/dev/ttyX`). Without it sway opens, then
  silently exits.

### 3.3 Static desktop = no first frame (damage starvation)

- **Symptom:** capture pipeline healthy (grim works), but the stream video thread waits
  forever for the first frame.
- **Cause:** Sunshine's wlgrab requests frames with damage; a headless desktop with
  invisible bar/static wallpaper never damages.
- **Fix:** visible sway bar with a 1 Hz clock (`server/scripts/ticker.sh`). Verify damage
  by two `grim` screenshots 2 s apart having different checksums.

### 3.4 Zombie sway/sunshine after restarts

- **Symptom:** after `systemctl restart sway-sunshine`, new sunshine can't bind port 48010,
  or starts against a stale wayland socket and probes all encoders in 400 ms each
  ("no display").
- **Cause:** `KillMode=process` (chosen so games survive sunshine restarts) leaves
  sway/sunshine orphaned on unit stop; a SIGKILLed sway leaves a wayland socket file whose
  `.lock` is free, so a fresh socket number gets delayed and scripts may grab the stale one.
- **Fix:** the full restart ritual (`stream-restart`) + `run-sunshine.sh` readiness gate:
  a wayland socket counts as live only if its `.lock` **cannot** be flocked (lock held by a
  living sway) AND sway IPC reports `HEADLESS-1`.

### 3.5 Boot ordering cycle silently disables the stream service

- **Symptom:** after reboot sway runs but Sunshine is not up; client sees the host offline.
  Nothing in `systemctl status` — look in `journalctl -u graphical.target` for
  "Job … deleted to break ordering cycle".
- **Cause:** `After=graphical.target` on the sway unit + sunshine unit `WantedBy=graphical.target`
  creates a cycle; systemd deletes one job silently. Manual start works — the bug only
  shows at boot.
- **Fix:** no `After=graphical.target` on the sway unit; units linked only to each other.

### 3.6 Boot race: PAM "System is booting up"

- sway-sunshine with `PAMName=login` may start before boot completes → PAM failure →
  `Restart=on-failure` brings it back in 5 s. Cosmetic; if it bothers you, add an
  ExecStartPre wait.

### 3.7 Xwayland display discovery

- Xwayland under the headless session is **lazy**: the socket file may exist while no
  Xwayland process runs; the first X client revives it. Don't treat a missing Xwayland
  process as breakage.
- Find the right display by **socket owner uid**, not by name (user renames break name
  matching): see `run-sunshine.sh`.

### 3.8 Renaming the remote user

- `usermod` refuses while any process of the user runs; the user manager
  (`user@<uid>.service`, pipewire/wireplumber/dbus) survives stream restarts. Order:
  stop stream stack → stop `user@<uid>.service` → kill leftovers → disable old linger →
  usermod → re-enable linger. uid unchanged keeps all env paths valid.

## 4. Clients and misc

- **Moonlight CLI tile mapping is unreliable**: streaming by app *name* may silently launch
  the default tile; numeric indexes do not match `apps.json` order. Verify actual launches
  via `journalctl -u sunshine-stream | grep Executing`.
- **Sunshine version churn**: builds differ wildly in behavior (device naming changed
  between builds: `libvirtualhid_…` vs `*_passthrough`). Pin the version (`IgnorePkg`) and
  re-check identifiers after any update — sway config, kcminputrc and the isolate helper
  all match on names.
- **Clipboard bridge:** `wl-copy` daemonizes and holds the SSH stdout open — redirect all
  output or the SSH call hangs; klipper needs ~1 s between set and get; `sshpass` with
  stdin-redirect hangs (pty conflict) — use key auth.
- **faillock:** 3 wrong sudo attempts lock the admin user for ALL auth including SSH
  (~20 min, and probes reset the timer). Do not brute-force.
- **Encoding host starvation** (pre-iGPU era): stutter/black bars under load = encoder CPU
  starvation, check `load average` and per-process CPU, not the capture (reinit counter 0
  = capture clean, network clean).
