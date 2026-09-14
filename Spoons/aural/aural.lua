-- Aural by @motionkartik

local aural = {}

-- Set to true for verbose console logging while debugging.
aural.debug = false

local function log(...)
    if aural.debug then
        print("[Aural]", ...)
    end
end

-- ── Paths ──

local function scriptDir()
   local source = debug.getinfo(1, "S").source:sub(2)
   return source:match("(.*/)") or "./"
end

local SCRIPT_DIR = scriptDir()
local ICON_DIR = SCRIPT_DIR .. "aural-icons/"
local SFSYMBOL_BIN = SCRIPT_DIR .. "sfsymbol-export"
local SWIFT_SOURCE = SCRIPT_DIR .. "sfsymbol_export.swift"

hs.fs.mkdir(ICON_DIR)

local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function needsRebuild()
    if not fileExists(SFSYMBOL_BIN) then
        return true
    end

    local src = hs.fs.attributes(SWIFT_SOURCE, "modification")
    local bin = hs.fs.attributes(SFSYMBOL_BIN, "modification")

    if not src or not bin then
        return false
    end

    return src > bin
end

local function ensureExporter()
    if not needsRebuild() then
        return true
    end

    if not fileExists(SWIFT_SOURCE) then
        hs.alert.show("Aural: sfsymbol_export.swift not found")
        return false
    end

    hs.alert.show("Compiling SF Symbol exporter...")

    local cmd = string.format(
        'swiftc %q -o %q',
        SWIFT_SOURCE,
        SFSYMBOL_BIN
    )

    local ok, stdout, stderr, rc = hs.execute(cmd, true)

    if rc == 0 and fileExists(SFSYMBOL_BIN) then
        return true
    end

    print(stdout or "")
    print(stderr or "")

    hs.alert.show("Failed to compile SF Symbol exporter")
    return false
end

if not ensureExporter() then
    return aural
end

-- ── SF Symbol per device category — tweak freely ──
local SYMBOLS = {
   airpods    = "airpods",
   bluetooth  = "earbuds",
   speakers   = "hifispeaker.fill",
   headphones = "headphones",
   mac        = "laptopcomputer",
   default    = "speaker.wave.2.fill",
}

-- ── Icon generation / caching ──
local VARIANTS = {
   menubar = { pointSize = 18, color = "template" },
   hud     = { pointSize = 44, color = "white" },
}

-- IMPORTANT: only successfully-loaded hs.image objects are cached.
-- A failed render (nil image) is never cached, so the next call retries
-- generation instead of permanently serving a blank/missing icon.
local iconCache = {}

local function ensureIcon(category, variant)
   local cacheKey = category .. ":" .. variant
   if iconCache[cacheKey] then return iconCache[cacheKey] end

   local path = ICON_DIR .. category .. "-" .. variant .. ".png"
   local f = io.open(path, "r")
   local fileWasPresent = f ~= nil
   if f then
       f:close()
   end

   if not fileWasPresent then
       local spec = VARIANTS[variant]
       local symbolName = SYMBOLS[category] or SYMBOLS.default
       local cmd = string.format(
           "%q %q %d %q %s 2>&1",
           SFSYMBOL_BIN, symbolName, spec.pointSize, path, spec.color
       )
       local handle = io.popen(cmd)
       local output = handle and handle:read("*a") or ""
       local ok = handle and handle:close()
       if not ok then
           local detail = output ~= "" and (" — " .. output:gsub("%s+$", "")) or " (no output — check the binary exists and is executable)"
           hs.alert.show("Aural: couldn't render " .. symbolName .. detail)
           log("icon render failed for", cacheKey, detail)
           return nil -- do not cache a failure
       end
   end

   local img = hs.image.imageFromPath(path)
   if not img then
       log("hs.image.imageFromPath returned nil for", path, "— not caching, will retry next time")
       return nil -- do not cache a failure
   end

   iconCache[cacheKey] = img
   return img
end

-- Decide which icon category best represents a device
local function categoryForDevice(dev)
   if not dev then return "default" end

   local ok, name = pcall(function() return dev:name() end)
   name = ok and name and name:lower() or ""

   local ok2, transport = pcall(function() return dev:transportType() end)
   transport = ok2 and transport and transport:lower() or ""

   if name:find("airpods") then
       return "airpods"
   elseif transport:find("bluetooth") then
       return "bluetooth"
   elseif name:find("headphone") or name:find("headset") then
       return "headphones"
   elseif name:find("speaker") then
       return "speakers"
   elseif transport:find("built") then
       return "mac"
   end

   return "default"
