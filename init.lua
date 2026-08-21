-- Spoonfeeder by @motionkartik
-- Automatically reloads Hammerspoon when any Lua file or Spoon changes

local spoonPath = hs.configdir .. "/Spoons"

----------------------------------------------------------------
-- Recursively load all .lua files, properly load .spoon bundles
----------------------------------------------------------------

local function loadDirectory(path)
    local files = {}
    local spoons = {}

    for file in hs.fs.dir(path) do
        if file ~= "." and file ~= ".." then
            local fullPath = path .. "/" .. file
            local attr = hs.fs.attributes(fullPath)

            if attr then
                if attr.mode == "directory" then
                    if file:match("%.spoon$") then
                        -- Track Spoon bundles separately, load via hs.loadSpoon()
                        table.insert(spoons, (file:gsub("%.spoon$", "")))
                    else
                        -- Regular subdirectory, keep recursing
                        loadDirectory(fullPath)
                    end

                elseif attr.mode == "file" and file:match("%.lua$") then
                    table.insert(files, fullPath)
                end
            end
        end
    end

    table.sort(files)

    for _, file in ipairs(files) do
        local ok, err = pcall(dofile, file)

        local relative = file:gsub("^" .. hs.configdir .. "/", "")

        if ok then
            print("Loaded: " .. relative)
        else
            print("Error loading: " .. relative)
            print(err)
        end
    end

    table.sort(spoons)

    for _, name in ipairs(spoons) do
        local ok, err = pcall(hs.loadSpoon, name)

        if ok then
            print("Loaded Spoon: " .. name)
        else
            print("Error loading Spoon: " .. name)
            print(err)
        end
    end
end

----------------------------------------------------------------
-- Initial Load
----------------------------------------------------------------

loadDirectory(spoonPath)

----------------------------------------------------------------
-- Auto Reload Configuration
----------------------------------------------------------------

local function reloadConfig(files)
    for _, file in ipairs(files) do
        if file:match("%.lua$") or file:match("%.spoon/") then
            if hs.auto_dlp_unload then
                pcall(hs.auto_dlp_unload)
            end

            hs.reload()
            return
        end
    end
end

watcher = hs.pathwatcher.new(hs.configdir, reloadConfig):start()

hs.alert.show("Config Loaded")