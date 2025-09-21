# Demo SIP Show

This repository ships `demo_sip_show.sh`, a Bash script that drives a complete SIP/Asterisk demonstration inside an LXD environment. It prepares an Asterisk PBX, configures SIP peers, launches monitoring terminals, and pilots PJSUA clients to showcase a guided call-center scenario followed by a bursty "hacker" mode.

![Demo walkthrough](sipdemoenglish.gif)

## Key Features

- **PBX bootstrap** – backs up `sip.conf` and `extensions.conf`, injects a temporary dialplan, provisions extensions, then reloads Asterisk.
- **Audio staging** – converts demo sounds from `.mp3` to `.wav`, assigns ring/connect/hangup roles, and synchronizes playback on host and containers.
- **Real-time dashboard** – tracks scenario progress, lists active channels (`core show channels`), SIP peers, and narrates each step (origin, destination, audio role, expected duration).
- **Guided scenario + stress mode** – runs a deterministic story (time service and cross-calls) and optionally fires configurable bursts to simulate attacks or high traffic.
- **Smart cleanup** – tears down lingering PJSUA/Asterisk sessions, clears loop state files, and reopens all terminal panes.

## Prerequisites

- Linux host with **LXD/LXC** and containers named `asterisk01`, `ua01`, `ua02` (defaults; override via env vars if needed).
- **PJSUA** clients installed inside user-agent containers.
- `ffmpeg`, `aplay`, and either `gnome-terminal` or `xterm` available on the host.
- Demo audio files stored in `sound/*.wav`.

## Tunable Variables

All variables ship with safe defaults and can be overridden at run time:

- `AST_CT`, `UAS`, `UA_PORTS`, `AST_EXT_BASE`, `AST_SVC_TIME`
- `SOUND_DIR`, `RING_SOUND`, `CONNECT_SOUND`, `HANG_SOUND`
- `SOUND_MIN_CALL_DURATION`, `SOUND_GUIDE_PAUSE`, `SOUND_BURST_PAUSE`, `SOUND_PLAYBACK_DELAY`, `SOUND_HANG_DELAY`
- `BUSY_DIR`, `BUSY_TIMEOUT`
- `BURST_MODE`, `LOOP_COUNT`, `CALL_BURST`, `BURST_INTERVAL_MS`

## Usage

```bash
./demo_sip_show.sh
```

What happens:
1. Required binaries (LXC/PJSUA/terminals) are detected.
2. Previous demo artefacts are cleaned up.
3. The Asterisk PBX and audio assets are staged.
4. Monitoring terminals (dashboard, logs, peers, Asterisk shells, UAs) are opened.
5. The guided scenario runs, followed by burst mode if enabled.

## Customising Audio

Drop `.mp3` files into `sound/`; the script converts them into `.wav` files and assigns them to roles. You can also point `RING_SOUND`, `CONNECT_SOUND`, and `HANG_SOUND` directly to existing WAV files.

## Logging

PJSUA call logs are written to `~/sip-tests` (configurable via `LOG_DIR`). Scenario progress is mirrored to `~/.sipdemo_current_step`, and burst state is tracked in `~/.sipdemo_loop_state`.

## Quick Troubleshooting

- **"unbound variable"** – run the script through Bash (the shebang already enforces Bash) and double-check audio variable overrides.
- **No audio playback** – confirm `aplay` is installed and sounds are readable.
- **Asterisk files unchanged** – ensure the `AST_CT` container exists and your user has permission to push files into it.

Happy demos!
