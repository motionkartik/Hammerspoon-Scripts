-- Auto-dlp by @motionkartik

-- ── Paths ──
local HOME         = os.getenv("HOME")
local DOWNLOAD_DIR = HOME .. "/Downloads/Auto-dlp"
local HISTORY_FILE = HOME .. "/Library/Application Support/Hammerspoon/video_history.txt"
local YTDLP        = "/opt/homebrew/bin/yt-dlp"
local NODE         = "/opt/homebrew/bin/node"
local FFMPEG_DIR   = "/opt/homebrew/bin"

-- ── Config ──
local COUNTDOWN_SECONDS  = 5
local MAX_HISTORY        = 500
local DOWNLOAD_TIMEOUT   = 600   
local MAX_CONCURRENT     = 2   
local CONCURRENT_FRAGS   = 4   
local COOKIE_BROWSER     = "chrome" -- Change to: "safari", "firefox", "edge", "brave", etc.

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

local activeSlots = {}
local terminating = {}   -- slotId -> true when we intentionally stop a task (suppress "failed")
local clipboardWatcher = nil
local rightClickWatcher = nil

-- Forward declaration (assigned further down).
local cancelSlot

local dialogWebview    = nil   -- the manual "Download from URL" webview, when open
local dialogController = nil   -- its hs.webview.usercontent controller; must stay
                               -- referenced or GC drops the message callback

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

  canvas:appendElements({
      type = "text",
      text = spec.title or "",
      textSize = 15,
      textColor = { white = 1, alpha = 1 },
      textAlignment = "left",
      textLineBreak = "truncateTail",
      frame = { x = NOTIF_PAD + NOTIF_ICON + 10, y = NOTIF_PAD + 2,
                w = NOTIF_WIDTH - NOTIF_PAD * 2 - NOTIF_ICON - 10, h = 22 },
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
  notify({
      icon  = audioOnly and ICONS.audio or ICONS.video,
      title = "Download Started",
      message = (audioOnly and "Audio" or "Video") .. " • " .. url,
      duration = 8,
      buttons = {
          { label = "Cancel", fn = function() cancelSlot(url) end },
      },
  })
end

local function notifyComplete(filePath, audioOnly)
  local name = filePath and filePath:match("([^/]+)$") or (audioOnly and "Audio" or "Video")
  notify({
      icon  = "✅",
      title = "Download Complete",
      message = name or "",
      duration = 8,
      buttons = {
          { label = "Open",      fn = function() if filePath then hs.execute('open -R "' .. filePath .. '"') end end },
          { label = "Open File", fn = function() if filePath then hs.execute('open "' .. filePath .. '"') end end },
      },
  })
end

local function notifyFailed(url, audioOnly)
  notify({
      icon  = "❌",
      title = "Download Failed",
      message = url,
      duration = 8,
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

  local ffmpeg_exists = hs.fs.attributes(FFMPEG_DIR .. "/ffmpeg")
  if not ffmpeg_exists then
      table.insert(missing, "ffmpeg (" .. FFMPEG_DIR .. "/ffmpeg)")
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

local function activeCount()
  local n = 0
  for _, s in pairs(activeSlots) do if s then n = n + 1 end end
  return n
end

-- ── History ──
local function loadHistory()
  local file = io.open(HISTORY_FILE, "r")
  if not file then return end

  local lines = {}
  for line in file:lines() do table.insert(lines, line) end
  file:close()

  local start = math.max(1, #lines - MAX_HISTORY + 1)
  for i = start, #lines do history[lines[i]] = true end

  if #lines > MAX_HISTORY then
      local out = io.open(HISTORY_FILE, "w")
      if out then
          for i = start, #lines do out:write(lines[i] .. "\n") end
          out:close()
      end
  end
end

local function saveHistory(url)
  local file = io.open(HISTORY_FILE, "a")
  if file then file:write(url .. "\n"); file:close() end
  history[url] = true
end

-- ── Cleanup ──
local function cleanupTempFiles()
  os.execute('find "' .. DOWNLOAD_DIR
      .. '" \\( -name "*.part" -o -name "*.ytdl" \\) -mtime +1 -delete')
end

-- ── yt-dlp args builder ──
local function buildArgs(url, audioOnly)
  local outTemplate = DOWNLOAD_DIR .. "/%(title)s.%(ext)s"
  local args = {
      "--js-runtimes",         "node:" .. NODE,
      "--ffmpeg-location",     FFMPEG_DIR,
      "--restrict-filenames",
      "--no-playlist",
      "--concurrent-fragments", tostring(CONCURRENT_FRAGS),
      "--cookies-from-browser", COOKIE_BROWSER,
      "--print",               "after_move:filepath",
      "-o",                    outTemplate,
  }

  if audioOnly then
      local extra = {
          "-f", "bestaudio/best",
          "--extract-audio",
          "--audio-format", "mp3",
          "--audio-quality", "0",
      }
      for _, v in ipairs(extra) do table.insert(args, v) end
  else
      local extra = {
          "-f", "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo+bestaudio",
          "--merge-output-format", "mp4",
          "--postprocessor-args",
              "ffmpeg:-c:v libx264 -crf 23 -preset fast -c:a copy",
      }
      for _, v in ipairs(extra) do table.insert(args, v) end
  end

  table.insert(args, url)
  return args
end

-- ── Domain allow-list ──
local function isAllowed(url)
  local lower = url:lower()
  for _, domain in ipairs(ALLOWED_DOMAINS) do
      if lower:find(domain, 1, true) then return true end
  end
  return false
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

cancelSlot = function(slotId)
  local slot = activeSlots[slotId]
  if not slot then return end

  terminating[slotId] = true
  if slot.watchdog then slot.watchdog:stop() end
  if slot.task    then slot.task:terminate() end
  activeSlots[slotId] = nil

  updateMenu()
  notify({
      icon  = "⛔",
      title = "Download Cancelled",
      message = slotId,
      duration = 3,
  })
end

local function cancelAll()
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  pendingBatch     = nil
  pendingBatchMode = nil
  pendingDeadline  = nil
  queue            = {}

  for slotId, slot in pairs(activeSlots) do
      if slot then
          terminating[slotId] = true
          if slot.watchdog then slot.watchdog:stop() end
          if slot.task    then slot.task:terminate() end
          activeSlots[slotId] = nil
      end
  end

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
function updateMenu()
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
      fn = function() hs.execute('open "' .. DOWNLOAD_DIR .. '"') end
  })

  lastMenu = menu
end

-- ── Parallel download engine ──
function processQueue()
  updateMenu()

  while activeCount() < MAX_CONCURRENT and #queue > 0 do
      local item           = table.remove(queue, 1)
      local url            = item.url
      local downloadAudioOnly = item.audioOnly

      local slotId = url

      notifyDownloadStarted(url, downloadAudioOnly)

      local args = buildArgs(url, downloadAudioOnly)

      local watchdog = hs.timer.doAfter(DOWNLOAD_TIMEOUT, function()
          local slot = activeSlots[slotId]
          if slot and slot.task then
              terminating[slotId] = true
              if slot.watchdog then slot.watchdog:stop() end
              slot.task:terminate()
              activeSlots[slotId] = nil
              notify({
                  icon  = "⏱",
                  title = "Download Timed Out",
                  message = url,
                  duration = 3,
              })
              processQueue()
          end
      end)

      local task = hs.task.new(
          YTDLP,
          function(exitCode, stdout, stderr)
              -- A cancel/timeout already cleaned this slot up; don't double-report.
              if terminating[slotId] then
                  terminating[slotId] = nil
                  updateMenu()
                  processQueue()
                  return
              end

              local slot = activeSlots[slotId]
              if slot and slot.watchdog then slot.watchdog:stop() end
              activeSlots[slotId] = nil

              print("================================")
              print("URL:",  url)
              print("Mode:", downloadAudioOnly and "Audio" or "Video")
              print("Exit:", exitCode)
              if stdout and stdout ~= "" then print(stdout) end
              if stderr and stderr ~= "" then print(stderr) end
              print("================================")

              if exitCode == 0 then
                  saveHistory(url)

                  local filePath = nil
                  for line in (stdout or ""):gmatch("[^\n]+") do
                      local trimmed = line:match("^%s*(.-)%s*$")
                      if trimmed ~= "" then filePath = trimmed end
                  end
                  filePath = filePath
                      or (DOWNLOAD_DIR .. "/" .. (downloadAudioOnly and "audio.mp3" or "video.mp4"))

                  notifyComplete(filePath, downloadAudioOnly)
              else
                  notifyFailed(url, downloadAudioOnly)
              end

              processQueue()
          end,
          args
      ):start()

      activeSlots[slotId] = { task = task, watchdog = watchdog }
      updateMenu()
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
   stopNotifTimers()
   if notifCanvas then
       pcall(function() notifCanvas:delete() end)
       notifCanvas = nil
   end
   for slotId, slot in pairs(activeSlots) do
       if slot then
           if slot.watchdog then slot.watchdog:stop() end
           if slot.task    then slot.task:terminate() end
           activeSlots[slotId] = nil
       end
   end
   if menubar then
       menubar:delete()
       menubar = nil
   end
end

-- Ensure we clean up if Hammerspoon is quitting
hs.shutdownCallback = hs.auto_dlp_unload

-- ── INITIALIZATION ──
loadHistory()
cleanupTempFiles()
hs.timer.doEvery(86400, cleanupTempFiles)

clipboardWatcher = hs.pasteboard.watcher.new(function()
  if mode == "idle" then return end   -- Idle = monitoring off

  local clipboard = hs.pasteboard.getContents()
  if not clipboard or #clipboard < 10 then return end

  local urls = {}
  local seen = {}

  for url in clipboard:gmatch("https?://[%w%-%._~:/%?#%[%]@!$&%'%(%)%*%+,;=]+") do
      local clean = url:gsub("[%.,%?!;]+$", "")

      if isAllowed(clean)
          and not history[clean]
          and not seen[clean]
      then
          local alreadyQueued = false
          for _, item in ipairs(queue) do
              if item.url == clean then alreadyQueued = true; break end
          end
          if not alreadyQueued and not activeSlots[clean] then
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
