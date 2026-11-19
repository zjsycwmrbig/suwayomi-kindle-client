local test_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = assert(test_path:match("^(.*)/tests/connection%.lua$"))
package.path = plugin_root .. "/?.lua;" .. package.path

local Connection = require("suwayomi_kindle/connection")
local SettingsStore = require("suwayomi_kindle/settings_store")

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local basic_result = Connection.test({
    server_url = "http://suwayomi.test",
    auth_method = "basic_auth",
    username = "alice",
    password = "secret",
}, function(url, _, headers)
    equal(url, "http://suwayomi.test/api/graphql", "builds GraphQL endpoint")
    equal(headers.Authorization, "Basic YWxpY2U6c2VjcmV0", "adds Basic Auth")
    return {
        ok = true,
        status = 200,
        body = [[{"data":{"categories":{"nodes":[]}}}]],
    }
end)
assert(basic_result.ok, basic_result.error)

local calls = 0
local login_result = Connection.test({
    server_url = "https://suwayomi.test/base",
    auth_method = "ui_login",
    username = "alice",
    password = "secret",
}, function(url, _, headers)
    calls = calls + 1
    equal(url, "https://suwayomi.test/base/api/graphql", "preserves a base path")
    if calls == 1 then
        equal(headers.Authorization, nil, "login request is anonymous")
        return {
            ok = true,
            status = 200,
            body = [[{"data":{"login":{"accessToken":"access-token","refreshToken":"refresh-token"}}}]],
        }
    end
    equal(headers.Authorization, "Bearer access-token", "uses the issued access token")
    return {
        ok = true,
        status = 200,
        body = [[{"data":{"categories":{"nodes":[{"id":1}]}}}]],
    }
end)
assert(login_result.ok, login_result.error)
equal(calls, 2, "performs login and verification")
equal(login_result.category_count, 1, "reads the protected category response")

local invalid = assert(Connection._verify_payload({
    ok = false,
    status = 401,
}))
equal(invalid.ok, false, "classifies authentication failure")
assert(invalid.error:find("认证", 1, true), "returns a safe authentication message")

local lfs = require("libs/libkoreader-lfs")
local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
local settings_store = SettingsStore:new{root = root}
local old = assert(io.open(root .. "/suwayomi_kindle.lua", "w"))
old:write([[return {server_url="http://suwayomi.test", auth_method="ui_login", username="alice", password="secret"}]])
old:close()
local saved = settings_store:load("connection")
equal(saved.username, "alice", "reads existing connection")
assert(not settings_store:is_verified(saved))
saved = assert(settings_store:mark_verified(saved))
assert(settings_store:is_verified(saved))
saved.password = "changed"
assert(not settings_store:is_verified(saved))
equal(settings_store:load("download").retention, "never")
assert(settings_store:update("browse", {language = "en", view_mode = "grid"}))
assert(settings_store:update("library", {view_mode = "list"}))
for _, policy in ipairs({"0", "1", "3", "5", "10", "never"}) do
    assert(settings_store:update("download", {max_parallel = 3, retention = policy, directory = "/tmp/books"}))
    equal(SettingsStore:new{root = root}:load("download").retention, policy)
end
equal(settings_store:load("browse").language, "en")
equal(settings_store:load("connection").password, "secret")
for _, section in ipairs({"browse", "download", "connection", "library"}) do
    assert(os.remove(settings_store:path(section)))
end
assert(os.remove(root .. "/suwayomi_kindle.lua"))
assert(lfs.rmdir(root))
print("connection and separate settings tests passed")
