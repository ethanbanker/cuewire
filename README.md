<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Cuewire app icon">
</p>

<h1 align="center">Cuewire</h1>

<p align="center">
  <strong>The missing cable between a Pioneer DDJ-FLX4 and AUTO/PILOT.</strong><br>
  Native macOS MIDI → OSC bridge with a live hardware surface, per-control mapping and feedback-aware routing.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-111827?style=flat-square&logo=swift&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-111827?style=flat-square">
  <img alt="Checks" src="https://img.shields.io/badge/checks-228%20passing-10b981?style=flat-square">
</p>

![Cuewire hardware surface](docs/images/surface.png)

Cuewire translates the DDJ-FLX4's MIDI notes, 14-bit faders and encoders into
AUTO/PILOT's OSC API, then folds AUTO/PILOT's feedback back into the controller:
button LEDs, motor-free fader pickup, and a live schematic of the hardware.

## Why Cuewire

AUTO/PILOT can learn a MIDI controller, but it cannot see the FLX4's 14-bit
fader pairs, shift layers, deck switching or the FLX4's single centre-detent
filter knob. Cuewire owns that translation:

- **14-bit precision** for tempo and channel faders, with a `0x2000` centre detent.
- **One-knob filter** split across AUTO/PILOT's low-pass `Filter1` and high-pass
  `Filter2`, exactly like rekordbox.
- **Deck A/B vs decks 1–4**, pads, loops, beat jump, browse encoder and shift layers.
- **Feedback-aware** toggles, LEDs and optional soft-takeover pickup.
- **OSC Mapping editor** for any MIDI note/CC, serial OSC controller or UDP OSC
  input, with routes discovered from the running AUTO/PILOT build.
- **Hub routing** to extra OSC destinations by address prefix.

## Install

Build from source (macOS 14+, Xcode command line tools):

```sh
git clone https://github.com/ethanbanker/cuewire.git
cd cuewire
./scripts/build-app.sh
open "dist/Cuewire.app"
```

The app starts the bridge automatically, puts a waveform icon in the menu bar,
and hides to the menu bar when its window closes.

## AUTO/PILOT setup

1. In AUTO/PILOT, **disable the FLX4's direct MIDI input** so actions are not applied twice.
2. Enable **OSC input**. Cuewire reads AUTO/PILOT's own settings on first launch
   (`osc.listenPort` → destination, `osc.feedbackPort` → feedback) and warns when
   the two disagree. **Settings → Use AUTO/PILOT ports** re-syncs them.
3. Keep **OSC feedback** enabled (about 30 Hz) and subscribe to all routes,
   including **TempoSlider**. Without deck/mixer subscriptions, CUE, learned
   toggles and pickup stay blocked and the log says why.
4. Leave Cuewire running while you play.

AUTO/PILOT accepts commands under `/AutoPilot/…` and publishes feedback under
`/Syndicate/…` in current builds. Cuewire sends `/AutoPilot/…`, folds either
namespace on the way back, and normalises serial commands from both.

## The surface

The window is a live schematic, not a static diagram: controls light up from the
engine and from AUTO/PILOT feedback, tempo is shown in semitones, and the mixers
follow the selected decks.

| Tempo | Filter | Mixer | Deck |
|---|---|---|---|
| 14-bit, centre detent, −12…+12 st readout | centre = neutral, left = low-pass, right = high-pass | trim, 3-band EQ, volume, meter, cue | pads, transport, loop, grid, browse |

## Mapping editor

![Cuewire OSC mapping editor](docs/images/mapping-editor.png)

**Bridge → OSC Mapping…** (⌘L) captures a control with Learn, then maps it to an
AUTO/PILOT route or any custom OSC address.

- **Trigger** — send `1` on press.
- **Momentary** — send `1` while held, `0` on release.
- **Toggle** — flip from confirmed AP feedback.
- **Absolute 0…1** — faders and knobs; learned FLX4 faders keep 14-bit precision.
- **Bipolar −1…+1** — tempo/filter-style controls.
- **Relative encoder** — signed deltas.
- **Passthrough** — forward an OSC input message unchanged.

