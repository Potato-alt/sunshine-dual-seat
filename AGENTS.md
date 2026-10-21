# AGENTS.md — conventions for AI agents on machines running sunshine-dual-seat

This file is for coding agents operating on a machine where this stack is (or will be)
installed. Follow these rules; they encode real incidents, not style preferences.

## Never do these

1. **Never enable or test the NVENC encoder** in `sunshine.conf` on this class of host.
   Starting an NVENC session has hard-hung the entire machine (network gone at ARP level,
   only a power cycle helps). The stream encodes on the Intel iGPU via `encoder = vaapi`.
2. **Never restart `sway-sunshine.service` while a client is connected.** Check first:
   `ss -tn | grep ':48010'` — no established connections = safe. A restart kills the
   streamed session and any game running in it.
3. **Never kill the local user's compositor** (kwin_wayland / plasmashell) to "fix" input
   or display issues. Local-session fixes must not require a session restart. If a config
   must be reloaded, prefer `busctl`/`qdbus` reconfigure paths listed in the runbook.
4. **Never fix input leakage by stripping udev properties** (`ID_INPUT` etc.) from the
   Sunshine virtual devices. wlroots enumerates only devices with `ID_INPUT`, so that kills
   input in the remote session too. Isolation happens at the consumer level — see
   `docs/gotchas.md` §1.
5. **Never "simplify" the restart to `systemctl restart sway-sunshine`.** Orphaned
   sway/sunshine processes survive the unit stop and hold the wayland socket and ports.
   Always use the full ritual in `server/scripts/stream-restart`.

## Before you change anything

- Read `docs/gotchas.md` for the subsystem you are touching.
- Confirm nobody is streaming: `ss -tn | grep ':48010'`.
- Confirm which sessions exist: `loginctl list-sessions` (local user on seat0, remote user
  has PAM sessions from `sway-sunshine.service`).
- If the local session is a **KDE Plasma Wayland** session, remember: KWin reads per-device
  input config **only from `kcminputrc`**, group path
  `[Libinput][vendor][product][device name with spaces]`, key **`Enabled`** (capital E —
  KConfig is case-sensitive). The `kwinrc` file is ignored for this purpose. See gotchas §1.

## Restart ritual (the only correct one)

```bash
systemctl stop sunshine-stream.service sway-sunshine.service
sleep 2
pkill -u @OPERATOR_USER@ -x sunshine
pkill -u @OPERATOR_USER@ -f "/usr/bin/sway --unsupported"
sleep 2
systemctl start sway-sunshine.service
# wait until passthrough devices reappear (up to ~10 s), then:
systemctl start sunshine-stream.service   # normally auto-started via Wants=
```

After a restart, virtual input devices are recreated: if a gamepad was connected, re-run
`server/scripts/sunshine-isolate-inputs` (as the local user) so the new devices are isolated.

## Verification mindset

Every change gets a measured verification, not a "looks fine":

- Video: real Moonlight stream decodes (`journalctl -u sunshine-stream` shows
  `Found H.264/HEVC encoder: *_vaapi`, no `Frame capture failed`).
- Input isolation: inject a synthetic event into a passthrough device as root
  (24-byte `struct input_event` write to `/dev/input/eventNN`) and measure that the local
  cursor does **not** move (read cursor pos via a KWin script writing `workspace.cursorPos`
  to the journal — klipper may not be installed). Beware: a human at the physical mouse
  contaminates this measurement.
- Audio: remote sink volume ≥100 % and `pactl` shows the null sink.

## Shell pitfalls on these hosts

- The admin user's login shell may be **fish**: always run remote automation as
  `ssh user@host 'bash -s' < script.sh`, never inline.
- `echo password | sudo -S tee file <<EOF` **eats the heredoc as the password** and writes
  an empty file. Stage files in `/tmp` (as the unprivileged user or via scp) and
  `sudo install -m …` them.
- `qdbus6` cannot introspect KWin's input-device objects; use
  `busctl --user … org.kde.KWin /org/kde/KWin/InputDevice/eventNN org.kde.KWin.InputDevice …`.