end

-- Safely get volume string (returns nil if unsupported)
local function getVolumeString(dev)
    if not dev then return nil end
    local ok, vol = pcall(function() return dev:volume() end)
    if not ok or type(vol) ~= "number" then return nil end

    local mutedOk, muted = pcall(function() return dev:muted() end)
    if mutedOk and muted then
        return "Muted"
    end

    return math.floor(vol) .. "%"
end

-- Safely get mute state (returns false if unsupported)
local function isMuted(dev)
    if not dev then return false end
    local ok, muted = pcall(function() return dev:muted() end)
    if not ok then return false end
    return muted == true
end

-- Some devices (notably virtual ones left behind by apps like Zoom after
-- they exit) stay in hs.audiodevice.allOutputDevices() even though macOS's
-- own Sound menu no longer lists them as real outputs. Trying to switch to
-- one silently fails. A device with 0 output channels is our best signal
-- that it's a dead/torn-down device, so we filter those out everywhere.
-- UIDs of devices that have failed a verified switch 3 times in this
-- Hammerspoon session. Populated by setDefaultOutputVerified below.
aural.deadDeviceUIDs = {}

local function isUsableOutputDevice(dev)
    if not dev then return false end
    if aural.deadDeviceUIDs[dev:uid()] then return false end
    local ok, channels = pcall(function() return dev:outputChannels() end)
    if not ok or type(channels) ~= "number" then
        -- If we can't tell, don't exclude it — better to attempt and let
        -- the verified-switch retry/alert logic catch a real failure.
        return true
    end
    return channels > 0
end

local function usableOutputDevices()
    local usable = {}
    for _, dev in ipairs(hs.audiodevice.allOutputDevices()) do
        if isUsableOutputDevice(dev) then
            table.insert(usable, dev)
        end
    end
    return usable
end

-- ── HUD: a transient ──
function aural.hideHUD()
    if aural.hudTimer then aural.hudTimer:stop() end
    if aural.hud then
        local canvas = aural.hud
        canvas:hide(0.25)
        hs.timer.doAfter(0.3, function()
            if aural.hud == canvas then
                canvas:delete()
                aural.hud = nil
            end
        end)
    end
end

function aural.showHUD(category, deviceName, volumeText)
    if aural.hudTimer then aural.hudTimer:stop() end
    if aural.hud then aural.hud:delete() end

    local w, h = 200, 150
    local screenFrame = hs.screen.mainScreen():frame()
    local x, y

    -- Get menubar frame to position HUD underneath it
    local ok, mbFrame = pcall(function() return aural.menubar:frame() end)

    if ok and mbFrame then
        -- Position horizontally centered under the menubar icon
        x = mbFrame.x + (mbFrame.w / 2) - (w / 2)
        -- Position vertically just below the menubar
        y = mbFrame.y + mbFrame.h + 4
    else
        -- Fallback to center of screen if menubar frame can't be found
        x = screenFrame.x + (screenFrame.w - w) / 2
        y = screenFrame.y + (screenFrame.h - h) / 2
    end

    -- Keep it from going off the left/right edges of the screen
    x = math.max(screenFrame.x + 4, math.min(x, screenFrame.x + screenFrame.w - w - 4))
    -- Keep it from going off the top of the screen (e.g., MacBooks with a notch)
    y = math.max(screenFrame.y, y)

    local canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })

    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = { white = 0.1, alpha = 0.85 },
        roundedRectRadii = { xRadius = 22, yRadius = 22 },
    })

    local icon = ensureIcon(category, "hud")
    if icon then
        canvas:appendElements({
            type = "image",
            image = icon,
            frame = { x = w / 2 - 28, y = 18, w = 56, h = 56 },
        })
    end

    -- Device Name
    canvas:appendElements({
        type = "text",
        text = deviceName or "",
        textSize = 14,
        textColor = { white = 1, alpha = 1 },
        textAlignment = "center",
        frame = { x = 8, y = 80, w = w - 16, h = 20 },
    })

    -- Volume Text (only if the device supports it)
    if volumeText then
        canvas:appendElements({
            type = "text",
            text = volumeText,
            textSize = 20,
            textColor = { white = 1, alpha = 0.9 },
            textAlignment = "center",
            frame = { x = 8, y = 105, w = w - 16, h = 28 },
        })
    end

    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:clickActivating(false)
    canvas:show(0.12)
    aural.hud = canvas

    aural.hudTimer = hs.timer.doAfter(1.1, function()
        aural.hideHUD()
    end)
