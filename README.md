# Starship for iPhone & Apple Vision Pro

Play **Star Fox 64** on your iPhone and Apple Vision Pro — the full campaign across every
branching route, with the Starship enhancements menu, game controllers and a tunable touch
layout, and on Vision Pro a stereoscopic **3D mode** that puts the game on a world-locked
panel floating in your room with real depth.

Built on [Starship](https://github.com/HarbourMasters/Starship) (Harbour Masters' native
Star Fox 64 port) and [libultraship](https://github.com/HarbourMasters/libultraship),
rendering natively on **Metal** — no translation layer. 100% vibe coded with lots of
passion and attention to detail.

![Star Fox 64 on Apple Vision Pro](docs/screenshots/visionos-window.jpg)

*Star Fox 64 on Apple Vision Pro — a resizable window floating in your room, with the
on-screen touch layout. The same build also runs in stereoscopic 3D.*

---

## Install

**Add the SideStore source** — the easiest path, and the app auto-updates when new
versions ship:

| Device | Source | Source URL |
| --- | --- | --- |
| iPhone / iPad | HarbourMasters ports | `https://raw.githubusercontent.com/rebelancap/harbourmasters-ports/main/apps-ios.json` |
| iPhone / iPad | All ports | `https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-ios.json` |
| Apple Vision Pro | HarbourMasters ports | `https://raw.githubusercontent.com/rebelancap/harbourmasters-ports/main/apps-visionos.json` |
| Apple Vision Pro | All ports | `https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-visionos.json` |

Starship is in both sources — add either one (HarbourMasters ports carries just the
HarbourMasters family; All ports carries every rebelancap port).

In [SideStore](https://sidestore.io) / [AltStore](https://altstore.io): *Sources → **+** →
paste the URL*, then install Starship.

**Getting SideStore onto your device** — on both platforms SideStore itself is installed
with **iloader**:

- **iPhone / iPad:** [iloader](https://github.com/nab138/iloader).
- **Apple Vision Pro:** my [iloader fork](https://github.com/rebelancap/iloader/releases#release-visionos) —
  upstream doesn't do visionOS. It runs on an Apple Silicon Mac and pairs with the headset
  over Wi-Fi: no cable, no Dev Strap, no Xcode.

Then add the source in SideStore exactly as above.

**Prefer a manual install?** Download `starship-*-iOS.ipa` / `starship-*-visionOS.ipa`
from the [latest release](../../releases/latest) and install it through SideStore/AltStore
yourself (iPhone can also use [Sideloadly](https://sideloadly.io)).

Then **add your Star Fox 64 ROM** — the app walks you through it on first launch.

## Texture pack (recommended)

The HD texture pack people use for Starship is **[LR2EB](https://gamebanana.com/wips/90597)**
on GameBanana. It's a work in progress (~65% complete) but play fine and looks great so far.

Download it, then copy the `.o2r` into
*On My iPhone / Apple Vision Pro → Starship → **mods*** in the Files app and relaunch.
Then turn it on in the game's menu: enable **Use Alternate Assets** (it's off by default,
so this step is required — until you flip it you'll see the vanilla textures). A texture
pack is where Vision Pro 3D mode really shines.

## Features

- The full campaign across every branching route, with all audio and music
- The **Starship enhancements menu** — the reason these ports exist: higher frame rates,
  widescreen, and the whole quality-of-life catalogue
- **In-app ROM extraction** — no PC tools, no companion app
- **Game controllers** (Backbone, DualSense, Xbox…) with menu-aware navigation
- **Touch controls** with the N64 button cluster and a **layout customizer** — drag any
  button, scale 70–140%, left-handed mirror, opacity, haptics, and **per-button
  hide/show** so you can drop the buttons you never use
- **60 / 120 Hz** (ProMotion) and a supersampling slider for extra sharpness
- Texture packs and other `.o2r` mods via drag-and-drop in Files
- On-screen fps + thermal readout for tuning
- **Apple Vision Pro:** a free-resizing 2D window rendering at true 4K, plus a
  **stereoscopic 3D mode** — the game on a world-locked panel floating in your room,
  with foveated rendering for full-resolution clarity where you're looking, spatial audio
  anchored to the screen, and live-tunable stereo depth, focus, screen size/distance/height,
  surroundings dimming, and a recenter button

## Requirements

- iPhone on **iOS 15+**, or **Apple Vision Pro** (visionOS 2+)
- **SideStore**, installed with [iloader](https://github.com/nab138/iloader) — Apple Vision
  Pro needs my [visionOS fork](https://github.com/rebelancap/iloader/releases#release-visionos)
  and an Apple Silicon Mac
- Your own Star Fox 64 ROM

## FAQ

**Do I need a PC to extract the ROM?** No — extraction runs inside the app on your device.

**The app stopped launching after about a week?** Apps sideloaded with a free Apple
account expire after 7 days (paid developer accounts last a year). SideStore/iloader
refresh them automatically in the background — open the sideloading app and let it
re-sign.

**Found a bug, or it crashed?** The app keeps its own logs, and its folder is visible in
**Files** — open *On My iPhone / Apple Vision Pro → Starship* and grab:

- `crash.txt` — a backtrace, written if the app died (this is the important one)
- `logs/` — the newest `.log` file

Attach those to a [GitHub issue](../../issues) or send them over Discord, along with what
you were doing. A crash without `crash.txt` is usually the app being killed for memory —
worth saying so, and which mission you were on.

---

## Building from source

Requires macOS with Xcode and `cmake` (`brew install cmake`).

```sh
scripts/bootstrap.sh          # clone + pin upstream Starship (submodules recursive)
scripts/build-oracle.sh       # native macOS build — generates the asset archive
scripts/extract-sf64-o2r.sh   # build sf64.o2r from your ROM (for the simulator)

scripts/build-sim.sh          # iOS Simulator build
scripts/run-sim.sh            # install + launch + screenshot

scripts/build-ios.sh          # signed iPhone build
scripts/build-visionos.sh     # signed Apple Vision Pro build
```

Upstream Starship is vendored **unmodified and pinned by commit**; every local change is a
reviewable patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh` (a patch that fails to apply fails the build). The iOS/visionOS app shell lives in `app/ios/`.


## Credits & license

- [Starship](https://github.com/HarbourMasters/Starship) by **Harbour Masters** and
  contributors — the port this is built on
- [libultraship](https://github.com/HarbourMasters/libultraship) (MIT) and the Harbour
  Masters asset pipeline — the platform layer
- [LR2EB](https://gamebanana.com/wips/90597) texture pack (work in progress)
- STAR FOX 64 © **Nintendo**. This project is not affiliated with or endorsed by
  Nintendo, and ships no Nintendo content.

<!-- TODO: pick a license for this repo's own code (the app shell + overlay patches).
     Upstream has no root LICENSE file; libultraship/ZAPDTR are MIT. -->
