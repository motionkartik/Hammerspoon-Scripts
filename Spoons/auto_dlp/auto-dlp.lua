-- Auto-dlp by @motionkartik

-- ── Paths ──
local HOME         = os.getenv("HOME")
local DOWNLOAD_DIR = HOME .. "/Downloads/Auto-dlp"
local WORK_ROOT    = DOWNLOAD_DIR .. "/.work"   -- per-download scratch dirs (hidden in Finder)
local HISTORY_FILE = HOME .. "/Library/Application Support/Hammerspoon/video_history.txt"
local YTDLP        = "/opt/homebrew/bin/yt-dlp"
local NODE         = "/opt/homebrew/bin/node"
local FFMPEG_DIR   = "/opt/homebrew/bin"
local FFMPEG       = FFMPEG_DIR .. "/ffmpeg"
local FFPROBE      = FFMPEG_DIR .. "/ffprobe"
local OPEN         = "/usr/bin/open"

-- ── Config ──
local COUNTDOWN_SECONDS  = 5
local MAX_HISTORY        = 500
local INACTIVITY_TIMEOUT = 180   -- seconds with NO yt-dlp output before a download is treated as stalled
local MAX_CONCURRENT     = 2
local CONCURRENT_FRAGS   = 4
local COOKIE_BROWSER     = "chrome" -- Change to: "safari", "firefox", "edge", "brave", etc.

-- H.264 conversion
local TRANSCODE_TO_H264  = true   -- convert non-H.264 video after download
local PREFER_SOURCE_H264 = true   -- true: take H.264 (usually <=1080p on YouTube) over 4K VP9, no conversion
                                  -- false: take best quality, then convert when needed
local USE_HW_ENCODER     = true   -- h264_videotoolbox (fast) vs libx264 (smaller / better quality)
local VT_QUALITY        = 65      -- videotoolbox -q:v (1-100, higher = better)
local X264_CRF           = 20     -- libx264 quality (lower = better / larger)

-- ── State ──
local menubar          = nil
local queue            = {}
local history          = {}
local pendingBatch     = nil
local pendingBatchMode = nil    -- mode the pending batch was detected under ("video" / "audio"), locked at detection time
local pendingDeadline  = nil    -- absolute time (hs.timer.secondsSinceEpoch) the countdown ends
local pendingTimer     = nil

-- mode: "idle" | "video" | "audio"
local MODES  = { "idle", "video", "audio" }
local mode   = "idle"

local ICONS = {
  idle  = "⏸",
  video = "▶",
  audio = "♪",
}

local MODE_LABELS = {
  idle  = "Idle",
  video = "Video",
  audio = "Audio",
}

local MODE_MESSAGES = {
  idle  = "Clipboard monitoring paused",
  video = "New links will download as Video",
  audio = "New links will download as Audio",
}

local lastMenu = {}   -- most recently built menu table, shown on right-click via popupMenu

-- activeSlots[key] = slot table. key = "video|<url>" or "audio|<url>", so the same
-- URL can be fetched as both video and audio. Each slot carries its own `cancelled`
-- flag, so late callbacks from a killed task can never touch a newer slot.
local activeSlots = {}
local slotCounter = 0
local clipboardWatcher = nil
local rightClickWatcher = nil
local cleanupTimer = nil

-- Forward declarations (assigned further down).
local cancelSlot, processQueue, updateMenu

local dialogWebview    = nil   -- the manual "Download from URL" webview, when open
local dialogController = nil   -- its hs.webview.usercontent controller; must stay
                               -- referenced or GC drops the message callback

-- ── Small helpers ──
local function makeKey(url, audioOnly)
  return (audioOnly and "audio|" or "video|") .. url
end

