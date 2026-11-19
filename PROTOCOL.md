# Petzl NAO+ Bluetooth protocol

Notes on how the NAO+ headlamp talks over Bluetooth Low Energy, worked out from the official Android app (MyPetzl Light 0.405) for interoperability. Everything here is what Beam uses; the Swift code in `Beam/Protocol/` is the reference implementation.

The REACTIK+ uses nearly the same protocol with different byte order. Beam only supports the NAO+.

## Services and characteristics

All three services are custom (base `…-11e4-b116-123b93f75cba`).

| Service | Service UUID | Write | Notify |
|---|---|---|---|
| Security | `13172bf6-8ab6-11e4-b116-123b93f75cba` | `131731d2-8ab6-11e4-b116-123b93f75cba` | `1317304c-8ab6-11e4-b116-123b93f75cba` |
| Light | `09b6b382-7b08-11e4-b116-123b93f75cba` | `09b6b5da-7b08-11e4-b116-123b93f75cba` | `09b6b72e-7b08-11e4-b116-123b93f75cba` |
| Battery | `68866e2a-7b08-11e4-b116-123b93f75cba` | `68867230-7b08-11e4-b116-123b93f75cba` | `6886738e-7b08-11e4-b116-123b93f75cba` |

- Writes use "with response", at most 20 bytes each.
- Send one command at a time and wait for its reply before sending the next.

## Finding the lamp

The advertisement carries manufacturer data starting with `96 02` (company ID 0x0296), followed by a 2-byte firmware ID (FID), little-endian. NAO+ FIDs: `1A0D`, `1A2D`, `0D1A`, `1A2C`.

## Connecting

1. Connect and discover the three services.
2. Enable notifications one at a time: Security, then Light, then Battery.
3. Write the key `50 65 74 7A 6C 5F 33 38 39 32 30 5F` (ASCII `Petzl_38920_`) to the Security write characteristic.
4. The lamp answers on the Security notify characteristic:
   - `AA`: paired, ready.
   - `A5`: first pairing. The user must briefly press the lamp's button; the lamp then answers `AA`. Beam resends the key every 3 seconds while it waits.

## Frames

A frame is an opcode byte, a parameter byte, then data. The reply repeats the first two bytes, which is how a reply is matched to its request.

| Frame | Meaning |
|---|---|
| `73 pp` | Read parameter `pp` (Light) |
| `74 pp …` | Write parameter `pp` (Light) |
| `20 pp` | Read battery parameter (Battery) |
| `65 01` | Apply the profile just written |
| `71 01` / `71 00` | Start / stop live adjustment |
| `75 …` | SOS message in Morse (reply `F5`) |
| `76 00` | Stop SOS (reply `F6`) |

On the NAO+, 16-bit values in variants are **big-endian**; battery counters are **little-endian**.

### Parameters

| `pp` | Content |
|---|---|
| `00` | Lamp name (UTF-8) |
| `03` | Current mode (1 byte) + red mode (1 byte) |
| `08` | Firmware: FID (2), version, revision, bootloader version, revision |
| `10` | Device: serial number (4), product type (1), … |
| `20` `21` `22` | Profile name, parts 1–3 |
| `23` `24` `25` | Reactive variant 1–3 |
| `26` `27` `28` | Steady variant 1–3 |

Battery characteristic: `20 03` battery info, `20 08` battery firmware.

### Current mode (`73 03`)

The first data byte, read as two hex digits: `00` off, `0n` reactive variant n, `1n` steady variant n (n a digit), `1B`/`1C` red light.

### Steady variant (18 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | narrow beam power (0–1000) |
| 2 | 2 | wide beam power (0–1000) |
| 4 | 2 | guaranteed run time (minutes) |
| 6 | 1 | behaviour (1–6) |
| 7 | 11 | zero |

### Reactive variant (18 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | behaviour |
| 1 | 1 | narrow beam start distance |
| 2 | 2 | narrow beam max |
| 4 | 2 | wide beam max |
| 6 | 2 | wide beam max when narrow is at max |
| 8 | 1 | reading threshold |
| 9 | 1 | zero |
| 10 | 2 | guaranteed run time (minutes) |
| 12 | 6 | zero |

An empty slot is 18 zero bytes.

### Profile name (3 × 18 bytes)

UTF-16 big-endian with a `FE FF` byte-order mark, padded with zeros. Parts 1 and 2 carry 18 bytes of text, part 3 carries 16 bytes, then `00` and a custom flag (0/1). About 25 characters fit.

### Battery (`20 03`, 14 bytes, little-endian)

Current charge counter (4), maximum counter (4), total charges (4), ageing (1), charge state (1). Level = current / maximum.

## Writing a profile

1. Name: `74 20`, `74 21`, `74 22`.
2. Steady variants: `74 26`, `74 27`, `74 28`.
3. Reactive variants: `74 23`, `74 24`, `74 25`.
4. `65 01`.
5. Read everything back to confirm.

## Red light

On the **Battery** write characteristic: `74 03`, then the current variant number as two decimal digits (`02` for variant 2), then `03` blink / `01` steady / `00` off, padded with zeros to 10 data bytes. Then read `73 03` on Light to confirm.

## SOS message

`75`, a count byte, then the message packed 2 bits per symbol, first symbol in the high bits:

- dot `00`, dash `01`, gap between letters `10`, gap between words `11`;
- if the bits don't fill a whole byte, add `11` and pad with `00`;
- the count is the number of symbols, including that final `11`.

"SOS" encodes as `75 0C 02 56 03`.

## Brightness from run time

For live adjustment the app turns a behaviour and a run time into beam powers. With `capacity = 2496 − (100 − ageing) × 26 − 140 − (minutes / 60) × 45` (mAh, `ageing` from the battery frame):

- Steady: `k = capacity / minutes × 60`; narrow = `round(k × 1000 / ((1 + f) × 1250))`, wide = `round(f × narrow)`, capped at 1000, with f = 0.5, 0.8, 2.0, 3.333, 0 (wide only), 0.7 for behaviours 1–6.
- Reactive: `d = capacity / (minutes × 60) × 7.875`; narrow max = `round(d × 10⁶ / ((1 + f) × 1250))`, wide max = `round(narrow × f)`, with f = 1.0, 0.8, 1.4, 3.333, 0.7 for behaviours 1–5. The reactive formula gives much less light than the factory profiles for the same run time.

Allowed run times per behaviour are in `VariantCalculator.autonomyRange`.

## Not covered

Firmware updates (Nordic DFU for the lamp, a separate protocol for the battery). Getting them wrong can brick the lamp.
