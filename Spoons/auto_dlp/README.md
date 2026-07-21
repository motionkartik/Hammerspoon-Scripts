# Auto-dlp

Automatically download videos or audio from your clipboard using **Hammerspoon** and **yt-dlp**. Simply copy a supported URL, wait for the countdown, and Auto-dlp handles the rest.

Perfect for creators who frequently download reference videos, social media content, or audio without opening Terminal.

## Author

**Kartik (@motionkartik)**

---

## Features

* Automatic clipboard monitoring
* One click enable/disable monitoring
* Download videos as **MP4**
* Download audio as **MP3**
* Parallel downloads with configurable download slots
* Download queue with pending countdown
* Cancel pending batch before it starts
* Duplicate URL detection
* Download history to prevent redownloading
* Notifications for download start and completion
* Open downloaded files directly from notifications
* Timeout protection for stuck downloads
* Automatic cleanup of temporary files
* Lightweight menu bar interface
* Browser cookie support for authenticated websites
* Spoon compatible and safe to reload

---

## Supported Websites

* YouTube
* Instagram
* Facebook
* X (Twitter)
* TikTok
* Vimeo
* Pinterest

---

## Requirements

* macOS
* Hammerspoon
* yt-dlp
* ffmpeg
* Node.js

Default executable paths:

```lua
YTDLP      = "/opt/homebrew/bin/yt-dlp"
NODE       = "/opt/homebrew/bin/node"
FFMPEG_DIR = "/opt/homebrew/bin"
```

If your installation is elsewhere, simply update these paths near the top of the script.

---

## Installation

### 1. Install Dependencies

```bash
brew install yt-dlp ffmpeg node
```

### 2. Place the Script

Recommended folder structure:

```
~/.hammerspoon/
│
├── init.lua
└── Spoons/
    └── auto_dlp.lua
```

If you're using **Spoonfeeder**, simply place the script inside the `Spoons` folder and it will be loaded automatically.

### 3. Reload Hammerspoon

Reload your Hammerspoon configuration.

Auto-dlp automatically checks that all required dependencies are installed before starting.

---

## Usage

1. Click the menu bar icon.
2. Enable **Monitoring**.
3. Copy one or more supported video URLs.
4. Auto-dlp detects every supported link.
5. A countdown begins.
6. Cancel if needed, otherwise downloads start automatically.
7. Receive a notification when each download finishes.
8. Click **Open** in the notification to reveal the downloaded file in Finder.

---

## Menu Options

* Toggle Monitoring
* Switch between Video (MP4) and Audio (MP3)
* Start Pending Downloads
* Cancel Pending Downloads
* Stop All Downloads
* Open Download Folder

---

## Configuration

The following values can be customized near the top of the script:

```lua
COUNTDOWN_SECONDS
MAX_HISTORY
DOWNLOAD_TIMEOUT
MAX_CONCURRENT
CONCURRENT_FRAGS
COOKIE_BROWSER
```

### Description

| Option | Description |
|---------|-------------|
| COUNTDOWN_SECONDS | Delay before downloads begin |
| MAX_HISTORY | Number of previously downloaded URLs remembered |
| DOWNLOAD_TIMEOUT | Maximum time allowed for a download |
| MAX_CONCURRENT | Number of downloads running simultaneously |
| CONCURRENT_FRAGS | yt-dlp fragment download threads |
| COOKIE_BROWSER | Browser used for extracting login cookies |

---

## Download Modes

### Video Mode

Downloads the highest quality available H.264 video and merges it into an MP4.

### Audio Mode

Downloads the highest quality audio and converts it to MP3.

---

## Download Location

By default, files are saved to:

```
~/Downloads/Auto-dlp
```

Change `DOWNLOAD_DIR` if you'd like to use another folder.

---

## Download History

Previously downloaded URLs are stored in:

```
~/Library/Application Support/Hammerspoon/video_history.txt
```

This prevents downloading the same URL multiple times.

---

## Browser Cookie Support

Some websites require authentication.

Auto-dlp can automatically import cookies from your browser.

Supported browsers include:

* Chrome
* Safari
* Firefox
* Brave
* Edge

To change the browser:

```lua
COOKIE_BROWSER = "chrome"
```

---

## Notes

* Only supported websites are monitored.
* Duplicate clipboard entries are ignored.
* Previously downloaded links are skipped automatically.
* Temporary download files are cleaned every day.
* Multiple downloads can run simultaneously.
* Downloads continue in the background while you work.

---

## License

MIT License

---

