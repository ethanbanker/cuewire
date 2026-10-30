<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Cuewire app icon">
</p>

<h1 align="center">Cuewire</h1>

<p align="center">
  <strong>A controller-to-OSC router for macOS.</strong><br>
  Map any MIDI control, serial OSC message or UDP OSC input to any OSC API — one API or several at once.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-111827?style=flat-square&logo=swift&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-111827?style=flat-square">
  <img alt="Checks" src="https://img.shields.io/badge/checks-438%20passing-10b981?style=flat-square">
</p>

![Cuewire live controller surface](docs/images/surface.png)

Cuewire sits between your hardware and the software that speaks OSC. It opens
every MIDI source, receives OSC over UDP and USB serial, learns controls, and
routes each one to the OSC address you choose — including several destinations
in the same session.

DDJ-FLX4 and Syndicate are the first supported presets, not the boundary of the
product. The surface above is the live FLX4 view; the same engine maps a custom
pad grid, a fader bank, an ESP32 encoder or a DAW scene launcher just as well.

## What it does

- **Any OSC API, not one vendor.** Point Cuewire at any host and port, then map
  controls to any address. The route picker is pre-filled from Syndicate when it
  is running, but custom addresses are first-class.
- **Multi-device routing.** Add extra OSC destinations with an owned address
  prefix. The longest matching prefix wins, so a single controller can drive
  Syndicate, Resolume, a visualizer and a lighting rig at the same time.
- **Any controller.** Every MIDI source is opened. MIDI Learn captures notes and
  CCs from whichever device you touch; 14-bit pairs, relative encoders and
  momentary/toggle behaviour are handled for you.
- **Serial and UDP OSC inputs.** An ESP32-S3 or any OSC-speaking controller can
  feed the same mapping engine over USB serial (SLIP or newline framing) or UDP.
- **Latency monitor.** The main window shows input-to-OSC p50/p95/max for MIDI,
  serial and UDP OSC, plus the serial ping round-trip, each with a live trace.
- **Feedback-aware.** Buttons, LEDs, toggles and soft-takeover pickup use the
  destination's own feedback instead of guessing.
- **Presets where they help.** The FLX4 gets 14-bit faders, deck switching, shift
  layers and its centre-detent filter. Syndicate ports and routes are
  discovered from the running app. Everything else stays generic.

## Install

Build from source (macOS 14+, Xcode command line tools):

```sh
git clone https://github.com/ethanbanker/cuewire.git
cd cuewire
./scripts/build-app.sh
open "dist/Cuewire.app"
```

The app starts routing automatically, puts a waveform icon in the menu bar, and
hides to the menu bar when its window closes.

## Routing model

```
MIDI controllers ─┐
Serial OSC       ─┼─▶ Cuewire engine ─▶ mappings ─▶ destination A (prefix /A)
UDP OSC          ─┘        ▲                        destination B (prefix /B)
                           └──── feedback from each destination
```

1. **Inputs** — all MIDI sources, a serial port, and an optional UDP control port.
2. **Mappings** — learned or hand-written: source control → OSC address, mode,
   range, deck substitution and target destination.
3. **Destinations** — the primary OSC API plus any extra host/port with an owned
   prefix. Unmatched traffic goes to the primary destination.

A mapping can target one specific destination, which is how a controller split
across applications stays predictable.

## Mapping editor

![Cuewire OSC mapping editor](docs/images/mapping-editor.png)

**Bridge → OSC Mapping…** (⌘L) captures a control with Learn, then maps it to any
OSC address.

- **Trigger** — send `1` on press.
- **Momentary** — send `1` while held, `0` on release.
- **Toggle** — flip from confirmed feedback.
- **Absolute 0…1** — faders and knobs; learned 14-bit controls keep their precision.
- **Bipolar −1…+1** — centred tempo/filter-style controls.
- **Relative encoder** — signed deltas.
- **Passthrough** — forward an OSC input message unchanged.

Picking a route applies its natural mode, and Save upgrades a leftover Trigger on
a continuous route, so a fader can never be saved as a one-shot press.

Mappings live in `~/Library/Application Support/Cuewire/mappings.json` and override
built-in presets by control identity. Pre-1.0 files in the old `FLX Bridge` folder
migrate automatically.

![Cuewire settings](docs/images/settings.png)

## Supported today