end

-- Update the existing HUD in place to prevent flickering during scroll
function aural.updateHUD(category, deviceName, volumeText)
    if not aural.hud then
        aural.showHUD(category, deviceName, volumeText)
        return
    end

    if aural.hudTimer then aural.hudTimer:stop() end

    local w = 200

    -- Update Icon
    local icon = ensureIcon(category, "hud")
    if icon then
        aural.hud[2] = {
            type = "image",
            image = icon,
            frame = { x = w / 2 - 28, y = 18, w = 56, h = 56 },
        }
    end

    -- Update Device Name
    aural.hud[3] = {
        type = "text",
        text = deviceName or "",
        textSize = 14,
        textColor = { white = 1, alpha = 1 },
        textAlignment = "center",
        frame = { x = 8, y = 80, w = w - 16, h = 20 },
    }

    -- Update Volume Text
    if volumeText then
        aural.hud[4] = {
            type = "text",
            text = volumeText,
            textSize = 20,
            textColor = { white = 1, alpha = 0.9 },
            textAlignment = "center",
            frame = { x = 8, y = 105, w = w - 16, h = 28 },
        }
    else
        -- If device doesn't support volume, clear the text element
        aural.hud[4] = nil
    end

    -- Reset the timer to keep it on screen
    aural.hudTimer = hs.timer.doAfter(1.1, function()
        aural.hideHUD()
    end)
end

-- ── Menubar item
aural.menubar = hs.menubar.new()
aural.lastDeviceUID = nil
aural.lastMuted = false

-- Repaint the menubar icon/tooltip, and pop the HUD if the device actually changed.
-- Always sets the icon (even if unchanged) so a previously-failed render gets
-- a chance to repaint on the next natural update instead of staying stuck.
function aural.updateIcon()
   local current = hs.audiodevice.defaultOutputDevice()
   local category = categoryForDevice(current)

   local icon = ensureIcon(category, "menubar")
   if icon then
       aural.menubar:setIcon(icon, true)
   else
       log("no menubar icon available for category", category, "— leaving previous icon in place")
   end
   aural.menubar:setTooltip(current and ("Aural — " .. current:name()) or "Aural")

   local uid = current and current:uid() or nil
   local muted = isMuted(current)

   if uid ~= aural.lastDeviceUID or muted ~= aural.lastMuted then
       log("device/mute state changed:", aural.lastDeviceUID, "->", uid, "muted:", muted)
       aural.lastDeviceUID = uid
       aural.lastMuted = muted
       if current and aural.hudEnabled then
           aural.showHUD(category, current:name(), getVolumeString(current))
       end
   end
end

-- Switch default output device, then verify it actually took hold.
-- setDefaultOutputDevice() can occasionally fail silently (e.g. a device
-- that just disconnected, or one CoreAudio momentarily refuses); a couple
-- of short-delay retries make the switch reliable without adding
-- noticeable click latency.
local function setDefaultOutputVerified(dev, attempt)
    attempt = attempt or 1
    if not dev then return end

    local targetUID = dev:uid()
    dev:setDefaultOutputDevice()

    hs.timer.doAfter(0.12, function()
        local now = hs.audiodevice.defaultOutputDevice()
        if now and now:uid() == targetUID then
            log("switch to", dev:name(), "confirmed on attempt", attempt)
            aural.updateIcon()
            return
        end

        log("switch to", dev:name(), "did not take on attempt", attempt)
        if attempt < 3 then
            setDefaultOutputVerified(dev, attempt + 1)
        else
            hs.alert.show("Aural: couldn't switch to " .. dev:name() .. " — skipping it from now on")
            aural.deadDeviceUIDs[targetUID] = true
            aural.updateIcon()
        end
    end)
end

local function switchTo(dev)
   return function()
       setDefaultOutputVerified(dev)
   end
end

local function buildMenu()
   local current = hs.audiodevice.defaultOutputDevice()
   local devices = usableOutputDevices()
   local menuItems = {}

   for _, dev in ipairs(devices) do
       table.insert(menuItems, {
           title   = dev:name(),
           image   = ensureIcon(categoryForDevice(dev), "menubar"),
           checked = current ~= nil and dev:uid() == current:uid(),
           fn      = switchTo(dev),
       })
   end

   table.insert(menuItems, { title = "-" })
   table.insert(menuItems, {
       title = "Refresh",
       fn = function() aural.updateIcon() end,
   })

   return menuItems
