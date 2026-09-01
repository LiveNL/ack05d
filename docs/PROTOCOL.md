# ACK05 protocol notes

How `ack05d` talks to the [XPPen ACK05](https://www.xp-pen.com/product/ack05-wireless-shortcut-remote.html)
over Bluetooth LE, and what was reverse-engineered
to get there. If you only want to use the driver, the [README](../README.md) is enough;
this is for anyone extending it or porting it.

## Two device behaviours

The ACK05 has two modes:

- **Default HID mode** — keys emit fixed keystrokes (Ctrl+Z, Ctrl+S, …). Usable through
  a remapper, but the keystrokes fire for real if the remapper is not running, and the
  dial centre button emits nothing at all.
- **Vendor / bitmask mode** — keys, dial rotation *and* the dial centre button arrive as
  one bitmask frame on a private GATT service. This is what the official driver uses, and
  what `ack05d` speaks.

## The GATT service

Vendor mode lives on a proprietary GATT service `FFE0`, not the HID profile:

| Characteristic | Use |
| --- | --- |
| `0001` | write — command channel |
| `0002` | notify — acknowledgements; **must be subscribed or `0003` never streams** |
| `0003` | notify — `0xf0` state frames, `0xf2` battery, `0xf8` reconnect |

## Enabling vendor mode

On the Telink hardware revision (identifiable by its Telink OTA service
`00010203-0405-0607-0809-0A0B0C0D1912`) the working handshake is:

1. subscribe `0002`, then `0003`
2. wait for the first battery heartbeat (proves the link is live)
3. write `02 b0 04 00 00 00 00 00 00 00` to `0001` **without response**

`ack05d` does exactly this, and if no state frame arrives within a few seconds it falls
back to replaying the official driver's full seven-packet sequence — `02 b0 04`,
`80 06 f1`, `02 b8 04`, `80 06 64`, `80 06 04`, `80 06 03`, `80 06 05` (with response,
500 µs gaps) — for units that need it. The `80 06 …` packets are the USB
string-descriptor unlock tunnelled over GATT.

The device uses a BLE address that rotates on power-up, so it is always found by service
UUID, never a remembered address, and vendor mode is re-asserted on every `0xf8`
reconnect event.

## Frame format

`02 f0 <byte2> <byte3> 00 00 00 <byte7> 00 00` — 10 bytes over BLE, 12 over USB:

- `byte2` bits → BTN_1..BTN_8
- `byte3` bit 0 → BTN_9, bit 1 → BTN_10, bit 2 → DIAL (the dial centre button)
- `byte7` bit 0 → wheel CW, bit 1 → wheel CCW
- `02 f2 <pct> <charging>` → battery
- `02 f8 …` → reconnect

Frames carry full state; press/release is derived by diffing consecutive frames. The
button-to-bit order follows the hardware matrix, not the silkscreen — run
`ack05d --identify` to map `BTN_n` to the physical keys on your unit.

## Transports

`ack05d` implements **Bluetooth LE only**. Over a USB-C cable or the bundled 2.4 GHz
dongle the ACK05 enumerates as USB HID instead, exposing the vendor collection on HID
usage page `0xFF0A` — reachable via `IOHIDManager` with the same `02 b0 04` enable
report, but not yet implemented here. The Linux kernel HID-BPF driver
(`drivers/hid/bpf/progs/XPPen__ACK05.bpf.c`, since 6.15) documents that path in full.

## Hardware revisions

Two revisions exist. The **A** revision uses a Nordic nRF52833; the **B** revision (this
one) uses a Telink SoC, identifiable by the Telink OTA service UUID above. Recipes from
other open-source projects that target the A revision, or that assume the device was left
in vendor mode by the official driver, do not reproduce on a B unit without the handshake
above.

## Credit

Protocol groundwork across the community:

- [Linux kernel HID-BPF driver](https://github.com/torvalds/linux/blob/master/drivers/hid/bpf/progs/XPPen__ACK05.bpf.c) — `XPPen__ACK05.bpf.c` (since 6.15): USB enable report and frame layout
- [RomainGehrig/XPPen-ACK05-driver](https://github.com/RomainGehrig/XPPen-ACK05-driver) — Python, Linux; documented the BLE `FFE0` channel and the `0002`-before-`0003` requirement
- [Jayphen/xp-pen](https://github.com/Jayphen/xp-pen) — Swift, macOS CoreBluetooth reference
- [MarSik/kymars-xppen-ack05](https://github.com/MarSik/kymars-xppen-ack05) — Rust, USB; frame decode
- [MartinSadovy/xppen-ack05](https://github.com/MartinSadovy/xppen-ack05) — Swift, macOS; documented the BLE HID path's limits
- [46slv/ACK05-Enhanced](https://github.com/46slv/ACK05-Enhanced) — C#, Windows; hardware capture of the dial button

This driver adds the verified BLE handshake for the Telink revision on macOS: subscribe
`0002` then `0003`, write the enable report **without response** after the first
heartbeat, with the official 7-packet sequence as fallback.
