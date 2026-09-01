<p align="center">
  <img src="assets/hero.png" alt="ack05d — XPPen ACK05 shortcut remote driver for macOS" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.7%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.7+">
  <img src="https://img.shields.io/badge/transport-Bluetooth%20LE-0a84ff" alt="Bluetooth LE">
  <img src="https://img.shields.io/badge/license-MIT-12cbb4" alt="MIT">
</p>

# ack05d — XPPen ACK05 Shortcut Remote driver for macOS (Bluetooth LE)

A community-built userspace driver for the **[XPPen ACK05 wireless shortcut remote](https://www.xp-pen.com/product/ack05-wireless-shortcut-remote.html)**
(also sold as XP-Pen ACK05 / "Shortcut Remote" / Mini Keydial) on macOS, Apple Silicon
and Intel. It talks to the remote directly over Bluetooth LE, so you can bind every key
to a shell command, drive configurable wheel modes, and use the dial centre button —
**without the official XPPen PenTablet driver**.

Built because the official macOS driver kept crashing for me on a multi-display setup,
and because no open-source project drove this remote over Bluetooth on the newer Telink
hardware revision. `ack05d` does.

## Features

- **All 11 buttons + the dial**, including the dial centre button the official driver
  hides and keystroke remappers can't reach.
- **Bind anything** — each key runs a shell command: launch an app, switch a tmux
  session, run a script.
- **Configurable wheel modes** — the dial cycles through modes you define (e.g. volume,
  window switching, zoom); the wheel drives the active one.
- **Native macOS HUD** — volume and brightness show the real system overlay, not a
  homegrown popup.
- **No kext, no root** — a small signed launch agent; Bluetooth only.
- **Optional on-screen overlay** showing which action fired, plus connect/ready status
  and battery level.

## Install

```sh
git clone https://github.com/LiveNL/ack05d.git
cd ack05d
./install.sh
```

That builds the driver, installs it as a login agent (auto-starts, auto-restarts), builds
the optional `hud` overlay into `~/.local/bin`, and seeds `~/.config/ack05d/config.json`
from the example if you don't have one yet.

Before the first run, pair the remote once under **System Settings → Bluetooth** (it
shows up as "Shortcut Remote"). If you had XPPen's own driver installed, quit or
uninstall it — two drivers can't share the remote.

> Actions that synthesize input — `mediaKey` (native volume/brightness HUD) and
> `keystroke` — need **Accessibility**: add "ACK05 Remote Community Driver" under
> **System Settings → Privacy & Security → Accessibility**. Launching apps, shell
> commands and the wheel itself need no permission. macOS asks for **Bluetooth** access
> the first time; allow it. Run `./make-signing-cert.sh` once so the Accessibility grant
> survives rebuilds (it installs a local self-signed signing certificate — see the script).

## Configure

Your mapping lives in `~/.config/ack05d/config.json` (seeded from
[`config.example.json`](config.example.json)). Learn which physical key is which — stop
the agent first, or every identify press also fires your configured action:

```sh
launchctl bootout gui/$(id -u)/io.github.livenl.ack05d
./.build/release/ack05d --identify     # press keys; prints BTN_1..BTN_10 and DIAL
./install.sh                            # restarts the agent
```

<p align="center">
  <img src="assets/buttons.svg" alt="ACK05 button layout with the names ack05d reports" width="620">
</p>

<p align="center"><sub>Physical layout, labelled with XPPen's K-numbers. <code>--identify</code> tells you which <code>BTN_n</code> each key reports on your unit (on mine K1→BTN_1 … K10→BTN_10).</sub></p>

```json
{
  "overlayCommand": "~/.local/bin/hud",
  "buttons": {
    "BTN_1": { "type": "shell", "command": "open -a Safari", "label": "Safari" },
    "DIAL":  { "type": "wheelModeCycle" }
  },
  "wheelModes": [
    {
      "name": "volume",
      "cw":  { "type": "mediaKey", "key": "volume_up" },
      "ccw": { "type": "mediaKey", "key": "volume_down" }
    },
    {
      "name": "zoom",
      "cw":  { "type": "keystroke", "keystroke": "cmd+=" },
      "ccw": { "type": "keystroke", "keystroke": "cmd+-" }
    }
  ]
}
```

### Action types

| Type | Does | Fields |
| --- | --- | --- |
| `shell` | Run a shell command | `command`, `label` |
| `mediaKey` | Post a system media key (native HUD) | `key` — `volume_up/down`, `mute`, `brightness_up/down`, `play_pause`, `next`, `previous` |
| `keystroke` | Synthesize a key chord | `keystroke` — e.g. `cmd+=`, `shift+cmd+4`; modifiers `cmd`/`opt`/`ctrl`/`shift`, keys a–z, 0–9, `=`, `-`, `[`, `]`, `space`, `return`, `tab`, `escape`, `delete`, arrows (US-ANSI key codes) |
| `battery` | Show the remote's battery level in the overlay | `label` (optional) |
| `wheelModeCycle` | Advance to the next wheel mode | — |
| `none` | Explicitly unbound | — |

`overlayCommand` is any program called as `<cmd> <label> <seconds>`; the bundled `hud`
shows a single, fixed-width overlay. Add `"silent": true` to an action whose command
draws its own overlay. Edit the file and the daemon hot-reloads it within ~1.5s — no
restart needed.

`connectingLabel` shows once the Bluetooth link is up and the handshake is running, and
is replaced by `connectedLabel` (with the battery level) the moment the remote is ready —
so you get a connecting → ready confirmation on boot/wake. `disconnectedLabel` shows when
the link drops. Set any to `""` to suppress; defaults are `"ACK05 connecting…"`,
`"ACK05 ready"` and silent.

<p align="center">
  <img src="assets/hud.png" alt="ack05d overlay showing an action label and the active wheel mode" width="560">
</p>

<p align="center"><sub>The optional <code>hud</code> overlay (two example messages shown) — one panel that refreshes as you press keys.</sub></p>

### CLI

```text
ack05d                    run with ~/.config/ack05d/config.json
ack05d --config PATH      use another config file
ack05d --identify         print each button/wheel event by name; runs no actions
ack05d --debug            log every wheel event and battery heartbeat
```

`ACK05D_IDENTIFY_OVERLAY=~/.local/bin/hud ack05d --identify` also shows each name on screen.

## Requirements

- macOS 13 or newer, Apple Silicon or Intel
- Bluetooth LE; the remote paired in System Settings → Bluetooth
- Xcode command-line tools (`xcode-select --install`) to build
- Tested on the Telink ("ACK05-B") hardware revision. The earlier Nordic ("ACK05-A")
  revision is untested — see [`docs/PROTOCOL.md`](docs/PROTOCOL.md#hardware-revisions).
  USB cable and the 2.4 GHz dongle are not supported (Bluetooth only).

## Troubleshooting

- **Log**: `tail -f ~/Library/Logs/ack05d.log`. A healthy start reads `connected` →
  `remote ready (NN%)`.
- **Status / restart**: `launchctl print gui/$(id -u)/io.github.livenl.ack05d`,
  `launchctl kickstart -k gui/$(id -u)/io.github.livenl.ack05d`.
- **"Bluetooth access denied"** in the log: allow the app under System Settings →
  Privacy & Security → Bluetooth.
- **Stuck on "connecting…"**: power-cycle the remote (its Bluetooth address rotates on
  power-up; the driver rescans automatically).
- **Keys type Ctrl+Z / Ctrl+S into apps**: the driver isn't running — in its factory mode
  the remote sends plain keystrokes. Check the log and restart the agent.
- **Volume/zoom does nothing**: the app isn't Accessibility-trusted, or you rebuilt
  without `make-signing-cert.sh` and the grant was reset — re-add it.

Reporting a bug? Include your macOS version, the hardware revision if you know it, and
the last ~50 lines of the log.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/io.github.livenl.ack05d
rm -f ~/Library/LaunchAgents/io.github.livenl.ack05d.plist ~/.local/bin/hud ~/Library/Logs/ack05d.log
rm -rf "$HOME/Applications/ACK05 Remote Community Driver.app" ~/.config/ack05d
```

Then remove the entry under Privacy & Security → Accessibility, and (if you created it)
the `ack05d-signing` certificate in Keychain Access.

## How it works

`ack05d` puts the remote into its vendor/bitmask mode over a private GATT service and
decodes the button frames — the same channel the official driver uses. The full
handshake, frame format, hardware-revision notes and credits are in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md).

Bluetooth LE is the only implemented transport; USB cable / 2.4 GHz dongle is documented
there but not yet built.

## Disclaimer

`ack05d` is an independent, unofficial project and is **not affiliated with, authorized
or endorsed by XPPen or Hanvon Ugee**. "XPPen" and "ACK05" are trademarks of their
respective owners, used here only to describe the hardware this driver interoperates
with. It ships **no XPPen code, firmware or assets** — it is a clean-room interoperability
implementation built from public sources and independent observation of the device's
own protocol. See [`NOTICE`](NOTICE).

## License

MIT — see [`LICENSE`](LICENSE).
