# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Clone with submodules (required - mchanger is a submodule)
git clone --recurse-submodules https://github.com/toml0006/discbot.git

# Build via Xcode CLI
xcodebuild -project discbot.xcodeproj \
  -scheme Discbot \
  -destination 'platform=macOS' \
  -configuration Release \
  build
```

Or open `discbot.xcodeproj` in Xcode and build.

## Project Overview

Discbot is a native macOS SwiftUI app for controlling SCSI media changers, specifically the Sony VGP-XL1B 200-disc DVD changer. It communicates with hardware via FireWire using IOKit and the mchanger C library.

**Platform constraint:** FireWire support was removed in macOS Tahoe (macOS 26). The app targets macOS 10.15-15 only.

## Architecture

MVVM pattern with clean separation:

- **Models/** - Data types: `Slot`, `DriveStatus`, `DiscMetadata`, `ChangerError`
- **Services/** - Hardware/system interaction (all thread-safe with NSLock):
  - `ChangerService` - SCSI changer control via mchanger C library
  - `MountService` - Disc detection/mounting via DiskArbitration framework
  - `ImagingService` - ISO creation via hdiutil
- **ViewModels/** - `ChangerViewModel` is the central state manager (~830 lines, manages all app state and operations)
- **Views/** - SwiftUI components (MainView, InventoryGridView, InventoryListView, etc.)

## Key Technical Details

- **C Bridging:** mchanger library accessed via bridging header
- **Thread Safety:** Services use `NSLock`; async operations on `DispatchQueue.global(qos: .userInitiated)`
- **Hardware Quirk:** VGP-XL1B doesn't report drive contents via SCSI, so disc presence uses DiskArbitration callbacks instead
- **System Tools Used:** `/usr/bin/drutil` (eject), `/usr/sbin/diskutil` (mount/unmount), `/usr/bin/hdiutil` (imaging)
