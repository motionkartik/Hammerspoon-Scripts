-- gboard_clip.lua  (menubar edition)
-- Hammerspoon <-> Gboard web clipboard (jasonwu1994/Gboard-patches)
-- Endpoints: POST /clipboard | GET /state | GET /status | GET /events (SSE)
-- Every request carries ?code=<pairing>&clientId=<uuid>
-- HTTPS port is always HTTP port + 1, so only the HTTP port is configurable.
--
-- Discovery policy: ONE scan only (Bonjour first, subnet sweep as fallback),
-- stopping as soon as a device is found. If nothing is found, a clickable popup
-- offers a rescan; ignore it and the script stays idle until you press
-- Connect / Find devices yourself.

local M = {}
local SETTINGS_KEY = "gboardclip.cfg"

----------------------------------------------------------------
-- CONFIG (persisted via hs.settings, editable from the menubar)
----------------------------------------------------------------
local defaults = {
  host = "",            -- last device found (filled in by discovery)
  port = 4455,          -- HTTP port; HTTPS = port + 1
  code = "",
  autoReceive = true, autoSend = false, autoConnect = true, autoRescan = true,
  paused = false,       -- pause = no automatic sending or receiving
  popupEnabled = true,
  popupDuration = 3.5,
  popupMaxChars = 280,
  maxClipboardBytes = 2 * 1024 * 1024,
  richText = false,
  logLevel = "info",
}
local cfg = {}
do
  local saved = hs.settings.get(SETTINGS_KEY) or {}
  for k, v in pairs(defaults) do
    if saved[k] ~= nil then cfg[k] = saved[k] else cfg[k] = v end
  end
end
local function saveCfg() hs.settings.set(SETTINGS_KEY, cfg) end

M.sendHotkey  = { {"cmd", "alt", "ctrl"}, "P" }
M.pauseHotkey = { {"ctrl", "cmd", "shift"}, "P" }
local CURL = "/usr/bin/curl"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local clientId    = hs.host.uuid()
local sseTask, retryTimer, pbWatcher, menubar
local buf         = ""
local wantOn      = false      -- user wants the connection up
local connected   = false      -- got a `meta` event from the portal
local clients     = {}         -- from `clients` events
local lastApplied, lastSent, lastIncoming
local lastCount   = hs.pasteboard.changeCount()
local found       = {}         -- devices discovered by the LAN scan
local scanning    = false
local failCount   = 0          -- consecutive failed connects
local autoScanUsed = false     -- one automatic scan per outage; reset when connected
local connectionGeneration = 0
local scanGeneration = 0
local activeScanCancel
local connectionStartedAt, lastSyncAt, lastSyncDirection, lastError
local lastDiscoveryMethod = "not yet scanned"
local retryDelay = 3
local syncWatcher              -- forward declaration (defined near the bottom)
local LOG_LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }

local function log(level, message)
  if (LOG_LEVELS[level] or 3) <= (LOG_LEVELS[cfg.logLevel] or 3) then
    print(string.format("[gboard-clip][%s] %s", level:upper(), tostring(message)))
  end
end

local note

local function setError(message)
  lastError = tostring(message)
  log("error", lastError)
  note(lastError)
end

local function validPort(n)
  return type(n) == "number" and n == math.floor(n) and n >= 1024 and n <= 65534
end

local function validIPv4(ip)
  if type(ip) ~= "string" then return false end
  local a,b,c,d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, v in ipairs({a,b,c,d}) do if tonumber(v) > 255 then return false end end
  return true
end

local function byteCount(text) return #(text or "") end

local function httpPort()  return tonumber(cfg.port) or 4455 end
local function httpsPort() return httpPort() + 1 end

local function base()
  return string.format("http://%s:%d", cfg.host, httpPort())
end

local function url(path)
  return string.format("%s%s?code=%s&clientId=%s", base(), path,
    hs.http.encodeForQuery(cfg.code or ""), hs.http.encodeForQuery(clientId))
end

note = function(msg)
  hs.notify.new({ title = "Gboard Clipboard", informativeText = msg, withdrawAfter = 3 }):send()
end

local function configured() return cfg.host ~= nil and cfg.host ~= "" end

----------------------------------------------------------------
-- POPUP under the menubar icon (shows the actual clipboard text)
-- opts: { duration = seconds, onClick = function }
----------------------------------------------------------------
local popup, popupTimer

local function dismissPopup()
  if popupTimer then popupTimer:stop(); popupTimer = nil end
  if popup then
    local c = popup; popup = nil
    c:hide(0.2)
    hs.timer.doAfter(0.3, function() c:delete() end)
  end
