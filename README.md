# Atmos Player

A native macOS player for MKV movies with Dolby Atmos. It sends the film's Dolby Digital Plus (E-AC-3) Atmos audio **untouched** over HDMI to your AV receiver or soundbar, so you get real Atmos with height channels instead of a stereo or 5.1 downmix.

Players I tried, VLC included, did not get Atmos through to the receiver from a Mac. Atmos Player takes exclusive control of the HDMI output, switches it to the E-AC-3 passthrough format and feeds the bitstream straight to the device, so macOS cannot mix, resample or decode it on the way.

It is about 2,000 lines of Swift with no third-party dependencies: its own Matroska demuxer, E-AC-3 frame parser, IEC 61937 packer and EMDF (Atmos metadata) reader, on top of Apple's AVFoundation, Core Audio and AudioToolbox.

## Requirements

- An Apple Silicon Mac on macOS 14 or later.
- An HDMI (or DisplayPort) connection to a Dolby Atmos receiver, soundbar or TV that accepts Dolby Digital Plus passthrough.
- MKV files with **HEVC** video and a **Dolby Digital Plus (E-AC-3)** audio track. A track named "Atmos" is picked automatically.

Not supported: Dolby TrueHD, plain AC-3, containers other than MKV, video codecs other than HEVC, and Atmos over the Mac's speakers, headphones or Bluetooth.

## Build

You need the Xcode command-line tools (`xcode-select --install`).

```bash
./build.sh          # builds "build/Atmos Player.app"
./build.sh --dmg    # also builds "build/Atmos Player.dmg"
```

The app is ad-hoc signed, so the first time you open it macOS may ask you to confirm in **System Settings → Privacy & Security**.

## Use

Open an `.mkv` file with the app, drag it onto the icon, or pick it from the open dialog on launch. Playback resumes where you left off.

| Key | Action |
|---|---|
| Space | Play / pause |
| ← / → | Back / forward 10 s |
| ↓ / ↑ | Back / forward 60 s |
| F, Esc | Full screen on / off |
| A, 1–9 | Next audio track / pick audio track |
| S | Next subtitle track (SRT, ASS/SSA, WebVTT) |
| + / − | Bigger / smaller subtitles |
| [ / ] | Shift the picture earlier / later if lips and sound are out of sync |
| R | Rear Boost (see below) |
| Q | Quit |

**Rear Boost** decodes the audio on the Mac to 5.1 PCM and raises the surround channels. It is for setups where the rears are too quiet; it turns Atmos height off. Press R until it shows "Dolby Atmos" to return to the untouched bitstream.

While it plays, Atmos Player has exclusive use of the HDMI audio device, so other apps are silent. The device's original format is restored when you quit.

## Command-line diagnostics

The same binary has a few tools for checking a file or your audio setup:

```bash
"build/Atmos Player.app/Contents/MacOS/Atmos Player" formats              # formats your HDMI device offers
"build/Atmos Player.app/Contents/MacOS/Atmos Player" probe movie.mkv      # tracks and the first E-AC-3 frames
"build/Atmos Player.app/Contents/MacOS/Atmos Player" emdf movie.mkv 600   # Atmos metadata at 600 s
"build/Atmos Player.app/Contents/MacOS/Atmos Player" audiotest movie.mkv 0 60   # bitstream 60 s of audio only
```

If `formats` does not list `cec3@192000`, your device or cable is not offering Dolby Digital Plus passthrough to the Mac.

## Contributing

Issues and pull requests are welcome, especially reports of receivers and soundbars it does or doesn't work with, and support for more formats such as TrueHD.

## Licence

MIT, see [LICENSE](LICENSE). Dolby, Dolby Atmos and Dolby Digital Plus are trademarks of Dolby Laboratories; this project is not affiliated with or endorsed by Dolby. It contains no Dolby code: decoding for Rear Boost uses the decoder built into macOS.