| Area | Status |
|---|---|
| MIDI controllers | Any CoreMIDI source; Learn works per note/CC, including 14-bit faders |
| DDJ-FLX4 | Full preset: deck controls, pads, loops, browse, mixer, 14-bit tempo/volume, centre-detent filter |
| Syndicate | Port and route discovery, feedback subscriptions, hub routing, legacy `/AutoPilot` aliases |
| Serial OSC | ESP32-S3 or any USB serial device; SLIP or newline framing, auto-detected |
| UDP OSC input | Optional control port with the same mapping engine |
| Extra destinations | Any IPv4 host/port with an address prefix; longest prefix wins |
| Feedback | Button LEDs, switch state, fader pickup, mapped feedback mirroring |

Generic controllers use **Learn**; the FLX4's stock bindings only run while an
FLX4 is actually connected, so another controller's notes and CCs are never
mapped by accident.

### FLX4 preset reference

| Control | MIDI | Default route |
|---|---|---|
| Play / Cue | CH 0/1 note 11 / 12 | `Deck/{deck}/PlayPause`, `Cue` |
| Sync / Master | CH 0/1 note 88 / 92 | `TempoSync`, `TempoMaster` |
| In / Out / 4-beat | CH 0/1 note 16 / 17 / 77 | `LoopIn`, `LoopOut`, `Loop` |
| Tempo fader | CH 0/1 CC 0 (14-bit) | `TempoSlider`, bipolar, + at bottom |
| Channel fader / trim | CH 0/1 CC 19 / 4 | `Mixer/CH{D}/Volume`, `Trim` |
| High / Mid / Low | CH 0/1 CC 7 / 11 / 15 | `Mixer/CH{D}/EQ/*` |
| Filter | CH 6 CC 23 / 24 | `Filter1` (cutoff) across the full travel, detent = open; Shift = `Filter2` (resonance) |
| Master / headphone | CH 6 CC 8 / 13 / 12 | `Header/MasterVolume`, `CueVolume`, `CueMix` |
| Deck select | CH 6 note 104 / 122 | 1↔3, 2↔4 |
| Browse | CH 6 CC 64 | `Browser/Up`, `Browser/Down` |
| Load | CH 6 note 70 / 71 | `Browser/L{deck}` |

Faders and knobs are absolute by default, like rekordbox. **Settings → Soft
takeover** makes them wait for the destination's confirmed value instead.

## Syndicate setup

Syndicate is optional. When it is running, Cuewire reads its settings and fills
in the ports and route list automatically.

1. In Syndicate, disable the FLX4's direct MIDI input so actions are not applied twice.
2. Enable OSC input. Cuewire reads `osc.listenPort` and `osc.feedbackPort`, and
   warns when they disagree with its own settings. **Use Syndicate ports** re-syncs.
3. Keep OSC feedback enabled and subscribe to all routes, including TempoSlider.
   Without feedback, CUE, toggles and pickup stay blocked and the log says why.
4. Point other applications at Cuewire's extra destinations with their own prefixes.

Syndicate accepts commands and publishes feedback under `/Syndicate/…`. A
pre-rename build that only listens on `/AutoPilot/…` is still detected, and
Cuewire retargets commands onto its root. Locally both spellings fold into one
key space, so old and new feedback drive the same routes.

## Serial OSC controller

Cuewire opens a USB serial port and decodes OSC with SLIP framing or newline
text, auto-detected. Short addresses expand:

```text
/Deck/1/PlayPause         → /Syndicate/Deck/1/PlayPause
/Mixer/CH1/Volume         → /Syndicate/Mixer/CH1/Volume
/AutoPilot/Deck/1/Playing → /Syndicate/Deck/1/Playing
```

When a serial mapping exists, its feedback is mirrored back over the serial link
as `/Syndicate/…` SLIP messages. Only mapped routes are mirrored, so the
controller does not receive every feedback path. Deck metadata, play state, the
loop and the master tempo are mirrored without a mapping, plus the master clock
(`/Header/Clock`, an int beat per bar) that drives the controller's beat dots.

### Pod strip

The Nexus 4's eight-pixel strip under the pod keys is painted with Syndicate's
hot-cue colours: pixel *n* under pod key *n* takes `general.cueColor<n>` from
Syndicate's settings, the same swatch its own decks draw, as
`/Nexus/Light/led/<n> <level> "#rrggbb"`. The palette is global to the app, so
one frame set covers whichever deck is loaded. It is re-read and repainted
every two seconds, which is what keeps the strip honest in two cases: switching
the hot-cue preset in Syndicate repaints without restarting either app, and a
board that reboots — it keeps the port open and goes on answering pings, so
nothing else notices — is repainted within a tick instead of sitting on the
firmware's idle colour. Slots the settings file does not name fall back to
Syndicate's factory palette. Nothing is sent when the serial port is closed, so
the firmware owns the strip and shows the selected deck's colour as before.

