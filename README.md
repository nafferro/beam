# Beam

An unofficial iPhone app for the Petzl NAO+ headlamp.

Petzl's MyPetzl Light app only runs on Android, so I wrote this one to control my NAO+ from an iPhone. It talks to the lamp over Bluetooth with the same protocol as the Android app. I worked the protocol out from that app so the two devices could work together; it's documented in [PROTOCOL.md](PROTOCOL.md).

> **Not affiliated with Petzl.** Petzl, NAO and REACTIK are trademarks of Petzl. This project contains no Petzl code, images or text. It's a personal project, offered as is, with no warranty.
>
> **Don't rely on it for your safety.** That includes the SOS feature. Using an unofficial app could change your lamp's settings in ways you don't expect; you do so at your own risk.

## What it does

- **Connects to the lamp.** It finds the NAO+, pairs with it (the first time you press the lamp's button) and reconnects on its own after that.
- **Shows the battery and the current mode.** Reactive, steady, red or off.
- **Writes a profile to the lamp.** Mountaineering, Bivouac, Multi-activity, Trail running, Trekking and Mountain biking.
- **Adjusts the light live.** Move a slider and the lamp changes its run time and brightness for the mode it's in.
- **Red light.** Steady, blinking or off.
- **SOS message.** Type a message and the lamp flashes it in Morse code.

It doesn't update the lamp's firmware, on purpose. A failed update can brick the lamp.

## Requirements

- A Mac with Xcode (built with Xcode 27).
- An iPhone on iOS 18 or later, and a NAO+.
- An Apple account to sign the app. A free account works, but the app stops opening after 7 days and you have to install it again.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml`.

## Install it on your iPhone

```bash
brew install xcodegen
```

```bash
xcodegen generate && open Beam.xcodeproj
```

Then:

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your Apple team ID and `PRODUCT_BUNDLE_IDENTIFIER` to an identifier of your own, and run `xcodegen generate` again. You can also pick the team in Xcode under **Beam → Signing & Capabilities**, but it's lost the next time the project is generated.
2. Connect the iPhone, choose it at the top of the Xcode window and press **Run** (⌘R).
3. On a free account, trust the developer on the iPhone in **Settings → General → VPN & Device Management**.

The first time it opens, allow Bluetooth, turn the lamp on and tap it in the list. When the app asks, press the lamp's button once.

## Project layout

```
project.yml              XcodeGen spec (edit this, not the .xcodeproj)
Beam/
  App/                   app entry point
  BLE/LampManager.swift  scanning, pairing, command queue, state
  Protocol/              frames, parsing, Morse, brightness formulas, profiles
  Views/                 SwiftUI screens and the shared style (Theme.swift)
  Resources/             factory profiles (JSON), icons, accent colour
BeamTests/               protocol tests
icon/make_icon.py        draws the app icon (SVG)
PROTOCOL.md              Bluetooth protocol notes
```

The protocol code (`Protocol/`) doesn't touch Bluetooth, so you can test it without a lamp. `LampManager` does the Bluetooth part: it sends one command at a time and waits for the lamp to answer before it sends the next.

## Tests

```bash
xcodebuild test -project Beam.xcodeproj -scheme Beam -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Use any simulator you have installed (`xcrun simctl list devices available`). The tests check the frames the app sends, how it reads the lamp's replies, the Morse encoding and the brightness formulas against the values in the factory profiles.

## Changing the icon

`icon/make_icon.py` writes three SVGs (light, dark and tinted). Render them at 1024×1024 into the asset catalog:

```bash
cd icon && python3 make_icon.py . && for n in light dark tinted; do rsvg-convert -w 1024 -h 1024 icon-$n.svg -o ../Beam/Resources/Assets.xcassets/AppIcon.appiconset/icon-$n.png; done
```

`rsvg-convert` comes with `brew install librsvg`.

## Known limits

- Tested with one NAO+. The REACTIK+ uses almost the same protocol, but Beam doesn't support it.
- In reactive mode, live adjustment uses the original app's formula, which gives less light than the factory profiles for the same run time. Steady mode doesn't have this problem.
- If something doesn't work, open ⋯ → Bluetooth log. It shows every frame sent and received, and you can share it from there.

## License

MIT. See [LICENSE](LICENSE).
