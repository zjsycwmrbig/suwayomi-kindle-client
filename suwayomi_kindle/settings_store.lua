local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local dump = require("dump")
local sha256 = require("ffi/sha2").sha256
local Languages = require("suwayomi_kindle/languages")

local Store = {}
Store.__index = Store

local defaults = {
    connection = {server_url = "", auth_method = "none", username = "", password = "",
        last_verified_credential_hash = "", last_verified_at = 0},
    theme = {mode = "day"},
    general = {confirm_exit = true},
    download = {directory = "", max_parallel = 1, retention = "1"},
    library = {view_mode = "list", sort = "title"},
    browse = {view_mode = "list", language = "zh", sort = "opened"},
    recommendation = {enabled = true, auto_search = false, limit = 24, sources = 3, search_languages = "zh,en,ja"},
}

local function fingerprint(settings)
    return sha256(table.concat({settings.server_url, settings.auth_method,
        settings.username, settings.password}, "\0"))
end

function Store:new(options)
    local root = options and options.root or DataStorage:getSettingsDir()
    return setmetatable({root = root}, self)
end

function Store:path(section)
    assert(defaults[section])
    return self.root .. "/suwayomi_kindle_" .. section .. ".lua"
end

function Store:load(section)
    local path = self:path(section)
    if section == "connection" and not lfs.attributes(path) then
        path = self.root .. "/suwayomi_kindle.lua"
    end
    local data = LuaSettings:open(path).data
    local values = {}
    for key, value in pairs(defaults[section]) do
        if type(data[key]) == type(value) then values[key] = data[key]
        else values[key] = value end
    end
    if section == "recommendation" then
        local order = type(data.search_languages) == "string" and data.search_languages
            or type(data.search_language) == "string" and data.search_language or nil
        values.search_languages = table.concat(Languages.titleOrder(order), ",")
    end
    return values
end

function Store:update(section, patch)
    local values = self:load(section)
    for key, value in pairs(patch) do
        if defaults[section][key] ~= nil then values[key] = value end
    end
    local path = self:path(section)
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil, "无法写入设置。" end
    local written = file:write("return ", dump(values, nil, true), "\n")
    local closed = file:close()
    if not written or not closed or not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, "无法保存设置。"
    end
    return values
end

function Store:is_verified(settings)
    return settings.server_url ~= "" and settings.last_verified_credential_hash == fingerprint(settings)
end

function Store:mark_verified(settings)
    local saved = self:load("connection")
    if fingerprint(saved) ~= fingerprint(settings) then return nil end
    return self:update("connection", {last_verified_credential_hash = fingerprint(settings), last_verified_at = os.time()})
end

return Store