local function shorten(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

-- Launch /usr/bin/open without a shell, so paths never need quoting.
local function openPath(...)
  hs.task.new(OPEN, function() end, { ... }):start()
end

-- ── Custom notifications ──
-- Aural-style canvas panels shown under the menubar icon. Unlike hs.notify,
-- these can carry clickable buttons. One notification shows at a time; the
-- rest queue up. Buttons are canvas rectangles with per-element mouse
-- tracking, dispatched through hs.canvas:mouseCallback.
local NOTIF_WIDTH   = 340
local NOTIF_PAD     = 14
local NOTIF_ICON    = 48
local NOTIF_BASE    = 90
local NOTIF_BTN_H   = 30
local NOTIF_BTN_GAP = 8

local notifyQueue    = {}
local currentNotif   = nil
local notifCanvas    = nil
local notifTimer     = nil
local notifTickTimer = nil
local notifButtons   = {}   -- button id -> callback

local function stopNotifTimers()
  if notifTimer then notifTimer:stop(); notifTimer = nil end
  if notifTickTimer then notifTickTimer:stop(); notifTickTimer = nil end
end

local showNextNotification

local function dismissNotification(instant)
  stopNotifTimers()
  if notifCanvas then
      local c = notifCanvas
      notifCanvas = nil
      if instant then
          -- Replacing/clearing right now: kill the old panel immediately so
          -- the next one can take its place without a wait or overlap.
          pcall(function() c:delete() end)
      else
          c:hide(0.15)
          hs.timer.doAfter(0.25, function() pcall(function() c:delete() end) end)
      end
  end
  currentNotif = nil
  notifButtons = {}
  if showNextNotification then
      hs.timer.doAfter(0.05, showNextNotification)
  end
end

-- Remove any queued or currently-showing notification with a matching tag.
local function dismissTagged(tag)
  local kept = {}
  for _, spec in ipairs(notifyQueue) do
      if spec.tag ~= tag then table.insert(kept, spec) end
  end
  notifyQueue = kept
  if currentNotif and currentNotif.tag == tag then
      dismissNotification()
  end
end

local function safeDynamicText(spec)
  if spec.dynamicText then
      local ok, text = pcall(spec.dynamicText)
      if ok then return text end
  end
  return spec.message or ""
end

showNextNotification = function()
  if notifCanvas then return end

  local spec = table.remove(notifyQueue, 1)
  if not spec then currentNotif = nil; return end

  currentNotif = spec
  notifButtons = {}

  local buttons    = spec.buttons or {}
  local hasButtons = #buttons > 0
  local height     = NOTIF_BASE + (hasButtons and (NOTIF_BTN_H + 12) or 0)

  local screenFrame = hs.screen.mainScreen():frame()
  local x, y
  local ok, mbFrame = pcall(function() return menubar and menubar:frame() end)

  if ok and mbFrame then
      x = mbFrame.x + (mbFrame.w / 2) - (NOTIF_WIDTH / 2)
      y = mbFrame.y + mbFrame.h + 6
  else
      x = screenFrame.x + (screenFrame.w - NOTIF_WIDTH) / 2
      y = screenFrame.y + 44
  end

  x = math.max(screenFrame.x + 8, math.min(x, screenFrame.x + screenFrame.w - NOTIF_WIDTH - 8))
  y = math.max(screenFrame.y, y)

  local canvas = hs.canvas.new({ x = x, y = y, w = NOTIF_WIDTH, h = height })

  canvas:appendElements({
      type = "rectangle",
      action = "fill",
      fillColor = { white = 0.08, alpha = 0.94 },
      strokeColor = { white = 0.35, alpha = 0.5 },
      strokeWidth = 1,
      roundedRectRadii = { xRadius = 16, yRadius = 16 },
  })

  canvas:appendElements({
      type = "text",
      text = spec.icon or "•",
      textSize = 30,
      textColor = { white = 1, alpha = 1 },
      textAlignment = "center",
      frame = { x = NOTIF_PAD, y = NOTIF_PAD + 2, w = NOTIF_ICON, h = NOTIF_ICON },
  })

  local CLOSE_SIZE = 20

  canvas:appendElements({
      type = "text",
      text = spec.title or "",
      textSize = 15,
      textColor = { white = 1, alpha = 1 },
      textAlignment = "left",
      textLineBreak = "truncateTail",
      frame = { x = NOTIF_PAD + NOTIF_ICON + 10, y = NOTIF_PAD + 2,
                w = NOTIF_WIDTH - NOTIF_PAD * 2 - NOTIF_ICON - 10 - CLOSE_SIZE - 6, h = 22 },
  })

  -- Small "x" close control, top-right corner. Tracked like the action
  -- buttons but wired directly to dismissNotification (no spec.fn), so it
  -- always just closes the panel rather than triggering the notif's action.
  canvas:appendElements({
      type = "rectangle",
      action = "fill",
      id = "closeBtn",
      trackMouseUp = true,
      trackMouseEnterExit = true,
      fillColor = { white = 1, alpha = 0 },
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
      frame = { x = NOTIF_WIDTH - NOTIF_PAD - CLOSE_SIZE, y = NOTIF_PAD - 4,
                w = CLOSE_SIZE, h = CLOSE_SIZE },
  })

  canvas:appendElements({
      type = "text",
      text = "✕",
      textSize = 12,
      textColor = { white = 0.85, alpha = 1 },
      textAlignment = "center",
      frame = { x = NOTIF_WIDTH - NOTIF_PAD - CLOSE_SIZE, y = NOTIF_PAD - 3,
                w = CLOSE_SIZE, h = CLOSE_SIZE },
  })

  local textW = NOTIF_WIDTH - NOTIF_PAD * 2 - NOTIF_ICON - 10
  canvas:appendElements({
      type = "text",
      id = "message",
      text = safeDynamicText(spec),
      textSize = 12,
      textColor = { white = 0.78, alpha = 1 },
      textAlignment = "left",
      textLineBreak = "wordWrap",
      frame = { x = NOTIF_PAD + NOTIF_ICON + 10, y = NOTIF_PAD + 26, w = textW, h = 42 },
  })

  if hasButtons then
      local btnY   = NOTIF_BASE
      local xRight = NOTIF_WIDTH - NOTIF_PAD

      for i = #buttons, 1, -1 do
          local b     = buttons[i]
          local label = b.label or "OK"
          local bw    = math.max(66, math.floor(#label * 8.5) + 22)
          local bx    = xRight - bw
          local id    = "btn_" .. i

          notifButtons[id] = b.fn

          canvas:appendElements({
              type = "rectangle",
              action = "fill",
              id = id,
              trackMouseUp = true,
              trackMouseEnterExit = true,
              fillColor = { white = 1, alpha = 0.14 },
              roundedRectRadii = { xRadius = 8, yRadius = 8 },
              frame = { x = bx, y = btnY, w = bw, h = NOTIF_BTN_H },
          })

          -- The label has no mouse tracking, so clicks over it fall through
          -- to the rectangle beneath and still fire the button callback.
          canvas:appendElements({
              type = "text",
              text = label,
              textSize = 13,
              textColor = { white = 1, alpha = 1 },
              textAlignment = "center",
              frame = { x = bx, y = btnY + 5, w = bw, h = NOTIF_BTN_H - 8 },
          })

          xRight = bx - NOTIF_BTN_GAP
      end
  end

  canvas:mouseCallback(function(c, message, id, _x, _y)
      if type(id) ~= "string" then return end

      if id == "closeBtn" then
          if message == "mouseEnter" then
              pcall(function() c[id].fillColor = { white = 1, alpha = 0.18 } end)
          elseif message == "mouseExit" then
              pcall(function() c[id].fillColor = { white = 1, alpha = 0 } end)
          elseif message == "mouseUp" then
              dismissNotification()
          end
          return
      end

      if message == "mouseEnter" then
          pcall(function() c[id].fillColor = { white = 1, alpha = 0.26 } end)
      elseif message == "mouseExit" then
          pcall(function() c[id].fillColor = { white = 1, alpha = 0.14 } end)
      elseif message == "mouseUp" then
          local fn = notifButtons[id]
          dismissNotification()
          if fn then fn() end
      end
  end)

  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:clickActivating(false)
  canvas:show(0.12)
  notifCanvas = canvas

  if spec.dynamicText then
      notifTickTimer = hs.timer.doEvery(1, function()
          if notifCanvas and currentNotif == spec then
              pcall(function() notifCanvas["message"].text = safeDynamicText(spec) end)
          end
      end)
  end

  notifTimer = hs.timer.doAfter(spec.duration or 8, dismissNotification)
end

local function notify(spec)
  -- Rapid repeats with the same tag (e.g. clicking through modes back-to-back)
  -- should not queue up behind each other. If one with this tag is already
  -- showing, drop it instantly and let the newest take its place.
  if spec.tag and currentNotif and currentNotif.tag == spec.tag then
      local kept = {}
      for _, s in ipairs(notifyQueue) do
          if s.tag ~= spec.tag then table.insert(kept, s) end
      end
      notifyQueue = kept
      dismissNotification(true)
  end

  table.insert(notifyQueue, spec)
  if not notifCanvas then showNextNotification() end
end

local function notifyDownloadStarted(url, audioOnly)
  local key = makeKey(url, audioOnly)
  notify({
      icon  = audioOnly and ICONS.audio or ICONS.video,
      title = "Download Started",
      message = (audioOnly and "Audio" or "Video") .. " • " .. url,
      duration = 8,
      buttons = {
          { label = "Cancel", fn = function() cancelSlot(key) end },
      },
  })
end

local function notifyComplete(filePath, audioOnly)
  if filePath and hs.fs.attributes(filePath) then
      local name = filePath:match("([^/]+)$") or (audioOnly and "Audio" or "Video")
      notify({
          icon  = "✅",
          title = "Download Complete",
          message = name,
          duration = 8,
          buttons = {
              { label = "Show in Finder", fn = function() openPath("-R", filePath) end },
              { label = "Open",           fn = function() openPath(filePath) end },
          },
      })
  else
      -- yt-dlp didn't report a usable path (or the file moved): don't point at a guess.
      notify({
          icon  = "✅",
          title = "Download Complete",
          message = "Saved to the Auto-dlp folder",
          duration = 8,
          buttons = {
              { label = "Open Folder", fn = function() openPath(DOWNLOAD_DIR) end },
          },
      })
  end
end

local function notifyFailed(url, audioOnly, reason)
  local msg = shorten(url, 48)
  if reason and reason ~= "" then msg = shorten(reason, 90) .. "\n" .. msg end
  notify({
      icon  = "❌",
      title = "Download Failed",
      message = msg,
      duration = 12,
      buttons = {
          { label = "Retry", fn = function()
              table.insert(queue, { url = url, audioOnly = audioOnly })
              processQueue()
          end },
      },
  })
end

-- ── Dependency Check ──
local function checkDependencies()
  local missing = {}

  local ytdlp_exists = hs.fs.attributes(YTDLP)
  if not ytdlp_exists then
      table.insert(missing, "yt-dlp (" .. YTDLP .. ")")
  end

  local node_exists = hs.fs.attributes(NODE)
  if not node_exists then
      table.insert(missing, "node (" .. NODE .. ")")
  end

  if not hs.fs.attributes(FFMPEG) then
      table.insert(missing, "ffmpeg (" .. FFMPEG .. ")")
  end

  if not hs.fs.attributes(FFPROBE) then
      table.insert(missing, "ffprobe (" .. FFPROBE .. ")")
  end

  if #missing > 0 then
      print("Auto-dlp initialization failed. Missing dependencies:")
      for _, m in ipairs(missing) do print("  - " .. m) end

      notify({
          icon  = "⚠",
          title = "Auto-dlp: Missing Dependencies",
          message = "Install these to enable downloads: " .. table.concat(missing, ", "),
          duration = 15,
      })

      return false
  end

  return true
end

if not checkDependencies() then
  return true
end

menubar = hs.menubar.new()

local ALLOWED_DOMAINS = {
  "youtube.com", "youtu.be",
  "instagram.com",
  "facebook.com", "fb.watch",
  "x.com", "twitter.com",
  "tiktok.com",
  "vimeo.com",
  "pinterest.com",
}

os.execute('mkdir -p "' .. DOWNLOAD_DIR .. '"')
os.execute('mkdir -p "' .. HOME .. '/Library/Application Support/Hammerspoon"')
-- Nothing can be mid-download at load time, so any leftover scratch dirs are stale.
os.execute('rm -rf "' .. WORK_ROOT .. '"')
os.execute('mkdir -p "' .. WORK_ROOT .. '"')

local function activeCount()
  local n = 0
  for _, s in pairs(activeSlots) do if s then n = n + 1 end end
  return n
end

-- ── History ──
-- Entries are keyed "video|<url>" / "audio|<url>". Older history files stored the
-- bare URL; those are treated as video downloads when loaded.
local function loadHistory()
  local file = io.open(HISTORY_FILE, "r")
  if not file then return end

  local lines = {}
  for line in file:lines() do table.insert(lines, line) end
  file:close()

  local start = math.max(1, #lines - MAX_HISTORY + 1)
  for i = start, #lines do
      local line = lines[i]
      if line:match("^video|") or line:match("^audio|") then
          history[line] = true
      elseif line ~= "" then
          history["video|" .. line] = true
      end
  end

  if #lines > MAX_HISTORY then
      local out = io.open(HISTORY_FILE, "w")
      if out then
          for i = start, #lines do out:write(lines[i] .. "\n") end
          out:close()
      end
  end
end

local function saveHistory(key)
  local file = io.open(HISTORY_FILE, "a")
  if file then file:write(key .. "\n"); file:close() end
  history[key] = true
end

-- ── Cleanup ──
local function cleanupTempFiles()
  os.execute('find "' .. DOWNLOAD_DIR
      .. '" \\( -name "*.part" -o -name "*.ytdl" -o -name "*.h264tmp.mp4" \\) -mtime +1 -delete')
  os.execute('find "' .. WORK_ROOT
      .. '" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} +')
end

-- ── yt-dlp args builder ──
-- Output protocol (parsed in the stream callback):
--   DLPPROG <percent> <speed>   progress lines (also act as the inactivity heartbeat)
--   DLPFILE:<path>              final file path, printed once after the move
-- Files are written into a private per-download work dir and only moved into
-- DOWNLOAD_DIR once fully finished (including any H.264 conversion). Name pattern is
-- <title>_<id, max 15 chars>.<ext>, so two posts by one account never share a name.
local function buildArgs(url, audioOnly, outDir)
  local outTemplate = outDir .. "/%(title)s_%(id).15s.%(ext)s"
  local args = {
      "--js-runtimes",          "node:" .. NODE,
      "--ffmpeg-location",      FFMPEG_DIR,
      "--restrict-filenames",
      "--no-playlist",
      "--concurrent-fragments", tostring(CONCURRENT_FRAGS),
      "--cookies-from-browser", COOKIE_BROWSER,
      "--embed-metadata",
      "--progress", "--newline",
      "--progress-template",    "download:DLPPROG %(progress._percent_str)s %(progress._speed_str)s",
      "--print",                "after_move:DLPFILE:%(filepath)s",
      "-o",                     outTemplate,
  }

  if audioOnly then
      local extra = {
          "-f", "bestaudio/best",
          "--extract-audio",
          "--audio-format", "mp3",
          "--audio-quality", "0",
          "--embed-thumbnail",
          "--convert-thumbnails", "jpg",
      }
      for _, v in ipairs(extra) do table.insert(args, v) end
  else
      local fmt = PREFER_SOURCE_H264
          and "bv*[vcodec^=avc1]+ba[ext=m4a]/bv*[vcodec^=avc1]+ba/bv*+ba/b"
          or  "bv*+ba/b"
      local extra = {
          "-f", fmt,
          "--merge-output-format", "mp4",
          "--embed-chapters",
      }
      for _, v in ipairs(extra) do table.insert(args, v) end
  end

  table.insert(args, url)
  return args
end

-- ── Domain allow-list ──
-- Matches on the URL's host (exact or subdomain), not on a substring of the whole URL.
local function isAllowed(url)
  local host = url:lower():match("^https?://([^/%?#:]+)")
  if not host then return false end
  for _, d in ipairs(ALLOWED_DOMAINS) do
      if host == d or host:sub(-(#d + 1)) == "." .. d then return true end
  end
  return false
end

-- ── Work dir / final-name helpers ──
local pendingCleanups = {}   -- keeps delayed-cleanup timers referenced until they fire

local function cleanupWork(slot)
  local dir = slot.workDir
  slot.workDir = nil
  -- Only ever delete inside our own scratch root.
  if dir and dir:sub(1, #WORK_ROOT + 1) == WORK_ROOT .. "/" then
      hs.task.new("/bin/rm", function() end, { "-rf", dir }):start()
  end
end

-- Used after kill/cancel: give the killed process a moment to exit before deleting its dir.
local function scheduleWorkCleanup(slot, delay)
  local t
  t = hs.timer.doAfter(delay, function()
      pendingCleanups[t] = nil
      cleanupWork(slot)
  end)
  pendingCleanups[t] = true
end

-- Largest regular file in the work dir that isn't a known temp artifact.
-- Only a fallback for when yt-dlp doesn't report DLPFILE.
local function findOutputFile(dir)
  if not dir then return nil end
  local best, bestSize = nil, -1
  local ok, iter, state = pcall(hs.fs.dir, dir)
  if not ok or not iter then return nil end
  for name in iter, state do
      if name:sub(1, 1) ~= "."
          and not name:match("%.part$") and not name:match("%.ytdl$")
          and not name:match("%.h264tmp%.mp4$") then
          local attr = hs.fs.attributes(dir .. "/" .. name)
          if attr and attr.mode == "file" and attr.size > bestSize then
              best, bestSize = dir .. "/" .. name, attr.size
          end
      end
  end
  return best
end

-- First free name in DOWNLOAD_DIR: name.ext, then name_01.ext, name_02.ext, ...
local function uniqueDest(name)
  local base, ext = name:match("^(.*)(%.[^./]+)$")
  if not base then base, ext = name, "" end

  local dest = DOWNLOAD_DIR .. "/" .. name
  local n = 0
  while hs.fs.attributes(dest) do
      n = n + 1
      if n > 999 then
          dest = string.format("%s/%s_%d%s", DOWNLOAD_DIR, base, os.time(), ext)
          break
      end
      dest = string.format("%s/%s_%02d%s", DOWNLOAD_DIR, base, n, ext)
  end
  return dest
end

-- Move a finished file out of its work dir into DOWNLOAD_DIR without ever overwriting.
-- The check and the rename run back-to-back on the main thread, so two downloads
-- finishing together can't pick the same name.
local function moveToFinal(path)
  local name = path:match("([^/]+)$")
  if not name then return nil, "bad path" end
  local dest = uniqueDest(name)
  local ok, err = os.rename(path, dest)
  if not ok then return nil, err end
  return dest
end

-- ── Slot helpers ──
-- Stop a slot's current process + watchdog and release its key. Callers decide
-- whether to notify / advance the queue.
local function killSlot(slot)
  slot.cancelled = true
  scheduleWorkCleanup(slot, 2)
  if slot.watchdog then slot.watchdog:stop(); slot.watchdog = nil end
  if slot.task then pcall(function() slot.task:terminate() end) end
  if activeSlots[slot.key] == slot then activeSlots[slot.key] = nil end
end

-- Inactivity watchdog: re-armed whenever yt-dlp produces output, so slow-but-moving
-- downloads are never killed; only ones that go silent for INACTIVITY_TIMEOUT seconds.
local function onStall(slot)
  if slot.cancelled then return end
  killSlot(slot)
  notifyFailed(slot.url, slot.audioOnly, "Stalled: no activity for " .. INACTIVITY_TIMEOUT .. "s")
  processQueue()
end

local function armWatchdog(slot)
  if slot.watchdog then slot.watchdog:stop() end
  slot.lastArm  = hs.timer.secondsSinceEpoch()
  slot.watchdog = hs.timer.doAfter(INACTIVITY_TIMEOUT, function() onStall(slot) end)
end

-- ── Output parsing ──
local function consumeLine(slot, line)
  line = line:match("^%s*(.-)%s*$")
  if line == "" then return end

  local prog = line:match("^DLPPROG%s+(.+)$")
  if prog then
      slot.progress = (prog:gsub("%s+", " "))
      return
  end

  local fp = line:match("^DLPFILE:(.+)$")
  if fp then slot.filePath = fp; return end

  table.insert(slot.log, line)
  if #slot.log > 200 then table.remove(slot.log, 1) end

  local err = line:match("^ERROR:%s*(.+)$")
  if err then slot.lastError = err end
end

local function makeStreamCallback(slot)
  return function(_, out, err)
      for which, data in pairs({ out = out, err = err }) do
          if data and data ~= "" then
              local rest = slot.partial[which] .. (data:gsub("\r", "\n"))
              while true do
                  local nl = rest:find("\n", 1, true)
                  if not nl then break end
                  consumeLine(slot, rest:sub(1, nl - 1))
                  rest = rest:sub(nl + 1)
              end
              slot.partial[which] = rest
          end
      end

      -- Heartbeat (throttled so we don't churn timers on every progress line).
      if not slot.cancelled and slot.watchdog
          and hs.timer.secondsSinceEpoch() - (slot.lastArm or 0) > 2 then
          armWatchdog(slot)
      end
      return true
  end
end

-- Turn the last yt-dlp "ERROR:" line into something short enough for a notification.
local function cleanError(raw)
  if not raw or raw == "" then return nil end
  local msg = raw
  msg = msg:gsub("^%[[^%]]+%]%s+[^%s:]+:%s*", "")   -- "[youtube] ID: " prefix
  msg = msg:gsub("%s*;%s*please report.*$", "")
  msg = msg:gsub("%s*Confirm you are on the latest version.*$", "")
  msg = msg:gsub("%s+", " ")
  return shorten(msg, 110)
end

-- ── H.264 conversion ──
local function probeStreams(path, cb)
  hs.task.new(FFPROBE, function(code, out)
      local info = {}
      if code == 0 then
          local ok, data = pcall(hs.json.decode, out)
          if ok and type(data) == "table" and type(data.streams) == "table" then
              for _, s in ipairs(data.streams) do
                  if s.codec_type == "video" and not info.video then
                      info.video = s.codec_name
                      info.pix   = s.pix_fmt
                  elseif s.codec_type == "audio" and not info.audio then
                      info.audio = s.codec_name
                  end
              end
          end
      end
      cb(info)
  end, {
      "-v", "error",
      "-show_entries", "stream=codec_name,codec_type,pix_fmt",
      "-of", "json",
      path,
  }):start()
end

-- Re-encodes only what's needed: video is copied if it's already 8-bit H.264,
-- audio is copied if it's already AAC. Keeps the original on any failure.
local function ensureH264(slot, filePath, done)
  probeStreams(filePath, function(info)
      if slot.cancelled then return end

      local v, a = info.video, info.audio
      if not v then return done(filePath) end

      local pixOk   = (info.pix == nil) or info.pix == "yuv420p" or info.pix == "yuvj420p"
      local videoOk = (v == "h264") and pixOk
      local audioOk = (a == nil) or (a == "aac")
      if videoOk and audioOk then return done(filePath) end

      local base  = filePath:gsub("%.[^./]+$", "")
      local final = base .. ".mp4"
      local tmp   = base .. ".h264tmp.mp4"

      slot.stage = "convert"
      updateMenu()

      local function encode(useHW)
          local args = { "-y", "-v", "error", "-i", filePath,
                         "-map", "0:v:0", "-map", "0:a?",
                         "-map_metadata", "0", "-map_chapters", "0" }

          if videoOk then
              for _, x in ipairs({ "-c:v", "copy" }) do table.insert(args, x) end
          elseif useHW then
              for _, x in ipairs({ "-c:v", "h264_videotoolbox", "-q:v", tostring(VT_QUALITY),
                                   "-pix_fmt", "yuv420p", "-tag:v", "avc1" }) do table.insert(args, x) end
          else
              for _, x in ipairs({ "-c:v", "libx264", "-crf", tostring(X264_CRF), "-preset", "fast",
                                   "-pix_fmt", "yuv420p" }) do table.insert(args, x) end
          end

          if audioOk then
              for _, x in ipairs({ "-c:a", "copy" }) do table.insert(args, x) end
          else
              for _, x in ipairs({ "-c:a", "aac", "-b:a", "192k" }) do table.insert(args, x) end
          end

          for _, x in ipairs({ "-movflags", "+faststart", tmp }) do table.insert(args, x) end

          if not (not videoOk and not useHW and USE_HW_ENCODER) then
              -- (skip the toast on the software retry after a hardware failure)
              notify({
                  icon = "🔄", title = "Converting",
                  message = v .. (a and ("/" .. a) or "") .. " → h264/aac",
                  duration = 4,
              })
          end

          local task = hs.task.new(FFMPEG, function(code, _, stderr)
              if slot.cancelled then
                  os.remove(tmp)
                  return
              end

              if code == 0 then
                  os.rename(tmp, final)
                  if final ~= filePath then os.remove(filePath) end
                  return done(final)
              end

              os.remove(tmp)
              if not videoOk and useHW then
                  print("Auto-dlp: videotoolbox failed, retrying with libx264")
                  if stderr and stderr ~= "" then print(stderr) end
                  return encode(false)
              end

              if stderr and stderr ~= "" then print(stderr) end
              notify({ icon = "⚠", title = "Conversion Failed",
                       message = "Kept original (" .. v .. ")", duration = 5 })
              done(filePath)
          end, args)

          -- Register on the slot so Cancel / Stop All kill ffmpeg too.
          slot.task = task
          task:start()
      end

      encode((not videoOk) and USE_HW_ENCODER)
  end)
end

-- ── Pending batch / cancellation helpers ──
local function startPendingBatch()
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  if not pendingBatch then return end

  local batchAudioOnly = (pendingBatchMode == "audio")
  for _, url in ipairs(pendingBatch) do
      table.insert(queue, { url = url, audioOnly = batchAudioOnly })
  end

  pendingBatch     = nil
  pendingBatchMode = nil
  pendingDeadline  = nil
  dismissTagged("detected")
  processQueue()
end

local function cancelPending()
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  pendingBatch     = nil
  pendingBatchMode = nil
  pendingDeadline  = nil
  updateMenu()
end

cancelSlot = function(key)
  local slot = activeSlots[key]
  if not slot then return end

  killSlot(slot)
  updateMenu()
  notify({
      icon  = "⛔",
      title = "Download Cancelled",
      message = slot.url,
      duration = 3,
  })
  processQueue()
end

local function cancelAll()
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  pendingBatch     = nil
  pendingBatchMode = nil
  pendingDeadline  = nil
  queue            = {}

  local slots = {}
  for _, slot in pairs(activeSlots) do table.insert(slots, slot) end
  for _, slot in ipairs(slots) do killSlot(slot) end

  -- Drop anything already queued and replace it with a single confirmation.
  notifyQueue = {}
  updateMenu()
  notify({
      icon  = "⛔",
      title = "Cancelled",
      message = "All pending and active downloads stopped",
      duration = 3,
  })
end

-- ── Manual URL (bypasses the allow-list, uses a chosen mode) ──
-- A custom webview dialog rather than hs.dialog.textPrompt: the native prompt
-- uses a single-line NSTextField which scrolls to the caret on paste, so long
-- URLs only show their tail. A wrapping <textarea> keeps the whole link visible
-- and gives us room for Video/Audio buttons inside the panel.
local URL_DIALOG_HTML = [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; padding: 16px 18px;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: #1e1e1e; color: #fff; overflow: hidden;
  }
  h1 { font-size: 14px; font-weight: 600; margin: 0 0 3px; }
  .sub { font-size: 11px; color: #9a9a9a; margin: 0 0 10px; }
  textarea {
    width: 100%; height: 62px; resize: none; display: block;
    white-space: pre-wrap; word-break: break-all; overflow-wrap: anywhere;
    background: #2a2a2a; color: #fff;
    border: 1px solid #3a3a3a; border-radius: 8px;
    padding: 8px 10px; font-size: 12.5px; line-height: 1.35;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    outline: none;
  }
  textarea:focus { border-color: #3a6df0; }
  textarea::placeholder { color: #666; }
  .err { height: 14px; margin: 4px 2px 0; font-size: 11px; color: #ff6b6b; }
  .modes { display: flex; margin: 8px 0 14px; }
  .mode {
    flex: 1; padding: 7px 0; text-align: center; font-size: 12.5px;
    background: #2a2a2a; color: #cfcfcf; cursor: default;
    border: 1px solid #3a3a3a; user-select: none; -webkit-user-select: none;
  }
  .mode:first-child { border-radius: 8px 0 0 8px; }
  .mode:last-child  { border-radius: 0 8px 8px 0; border-left: none; }
  .mode.active { background: #3a6df0; border-color: #3a6df0; color: #fff; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; }
  button {
    padding: 7px 18px; border-radius: 8px; font-size: 12.5px;
    border: 1px solid #3a3a3a; background: #2a2a2a; color: #fff;
    cursor: default; outline: none;
  }
  button.primary { background: #3a6df0; border-color: #3a6df0; }
</style>
</head>
<body>
  <h1>Download from URL</h1>
  <p class="sub">Paste any media URL &mdash; the allow-list is bypassed.</p>
  <textarea id="url" spellcheck="false" placeholder="https://..."></textarea>
  <div class="err" id="err"></div>
  <div class="modes">
    <div class="mode" id="mVideo">Video</div>
    <div class="mode" id="mAudio">Audio</div>
  </div>
  <div class="actions">
    <button id="cancel">Cancel</button>
    <button id="download" class="primary">Download</button>
  </div>
<script>
  var selected = "video";
  var ERR = document.getElementById("err");
  function setMode(m) {
    selected = m;
    document.getElementById("mVideo").classList.toggle("active", m === "video");
    document.getElementById("mAudio").classList.toggle("active", m === "audio");
  }
  function post(action) {
    var url = document.getElementById("url").value.trim();
    if (action === "download" && !/^https?:\/\/\S+$/i.test(url)) {
      ERR.textContent = "Please enter a valid http(s) link.";
      return;
    }
    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.autoDlp;
    if (!h) { ERR.textContent = "Hammerspoon bridge unavailable - reload the config."; return; }
    try {
      h.postMessage({ action: action, url: url, mode: selected });
    } catch (e) {
      ERR.textContent = "postMessage failed: " + (e && e.message ? e.message : e);
    }
  }
  document.getElementById("mVideo").onclick   = function() { setMode("video"); };
  document.getElementById("mAudio").onclick   = function() { setMode("audio"); };
  document.getElementById("cancel").onclick   = function() { post("cancel"); };
  document.getElementById("download").onclick = function() { post("download"); };
  document.getElementById("url").addEventListener("keydown", function(e) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { post("download"); }
    if (e.key === "Escape") { post("cancel"); }
  });
  window.addEventListener("load", function() {
    setMode(window.__initialMode || "video");
    var ta = document.getElementById("url");
    ta.focus();
    ta.selectionStart = ta.selectionEnd = ta.value.length;
  });
</script>
</body>
</html>
]]

local function closeURLDialog()
  if dialogWebview then
      pcall(function() dialogWebview:delete() end)
  end
  dialogWebview = nil
  dialogController = nil
end

local function downloadFromURL()
  -- Reopen fresh each time so the suggested mode tracks the current mode.
  closeURLDialog()

  local startMode = (mode == "audio") and "audio" or "video"

  local controller = hs.webview.usercontent.new("autoDlp")
  controller:injectScript({
      source = "window.__initialMode = '" .. startMode .. "';",
      injectionTime = "documentStart",
  })

  controller:setCallback(function(scriptMessage)
      -- WKScriptMessage wraps the posted object as scriptMessage.body
      local data = (type(scriptMessage) == "table") and scriptMessage.body or nil
      if type(data) ~= "table" then return end
      local action = data.action
      local url    = data.url
      local m      = data.mode

      -- Defer so we never tear the webview down from inside its own message
      -- pump; by then the posted data has been copied into plain locals.
      hs.timer.doAfter(0, function()
          if action == "cancel" then
              closeURLDialog()
          elseif action == "download" then
              closeURLDialog()

              url = tostring(url or ""):match("^%s*(.-)%s*$") or ""
              if not url:match("^https?://") then
                  notify({
                      icon  = "⚠",
                      title = "Invalid URL",
                      message = "Please enter a valid http(s) link.",
                      duration = 3,
                  })
                  return
              end

              local audioOnly = (m == "audio")
              table.insert(queue, { url = url, audioOnly = audioOnly })
              notify({
                  icon  = "⬇",
                  title = "Queued",
                  message = (audioOnly and "Audio" or "Video") .. " download added manually",
                  duration = 3,
              })
              processQueue()
          end
      end)
  end)

  local sf = hs.screen.mainScreen():frame()
  local w, h = 460, 252
  local rect = {
      x = sf.x + (sf.w - w) / 2,
      y = sf.y + (sf.h - h) / 2,
      w = w,
      h = h,
  }

  local wv = hs.webview.newBrowser(rect, {
      developerExtrasEnabled = false,
  }, controller)

  wv:windowTitle("Download from URL")
  wv:deleteOnClose(true)
  wv:closeOnEscape(false)
  pcall(function() wv:darkMode(true) end)
  wv:html(URL_DIALOG_HTML)
  wv:show()
  wv:bringToFront(true)
  pcall(function() wv:hswindow():focus() end)

  dialogWebview = wv
  dialogController = controller
end

-- ── Mode switching ──
local function setMode(newMode)
  if mode == newMode then
      updateMenu()
      return
  end

  mode = newMode
  updateMenu()
  notify({
      tag   = "mode",
      icon  = ICONS[newMode],
      title = "Mode: " .. MODE_LABELS[newMode],
      message = MODE_MESSAGES[newMode],
      duration = 2,
  })
end

-- ── Menu ──
updateMenu = function()
  local ac = activeCount()
  -- Sum total active downloads, queued downloads, and pending batch items
  local total = #queue + (pendingBatch and #pendingBatch or 0) + ac

  if menubar then
      menubar:setTitle(ICONS[mode] .. " " .. total)
  end

  local menu = {}

  if pendingBatch then
      local batchTag = (pendingBatchMode == "audio") and " Audio" or " Video"
      table.insert(menu, { title = "Pending Batch (" .. #pendingBatch .. ")" .. batchTag })

      table.insert(menu, {
          title = "Start Now",
          fn = function() startPendingBatch() end
      })

      table.insert(menu, {
          title = "Cancel Pending Batch",
          fn = function() cancelPending() end
      })

      table.insert(menu, { title = "-" })
  end

  -- Live status lines for active downloads (refreshed each time the menu is opened).
  local active = {}
  for _, s in pairs(activeSlots) do table.insert(active, s) end
  table.sort(active, function(a, b) return a.seq < b.seq end)
  if #active > 0 then
      for _, s in ipairs(active) do
          local status = (s.stage == "convert") and "Converting…" or (s.progress or "Starting…")
          table.insert(menu, {
              title = (s.audioOnly and "♪ " or "▶ ") .. status .. "  " .. shorten(s.url, 40),
              disabled = true,
          })
      end
      table.insert(menu, { title = "-" })
  end

  table.insert(menu, {
      title = "Download URL…",
      fn = function() downloadFromURL() end
  })

  table.insert(menu, { title = "-" })

  table.insert(menu, {
      title = (mode == "idle") and "✓ Idle" or "Idle",
      fn = function() setMode("idle") end
  })
  table.insert(menu, {
      title = (mode == "video") and "✓ Video" or "Video",
      fn = function() setMode("video") end
  })
  table.insert(menu, {
      title = (mode == "audio") and "✓ Audio" or "Audio",
      fn = function() setMode("audio") end
  })

  table.insert(menu, { title = "-" })

  table.insert(menu, {
      title = "Stop All Downloads",
      fn = function() cancelAll() end
  })

  table.insert(menu, {
      title = "Open Download Folder",
      fn = function() openPath(DOWNLOAD_DIR) end
  })

  lastMenu = menu
end

-- ── Parallel download engine ──
-- yt-dlp exit handler. Runs once per slot; cancelled slots were already cleaned up
-- by whoever cancelled them, so they only get a menu refresh here.
local function onYtdlpExit(slot, exitCode)
  if slot.watchdog then slot.watchdog:stop(); slot.watchdog = nil end

  -- Flush any final line that arrived without a trailing newline.
  for _, which in ipairs({ "out", "err" }) do
      if slot.partial[which] ~= "" then
          consumeLine(slot, slot.partial[which])
          slot.partial[which] = ""
      end
  end

  if slot.cancelled then
      updateMenu()
      return
  end

  print("================================")
  print("URL:",  slot.url)
  print("Mode:", slot.audioOnly and "Audio" or "Video")
  print("Exit:", exitCode)
  for _, line in ipairs(slot.log) do print(line) end
  if slot.filePath then print("File:", slot.filePath) end
  print("================================")

  local function release()
      if activeSlots[slot.key] == slot then activeSlots[slot.key] = nil end
  end

  if exitCode ~= 0 then
      release()
      cleanupWork(slot)
      notifyFailed(slot.url, slot.audioOnly, cleanError(slot.lastError))
      processQueue()
      return
  end

  local filePath = slot.filePath
  if not (filePath and hs.fs.attributes(filePath)) then
      filePath = findOutputFile(slot.workDir)
  end

  if not filePath then
      release()
      cleanupWork(slot)
      notifyFailed(slot.url, slot.audioOnly, "yt-dlp finished but produced no file")
      processQueue()
      return
  end

  -- Last step for every path (converted, unconverted, audio): move into DOWNLOAD_DIR
  -- under a name that doesn't exist yet. History is only written once the file is there.
  local function finish(path)
      if slot.cancelled then return end

      local dest, err = moveToFinal(path)
      release()

      if dest then
          saveHistory(slot.key)
          cleanupWork(slot)
          notifyComplete(dest, slot.audioOnly)
      else
          print("Auto-dlp: could not move " .. path .. " (" .. tostring(err) .. ")")
          notify({
              icon  = "⚠",
              title = "Couldn't Move File",
              message = "Left in the hidden .work folder",
              duration = 10,
              buttons = {
                  { label = "Show in Finder", fn = function() openPath("-R", path) end },
              },
          })
      end
      processQueue()
  end

  if slot.audioOnly or not TRANSCODE_TO_H264 then
      finish(filePath)
  else
      ensureH264(slot, filePath, finish)
  end
end

processQueue = function()
  updateMenu()

  while activeCount() < MAX_CONCURRENT and #queue > 0 do
      local item = table.remove(queue, 1)
      local key  = makeKey(item.url, item.audioOnly)

      if not activeSlots[key] then
          slotCounter = slotCounter + 1
          local slot = {
              key       = key,
              url       = item.url,
              audioOnly = item.audioOnly,
              seq       = slotCounter,
              stage     = "download",
              partial   = { out = "", err = "" },
              log       = {},
              workDir   = string.format("%s/%d-%d", WORK_ROOT, os.time(), slotCounter),
          }
          os.execute('mkdir -p "' .. slot.workDir .. '"')
          activeSlots[key] = slot

          notifyDownloadStarted(item.url, item.audioOnly)
          armWatchdog(slot)

          local task = hs.task.new(
              YTDLP,
              function(exitCode) onYtdlpExit(slot, exitCode) end,
              makeStreamCallback(slot),
              buildArgs(item.url, item.audioOnly, slot.workDir)
          )

          if task then
              slot.task = task
              task:start()
          else
              killSlot(slot)
              notifyFailed(item.url, item.audioOnly, "Could not launch yt-dlp")
          end

          updateMenu()
      end
  end
end

-- UNLOAD FUNCTION (Crucial for /Spoons)
function hs.auto_dlp_unload()
   if clipboardWatcher then
       clipboardWatcher:stop()
       clipboardWatcher = nil
   end
   if rightClickWatcher then
       rightClickWatcher:stop()
       rightClickWatcher = nil
   end
   if pendingTimer then
       pendingTimer:stop()
       pendingTimer = nil
   end
   if cleanupTimer then
       cleanupTimer:stop()
       cleanupTimer = nil
   end
   closeURLDialog()
   stopNotifTimers()
   if notifCanvas then
       pcall(function() notifCanvas:delete() end)
       notifCanvas = nil
   end
   local slots = {}
   for _, slot in pairs(activeSlots) do table.insert(slots, slot) end
   for _, slot in ipairs(slots) do killSlot(slot) end
   if menubar then
       menubar:delete()
       menubar = nil
   end
end

-- Chain onto hs.shutdownCallback instead of overwriting it, so other scripts
-- (aural.lua etc.) keep their own handlers. The guard stops wrappers stacking
-- when this file is reloaded without restarting Hammerspoon.
if not hs._autoDlpShutdownHooked then
  hs._autoDlpShutdownHooked = true
  local prev = hs.shutdownCallback
  hs.shutdownCallback = function()
      if hs.auto_dlp_unload then hs.auto_dlp_unload() end
      if prev then prev() end
  end
end

-- ── INITIALIZATION ──
loadHistory()
cleanupTempFiles()
cleanupTimer = hs.timer.doEvery(86400, cleanupTempFiles)

clipboardWatcher = hs.pasteboard.watcher.new(function()
  if mode == "idle" then return end   -- Idle = monitoring off

  local clipboard = hs.pasteboard.getContents()
  if not clipboard or #clipboard < 10 then return end

  local audioMode = (mode == "audio")
  local urls = {}
  local seen = {}

  for url in clipboard:gmatch("https?://[%w%-%._~:/%?#%[%]@!$&%'%(%)%*%+,;=]+") do
      local clean = url:gsub("[%.,%?!;]+$", "")
      local key   = makeKey(clean, audioMode)

      if isAllowed(clean)
          and not history[key]
          and not seen[clean]
      then
          local alreadyQueued = false
          for _, item in ipairs(queue) do
              if item.url == clean and item.audioOnly == audioMode then alreadyQueued = true; break end
          end
          if not alreadyQueued and not activeSlots[key] then
              seen[clean] = true
              table.insert(urls, clean)
          end
      end
  end

  if #urls == 0 then return end

  dismissTagged("detected")
  if pendingTimer then pendingTimer:stop() end

  pendingBatch     = urls
  pendingBatchMode = mode   -- lock batch to whatever mode was active at detection time
  pendingDeadline  = hs.timer.secondsSinceEpoch() + COUNTDOWN_SECONDS

  notify({
      tag   = "detected",
      icon  = "⬇",
      title = "Media Detected (" .. #urls .. ")",
      dynamicText = function()
          local remaining = math.max(0, math.ceil(pendingDeadline - hs.timer.secondsSinceEpoch()))
          local tag = (pendingBatchMode == "audio") and "Audio" or "Video"
          return #urls .. " " .. tag .. " link(s) • auto-starting in " .. remaining .. "s"
      end,
      buttons = {
          { label = "Start Now",  fn = function() startPendingBatch() end },
          { label = "Cancel",     fn = function() cancelPending() end },
          { label = "Cancel All", fn = function() cancelAll() end },
      },
      duration = COUNTDOWN_SECONDS + 3,
  })
  updateMenu()

  pendingTimer = hs.timer.doAfter(COUNTDOWN_SECONDS, function()
      startPendingBatch()
  end)
end)

clipboardWatcher:start()

-- ── Left click = cycle Idle → Video → Audio → Idle ──
local function cycleMode()
  local currentIndex = 1
  for i, m in ipairs(MODES) do
      if m == mode then currentIndex = i; break end
  end
  setMode(MODES[(currentIndex % #MODES) + 1])
end

if menubar then
  -- setClickCallback fires on left click (setMenu is intentionally never
  -- attached, otherwise it would hijack left-click too).
  menubar:setClickCallback(function(_mods)
      cycleMode()
  end)
end

-- ── Right click = pop up the full menu ──
local function isMouseOverMenubar()
  if not menubar then return false end
  local frame = menubar:frame()
  if not frame then return false end
  local loc = hs.mouse.absolutePosition()
  return loc.x >= frame.x and loc.x <= frame.x + frame.w
      and loc.y >= frame.y and loc.y <= frame.y + frame.h
end

rightClickWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.rightMouseUp },
  function(event)
      if isMouseOverMenubar() and menubar then
          updateMenu()   -- refresh live progress lines before showing
          menubar:setMenu(lastMenu)
          menubar:popupMenu(hs.mouse.absolutePosition())
          -- Detach again so a subsequent LEFT click falls through to
          -- setClickCallback's cycle behavior instead of reopening this menu.
          menubar:setMenu(nil)
      end
      return false
  end
)
rightClickWatcher:start()

updateMenu()
notify({
  icon  = ICONS[mode],
  title = "Auto-dlp Ready",
  message = "Left-click to switch modes • Right-click for the menu",
  duration = 4,
})