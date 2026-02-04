# Discbot

A macOS app for controlling SCSI media changer devices. Built for the [Sony VGP-XL1B](https://www.sony.com/electronics/support/home-video-media-changers/vgp-xl1b) 200-disc changer, but should work with other SCSI-compliant media changers.

## Features

- Visual inventory of all disc slots
- Load and unload discs with a click
- View mounted disc metadata
- Batch operations for imaging multiple discs

## Requirements

- macOS 10.15 (Catalina) through macOS 15 (Sequoia)
- A SCSI media changer device connected via FireWire or Thunderbolt-to-FireWire adapter

> **Important:** macOS 16 (Tahoe) [removed FireWire support entirely](https://tidbits.com/2025/09/19/support-for-firewire-removed-from-macos-26-tahoe/). If your changer connects via FireWire, you must use macOS 15 (Sequoia) or earlier. The app will compile and run on Tahoe, but will show a warning at startup and won't be able to connect to FireWire devices.

## Build

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/toml0006/discbot.git
```

Open `discbot.xcodeproj` in Xcode and build.

## See also

- [mchanger](https://github.com/toml0006/mchanger) - CLI tool and library for controlling media changers

## License

MIT License - See LICENSE file for details.