end

local ACCENT = {
  send = { red = 0.35, green = 0.62, blue = 1.00 },   -- Mac -> phone (blue)
  recv = { red = 0.30, green = 0.85, blue = 0.50 },   -- phone -> Mac (green)
  info = { red = 0.72, green = 0.72, blue = 0.78 },   -- connected / resumed (grey)
  pause = { red = 1.00, green = 0.75, blue = 0.25 },  -- paused (amber)
  ask = { red = 1.00, green = 0.55, blue = 0.25 },    -- action needed (orange)
}

local function showPopup(text, dir, opts)
  opts = opts or {}
  if not text or text == "" then return end

  -- Disabling previews hides clipboard contents, not synchronization feedback.
  -- "ask" prompts are always shown because they need your action.
  if not cfg.popupEnabled then
    if dir == "send" then
      text = "Sent to phone"
    elseif dir == "recv" then
      text = "Received from phone"
    elseif dir ~= "ask" then
      return
    end
  end

  local accent = ACCENT[dir] or ACCENT.recv
  if popupTimer then popupTimer:stop(); popupTimer = nil end
  if popup then popup:delete(); popup = nil end

  local shown = (text:gsub("\r", "")):gsub("^%s+", "")
  shown = shown:gsub("%s+$", "")
  local MAX = math.max(40, math.min(2000, tonumber(cfg.popupMaxChars) or 280))
  local n = utf8.len(shown)
  if n and n > MAX then shown = shown:sub(1, utf8.offset(shown, MAX + 1) - 1) .. "…" end

  local lines = 0
  for ln in (shown .. "\n"):gmatch("(.-)\n") do
    lines = lines + math.max(1, math.ceil((utf8.len(ln) or #ln) / 42))
  end
  lines = math.min(lines, 8)
  local W, H = 340, lines * 17 + 22

  local sf = hs.screen.mainScreen():fullFrame()
  local ok, fr = pcall(function() return menubar and menubar:frame() end)
  local x, y
  if ok and fr and fr.w and fr.w > 0 then
    x = fr.x + fr.w / 2 - W / 2
    y = fr.y + fr.h + 6
  else
    x = sf.x + sf.w - W - 12
    y = sf.y + 30
  end
  x = math.max(sf.x + 8, math.min(x, sf.x + sf.w - W - 8))

  local radii = { xRadius = 12, yRadius = 12 }
  local c = hs.canvas.new({ x = x, y = y, w = W, h = H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces + hs.canvas.windowBehaviors.stationary)
  c[1] = { type = "rectangle", action = "fill", roundedRectRadii = radii,
           fillColor = { white = 0.1, alpha = 0.95 }, trackMouseDown = true }
  c[2] = { type = "rectangle", action = "stroke", roundedRectRadii = radii,
           strokeColor = { red = accent.red, green = accent.green, blue = accent.blue, alpha = 0.35 },
           strokeWidth = 1, frame = { x = 0.5, y = 0.5, w = W - 1, h = H - 1 } }
  c[3] = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
           fillColor = { red = accent.red, green = accent.green, blue = accent.blue, alpha = 1 },
           frame = { x = 9, y = 10, w = 3, h = H - 20 } }
  c[4] = { type = "text", text = shown, textColor = { white = 1, alpha = 0.95 },
           textFont = ".AppleSystemUIFont", textSize = 13, textLineBreak = "wordWrap",
           frame = { x = 20, y = 10, w = W - 32, h = H - 20 } }
  c:mouseCallback(function(_, msg)
    if msg == "mouseDown" then
      local onClick = opts.onClick
      dismissPopup()
      if onClick then onClick() end
    end
  end)
  c:show(0.15)
  popup = c
  popupTimer = hs.timer.doAfter(
    math.max(1, math.min(15, opts.duration or tonumber(cfg.popupDuration) or 3.5)), dismissPopup)
end

----------------------------------------------------------------
-- MENUBAR
----------------------------------------------------------------
local function refreshTitle()
  -- Every connection/pause state change passes through here, so this is also
  -- where the clipboard watcher is started or stopped (only runs when needed).
  if syncWatcher then syncWatcher() end
  if not menubar then return end
  -- Minimal single-glyph menu-bar presence; detailed state lives in the menu.
  menubar:setTitle(connected and "▣" or (scanning and "◌" or "▢"))
  if menubar.setTooltip then
    local state = connected and (cfg.paused and "Paused" or "Connected")
      or (scanning and "Discovering devices") or (wantOn and "Reconnecting") or "Disconnected"
    menubar:setTooltip("Gboard Clipboard · " .. state .. (configured() and (" · " .. cfg.host) or ""))
  end
end

local function prompt(title, info, default, cb)
  hs.focus()
  local btn, text = hs.dialog.textPrompt(title, info, default or "", "Save", "Cancel")
  if btn == "Save" then cb(text) end
end

local connect, disconnect, useDevice, begin

local function togglePause()
  cfg.paused = not cfg.paused
  saveCfg()
  refreshTitle()
  showPopup(cfg.paused and "Sync paused" or "Sync active", cfg.paused and "pause" or "info")
end

-- Clickable prompt: click = scan once more. Ignore it and everything stays idle.
local function askRescan(reason)
  showPopup((reason or "Phone not found") .. "\nClick here to scan again", "ask",
    { duration = 10, onClick = function() connect() end })
end

-- Stop everything (no retries, no scanning) and ask what to do.
local function giveUp(reason)
  disconnect()
  askRescan(reason)
end

----------------------------------------------------------------
-- DEVICE DISCOVERY (one pass: Bonjour first, subnet sweep as fallback)
----------------------------------------------------------------
local function ipToNumber(ip)
  local a,b,c,d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return (((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d))
end

local function numberToIP(n)
  local d = n % 256; n = math.floor(n / 256)
  local c = n % 256; n = math.floor(n / 256)
  local b = n % 256; n = math.floor(n / 256)
  local a = n % 256
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

local function localRange()
  local iface = hs.network.primaryInterfaces()
  if not iface then return nil end
  local details = hs.network.interfaceDetails(iface)
  local ip = details and details.IPv4 and details.IPv4.Addresses and details.IPv4.Addresses[1]
  local mask = details and details.IPv4 and details.IPv4.SubnetMasks and details.IPv4.SubnetMasks[1]
  local ipNum, maskNum = ipToNumber(ip or ""), ipToNumber(mask or "")
  if not ipNum or not maskNum then return nil end
  local network = (ipNum & maskNum)
  local broadcast = network | (0xFFFFFFFF ~ maskNum)
  local first, last = network + 1, broadcast - 1
  -- Avoid an unexpectedly huge sweep; Bonjour remains available on large LANs.
  if last - first > 1022 then return nil, nil, nil, ip end
  return first, last, ip
end

-- Service types browsed over Bonjour/mDNS. The phone only shows up here if the
-- patch advertises itself; otherwise the subnet sweep below finds it anyway.
M.bonjourTypes = { "_http._tcp.", "_https._tcp." }

local bonjourKeep = {}   -- keep service objects alive while resolving
local probeTasks = {}

-- Ask one host for /status; cb({ip=, clients=}) if it is the portal, else cb(nil)
local function probe(ip, cb, quick)
  local out = ""
  local connectTimeout = quick and "0.5" or "1"
  local maxTime = quick and "0.9" or "2"
  local t = hs.task.new(CURL,
    function()
      local ok, obj = pcall(hs.json.decode, out)
      probeTasks[ip] = nil
      if ok and type(obj) == "table" and type(obj.pairingRequired) == "boolean" then
        cb({ ip = ip, clients = #(obj.clients or {}), name = obj.deviceName or obj.name })
      else
        cb(nil)
      end
    end,
    function(_, o) if o then out = out .. o end; return true end,
    { "-s", "--connect-timeout", connectTimeout, "-m", maxTime,
      string.format("http://%s:%d/status", ip, httpPort()) })
  probeTasks[ip] = t
  t:start()
end

-- Fast path: browse Bonjour, keep services on our port, verify with /status.
-- cb(list) fires whenever a verified device shows up. Returns a stop() function.
local function bonjourFind(cb)
  if not hs.bonjour then return function() end end
  local ports = { [httpPort()] = true, [httpsPort()] = true }
  local _, _, myip = localRange()
  local seen, list, browsers, alive = {}, {}, {}, true

  local function candidate(ip)
    if not alive or seen[ip] or ip == myip then return end
    seen[ip] = true
    probe(ip, function(entry)
      if entry and alive then list[#list + 1] = entry; cb(list) end
    end)
  end

  local function onService(svc)
    bonjourKeep[#bonjourKeep + 1] = svc
    svc:resolve(2, function(sv)
      if not alive then return end
      local okp, port = pcall(function() return sv:port() end)
      local okn, name = pcall(function() return sv:name() end)
      log("debug", string.format("bonjour: %s on port %s", okn and name or "?", okp and port or "?"))
      if not (okp and ports[port]) then return end
      local oka, addrs = pcall(function() return sv:addresses() end)
      if oka and type(addrs) == "table" then
        for _, addr in ipairs(addrs) do
          if addr:match("^%d+%.%d+%.%d+%.%d+$") then candidate(addr) end
        end
      end
    end)
  end

  for _, t in ipairs(M.bonjourTypes) do
    local ok, br = pcall(function()
      local b = hs.bonjour.new()
      b:findServices(t, "local", 2.2, function(...)
        for _, arg in ipairs({ ... }) do            -- pick out the service object
          if type(arg) == "userdata" then
            local okr, r = pcall(function() return arg.resolve end)
            if okr and r then onService(arg); break end
          end
        end
      end)
      return b
    end)
    if ok and br then browsers[#browsers + 1] = br end
  end

  return function()
    alive = false
    for _, b in ipairs(browsers) do pcall(function() b:stop() end) end
    bonjourKeep = {}
  end
end

-- Slow path: probe every host in the local subnet. cb(list) when the sweep ends.
-- onHit(entry) fires on every verified device so the caller can stop early;
-- the sweep itself stops pumping as soon as isCurrent() turns false.
local function sweep(cb, isCurrent, onHit)
  local first, last, myip = localRange()
  if not first then
    note("Subnet is unavailable or too large for a safe scan; use Bonjour or set the phone IP manually")
    cb({})
    return
  end
  local nextIP, active, results, done = first, 0, {}, false
  local LIMIT = 32
  local function pump()
    if done or (isCurrent and not isCurrent()) then return end
    while active < LIMIT and nextIP <= last do
      local ip = numberToIP(nextIP); nextIP = nextIP + 1
      if ip ~= myip then
        active = active + 1
        probe(ip, function(entry)
          active = active - 1
          if entry then
            results[#results + 1] = entry
            if onHit then onHit(entry) end
          end
          if nextIP > last and active == 0 then
            done = true
            cb(results)
          else pump() end
        end)
      end
    end
    if nextIP > last and active == 0 and not done then done = true; cb(results) end
  end
  pump()
end

-- Find the phone. Bonjour runs first; the subnet sweep only starts if Bonjour
-- has produced nothing after 1.5s. The moment a verified device appears
-- (plus a 0.6s grace window to catch a second one) everything is stopped.
-- cb(list) gets {{ip=..., clients=n}, ...}; an empty list means "not found".
function M.scan(cb)
  if scanning then return end
  scanning = true
  scanGeneration = scanGeneration + 1
  local myGeneration = scanGeneration
  refreshTitle()
  local finished, stopBonjour = false, function() end
  local graceTimer, sweepTimer
  local results, seen = {}, {}
  local function addAll(list)
    for _, d in ipairs(list or {}) do
      if d.ip and not seen[d.ip] then seen[d.ip] = true; results[#results + 1] = d end
    end
  end
  local function current() return scanning and scanGeneration == myGeneration end
  local function stopTimers()
    if graceTimer then graceTimer:stop(); graceTimer = nil end
    if sweepTimer then sweepTimer:stop(); sweepTimer = nil end
  end
  local function finish(list, method)
    if finished or not current() then return end
    finished = true
    stopTimers()
    stopBonjour()
    scanning = false
    addAll(list)
    table.sort(results, function(a,b) return a.ip < b.ip end)
    found = results
    lastDiscoveryMethod = method or "Bonjour + subnet scan"
    log("info", "Discovery finished: " .. #results .. " device(s) via " .. lastDiscoveryMethod)
    refreshTitle()
    if cb then cb(results) end
  end
  local function foundOne(method)
    if graceTimer or finished then return end
    graceTimer = hs.timer.doAfter(0.6, function() graceTimer = nil; finish({}, method) end)
  end

  stopBonjour = bonjourFind(function(list) addAll(list); foundOne("Bonjour") end)
  sweepTimer = hs.timer.doAfter(1.5, function()
    sweepTimer = nil
    if not current() or finished then return end
    sweep(function(list)
      addAll(list)
      finish({}, "Subnet scan")
    end, current, function(entry) addAll({ entry }); foundOne("Subnet scan") end)
  end)
  activeScanCancel = function()
    if finished then return end
    finished = true
    stopTimers()
    stopBonjour()
    scanning = false
    scanGeneration = scanGeneration + 1
    refreshTitle()
  end
end

-- One device -> use it. Several -> prefer the remembered one, else let the
-- user choose from the Devices menu. None -> nil.
local function pickDevice(list, preferred)
  if #list == 1 then return list[1].ip end
  for _, d in ipairs(list) do
    if d.ip == preferred then return d.ip end
  end
  return nil
end

----------------------------------------------------------------
-- MENU
----------------------------------------------------------------
local function buildMenu()
  local state, symbol
  if connected then state, symbol = (cfg.paused and "Paused" or "Connected"), (cfg.paused and "Ⅱ" or "●")
  elseif scanning then state, symbol = "Finding your phone…", "◌"
  elseif wantOn then state, symbol = "Reconnecting…", "◌"
  else state, symbol = "Disconnected", "○" end

  local items = {
    { title = symbol .. "  " .. state .. (configured() and ("  ·  " .. cfg.host) or ""), disabled = true },
    { title = "-" },
  }

  -- Primary actions only: keep the root menu short.
  table.insert(items, { title = wantOn and "Disconnect" or "Connect",
    fn = function() if wantOn then disconnect() else connect() end end })
  table.insert(items, { title = "Send clipboard to phone  (⌃⌥⌘P)", disabled = not connected or cfg.paused,
    fn = function() M.sendCurrent() end })
  table.insert(items, { title = "Get clipboard from phone", disabled = not configured(), fn = function()
    hs.http.asyncGet(url("/state"), nil, function(st, body)
      if st ~= 200 then setError("Could not get clipboard (HTTP " .. tostring(st) .. ")"); return end
      local ok, o = pcall(hs.json.decode, body or "")
      if not ok or type(o) ~= "table" then setError("Phone returned an invalid clipboard response"); return end
      if o.text and #o.text > 0 then
        if byteCount(o.text) > (tonumber(cfg.maxClipboardBytes) or 2 * 1024 * 1024) then
          setError("Incoming clipboard exceeds the configured size limit"); return
        end
        lastApplied = o.text
        lastSyncAt, lastSyncDirection = os.time(), "Phone → Mac"
        hs.pasteboard.setContents(o.text)
        lastCount = hs.pasteboard.changeCount()
        showPopup(o.text, "recv")
      else hs.alert.show("Phone clipboard is empty", 0.8) end
    end)
  end })
  table.insert(items, { title = "-" })
  table.insert(items, { title = cfg.paused and "Resume syncing  (⌃⇧⌘P)" or "Pause syncing  (⌃⇧⌘P)",
    disabled = not connected, fn = togglePause })

  table.insert(items, { title = "Sync", menu = {
    { title = "Automatically receive  ·  Phone → Mac", checked = cfg.autoReceive,
      fn = function() cfg.autoReceive = not cfg.autoReceive; saveCfg() end },
    { title = "Automatically send  ·  Mac → Phone", checked = cfg.autoSend,
      fn = function() cfg.autoSend = not cfg.autoSend; saveCfg(); syncWatcher() end },
    { title = "-" },
    { title = "Connect when Hammerspoon starts", checked = cfg.autoConnect,
      fn = function() cfg.autoConnect = not cfg.autoConnect; saveCfg() end },
    { title = "Scan once if the phone is lost", checked = cfg.autoRescan,
      fn = function() cfg.autoRescan = not cfg.autoRescan; saveCfg() end },
  } })

  local devices = {
    { title = scanning and "Searching…" or "Find devices", disabled = scanning, fn = function()
      M.scan(function(list)
        if #list == 0 then note("No Gboard clipboard devices found")
        elseif #list == 1 then useDevice(list[1].ip)
        else note("Found " .. #list .. " devices; select one here") end
      end)
    end },
  }
  if #found > 0 then
    table.insert(devices, { title = "-" })
    for _, d in ipairs(found) do
      table.insert(devices, { title = (d.name and (d.name .. "  ·  ") or "") .. d.ip,
        checked = d.ip == cfg.host, fn = function() useDevice(d.ip) end })
    end
  end
  table.insert(devices, { title = "-" })
  table.insert(devices, { title = "Enter IP address…", fn = function()
    prompt("Phone IP address", "Only needed if automatic discovery fails.", cfg.host, function(v)
      local ip = (v or ""):gsub("%s+", "")
      if validIPv4(ip) then useDevice(ip) else note("Enter a valid IPv4 address") end
    end)
  end })
  table.insert(items, { title = "Devices", menu = devices })

  table.insert(items, { title = "Settings", menu = {
    { title = "Clipboard preview", checked = cfg.popupEnabled,
      fn = function() cfg.popupEnabled = not cfg.popupEnabled; saveCfg() end },
    { title = "Preview duration…", fn = function()
      prompt("Preview duration", "Seconds (1–15)", tostring(cfg.popupDuration), function(v)
        local n = tonumber(v); if n and n >= 1 and n <= 15 then cfg.popupDuration = n; saveCfg()
        else note("Enter a value from 1 to 15") end
      end)
    end },
    { title = "Preview length…", fn = function()
      prompt("Preview length", "Characters (40–2000)", tostring(cfg.popupMaxChars), function(v)
        local n = tonumber(v); if n and n >= 40 and n <= 2000 then cfg.popupMaxChars = math.floor(n); saveCfg()
        else note("Enter a value from 40 to 2000") end
      end)
    end },
    { title = "Optional rich-text data", checked = cfg.richText,
      fn = function() cfg.richText = not cfg.richText; saveCfg() end },
    { title = "-" },
    { title = "HTTP port…", fn = function()
      prompt("Portal HTTP port", "HTTPS port is HTTP port + 1.", tostring(httpPort()), function(v)
        local n = tonumber(v)
        if validPort(n) then cfg.port = n; saveCfg(); if wantOn then disconnect(); connect() end
        else note("Port must be an integer from 1024 to 65534") end
      end)
    end },
    { title = "Pairing code…", fn = function()
      prompt("Pairing code", "Digits shown on the phone.", cfg.code, function(v)
        cfg.code = (v or ""):gsub("%D", ""); saveCfg()
        if wantOn then disconnect(); connect() end
      end)
    end },
    { title = "Open portal in browser", disabled = not configured(), fn = function()
      hs.urlevent.openURL(base() .. "/?code=" .. hs.http.encodeForQuery(cfg.code or ""))
    end },
  } })

  local lastSync = lastSyncAt and (os.date("%H:%M", lastSyncAt) .. "  ·  " .. (lastSyncDirection or "")) or "Not yet"
  table.insert(items, { title = "Activity", menu = {
    { title = "Last sync  ·  " .. lastSync, disabled = true },
    { title = "Connected clients  ·  " .. tostring(#clients), disabled = true },
    { title = "Connection time  ·  " .. (connectionStartedAt and
      (tostring(math.floor((os.time() - connectionStartedAt) / 60)) .. " min") or "—"), disabled = true },
    { title = "-" },
    { title = "Copy diagnostics", fn = function()
      local report = table.concat({ "Gboard Clipboard diagnostics",
        "State=" .. (connected and "connected" or (wantOn and "connecting" or "disconnected")),
        "Host=" .. tostring(cfg.host), "Port=" .. tostring(httpPort()),
        "Discovery=" .. tostring(lastDiscoveryMethod), "Reconnect attempts=" .. tostring(failCount),
        "Last sync=" .. tostring(lastSyncAt), "Last error=" .. tostring(lastError or "none") }, "\n")
      hs.pasteboard.setContents(report); note("Diagnostics copied")
    end },
  } })

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Stop Gboard Clipboard", fn = function() M.stop() end })
  return items
end

----------------------------------------------------------------
-- SEND (Mac -> phone)
----------------------------------------------------------------
function M.send(text, richData)
  if not configured() or not text or #text == 0 then return end
  if byteCount(text) > (tonumber(cfg.maxClipboardBytes) or 2 * 1024 * 1024) then
    setError("Clipboard is too large (" .. byteCount(text) .. " bytes); limit is " .. tostring(cfg.maxClipboardBytes) .. " bytes")
    return
  end
  lastSent = text
  local payload = { text = text, clientId = clientId, messageId = hs.host.uuid() }
  if cfg.richText and type(richData) == "table" and type(richData.rtf) == "string" then
    payload.richText = richData.rtf
  end
  local body = hs.json.encode(payload)
  log("debug", "Sending clipboard payload: " .. #body .. " bytes")
  hs.http.asyncPost(url("/clipboard"), body, { ["Content-Type"] = "application/json" },
    function(status, responseBody)
      if status == 200 then
        lastSyncAt, lastSyncDirection, lastError = os.time(), "Mac → phone", nil
        showPopup(text, "send")
      elseif status == 401 or status == 403 then
        lastError = "Authentication failed (HTTP " .. tostring(status) .. ")"
        setError("Pairing code rejected; update it in the menu")
      else setError("Send failed: HTTP " .. tostring(status)) end
    end)
end

function M.sendCurrent()
  local text = hs.pasteboard.getContents()
  local rich
  if cfg.richText and hs.pasteboard.readAll then
    local ok, all = pcall(hs.pasteboard.readAll)
    if ok and type(all) == "table" then
      local rtf = all["public.rtf"] or all["text/rtf"]
      if type(rtf) == "string" then rich = { rtf = rtf } end
    end
  end
  M.send(text, rich)
end

----------------------------------------------------------------
-- RECEIVE (phone -> Mac) via SSE through curl
----------------------------------------------------------------
local function handleEvent(name, data)
  local ok, obj = pcall(hs.json.decode, data)
  if not ok then obj = nil end

  if name == "meta" then
    local wasConnected = connected
    connected = true; failCount = 0; retryDelay = 3; lastError = nil
    autoScanUsed = false           -- healthy again: a future outage gets one scan
    refreshTitle()
    if not wasConnected then
      showPopup("Connected to " .. cfg.host .. (cfg.paused and "  (paused)" or ""), "info")
    end
  elseif name == "clients" and obj then
    clients = obj.clients or {}
  elseif name == "clipboard" and obj and obj.text and #obj.text > 0 then
    if obj.clientId == clientId then return end
    if obj.text == lastSent or obj.text == lastApplied then return end
    if obj.source == "desktop" then return end
    if byteCount(obj.text) > (tonumber(cfg.maxClipboardBytes) or 2 * 1024 * 1024) then
      setError("Incoming clipboard rejected: payload exceeds configured size limit")
      return
    end
    lastIncoming = obj.text
    if cfg.autoReceive and not cfg.paused then
      lastApplied = obj.text
      local applied = false
      if cfg.richText and type(obj.richText) == "string" and hs.pasteboard.writeAll then
        local ok = pcall(hs.pasteboard.writeAll, { ["public.utf8-plain-text"] = obj.text, ["public.rtf"] = obj.richText })
        applied = ok
      end
      if not applied then hs.pasteboard.setContents(obj.text) end
      lastSyncAt, lastSyncDirection, lastError = os.time(), "phone → Mac", nil
      lastCount = hs.pasteboard.changeCount()
      showPopup(obj.text, "recv")
    end
  elseif name == "kicked" then
    setError("This Mac was kicked from the portal; check the pairing code and connected devices")
    disconnect()
  elseif name == "ack" and obj and obj.status == "failed" then
    note("Phone failed to apply: " .. tostring(obj.error))
  end
end

-- SSE parser. Splits events on a blank line (\n\n or \r\n\r\n), normalizes line
-- endings per line instead of re-processing the whole buffer, only searches
-- the newly arrived bytes for a delimiter, and trims the buffer once per chunk.
local function feed(chunk)
  local searchFrom = math.max(1, #buf - 2)   -- a delimiter may straddle two chunks
  buf = buf .. chunk
  local start = 1                            -- beginning of the unprocessed region
  while true do
    local s, e = buf:find("\r?\n\r?\n", math.max(start, searchFrom))
    if not s then break end
    local block = buf:sub(start, s - 1)
    start = e + 1
    searchFrom = start
    local name, data = "message", {}
    for line in block:gmatch("[^\r\n]+") do
      local k, v = line:match("^(%w+):%s?(.*)$")
      if k == "event" then name = v elseif k == "data" then data[#data + 1] = v end
    end
    if #data > 0 then handleEvent(name, table.concat(data, "\n")) end
  end
  if start > 1 then buf = buf:sub(start) end
end

local function openStream()
  if sseTask or not wantOn or not configured() then return end
  local generation = connectionGeneration
  buf = ""
  local task
  task = hs.task.new(CURL,
    function()
      if generation ~= connectionGeneration then return end
      if sseTask == task then sseTask = nil end
      connected = false; clients = {}
      if not wantOn then refreshTitle(); return end
      failCount = failCount + 1
      refreshTitle()

      -- After 3 failed attempts: scan ONCE. Found -> reconnect (new IP if it moved).
      -- Not found, or already scanned this outage -> stop and ask; stay idle.
      if cfg.autoRescan and failCount >= 3 and not scanning then
        failCount = 0
        if autoScanUsed then giveUp("Phone unreachable"); return end
        autoScanUsed = true
        M.scan(function(list)
          if not wantOn then return end
          local pick = pickDevice(list, cfg.host)
          if not pick then
            if #list > 1 then
              note("Found " .. #list .. " devices — choose one from Devices")
              disconnect()
            else
              giveUp("Phone not found")
            end
            return
          end
          if pick ~= cfg.host then
            cfg.host = pick; saveCfg()
            note("Phone moved to " .. cfg.host .. " — reconnecting")
          end
          begin()
        end)
        return
      end

      -- Normal short outage: single-curl retry with backoff (no scanning).
      if retryTimer then retryTimer:stop() end
      retryDelay = math.min(30, math.max(3, retryDelay * 1.7))
      retryTimer = hs.timer.doAfter(retryDelay, openStream)
    end,
    function(_, out) if generation == connectionGeneration and out and #out > 0 then feed(out) end; return true end,
    { "-sN", "--no-buffer", "--connect-timeout", "5",
      "-H", "Accept: text/event-stream", url("/events") })
  sseTask = task
  task:start()
end

-- Start streaming from cfg.host
begin = function()
  wantOn = true
  connectionGeneration = connectionGeneration + 1
  local generation = connectionGeneration
  connected = false
  connectionStartedAt = os.time()
  retryDelay = 3
  refreshTitle()
  hs.http.asyncGet(url("/status"), nil, function(status, body)
    if generation ~= connectionGeneration then return end
    if status == 200 then
      local ok, statusObj = pcall(hs.json.decode, body or "")
      if ok and type(statusObj) == "table" and statusObj.pairingRequired and not statusObj.pairingVerified then
        setError("Pairing code not accepted — update it from the menu")
        disconnect()
      end
    elseif status == 401 or status == 403 then
      setError("Authentication failed — check the pairing code")
      disconnect()
    elseif status then
      log("warn", "Status check returned HTTP " .. tostring(status))
    end
  end)
  openStream()
end

-- Connect quickly to the last-known phone first. Only if it cannot be reached
-- is ONE scan run. If that finds nothing: popup, then idle (no retries, no
-- further scans) until you click the popup, press Connect, or use Find devices.
connect = function()
  if scanning then return end
  wantOn = true
  autoScanUsed = false
  refreshTitle()

  local function scanOnce(preferred)
    autoScanUsed = true
    M.scan(function(list)
      if not wantOn then return end
      local pick = pickDevice(list, preferred)
      if pick then
        cfg.host = pick
        saveCfg()
        begin()
      elseif #list > 1 then
        note("Found " .. #list .. " devices — choose one from Devices")
        disconnect()
      else
        giveUp("Phone not found")
      end
    end)
  end

  if configured() then
    local rememberedHost = cfg.host
    probe(rememberedHost, function(entry)
      if not wantOn or cfg.host ~= rememberedHost then return end
      if entry then
        log("info", "Remembered device responded; skipping network discovery")
        begin()
      else
        log("info", "Remembered device did not respond; scanning once")
        scanOnce(rememberedHost)
      end
    end, true)
  else
    scanOnce(nil)
  end
end

disconnect = function()
  wantOn = false
  connectionGeneration = connectionGeneration + 1
  if activeScanCancel then activeScanCancel(); activeScanCancel = nil end
  if retryTimer then retryTimer:stop(); retryTimer = nil end
  if sseTask then sseTask:terminate(); sseTask = nil end
  connected = false; clients = {}; connectionStartedAt = nil
  refreshTitle()
end

useDevice = function(ip)
  if not validIPv4(ip) then note("Enter a valid IPv4 address"); return end
  disconnect()
  autoScanUsed = false
  cfg.host = ip; saveCfg()
  begin()
end

----------------------------------------------------------------
-- AUTO-SEND WATCHER (only runs while auto-send + connected + not paused)
----------------------------------------------------------------
syncWatcher = function()
  local need = cfg.autoSend and connected and not cfg.paused
  if need and not pbWatcher then
    lastCount = hs.pasteboard.changeCount()   -- ignore anything copied while off
    pbWatcher = hs.timer.doEvery(0.5, function()
      local c = hs.pasteboard.changeCount()
      if c == lastCount then return end
      lastCount = c
      local t = hs.pasteboard.getContents()
      if t and t ~= lastApplied and t ~= lastSent then M.sendCurrent() end
    end)
  elseif not need and pbWatcher then
    pbWatcher:stop(); pbWatcher = nil
  end
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------
function M.start()
  log("info", "Starting Gboard Clipboard")
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setMenu(buildMenu)
  refreshTitle()
  if M.hk then M.hk:delete() end
  if M.sendHotkey then
    M.hk = hs.hotkey.bind(M.sendHotkey[1], M.sendHotkey[2], M.sendCurrent)
  end
  if M.pausehk then M.pausehk:delete() end
  if M.pauseHotkey then
    M.pausehk = hs.hotkey.bind(M.pauseHotkey[1], M.pauseHotkey[2], togglePause)
  end
  if cfg.autoConnect then connect() end
  return M
end

function M.stop()
  log("info", "Stopping Gboard Clipboard")
  disconnect()
  dismissPopup()
  if pbWatcher then pbWatcher:stop(); pbWatcher = nil end
  if M.hk then M.hk:delete() end
  if M.pausehk then M.pausehk:delete() end
  if menubar then menubar:delete(); menubar = nil end
end

-- Spoonfeeder loads files with dofile(), which ignores return values,
-- so the script starts itself and keeps a global to avoid garbage collection.
gclip = M.start()
return M