-- Auto-dlp by @motionkartik

-- Paths
local HOME         = os.getenv("HOME")
local DOWNLOAD_DIR = HOME .. "/Downloads/Auto-dlp"
local HISTORY_FILE = HOME .. "/Library/Application Support/Hammerspoon/video_history.txt"
local YTDLP        = "/opt/homebrew/bin/yt-dlp"
local NODE          = "/opt/homebrew/bin/node"
local FFMPEG_DIR   = "/opt/homebrew/bin"

-- Config
local COUNTDOWN_SECONDS  = 5
local MAX_HISTORY        = 500
local DOWNLOAD_TIMEOUT   = 600 
local MAX_CONCURRENT     = 2   
local CONCURRENT_FRAGS   = 4   
local COOKIE_BROWSER     = "chrome" -- Change to: "safari", "firefox", "edge", "brave", etc.

-- Dependency Check
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
       local missingText = table.concat(missing, "\n")
      
       hs.notify.new({
           title             = "Auto-dlp: Missing Dependencies",
           informativeText   = "Please install them to enable downloads.",
           alwaysPresent     = true,
       }):send()

       hs.alert.show("Auto-dlp Error:\n\nMissing dependencies:\n" .. missingText, { textColor = { white = 1.0, alpha = 1.0 }, fillColor = { red = 0.8, green = 0.2, blue = 0.2, alpha = 0.8 } }, 10)
      
       return false
   end
  
   return true
end

-- Run check immediately. If it fails, stop the script here.
if not checkDependencies() then
   print("Auto-dlp initialization failed: Missing dependencies.")
   return true
end

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

-- State
local menubar          = hs.menubar.new()
local queue            = {}    
local history          = {}
local pendingBatch     = nil
local pendingBatchMode = nil    -- mode the pending batch was detected under ("video" / "audio"), locked at detection time
local pendingTimer     = nil

-- mode: "idle" | "video" | "audio"
local MODES  = { "idle", "video", "audio" }
local mode   = "idle"

local ICONS = {
  idle  = "⏸",
  video = "▶",
  audio = "♪",
}

local lastMenu = {}   -- most recently built menu table, shown on right-click via popupMenu

local activeSlots = {}
local clipboardWatcher = nil
local rightClickWatcher = nil

local function activeCount()
  local n = 0
  for _, s in pairs(activeSlots) do if s then n = n + 1 end end
  return n
end

-- Notifications
local function notify(title, text)
  hs.notify.new({ title = title, informativeText = text }):send()
end

local function notifyDetected(urls, batchMode)
  local modeTag = (batchMode == "audio") and " Audio" or " Video"
  hs.notify.new(
      function(n)
          if n:activationType() == hs.notify.activationTypes.actionButtonClicked then
              if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
              pendingBatch = nil
              updateMenu()
          end
      end,
      {
          title             = "Media Detected",
          informativeText   = #urls .. " download(s) queued -" .. modeTag,
          actionButtonTitle = "Cancel",
          hasActionButton   = true,
          alwaysPresent     = true,
      }
  ):send()
end

local function notifyComplete(filePath, downloadAudioOnly)
  local name = filePath:match("([^/]+)$") or (downloadAudioOnly and "Audio" or "Video")
  hs.notify.new(
      function(n)
          local t = n:activationType()
          -- Triggered by clicking the "Open" button OR clicking the notification body itself
          if t == hs.notify.activationTypes.actionButtonClicked
              or t == hs.notify.activationTypes.contentsClicked
              or t == hs.notify.activationTypes.additionalActionClicked then
              -- Reveals the specific file in Finder
              if filePath then hs.execute('open -R "' .. filePath .. '"') end
          end
      end,
      {
          title             = "Download Complete",
          informativeText   = name,
          actionButtonTitle = "Open",
          hasActionButton   = true,
          alwaysPresent     = true,
      }
  ):send()
end

-- History
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

-- Cleanup
local function cleanupTempFiles()
  os.execute('find "' .. DOWNLOAD_DIR
      .. '" \\( -name "*.part" -o -name "*.ytdl" \\) -mtime +1 -delete')
end

-- yt-dlp args builder
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

-- Domain allow-list
local function isAllowed(url)
  local lower = url:lower()
  for _, domain in ipairs(ALLOWED_DOMAINS) do
      if lower:find(domain, 1, true) then return true end
  end
  return false
