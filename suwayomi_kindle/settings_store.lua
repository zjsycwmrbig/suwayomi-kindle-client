local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local dump = require("dump")
local sha256 = require("ffi/sha2").sha256

local Store = {}
Store.__index = Store

local defaults = {
    connection = {server_url = "", auth_method = "none", username = "", password = "",
        last_verified_credential_hash = "", last_verified_at = 0},
    download = {directory = "", max_parallel = 1, retention = "never"},
    library = {view_mode = "list"},
    browse = {view_mode = "list", language = "zh"},
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
        values[key] = type(data[key]) == type(value) and data[key] or value
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
