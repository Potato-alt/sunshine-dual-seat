# sunshine-dual-seat

**Two independent desktop sessions on one Linux machine**: a local session for the person
sitting at the keyboard, and a headless Sway session streamed by [Sunshine](https://github.com/LizardByte/Sunshine)
to [Moonlight](https://moonlight-stream.org) clients — with the two sessions fully isolated
from each other's input, audio and GPU load.

This repository exists so that **coding agents** (and humans) can reproduce the setup
without rediscovering its landmines. The configuration files alone are worth little;
the knowledge is in [`docs/gotchas.md`](docs/gotchas.md) — every non-obvious failure mode
we hit, with symptoms, root causes and fixes.

Tested on CachyOS (Arch-based), October 2026. Versions known to work together are pinned
in [`docs/architecture.md`](docs/architecture.md#tested-versions).

```
┌────────────────────────── one machine ──────────────────────────┐
│                                                                 │
│  seat0 / tty1              headless (no seat, no monitor)       │
│  ┌──────────────────┐      ┌───────────────────────────────┐   │
│  │ local user       │      │ remote user (systemd unit)    │   │
│  │ Plasma Wayland   │      │ sway WLR_BACKENDS=headless    │   │
│  │ (KWin)           │      │   virtual output HEADLESS-1   │   │
│  └────────┬─────────┘      └──────────────┬────────────────┘   │
│           │                               │ capture (wlgrab)   │
│           │                          ┌────▼─────┐              │
│   monitor │                          │ Sunshine │  encode:     │
│           │                          │          │  VAAPI iGPU  │
│  physical │                          └────┬─────┘              │
│  kb/mouse │                        LAN ╱      ╲                │
│           │                  Moonlight╱        ╲ ingress:     │
│           ▼                            ▼         uinput ──► sway
│   sees ONLY its own               remote client   (isolated! see
│   devices + NOTHING               plays games     docs/gotchas.md)
│   from the stream                                      │
└─────────────────────────────────────────────────────────────────┘
```

## What you get

- Local desktop session stays fully usable while someone else streams and plays.
- Remote session renders in a **virtual monitor** (`HEADLESS-1`), resolution follows the client
  per-stream (`set-resolution.sh` via Sunshine prep-cmd).
- **Video encoding on the Intel iGPU** (VAAPI) — the discrete NVIDIA GPU stays free for games,
  and the streaming encoder costs ~2 W / a few % of the iGPU at 1080p60.
- **Input isolation both ways**: Sunshine's virtual devices are invisible to the local session
  (KWin/X11 rules) and physical devices are invisible to the remote session (sway input filters).
- Virtual audio sink for the stream (local users hear nothing from it).
- In-stream **Server Control** tile: volume, mouse sensitivity, logs, stream restart, reboot.
- Clipboard bridge client ↔ streamed session (optional, SSH-based).
- systemd units that survive reboots and crashes, with a zombie-proof startup gate.

## Layout

```
server/
  units/      systemd units (headless sway + sunshine)
  configs/    sway config, sunshine.conf, apps.json, pipewire null-sink
  scripts/    runtime scripts (startup gate, resolution, control menu, isolation…)
  xorg/       X11 InputClass + GPU-pinning snippets for SDDM/greeter sessions
  sudoers/    least-privilege entries for the in-stream control menu
  install.sh  parameterized installer (fills @VARS@, copies everything into place)
  verify.sh   post-install / post-reboot health check
client/       Moonlight-side helpers (wrapper, clipboard bridge)
docs/
  runbook.md        step-by-step install procedure with verification gates
  gotchas.md        every landmine we stepped on (read before debugging!)
  architecture.md   how the pieces fit, tested versions, design decisions
assets/fetch-icons.sh   downloads Moonlight tile art from Steam CDN
AGENTS.md     conventions for AI agents working on machines running this stack
```

## Quick start

An agent should follow [`docs/runbook.md`](docs/runbook.md) top to bottom — it is written
as a sequence of steps, each with an explicit **Gate** (a command and its expected output).
Do not skip gates; almost every failure we have seen came from an unverified assumption.

Minimal human path:

```bash
# 1. fill in the variables at the top of server/install.sh
# 2. run it on the server
sudo ./server/install.sh
# 3. verify
./server/verify.sh
# 4. pair Moonlight with the Sunshine web UI (https://<server>:47990) and stream
```

## Hardware expectations

- Any x86 machine with an **Intel iGPU (HD 5xx or newer)** for VAAPI encoding; a discrete
  NVIDIA GPU is optional and only used for OpenGL games. An AMD iGPU should work by pointing
  `adapter_name` at its render node (untested here).
- One monitor/seat for the local user; the remote session needs **no** display at all.

## Status

Working daily-driver on one machine since 2026-10; quirks are documented, not hidden.
PRs with portability fixes (AMD encode, other distros, Wayland-native local sessions other
than KDE) are welcome.

## License

[MIT](LICENSE)
