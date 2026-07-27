-- Aural by @motionkartik

local aural = {}

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

local iconCache = {}

local function ensureIcon(category, variant)
   local cacheKey = category .. ":" .. variant
   if iconCache[cacheKey] then return iconCache[cacheKey] end

   local path = ICON_DIR .. category .. "-" .. variant .. ".png"
   local f = io.open(path, "r")
   if f then
       f:close()
   else
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
       end
   end

   local img = hs.image.imageFromPath(path)
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
    return math.floor(vol) .. "%"
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
    local x = screenFrame.x + (screenFrame.w - w) / 2
    local y = screenFrame.y + (screenFrame.h - h) / 2

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

    -- Update Icon
    local icon = ensureIcon(category, "hud")
    if icon then
        aural.hud[2] = {
            type = "image",
            image = icon,
            frame = { x = 100 - 28, y = 18, w = 56, h = 56 },
        }
    end

    -- Update Device Name
    aural.hud[3] = {
        type = "text",
        text = deviceName or "",
        textSize = 14,
        textColor = { white = 1, alpha = 1 },
        textAlignment = "center",
        frame = { x = 8, y = 80, w = 200 - 16, h = 20 },
    }

    -- Update Volume Text
    if volumeText then
        aural.hud[4] = {
            type = "text",
            text = volumeText,
            textSize = 20,
            textColor = { white = 1, alpha = 0.9 },
            textAlignment = "center",
            frame = { x = 8, y = 105, w = 200 - 16, h = 28 },
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

local function switchTo(dev)
   return function()
       dev:setDefaultOutputDevice()
       aural.updateIcon()
   end
end

local function buildMenu()
   local current = hs.audiodevice.defaultOutputDevice()
   local devices = hs.audiodevice.allOutputDevices()
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

-- Repaint the menubar icon/tooltip, and pop the HUD if the device actually changed
function aural.updateIcon()
   local current = hs.audiodevice.defaultOutputDevice()
   local category = categoryForDevice(current)

   aural.menubar:setIcon(ensureIcon(category, "menubar"), true)
   aural.menubar:setTooltip(current and ("Aural — " .. current:name()) or "Aural")

   local uid = current and current:uid() or nil
   if uid ~= aural.lastDeviceUID then
       aural.lastDeviceUID = uid
       if current and aural.hudEnabled then
           aural.showHUD(category, current:name(), getVolumeString(current))
       end
   end
end

-- ── Left click = instant cycle to next device ──
local function cycleToNext()
   local devices = hs.audiodevice.allOutputDevices()
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
   nextDevice:setDefaultOutputDevice()
   aural.updateIcon()
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

hs.audiodevice.watcher.setCallback(function(_event)
   aural.updateIcon()
end)
hs.audiodevice.watcher.start()

-- Turn the HUD on/off from the console if you ever want to: aural.hudEnabled = false
aural.hudEnabled = true

-- initial paint on load
aural.lastDeviceUID = hs.audiodevice.defaultOutputDevice() and hs.audiodevice.defaultOutputDevice():uid() or nil
aural.menubar:setIcon(ensureIcon(categoryForDevice(hs.audiodevice.defaultOutputDevice()), "menubar"), true)

return aural