-- Boundary: persistent plugin configuration.
--
-- Responsibility: load and atomically flush the small connection document.
-- Session tokens and cookies are deliberately excluded.
-- Owned state: one LuaSettings instance.
-- Dependencies: KOReader LuaSettings and DataStorage.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Config = require("suwayomi_kindle/config")
local sha256 = require("ffi/sha2").sha256

local SettingsStore = {}
SettingsStore.__index = SettingsStore

local DEFAULTS = {
    server_url = "",
    auth_method = "none",
    username = "",
    password = "",
    last_verified_url = "",
    last_verified_auth_method = "",
    last_verified_username = "",
    last_verified_credential_hash = "",
    last_verified_at = 0,
}

local function copy(value)
    local result = {}
    for k, v in pairs(value or {}) do
        result[k] = v
    end
    return result
end

local function credential_hash(settings)
    return sha256(table.concat({
        tostring(settings.server_url or ""),
        tostring(settings.auth_method or "none"),
        tostring(settings.username or ""),
        tostring(settings.password or ""),
    }, "\0"))
end

function SettingsStore:new(options)
    options = options or {}
    local file = options.file
        or (DataStorage:getSettingsDir() .. "/suwayomi_kindle.lua")
    return setmetatable({
        file = file,
        lua_settings = LuaSettings:open(file),
    }, self)
end

function SettingsStore:load()
    local values = copy(DEFAULTS)
    for key in pairs(DEFAULTS) do
        local value = self.lua_settings:readSetting(key)
        if value ~= nil then
            values[key] = value
        end
    end
    return values
end

function SettingsStore:save(settings)
    local normalized, normalize_error = Config.normalize(settings)
    if not normalized then
        return nil, normalize_error
    end

    for _, key in ipairs({
        "server_url",
        "auth_method",
        "username",
        "password",
    }) do
        self.lua_settings:saveSetting(key, normalized[key])
    end
    self.lua_settings:flush()
    return normalized
end

function SettingsStore:is_verified(settings)
    settings = settings or {}
    local saved = self:load()
    local url = Config.trim(settings.server_url)
    return url ~= ""
        and saved.last_verified_url == url
        and saved.last_verified_auth_method == tostring(settings.auth_method or "none")
        and saved.last_verified_username == Config.trim(settings.username)
        and saved.last_verified_credential_hash == credential_hash(settings)
end

function SettingsStore:mark_verified(settings)
    self.lua_settings:saveSetting("last_verified_url", Config.trim(settings.server_url))
    self.lua_settings:saveSetting("last_verified_auth_method", tostring(settings.auth_method or "none"))
    self.lua_settings:saveSetting("last_verified_username", Config.trim(settings.username))
    self.lua_settings:saveSetting("last_verified_credential_hash", credential_hash(settings))
    self.lua_settings:saveSetting("last_verified_at", os.time())
    self.lua_settings:flush()
end

return SettingsStore
