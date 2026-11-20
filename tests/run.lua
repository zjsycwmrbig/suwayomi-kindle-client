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

local Progress = require("suwayomi_kindle/progress")
local fraction, percent = Progress.measure(7, 3)
equal(fraction, 4/7)
equal(percent, 57)
equal(select(2, Progress.measure(7, 7)), 0)
equal(select(2, Progress.measure(7, 0)), 100)
equal(select(2, Progress.measure(1000, 1)), 99)
equal((Progress.measure(0, 0)), nil)
equal((Progress.measure(7)), nil)
equal((Progress.measure(7, 8)), nil)
print("reading progress calculation passed")
equal(Progress.badge(7, 3), "4/7 · 57%")
equal(Progress.badge(7, 0), "已读")
equal(Progress.badge(7, 7), "未读")
equal(Progress.badge(0, 0), "暂无章节")
equal(Progress.badge(7, nil), "进度未知")

local Languages = require("suwayomi_kindle/languages")
local options = Languages.options("zh", {{lang="fil-PH"}})
assert(options[#options] == "fil")
local mixed = Languages.toggle("zh", "en", options)
assert(mixed == "zh,en" and Languages.set(mixed)[Languages.base("zh-Hant")])
assert(Languages.toggle(mixed, "zh", options) == "en")
assert(not Languages.set(Languages.toggle("all", "en", options)).en)
assert(Languages.toggle("all", "all", options) == "")

local Pages = require("suwayomi_kindle/source_pages")
local calls = {}
local counts = {5, 1, 3}
local client = {sourcePage = function(_, input)
    calls[#calls+1] = input.page
    local rows = {}
    for i=1,counts[input.page] do rows[i] = {id = input.page .. "/" .. i} end
    return {mangas = rows, has_next = input.page < #counts}
end}
local first = assert(Pages.fetch(client, {size=2, target=1}))
assert(first.remote==1 and first.slice==1 and not first.ended and #calls==1)
local last = assert(Pages.fetch(client,{size=2,target="last",counts=first.counts}))
assert(last.remote==3 and last.slice==2 and last.ended and #calls==3)
local jump = assert(Pages.fetch(client,{size=2,target=3,counts=last.counts,ended=true}))
assert(jump.remote==1 and jump.slice==3 and jump.ended and #calls==4)
local beyond = assert(Pages.fetch(client,{size=2,target=99,counts=last.counts,ended=true}))
assert(beyond.remote==3 and beyond.slice==2)
local by_item = assert(Pages.fetch(client,{size=2,target=6,by_item=true}))
assert(by_item.remote==2 and by_item.slice==1)
by_item = assert(Pages.fetch(client,{size=2,target=9,by_item=true,counts=last.counts,ended=true}))
assert(by_item.remote==3 and by_item.slice==2)
local no_item, item_error = Pages.fetch(client,{size=2,target=10,by_item=true,counts=last.counts,ended=true})
assert(not no_item and item_error == "没有这么多项目。")
print("language selection and source pagination tests passed")

local Sources = require("suwayomi_kindle/browse_sources")
local source_list = {{id="p",name="Zulu",lang="zh-Hant"},{id="n",name="Beta",lang="zh"},
    {id="a",name="alpha",lang="zh"},{id="e",name="English",lang="en"}}
local opened = {p=1,a=2,n=3,e=4,removed=5}
local history = {opened=opened}
equal(Sources.landing(source_list,"zh",history).id,"n")
equal(Sources.landing(source_list,"zh",history,{n=1}).id,"n")
equal(Sources.landing(source_list,"all",history).id,"e")
equal(Sources.landing(source_list,"ja",history),nil)
equal(Sources.landing(source_list,"zh",{opened={}}),nil)
local function order(language,filter,sort)
    local ids = {}
    for i,source in ipairs(Sources.list(source_list,language,filter,sort,{p=true},opened)) do ids[i] = source.id end
    return table.concat(ids,",")
end
equal(order("zh","","opened"),"p,n,a")
equal(order("zh","","name"),"p,a,n")
equal(order("all","","language"),"p,e,a,n")
equal(order("all","ta","opened"),"n")
print("default source, language filtering, and source sort tests passed")
