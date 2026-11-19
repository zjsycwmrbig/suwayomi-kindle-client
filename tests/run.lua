package.path = "./?.lua;" .. package.path

local Config = require("suwayomi_kindle/config")

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

local normalized = assert(Config.normalize_server_url("192.168.1.8:4567/api/graphql/"))
equal(normalized, "http://192.168.1.8:4567", "normalizes HTTP and strips GraphQL path")

normalized = assert(Config.normalize_server_url("https://example.com/suwayomi/"))
equal(normalized, "https://example.com/suwayomi", "preserves base path")

local invalid, err = Config.normalize_server_url("ftp://example.com")
equal(invalid, nil, "rejects unsupported schemes")
truthy(err:find("http", 1, true), "explains supported schemes")

local settings = assert(Config.normalize{
    server_url = "https://example.com",
    auth_method = "ui_login",
    username = " reader ",
    password = "secret",
})
equal(settings.username, "reader", "trims username")
equal(settings.auth_method, "ui_login", "keeps auth method")

invalid, err = Config.normalize{
    server_url = "https://example.com",
    auth_method = "ui_login",
    username = "",
    password = "",
}
equal(invalid, nil, "rejects incomplete UI login")
truthy(err:find("用户名", 1, true), "explains missing username")

print("config tests passed")
