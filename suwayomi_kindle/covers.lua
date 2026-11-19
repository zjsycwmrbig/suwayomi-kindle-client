-- Evict stale slot entries, keeping every poster on the current page even
-- when two visible titles hash to the same slot.
local Storage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local sha256 = require("ffi/sha2").sha256
local Covers = {}

local function location(config, item)
    local hash = sha256(table.concat({config.server_url, config.auth_method, config.username,
        item.id, item.thumbnail or ""}, "\0"))
    local dir = Storage:getDataDir() .. "/cache" .. "/suwayomi_posters/" .. hash:sub(1, 2)
    return dir .. "/" .. hash .. ".png", dir
end

function Covers.path(config, item)
    local path = location(config, item)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

function Covers.fetch(client, items)
    local render = require("ffi/mupdf").renderImage
    local visible = {}
    for _, item in ipairs(items) do visible[location(client.settings, item)] = true end
    local changed = false
    for _, item in ipairs(items) do
        if not Covers.path(client.settings, item) then
            local body = client:thumbnail(item.id)
            if body and #body > 0 then
                local rendered, bitmap = pcall(render, body, #body, 144, 204)
                if rendered and bitmap then
                    local path, dir = location(client.settings, item)
                    require("util").makePath(dir)
                    local tmp = path .. ".tmp"
                    local ok = pcall(bitmap.writePNG, bitmap, tmp)
                    bitmap:free()
                    if ok and (lfs.attributes(tmp, "size") or 0) > 0 and os.rename(tmp, path) then
                        changed = true
                        for name in lfs.dir(dir) do
                            if name:match("^%x+%.png$") and not visible[dir .. "/" .. name] then os.remove(dir .. "/" .. name) end
                        end
                    else
                        os.remove(tmp)
                    end
                end
            end
        end
    end
    return {changed = changed}
end

return Covers