Picking a route applies its natural mode, and Save upgrades a leftover Trigger on a
continuous route, so a fader can never be saved as a one-shot press.

Mappings live in `~/Library/Application Support/Cuewire/mappings.json` and override
the stock FLX4 map by control identity. Pre-1.0 files in the old `FLX Bridge`
folder migrate automatically.

![Cuewire settings](docs/images/settings.png)

## Serial OSC controller

Cuewire also accepts OSC over USB serial (ESP32-S3) with SLIP framing or newline
text, auto-detected. Short addresses are expanded:

```text
/Deck/1/PlayPause       → /AutoPilot/Deck/1/PlayPause
/Mixer/CH1/Volume       → /AutoPilot/Mixer/CH1/Volume
/Syndicate/Deck/1/Playing → /AutoPilot/Deck/1/Playing
```

When a serial mapping exists, its AUTO/PILOT feedback is mirrored back over the
serial link as `/AutoPilot/…` SLIP messages. Only mapped routes are mirrored, so
the controller does not receive all 293 feedback paths at 30 Hz.

## Stock FLX4 map

| Control | MIDI | AUTO/PILOT |
|---|---|---|
| Play / Cue | CH 0/1 note 11 / 12 | `Deck/{deck}/PlayPause`, `Cue` |
| Sync / Master | CH 0/1 note 88 / 92 | `TempoSync`, `TempoMaster` |
| In / Out / 4-beat | CH 0/1 note 16 / 17 / 77 | `LoopIn`, `LoopOut`, `Loop` |
| Tempo fader | CH 0/1 CC 0 (14-bit) | `TempoSlider`, bipolar, + at bottom |
| Channel fader / trim | CH 0/1 CC 19 / 4 | `Mixer/CH{D}/Volume`, `Trim` |
| High / Mid / Low | CH 0/1 CC 7 / 11 / 15 | `Mixer/CH{D}/EQ/*` |
| Filter | CH 6 CC 23 / 24 | left half `Filter1`, right half `Filter2`, centre 0/0 |
| Master / headphone | CH 6 CC 8 / 13 / 12 | `Header/MasterVolume`, `CueVolume`, `CueMix` |
| Deck select | CH 6 note 104 / 122 | 1↔3, 2↔4 |
| Browse | CH 6 CC 64 | `Browser/Up`, `Browser/Down` |
| Load | CH 6 note 70 / 71 | `Browser/L{deck}` |

Faders and knobs are absolute by default, like rekordbox. **Settings → Soft
takeover** makes them wait for AUTO/PILOT's confirmed value instead.

## Architecture

```
DDJ-FLX4 ──CoreMIDI──▶ MIDITransport ─▶ FLX4Engine ─▶ OSCTransport ─▶ AUTO/PILOT
                                             ▲                          │
                                             └──── feedback (UDP) ◀─────┘
Serial / UDP OSC ─────────▶ learn + user mappings ─────────▶ hub destinations
```

`BridgeCore` is UI-free and covered by the `BridgeChecks` executable; the AppKit
app only observes `BridgeService` snapshots.

## Development

```sh
swift build
swift run BridgeChecks        # 228 checks
./scripts/build-app.sh        # dist/Cuewire.app
swift scripts/make-icon.swift /tmp/icon.png
```

Verified behaviour includes 14-bit fader precision and direction, centre-detent
filter splitting, learned trigger/momentary/absolute/bipolar/toggle/relative
mappings, feedback validation, OSC serialization and SLIP framing, hot-plug MIDI,
hub routing, settings persistence and mapping-mode defaults.

## Limits

- MIDI Learn listens to the FLX4 (or a virtual source named like one); other
  controllers are not opened.
- Toggles require confirmed AUTO/PILOT feedback.
- The filter split assumes AP's **LP/HP** filter type.
- The app is ad-hoc signed; Gatekeeper may ask for confirmation on first launch.
- Unofficial project. Not affiliated with AlphaTheta/Pioneer DJ or AUTO/PILOT.

## License

MIT — see [LICENSE](LICENSE).
