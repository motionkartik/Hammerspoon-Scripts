-- gboard_clip.lua  (menubar edition)
-- Hammerspoon <-> Gboard web clipboard (jasonwu1994/Gboard-patches)
-- Endpoints: POST /clipboard | GET /state | GET /status | GET /events (SSE)
-- Every request carries ?code=<pairing>&clientId=<uuid>
-- HTTPS port is always HTTP port + 1, so only the HTTP port is configurable.

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
local failCount   = 0          -- consecutive failed connects (for auto re-find)

local function httpPort()  return tonumber(cfg.port) or 4455 end
local function httpsPort() return httpPort() + 1 end

local function base()
  return string.format("http://%s:%d", cfg.host, httpPort())
end

local function url(path)
  return string.format("%s%s?code=%s&clientId=%s", base(), path,
    hs.http.encodeForQuery(cfg.code or ""), hs.http.encodeForQuery(clientId))
end

local function note(msg)
  hs.notify.new({ title = "Gboard Clipboard", informativeText = msg, withdrawAfter = 3 }):send()
end

local function configured() return cfg.host ~= nil and cfg.host ~= "" end

----------------------------------------------------------------
-- POPUP under the menubar icon (shows the actual clipboard text)
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
}

local function showPopup(text, dir)
  if not text or text == "" then return end
  local accent = ACCENT[dir] or ACCENT.recv
  if popupTimer then popupTimer:stop(); popupTimer = nil end
  if popup then popup:delete(); popup = nil end

  local shown = (text:gsub("\r", "")):gsub("^%s+", "")
  shown = shown:gsub("%s+$", "")
  local MAX = 280
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
  c:mouseCallback(function(_, msg) if msg == "mouseDown" then dismissPopup() end end)
  c:show(0.15)
  popup = c
  popupTimer = hs.timer.doAfter(math.min(5, 2.2 + #shown / 90), dismissPopup)
end

----------------------------------------------------------------
-- MENUBAR
----------------------------------------------------------------
local function refreshTitle()
  if not menubar then return end
  local icon
  if scanning then icon = "📋🔍"
  elseif connected then icon = cfg.paused and "📋⏸" or "📋●"
  elseif wantOn then icon = "📋…"
  else icon = "📋○" end
  menubar:setTitle(icon)
end

local function prompt(title, info, default, cb)
  hs.focus()
  local btn, text = hs.dialog.textPrompt(title, info, default or "", "Save", "Cancel")
  if btn == "Save" then cb(text) end
end

local connect, disconnect, useDevice

local function togglePause()
  cfg.paused = not cfg.paused
  saveCfg()
  refreshTitle()
  showPopup(cfg.paused and "Sync paused" or "Sync active", cfg.paused and "pause" or "info")
end

----------------------------------------------------------------
-- DEVICE DISCOVERY (sweeps the whole local subnet, no fixed IP)
----------------------------------------------------------------
local function localRange()
  local v4 = hs.network.primaryInterfaces()
  if not v4 then return nil end
  local d = hs.network.interfaceDetails(v4)
  local ip   = d and d.IPv4 and d.IPv4.Addresses   and d.IPv4.Addresses[1]
  local mask = d and d.IPv4 and d.IPv4.SubnetMasks and d.IPv4.SubnetMasks[1]
  if not ip then return nil end
  local a, b, c, last = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  local lo, hi = 1, 254
  local m3 = mask and tonumber(mask:match("%.(%d+)%.%d+$"))
  local m4 = mask and tonumber(mask:match("(%d+)$"))
  if m3 == 255 and m4 then                 -- honour subnets narrower than /24
    local base_ = tonumber(last) & m4
    lo, hi = base_ + 1, (base_ | (255 - m4)) - 1
  end
  return string.format("%s.%s.%s", a, b, c), lo, hi, ip
end

-- Service types browsed over Bonjour/mDNS. The phone only shows up here if the
-- patch advertises itself; otherwise the subnet sweep below finds it anyway.
M.bonjourTypes = { "_http._tcp.", "_https._tcp." }

local bonjourKeep = {}   -- keep service objects alive while resolving

-- Ask one host for /status; cb({ip=, clients=}) if it is the portal, else cb(nil)
local function probe(ip, cb)
  local out = ""
  local t = hs.task.new(CURL,
    function()
      local ok, obj = pcall(hs.json.decode, out)
      if ok and type(obj) == "table" and type(obj.pairingRequired) == "boolean" then
        cb({ ip = ip, clients = #(obj.clients or {}) })
      else
        cb(nil)
      end
    end,
    function(_, o) if o then out = out .. o end; return true end,
    { "-s", "--connect-timeout", "1", "-m", "2", string.format("http://%s:%d/status", ip, httpPort()) })
  t:start()
end

-- Fast path: browse Bonjour, keep services on our port, verify with /status.
-- cb(list) fires whenever a verified device shows up. Returns a stop() function.
local function bonjourFind(cb)
  if not hs.bonjour then return function() end end
  local ports = { [httpPort()] = true, [httpsPort()] = true }
  local _, _, _, myip = localRange()
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
      print(string.format("[gboard-clip] bonjour: %s on port %s", okn and name or "?", okp and port or "?"))
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

-- Slow path: probe every host in the local subnet. cb(list)
local function sweep(cb)
  local prefix, lo, hi, myip = localRange()
  if not prefix then
    note("Can't determine local network")
    cb({})
    return
  end

  local script = string.format(
    [[for i in $(seq %d %d); do ( r=$(/usr/bin/curl -s --connect-timeout 1 -m 2 "http://%s.$i:%d/status" | tr -d '\n'); [ -n "$r" ] && echo "%s.$i|$r" ) & done; wait]],
    lo, hi, prefix, httpPort(), prefix)

  local out = ""
  local task = hs.task.new("/bin/sh",
    function()
      local list = {}
      for line in out:gmatch("[^\n]+") do
        local ip, js = line:match("^([%d%.]+)|(.*)$")
        if ip and ip ~= myip then
          local ok, obj = pcall(hs.json.decode, js)
          if ok and type(obj) == "table" and type(obj.pairingRequired) == "boolean" then
            list[#list + 1] = { ip = ip, clients = #(obj.clients or {}) }
          end
        end
      end
      cb(list)
    end,
    function(_, o) if o then out = out .. o end; return true end,
    { "-c", script })
  task:start()
end

-- Find the phone: Bonjour first; if nothing answers within 1s, sweep the subnet too.
-- First verified result wins. cb(list) gets {{ip=..., clients=n}, ...}.
function M.scan(cb)
  if scanning then return end
  scanning = true; refreshTitle()

  local finished = false
  local stopBonjour = function() end

  local function finish(list)
    if finished then return end
    finished = true
    stopBonjour()
    scanning = false
    local copy = {}
    for _, d in ipairs(list) do copy[#copy + 1] = d end
    table.sort(copy, function(x, y) return x.ip < y.ip end)
    found = copy
    refreshTitle()
    if cb then cb(copy) end
  end

  stopBonjour = bonjourFind(function(list) finish(list) end)
  hs.timer.doAfter(1.0, function()
    if not finished then sweep(finish) end
  end)
end

----------------------------------------------------------------
-- MENU
----------------------------------------------------------------
local function buildMenu()
  local status
  if connected then status = "Connected to " .. cfg.host .. (cfg.paused and "  (paused)" or "")
  elseif scanning then status = "Scanning network …"
  elseif wantOn then status = "Connecting …"
  else status = "Disconnected" end

  local items = {
    { title = status, disabled = true },
    { title = "-" },
  }

  if wantOn then
    table.insert(items, { title = "Disconnect", fn = function() disconnect() end })
  else
    table.insert(items, { title = "Connect (auto-find on network)", fn = function() connect() end })
  end

  table.insert(items, { title = cfg.paused and "Resume syncing  (⌃⇧⌘P)" or "Pause syncing  (⌃⇧⌘P)",
                        fn = togglePause })
  table.insert(items, { title = "Send Mac clipboard to phone  (⌃⌥⌘P)", fn = function() M.sendCurrent() end,
                        disabled = not connected })
  table.insert(items, { title = "Pull phone clipboard now", disabled = not configured(), fn = function()
    hs.http.asyncGet(url("/state"), nil, function(st, body)
      if st ~= 200 then note("State failed: HTTP " .. tostring(st)); return end
      local o = hs.json.decode(body) or {}
      if o.text and #o.text > 0 then
        lastApplied = o.text
        hs.pasteboard.setContents(o.text)
        lastCount = hs.pasteboard.changeCount()
        showPopup(o.text, "recv")
      else hs.alert.show("Phone clipboard empty", 0.6) end
    end)
  end })

  table.insert(items, { title = "-" })
  table.insert(items, { title = scanning and "Scanning network …" or "Find devices on network",
    disabled = scanning, fn = function()
      M.scan(function(list)
        if #list == 1 then useDevice(list[1].ip)
        elseif #list > 1 then note("Found " .. #list .. " devices - pick one from the menu")
        else note("No devices found on port " .. httpPort()) end
      end)
    end })
  if #found > 0 then
    local sub = {}
    for _, d in ipairs(found) do
      table.insert(sub, { title = d.ip .. "  (" .. d.clients .. " client" .. (d.clients == 1 and "" or "s") .. ")",
        checked = (d.ip == cfg.host), fn = function() useDevice(d.ip) end })
    end
    table.insert(items, { title = "Devices found", menu = sub })
  end

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Auto-receive (phone → Mac)", checked = cfg.autoReceive,
    fn = function() cfg.autoReceive = not cfg.autoReceive; saveCfg() end })
  table.insert(items, { title = "Auto-send (Mac → phone)", checked = cfg.autoSend,
    fn = function() cfg.autoSend = not cfg.autoSend; saveCfg() end })
  table.insert(items, { title = "Connect on Hammerspoon launch", checked = cfg.autoConnect,
    fn = function() cfg.autoConnect = not cfg.autoConnect; saveCfg() end })
  table.insert(items, { title = "Re-find phone if its IP changes", checked = cfg.autoRescan,
    fn = function() cfg.autoRescan = not cfg.autoRescan; saveCfg() end })

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Port: " .. httpPort() .. "  (HTTPS " .. httpsPort() .. ")", fn = function()
    prompt("Portal HTTP port", "HTTPS is always this + 1. Default 4455.", tostring(httpPort()), function(t)
      local n = tonumber(t)
      if n then cfg.port = n; saveCfg(); if wantOn then disconnect(); connect() end end
    end)
  end })
  table.insert(items, { title = "Pairing code: " .. ((cfg.code ~= "" and cfg.code) or "not set"), fn = function()
    prompt("Pairing code", "Digits shown on the phone", cfg.code, function(t)
      cfg.code = t:gsub("%D", ""); saveCfg()
      if wantOn then disconnect(); connect() end
    end)
  end })

  if configured() then
    table.insert(items, { title = "Open portal in browser (HTTP)", fn = function()
      hs.urlevent.openURL(base() .. "/?code=" .. hs.http.encodeForQuery(cfg.code or ""))
    end })
    table.insert(items, { title = "Open portal in browser (HTTPS)", fn = function()
      hs.urlevent.openURL(string.format("https://%s:%d/?code=%s", cfg.host,
        httpsPort(), hs.http.encodeForQuery(cfg.code or "")))
    end })
  end

  table.insert(items, { title = "Advanced", menu = {
    { title = "Set IP manually (only if scan can't see the phone)", fn = function()
      prompt("Phone IP", "Normally found automatically. Current: " .. (configured() and cfg.host or "none"),
        cfg.host, function(t) useDevice((t:gsub("%s+", ""))) end)
    end },
  } })

  if #clients > 0 then
    table.insert(items, { title = "-" })
    table.insert(items, { title = "Connected clients", disabled = true })
    for _, c in ipairs(clients) do
      local me = (c.id == clientId) and " (this Mac)" or ""
      table.insert(items, { title = "   " .. tostring(c.label or c.address or c.id) .. me, disabled = true })
    end
  end

  if lastIncoming then
    table.insert(items, { title = "-" })
    table.insert(items, { title = "Last from phone: " .. (lastIncoming:gsub("%s+", " ")):sub(1, 40),
      fn = function() hs.pasteboard.setContents(lastIncoming); lastCount = hs.pasteboard.changeCount() end })
  end

  return items
end

----------------------------------------------------------------
-- SEND (Mac -> phone)
----------------------------------------------------------------
function M.send(text)
  if not configured() or not text or #text == 0 then return end
  lastSent = text
  local body = hs.json.encode({ text = text, clientId = clientId, messageId = hs.host.uuid() })
  hs.http.asyncPost(url("/clipboard"), body, { ["Content-Type"] = "application/json" },
    function(status)
      if status == 200 then showPopup(text, "send")
      elseif status == 401 then note("Pairing code rejected (401)")
      else note("Send failed: HTTP " .. tostring(status)) end
    end)
end

function M.sendCurrent() M.send(hs.pasteboard.getContents()) end

----------------------------------------------------------------
-- RECEIVE (phone -> Mac) via SSE through curl
----------------------------------------------------------------
local function handleEvent(name, data)
  local ok, obj = pcall(hs.json.decode, data)
  if not ok then obj = nil end

  if name == "meta" then
    local wasConnected = connected
    connected = true; failCount = 0; refreshTitle()
    if not wasConnected then
      showPopup("Connected to " .. cfg.host .. (cfg.paused and "  (paused)" or ""), "info")
    end
  elseif name == "clients" and obj then
    clients = obj.clients or {}
  elseif name == "clipboard" and obj and obj.text and #obj.text > 0 then
    if obj.clientId == clientId then return end
    if obj.text == lastSent or obj.text == lastApplied then return end
    if obj.source == "desktop" then return end
    lastIncoming = obj.text
    if cfg.autoReceive and not cfg.paused then
      lastApplied = obj.text
      hs.pasteboard.setContents(obj.text)
      lastCount = hs.pasteboard.changeCount()
      showPopup(obj.text, "recv")
    end
  elseif name == "kicked" then
    note("Kicked from the portal")
    disconnect()
  elseif name == "ack" and obj and obj.status == "failed" then
    note("Phone failed to apply: " .. tostring(obj.error))
  end
end

local function feed(chunk)
  buf = (buf .. chunk):gsub("\r\n", "\n")
  while true do
    local s, e = buf:find("\n\n", 1, true)
    if not s then break end
    local block = buf:sub(1, s - 1)
    buf = buf:sub(e + 1)
    local name, data = "message", {}
    for line in block:gmatch("[^\n]+") do
      local k, v = line:match("^(%w+):%s?(.*)$")
      if k == "event" then name = v elseif k == "data" then data[#data + 1] = v end
    end
    if #data > 0 then handleEvent(name, table.concat(data, "\n")) end
  end
end

local function openStream()
  if sseTask or not wantOn or not configured() then return end
  buf = ""
  local task
  task = hs.task.new(CURL,
    function()
      if sseTask == task then sseTask = nil end
      if not connected then failCount = failCount + 1 end
      connected = false; clients = {}
      refreshTitle()
      -- Phone may have a new IP (DHCP): sweep the network again
      if wantOn and cfg.autoRescan and failCount >= 3 and not scanning then
        failCount = 0
        M.scan(function(list)
          if #list == 1 and list[1].ip ~= cfg.host then
            cfg.host = list[1].ip; saveCfg()
            note("Phone moved to " .. cfg.host)
          end
        end)
      end
      if wantOn then
        if retryTimer then retryTimer:stop() end
        retryTimer = hs.timer.doAfter(3, openStream)
      end
    end,
    function(_, out) if out and #out > 0 then feed(out) end; return true end,
    { "-sN", "--no-buffer", "--connect-timeout", "5",
      "-H", "Accept: text/event-stream", url("/events") })
  sseTask = task
  task:start()
end

-- Start streaming from cfg.host
local function begin()
  wantOn = true
  refreshTitle()
  hs.http.asyncGet(url("/status"), nil, function(status, body)
    if status == 200 then
      local s = hs.json.decode(body) or {}
      if s.pairingRequired and not s.pairingVerified then
        note("Pairing code not accepted - set it from the menu")
      end
    end
  end)
  openStream()
end

-- Connect = find the phone on the network first, then stream
connect = function()
  if scanning then return end
  wantOn = true
  refreshTitle()
  M.scan(function(list)
    if not wantOn then return end                 -- user hit Disconnect meanwhile
    local pick
    if #list == 1 then
      pick = list[1].ip
    elseif #list > 1 then
      for _, d in ipairs(list) do if d.ip == cfg.host then pick = d.ip end end
      if not pick then
        note("Found " .. #list .. " devices - pick one from the menu")
        wantOn = false; refreshTitle(); return
      end
    elseif configured() then
      pick = cfg.host                              -- scan saw nothing: try last known
    else
      note("No devices found on port " .. httpPort())
      wantOn = false; refreshTitle(); return
    end
    cfg.host = pick; saveCfg()
    begin()
  end)
end

disconnect = function()
  wantOn = false
  if retryTimer then retryTimer:stop(); retryTimer = nil end
  if sseTask then sseTask:terminate(); sseTask = nil end
  connected = false; clients = {}
  refreshTitle()
end

useDevice = function(ip)
  if not ip or ip == "" then return end
  disconnect()
  cfg.host = ip; saveCfg()
  begin()
end

----------------------------------------------------------------
-- AUTO-SEND WATCHER
----------------------------------------------------------------
local function startWatcher()
  if pbWatcher then pbWatcher:stop() end
  pbWatcher = hs.timer.doEvery(0.5, function()
    local c = hs.pasteboard.changeCount()
    if c == lastCount then return end
    lastCount = c
    if not (cfg.autoSend and connected and not cfg.paused) then return end
    local t = hs.pasteboard.getContents()
    if t and t ~= lastApplied then M.send(t) end
  end)
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------
function M.start()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setMenu(buildMenu)
  refreshTitle()
  startWatcher()
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
  disconnect()
  dismissPopup()
  if pbWatcher then pbWatcher:stop() end
  if M.hk then M.hk:delete() end
  if M.pausehk then M.pausehk:delete() end
  if menubar then menubar:delete(); menubar = nil end
end

-- Spoonfeeder loads files with dofile(), which ignores return values,
-- so the script starts itself and keeps a global to avoid garbage collection.
gclip = M.start()
return M