### Namespace

Commands follow the app that is running. Cuewire reads the namespace from
Syndicate's own settings. A renamed root (`/Stage/Left/…`) or a pre-rename build
that only listens on `/AutoPilot/…` would silently discard `/Syndicate/…`
commands, so the detected root is used on the way out. Mappings saved before the
rename still spell `/AutoPilot/…` and are normalised first. Extra destinations
keep their own prefixes, and without a readable settings file the default
`/Syndicate/…` is kept.

The link runs at **921600** by default to keep the ping round trip under 2 ms;
**Settings → Serial OSC → baud** must match the firmware, which can be built
for another rate with `BAUD=460800 ./scripts/build.sh`.

### Device-owned input

Some board messages are input only and mean nothing until they are mapped, so
Cuewire does not pass them through to a destination. The Nexus 4 rotary
encoder is one: `/Nexus/Encoder/1` carries a signed int delta per detent and
`/Nexus/Encoder/1/Push` carries `1`/`0`. Learn the turn, pick **Relative
encoder** (the editor selects it when it captures `/Nexus/Encoder/…`), and point
it at any route — `BeatSkip` for beat jumps, `TempoSlider` for a nudge. A wheel
is endless and bidirectional, so a *browser* needs two routes: set **Reverse** to
`/Syndicate/Browser/Down` and the main route to `/Syndicate/Browser/Up`. Relative
mode then sends one trigger per detent to the route for that direction (and
repeats it for a fast spin), exactly like the FLX4's own browse knob. With
Reverse empty the signed delta is sent to the one route instead. The push is a
separate control, so it can be Trigger, Momentary or Toggle — its `0` release is
swallowed, so one click fires one command or one toggle. A turn saved in a press
mode is repaired to Relative on load, since a `-1` detent would otherwise look
like a release and one direction of the knob would do nothing. An unmapped turn
is logged once and dropped, not forwarded.

The board's namespace is `/Nexus`. Firmware from before the rename speaks
`/Aether`, so that prefix is folded onto `/Nexus` as messages arrive and saved
mappings that name it are rewritten on load; an older board keeps working with
no re-learning.

### Keeping the link alive

A USB serial descriptor outlives the device behind it, so an unplugged or wedged
controller can look connected while nothing flows. Three things keep the link
honest:

- The device node's identity is checked every two seconds; a vanished or
  replaced node is reopened, and a saved port that is gone falls back to the USB
  port that actually appeared.
- Cuewire pings `/Nexus/Ping` every two seconds. No `/Nexus/Pong` for six
  seconds means the link is dead: the port is closed and reopened, which is the
  same thing the Settings *Rescan* button does, so no manual step is needed.
- When the board comes back (or answers after a gap) the cached deck state is
  republished and Syndicate is asked to resend its feedback, so titles, BPM and
  play state reappear without touching a control.

## Development

```sh
swift build
swift run BridgeChecks        # 438 checks
./scripts/build-app.sh        # dist/Cuewire.app
swift scripts/make-icon.swift /tmp/icon.png
```

`BridgeCore` is UI-free and covered by the `BridgeChecks` executable; the AppKit
app only observes `BridgeService` snapshots. Checks cover 14-bit precision and
direction, centre-detent filter travel, generic-controller isolation from the
FLX4 preset, learned mapping modes, feedback validation, OSC serialization and
SLIP framing, hot-plug MIDI, hub routing, settings persistence and mode defaults.

## Limits

- Toggles and pickup require confirmed feedback from the destination.
- The FLX4 preset assumes Syndicate's single-filter build (`LP/HP RES`), where
  cutoff is one bipolar-feeling `Filter1` value. On a pre-0.2 build with the old
  two-knob LP/HP filter, `Filter1` is only the low-pass and the right half of the
  knob does nothing.
- Serial OSC uses one port at a time.
- The app is ad-hoc signed; Gatekeeper may ask for confirmation on first launch.
- Unofficial project. Not affiliated with AlphaTheta/Pioneer DJ or Syndicate.

## License

MIT — see [LICENSE](LICENSE).
