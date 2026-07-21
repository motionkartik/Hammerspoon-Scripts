# Spoonfeeder

Automatically load every Hammerspoon Lua script from a dedicated `Spoons` folder, with automatic configuration reloading whenever you make changes.

Created by **@motionkartik**

## Features

* Automatically detects and loads every `.lua` file inside the `Spoons` folder
* No need to manually `require()` or `dofile()` each script
* Safe loading using `pcall()`, preventing one broken script from stopping the rest
* Prints successful loads and errors to the Hammerspoon Console
* Automatically reloads Hammerspoon whenever any Lua file changes
* Calls `hs.auto_dlp_unload()` before reloading (if available), allowing scripts to clean up timers, watchers, hotkeys, and other resources
* Displays a confirmation alert after configuration is loaded

## Folder Structure

```text
~/.hammerspoon/
│
├── init.lua
└── Spoons/
    ├── AutoDownloader.lua
    ├── Clipboard.lua
    ├── AudioSwitcher.lua
    ├── WindowManager.lua
    └── AnyOtherScript.lua
```

Every `.lua` file inside the `Spoons` folder is automatically loaded.

## Installation

Copy the following loader into your `init.lua`.

## Recommended Folder Naming

Although Spoonfeeder automatically loads every `.lua` file inside the `Spoons` directory, including subfolders, the filesystem does not guarantee the order in which folders are discovered.

If one script depends on another, it is recommended to organize folders with numeric prefixes.

Example:

```text
Spoons/
├── 00_Core/
│   ├── Config.lua
│   ├── Logger.lua
│   └── Helpers.lua
├── 10_Audio/
│   └── AudioSwitcher.lua
├── 20_Clipboard/
│   └── Clipboard.lua
├── 30_WindowManagement/
│   └── Window.lua
└── 40_Downloaders/
    └── AutoDownloader.lua
```

This convention makes your project easier to navigate and gives you a predictable structure as it grows.

For independent scripts, no prefixes are necessary. They are simply recommended when organizing larger Hammerspoon configurations or grouping related functionality.


## How It Works

### Automatic Script Loading

On startup, Spoonfeeder:

1. Scans the `Spoons` directory.
2. Finds every `.lua` file.
3. Executes each script using `dofile()`.
4. Wraps execution with `pcall()` so one failing script does not prevent others from loading.

Example Console output:

```text
Loaded: Clipboard.lua
Loaded: AudioSwitcher.lua
Loaded: WindowManager.lua
```

If a script contains an error:

```text
Error loading Clipboard.lua
attempt to index a nil value
```

## Automatic Reloading

A filesystem watcher monitors your Hammerspoon configuration.

Whenever any `.lua` file changes:

* `hs.auto_dlp_unload()` is called if it exists.
* Hammerspoon reloads automatically.
* A confirmation alert is displayed.

This creates a fast development workflow where saving a file immediately reloads your configuration.

## Optional Cleanup Function

If one of your scripts creates timers, watchers, event taps, hotkeys, or other persistent objects, define:

```lua
function hs.auto_dlp_unload()
    -- Cleanup resources here
end
```

Spoonfeeder will call it before every reload, helping prevent duplicate timers or leaked resources.

## Why Spoonfeeder?

Without Spoonfeeder:

```lua
require("Clipboard")
require("AudioSwitcher")
require("WindowManager")
require("Downloader")
require("MediaKeys")
...
```

Every new script requires another line in `init.lua`.

With Spoonfeeder:

Simply drop a `.lua` file into the `Spoons` folder and it is loaded automatically.

## Requirements

* macOS
* Hammerspoon

## License

MIT License
