-- Spoonfeeder by @motionkartik
-- Automatically reloads Hammerspoon when any Lua file changes

local spoonPath = hs.configdir .. "/Spoons"

----------------------------------------------------------------
-- Recursively load all .lua files
----------------------------------------------------------------

local function loadDirectory(path)
    local files = {}
    
    for file in hs.fs.dir(path) do
        if file ~= "." and file ~= ".." then
            local fullPath = path .. "/" .. file
            local attr = hs.fs.attributes(fullPath)

            if attr then
                if attr.mode == "directory" then
                    loadDirectory(fullPath)

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
        if file:match("%.lua$") then
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