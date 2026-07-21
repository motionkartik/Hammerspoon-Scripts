# Spoonfeeder

A simple Hammerspoon loader that automatically discovers and loads every Lua script inside the `Spoons` directory, including nested folders. It also watches your configuration for changes and reloads Hammerspoon automatically, making development fast and effortless.

Created by **@motionkartik**

## Features

* Automatically loads every `.lua` file inside the `Spoons` directory and all subfolders
* No need to manually `require()` or `dofile()` each script
* Safe loading using `pcall()`, so one broken script won't stop the others
* Automatically reloads Hammerspoon whenever any Lua file changes
* Calls `hs.auto_dlp_unload()` before reloading (if available) for proper cleanup
* Prints successful loads and errors to the Hammerspoon Console
* Displays a confirmation alert after configuration loads

## Repository Structure

```text
~/.hammerspoon/
├── init.lua
└── Spoons/
    ├── Aural/
    │   ├── Aural.lua
    │   └── README.md
    └── Auto_DLP/
        ├── Auto_DLP.lua
        └── README.md
```

Every `.lua` file inside the `Spoons` directory is automatically loaded, regardless of how deeply it is nested.

## Included Spoons

### Aural

A lightweight macOS audio device switcher for Hammerspoon.

Features include:

* Scroll over the menu bar icon to instantly switch audio devices
* Switch both input and output devices
* Favorite devices
* Device overlay notifications
* Native macOS integration

### Auto_DLP

An automatic clipboard downloader powered by `yt-dlp`.

Features include:

* Watches the clipboard for supported URLs
* Automatically downloads videos
* Supports multiple platforms
* Uses FFmpeg for post processing
* Download history support
* Automatic reload friendly

## Installation

1. Clone this repository into your Hammerspoon configuration directory.

```bash
git clone <repository-url> ~/.hammerspoon
```

2. Make sure your `init.lua` contains the Spoonfeeder loader.

3. Reload Hammerspoon.

That's it. Any Lua script added anywhere inside the `Spoons` folder will be loaded automatically.

## Recommended Folder Naming

Although Spoonfeeder automatically loads every Lua script, it is recommended to organize larger projects using numeric prefixes.

Example:

```text
Spoons/
├── 00_Core/
├── 10_Aural/
├── 20_Auto_DLP/
├── 30_WindowManagement/
└── 40_Clipboard/
```

This keeps related functionality grouped together and makes large Hammerspoon configurations easier to navigate.

For small or independent scripts, prefixes are completely optional.

## How It Works

On startup, Spoonfeeder:

1. Recursively scans the `Spoons` directory.
2. Finds every `.lua` file.
3. Executes each script using `dofile()`.
4. Wraps execution in `pcall()` so one script failing does not prevent the others from loading.

Example Console output:

```text
Loaded: Spoons/Aural/Aural.lua
Loaded: Spoons/Auto_DLP/Auto_DLP.lua
```

If a script contains an error:

```text
Error loading: Spoons/Aural/Aural.lua
attempt to index a nil value
```

## Automatic Reloading

A filesystem watcher monitors your Hammerspoon configuration.

Whenever any `.lua` file changes:

* `hs.auto_dlp_unload()` is called if it exists.
* Hammerspoon reloads automatically.
* Your updated scripts are loaded immediately.

This provides a smooth development workflow where simply saving a file refreshes your entire configuration.

## Optional Cleanup

If one of your scripts creates timers, watchers, hotkeys, event taps, or other persistent resources, expose the following function:

```lua
function hs.auto_dlp_unload()
    -- Stop timers
    -- Remove watchers
    -- Clean up resources
end
```

Spoonfeeder will call it before every reload, helping prevent duplicate timers, duplicate hotkeys, and other leftover resources.

## Why Spoonfeeder?

Without Spoonfeeder:

```lua
require("Aural")
require("Auto_DLP")
require("Clipboard")
require("WindowManagement")
require("MediaKeys")
...
```

Every new script requires another line inside `init.lua`.

With Spoonfeeder:

Simply drop a `.lua` file anywhere inside the `Spoons` folder and it will be discovered and loaded automatically.

## Requirements

* macOS
* Hammerspoon

## License

MIT License
