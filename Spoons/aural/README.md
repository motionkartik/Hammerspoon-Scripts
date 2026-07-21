# Aural

A lightweight Hammerspoon utility that makes switching audio devices on macOS effortless.

Built by **@motionkartik**

## Features

* Left click the menu bar icon to instantly cycle through all available output devices.
* Right click to open a complete list of available audio devices.
* Scroll over the menu bar icon to control system volume.
* Automatic device specific icons using SF Symbols.
* Beautiful floating HUD when the output device changes.
* Automatically generates and caches icons for maximum performance.
* Automatically compiles the SF Symbol exporter on first launch.
* Automatically recompiles the exporter whenever its Swift source is updated.
* No manual compilation required.

## Requirements

* macOS 12 or later (recommended)
* Hammerspoon
* Swift compiler (included with Xcode or Xcode Command Line Tools)

## Installation

Clone or download this repository into your Hammerspoon `Spoons` directory.

```
~/.hammerspoon/Spoons/
```

Your folder should look like this:

```
Spoons/
└── Aural/
    ├── aural.lua
    ├── sfsymbol_export.swift
    └── aural-icons/
```

Then load it from your `init.lua`:

```lua
dofile(hs.configdir .. "/Spoons/Aural/aural.lua")
```

Reload Hammerspoon.

On the first launch, Aural will automatically:

1. Detect whether the `sfsymbol-export` helper exists.
2. Compile it from `sfsymbol_export.swift` using `swiftc`.
3. Generate all required icon assets.
4. Cache the generated icons for future launches.

No manual compilation is necessary.

## Controls

| Action      | Result                          |
| ----------- | ------------------------------- |
| Left Click  | Cycle to the next output device |
| Right Click | Show device selection menu      |
| Scroll Up   | Volume Down (inverted)          |
| Scroll Down | Volume Up (inverted)            |

## Automatic Rebuilds

Whenever `sfsymbol_export.swift` is newer than the compiled helper, Aural automatically recompiles it during startup.

This means you only need to update the Swift source file, Aural takes care of rebuilding everything else.

## HUD

When the default output device changes, Aural displays a clean floating HUD showing:

* Device icon
* Device name

The HUD can be disabled from the Lua console:

```lua
aural.hudEnabled = false
```

Enable it again with:

```lua
aural.hudEnabled = true
```

## Icon Cache

Generated icons are stored in:

```
aural-icons/
```

Icons are generated only when needed and then reused, making subsequent launches nearly instantaneous.

## Supported Device Icons

Aural automatically selects icons based on the connected device.

| Device             | Icon          |
| ------------------ | ------------- |
| AirPods            | AirPods       |
| Bluetooth Audio    | Earbuds       |
| Speakers           | Hi-Fi Speaker |
| Headphones         | Headphones    |
| Built-in Mac Audio | Laptop        |
| Unknown Devices    | Speaker       |

## Why compile automatically?

Most users do not have a precompiled binary.

Instead of requiring a manual command like:

```bash
swiftc sfsymbol_export.swift -o sfsymbol-export
```

Aural detects the missing helper and compiles it automatically. This keeps the repository architecture independent and removes an installation step.

## License

MIT License

## Credits

Created by **@motionkartik**

Powered by:

* Hammerspoon
* Swift
* SF Symbols
* macOS Audio APIs
