# ack05d

A small userspace driver for the **XPPen ACK05 "Shortcut Remote"** on macOS, over
**Bluetooth LE** — no XPPen driver required. Each key runs a shell command of your
choosing; the dial wheel drives configurable modes; the dial centre button works.

Built because the official XPPen macOS driver (a Qt app) crashes on multi-display
setups, and because no existing open-source project drives this remote over Bluetooth
on the Telink hardware revision.

## Why this exists / how it differs

The ACK05 has two behaviours:

- **Default HID mode** — keys emit fixed keystrokes (Ctrl+Z, Ctrl+S, …). Usable through
  a remapper, but the keystrokes fire for real if the remapper is not running, and the
  dial centre button emits nothing.
- **Vendor/bitmask mode** — keys, dial rotation *and* the dial centre button arrive as
  one bitmask frame on a private GATT service. This is what the official driver uses,
  and what `ack05d` speaks.

### Bluetooth vendor mode — the part that was unsolved

The device exposes a proprietary GATT service `FFE0`:

| Characteristic | Use |
| --- | --- |
| `0001` | write — command channel |
| `0002` | notify — acknowledgements; **must be subscribed or `0003` never streams** |
| `0003` | notify — `0xf0` state frames, `0xf2` battery, `0xf8` reconnect |

On the Telink hardware revision (identifiable by its Telink OTA service
`00010203-0405-0607-0809-0A0B0C0D1912`), the working handshake is:

1. subscribe `0002`, then `0003`
2. wait for the first battery heartbeat (proves the link is live)
3. write `02 b0 04 00 00 00 00 00 00 00` to `0001` **without response**

`ack05d` does this automatically, and falls back to replaying the official driver's
full seven-packet sequence (`02 b0 04`, `80 06 f1`, `02 b8 04`, `80 06 64/04/03/05`,
with-response, 500 µs gaps) if no state frame arrives — for units that need it.

The device uses a BLE address that rotates on power-up, so it is always found by
service UUID, and vendor mode is re-asserted on every reconnect.

## Frame format

`02 f0 <byte2> <byte3> 00 00 00 <byte7> 00 00` (10 bytes over BLE, 12 over USB):

- `byte2` bits → BTN_1..BTN_8, `byte3` bits 0..1 → BTN_9/BTN_10, `byte3` bit 2 → DIAL
- `byte7` bit 0 → wheel CW, bit 1 → wheel CCW
- `02 f2 <pct> <charging>` battery; `02 f8 …` reconnect

Frames are full-state; press/release is derived by diffing.

## Build & run

```sh
swift build -c release
./.build/release/ack05d --identify     # print each button by name; runs nothing
./.build/release/ack05d                 # run using ~/.config/ack05d/config.json
```

`--identify` set `ACK05D_IDENTIFY_OVERLAY=/path/to/overlay` to also show each button
name on screen.

## Config

`~/.config/ack05d/config.json` (or `$XDG_CONFIG_HOME/ack05d/config.json`). See
`config.example.json`. Button names are `BTN_1`..`BTN_10` and `DIAL` — run
`--identify` once to learn which physical key is which on your unit.

Action types: `shell` (run `command`, show `label`), `mediaKey` (post a system media
key — `volume_up`/`volume_down`/`mute`/`brightness_up`/`brightness_down`/`play_pause`/
`next`/`previous` — raising the native macOS HUD), `wheelModeCycle` (advance the wheel
mode), `none` (unbound). `overlayCommand` is an optional program called as
`<cmd> <label> <seconds>` for an on-screen HUD.

`mediaKey` posts events via CGEvent, which requires the daemon to be
**Accessibility-trusted**. Run it from an `.app` bundle and add that bundle under
System Settings → Privacy & Security → Accessibility. Re-signing the bundle (any
rebuild that changes the binary) invalidates the grant, so re-add it after a rebuild.

## Autostart

Copy `launchd/nl.livenl.ack05d.plist.template` to
`~/Library/LaunchAgents/`, replace `@BIN@` with the built binary path, then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/nl.livenl.ack05d.plist`.

## Transports

`ack05d` speaks **Bluetooth LE only** (GATT service `FFE0`). Over a USB-C cable or the
bundled 2.4 GHz dongle the ACK05 enumerates as USB HID instead, exposing the vendor
collection on HID usage page `0xFF0A` — reachable via `IOHIDManager` with the same
`02 b0 04` enable report, but **not yet implemented** here. The Linux kernel HID-BPF
driver documents that path in full if you want to add it. For now, use the remote over
Bluetooth.

## Requirements

- macOS 13+
- Bluetooth. Grant the binary (or its launching terminal) Bluetooth access on first run.

## License

MIT — see `LICENSE`.