end

-- Menu
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
          fn = function()
              if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
              for _, url in ipairs(pendingBatch) do
                  table.insert(queue, { url = url, audioOnly = (pendingBatchMode == "audio") })
              end
              pendingBatch = nil
              pendingBatchMode = nil
              processQueue()
          end
      })

      table.insert(menu, {
          title = "Cancel Pending Batch",
          fn = function()
              if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
              pendingBatch = nil
              pendingBatchMode = nil
              updateMenu()
          end
      })

      table.insert(menu, { title = "-" })
  end

  table.insert(menu, {
      title = (mode == "idle") and "✓ Idle" or "Idle",
      fn = function() mode = "idle"; updateMenu() end
  })
  table.insert(menu, {
      title = (mode == "video") and "✓ Video" or "Video",
      fn = function() mode = "video"; updateMenu() end
  })
  table.insert(menu, {
      title = (mode == "audio") and "✓ Audio" or "Audio",
      fn = function() mode = "audio"; updateMenu() end
  })

  table.insert(menu, { title = "-" })

  table.insert(menu, {
      title = "Stop All Downloads",
      fn = function()
          for slotId, slot in pairs(activeSlots) do
              if slot then
                  if slot.watchdog then slot.watchdog:stop() end
                  if slot.task    then slot.task:terminate() end
                  activeSlots[slotId] = nil
              end
          end
          queue = {}
          if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
          pendingBatch = nil
          notify("Downloads Stopped", "All slots cleared")
          updateMenu()
      end
  })

  table.insert(menu, {
      title = "Open Download Folder",
      fn = function() hs.execute('open "' .. DOWNLOAD_DIR .. '"') end
  })

  lastMenu = menu
end

-- Parallel download engine
function processQueue()
  updateMenu()

  while activeCount() < MAX_CONCURRENT and #queue > 0 do
      local item           = table.remove(queue, 1)
      local url            = item.url
      local downloadAudioOnly = item.audioOnly

      local slotId = url

      notify("Download Started",
          (downloadAudioOnly and "Audio" or "Video") .. " " .. url)

      local args = buildArgs(url, downloadAudioOnly)

      local watchdog = hs.timer.doAfter(DOWNLOAD_TIMEOUT, function()
          local slot = activeSlots[slotId]
          if slot and slot.task then
              slot.task:terminate()
              activeSlots[slotId] = nil
              notify("Download Timed Out", url)
              processQueue()
          end
      end)

      local task = hs.task.new(
          YTDLP,
          function(exitCode, stdout, stderr)
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
                  notify("Download Failed", "Check Hammerspoon Console")
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

-- INITIALIZATION
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
      url = url:gsub("[%.,%?!;]+$", "")

      if isAllowed(url)
          and not history[url]
          and not seen[url]
      then
          local alreadyQueued = false
          for _, item in ipairs(queue) do
              if item.url == url then alreadyQueued = true; break end
          end
          if not alreadyQueued and not activeSlots[url] then
              seen[url] = true
              table.insert(urls, url)
          end
      end
  end

  if #urls == 0 then return end

  if pendingTimer then pendingTimer:stop() end
  pendingBatch     = urls
  pendingBatchMode = mode   -- lock batch to whatever mode was active at detection time
  notifyDetected(urls, pendingBatchMode)
  updateMenu()

  pendingTimer = hs.timer.doAfter(COUNTDOWN_SECONDS, function()
      if not pendingBatch then return end

      local batchAudioOnly = (pendingBatchMode == "audio")
      for _, url in ipairs(pendingBatch) do
          table.insert(queue, { url = url, audioOnly = batchAudioOnly })
      end
      pendingBatch     = nil
      pendingBatchMode = nil
      pendingTimer     = nil

      processQueue()
  end)
end)

clipboardWatcher:start()

-- ── Left click = cycle Idle → Video → Audio → Idle ──
local function cycleMode()
  local currentIndex = 1
  for i, m in ipairs(MODES) do
      if m == mode then currentIndex = i; break end
  end
  mode = MODES[(currentIndex % #MODES) + 1]
  updateMenu()
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
notify("Auto-dlp started", "Left-click the menu bar icon to switch modes")