end

-- ── Left click = instant cycle to next device ──
local function cycleToNext()
   local devices = usableOutputDevices()
   if #devices == 0 then return end

   local current = hs.audiodevice.defaultOutputDevice()
   local currentIndex = 1
   if current then
       for i, dev in ipairs(devices) do
           if dev:uid() == current:uid() then
               currentIndex = i
               break
           end
       end
   end

   local nextDevice = devices[(currentIndex % #devices) + 1]
   log("cycling from", current and current:name() or "nil", "to", nextDevice:name())
   setDefaultOutputVerified(nextDevice)
end

aural.menubar:setClickCallback(function(_mods)
   cycleToNext()
end)

-- ── Scroll = adjust volume ──
local function adjustVolume(direction)
   local current = hs.audiodevice.defaultOutputDevice()
   if not current then return end

   local ok, vol = pcall(function() return current:volume() end)
   if not ok or type(vol) ~= "number" then return end

   -- Scrolling implies intent to hear sound — unmute first, otherwise
   -- setVolume() below has no audible effect even though the number changes.
   -- Start from 0 (not the pre-mute level) so unmuting-by-scroll never
   -- blasts audio back in at whatever volume it was left at.
   if isMuted(current) then
       pcall(function() current:setMuted(false) end)
       aural.lastMuted = false
       vol = 0
   end

   -- Adjust volume by 5 units per scroll tick
   vol = math.max(0, math.min(100, vol + (direction * 5)))
   current:setVolume(vol)

   -- Update live HUD smoothly while scrolling
   if aural.hudEnabled then
       local category = categoryForDevice(current)
       local name = current:name()
       aural.updateHUD(category, name, getVolumeString(current))
   end
end

-- ── Right click = pop up the full device list, Scroll = volume ──
local function isMouseOverMenubar()
   local frame = aural.menubar:frame()
   if not frame then return false end

   local loc = hs.mouse.absolutePosition()
   return loc.x >= frame.x and loc.x <= frame.x + frame.w
      and loc.y >= frame.y and loc.y <= frame.y + frame.h
end

aural.rightClickWatcher = hs.eventtap.new({
   hs.eventtap.event.types.rightMouseUp,
   hs.eventtap.event.types.scrollWheel
}, function(event)
   local eventType = event:getType()

   -- Handle Scroll Wheel for Volume
   if eventType == hs.eventtap.event.types.scrollWheel then
       if isMouseOverMenubar() then
           local direction = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)

           if direction < 0 then
               adjustVolume(-1) -- Scroll up = Volume down (Inverted)
           elseif direction > 0 then
               adjustVolume(1)  -- Scroll down = Volume up (Inverted)
           end

           -- Return true to swallow the event so the background app doesn't also scroll
           return true
       end
       return false
   end

   -- Handle Right Click for Menu Popup
   if eventType == hs.eventtap.event.types.rightMouseUp then
       local frame = aural.menubar:frame()
       if not frame then return false end

       local loc = event:location()
       if loc.x >= frame.x and loc.x <= frame.x + frame.w
          and loc.y >= frame.y and loc.y <= frame.y + frame.h then
           aural.menubar:setMenu(buildMenu())
           aural.menubar:popupMenu(hs.geometry.point(frame.x, frame.y + frame.h))
           aural.menubar:setMenu(nil) -- detach again so left-click callback keeps firing
       end
   end

   return false
end)
aural.rightClickWatcher:start()

-- ── Watcher ──

hs.audiodevice.watcher.setCallback(function(event)
   log("CoreAudio watcher event:", event)
   aural.updateIcon()
end)
hs.audiodevice.watcher.start()

-- Turn the HUD on/off from the console if you ever want to: aural.hudEnabled = false
aural.hudEnabled = true

-- initial paint on load
local initialDevice = hs.audiodevice.defaultOutputDevice()
aural.lastDeviceUID = initialDevice and initialDevice:uid() or nil
aural.lastMuted = isMuted(initialDevice)
local initialIcon = ensureIcon(categoryForDevice(initialDevice), "menubar")
if initialIcon then
    aural.menubar:setIcon(initialIcon, true)
end

return aural