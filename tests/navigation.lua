-- Run in KOReader's runtime with SDL_VIDEO_DRIVER=dummy and a temporary KO_HOME.
require("setupkoenv")
local root = assert(debug.getinfo(1, "S").source:match("^@(.*)/tests/navigation%.lua$"))
package.path = root .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
local device = require("device")
require("document/canvascontext"):init(device)
require("ui/bidi").setup("zh_CN")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UI = require("ui/uimanager")
local Pager = require("suwayomi_kindle/ui/pager")
local store = require("suwayomi_kindle/settings_store"):new()
local home = require("suwayomi_kindle/ui/home"):new{settings_store = store}
home.settings.connection.server_url = "http://example.test"
home.index = {pins = function() return {} end, page = function(_, page, size)
    return {items = {}, count = size + 1, synced = 1, page = page}
end}
UI:show(home)
home:set_tab("library")

local function find(widget, key, value)
    if widget[key] == value then return widget end
    for _, child in ipairs(widget) do
        local match = find(child, key, value)
        if match then return match end
    end
end

local function check_footer()
    home:paintTo(device.screen.bb, 0, 0)
    local nav = home[1][1][2]:contentRange()
    local viewport = home.cropping_widget.dimen
    assert(viewport.y + viewport.h == nav.y)
    local control = assert(find(home, "icon", "chevron.first")).dimen
    assert(control.y >= nav.y and control.y + control.h <= nav.y + Pager.height())
    assert(find(home, "tab_id", "library").dimen.y == nav.y + Pager.height() + device.screen:scaleBySize(1))
    return nav.y
end

local function tap(x, y)
    UI:sendEvent(Event:new("Gesture", {ges = "tap", pos = Geom:new{x = x, y = y, w = 1, h = 1}}))
end

local y = check_footer()
home.pagination.go(2)
assert(home.pagination.page == 2 and check_footer() == y)
local viewport, tree = home.cropping_widget, home[1]
local function open()
    find(home, "icon_name", "menu").callback()
    local drawer = assert(home.drawer)
    drawer:paintTo(device.screen.bb, 0, home.drawer_top)
    assert(drawer.dimen.w < device.screen:getWidth() and drawer.dimen.y == home.drawer_top and drawer.dimen.h == home.drawer_height)
    return drawer
end
local drawer = open()
tap(drawer.dimen.w - 5, drawer.dimen.h - 10)
assert(home.drawer == drawer)
tap(device.screen:getWidth() - 4, device.screen:getHeight() - 10)
assert(not home.drawer and home.selected_tab == "library" and home.pagination.page == 2)
assert(home[1] == tree and home.cropping_widget == viewport and check_footer() == y)

local invocations = 0
home.catalog_actions = function()
    return {{"从服务器刷新", function() invocations = invocations + 1; assert(not home.drawer) end}}
end
drawer = open()
local entry = assert(find(drawer, "label", "从服务器刷新"))
tap(entry.dimen.x + 8, entry.dimen.y + 8)
assert(invocations == 1 and not home.drawer)
open()
UI:sendEvent(Event:new("CloseDialog"))
assert(not home.drawer)

home.all_sources = {{name = "测试源", lang = "zh"}}
home:set_tab("browse")
assert(check_footer() == y)
home:set_tab("settings")
home.settings_route = "languages"
home:refresh()
assert(check_footer() == y)
home:set_tab("library")
home.index = require("suwayomi_kindle/library_index").new(home.settings.connection)
home.detail = {id="41",title="测试漫画",source="测试源",description="简介内容",chapters=32,in_library=true}
local chapters = require("suwayomi_kindle/chapters")
assert(chapters.refresh(home.index,{chapterPage=function()
    local rows = {}
    for i=1,32 do rows[i] = {id=i,name="第"..i.."话",isRead=i<24} end
    return {nodes=rows,totalCount=32,pageInfo={hasNextPage=false}}
end},"41"))
home:refresh()
home:paintTo(device.screen.bb,0,0)
assert(find(home,"text","简介内容"))
find(home,"text","继续阅读").callback()
assert(home.directory.target == 24 and home.pagination.page > 1)
check_footer()
assert(find(home,"label","第24话"))
home:catalog_back()
find(home,"text","全部章节").callback()
assert(home.pagination.page == 1 and find(home,"label","第1话"))
home.catalog_actions=nil
local menu=open()
assert(not find(menu,"text","全部章节"))
find(menu,"label","自动下载").callback()
for _,count in ipairs({1,3,5}) do assert(find(menu,"label",count .. " 章")) end
find(menu,"label","3 章").callback()
local downloads=require("suwayomi_kindle/downloads")
assert(downloads.policy(home.index,"41").ahead==3)
menu=open()
find(menu,"label","删除策略").callback()
find(menu,"label","保留 5 章").callback()
assert(downloads.policy(home.index,"41").retention=="5")
local first=find(home,"label","第1话")
local function parent_of(widget,element)
    for _,child in ipairs(widget) do
        if child==element then return widget end
        local parent=parent_of(child,element)
        if parent then return parent end
    end
end
local row=assert(parent_of(home,first))
assert(row[2].text=="下载" and row[3].icon_name=="chevron_right")
row[3].callback()
local more=UI:getTopmostVisibleWidget()
assert(find(more,"text","标记之前为已读") and find(more,"text","标记之后为未读"))
assert(not find(more,"text","返回目录"))
UI:close(more)
row[2].callback()
assert(require("suwayomi_kindle/chapters").page(home.index,"41",1,1).items[1].state=="queued")
local opened
home.open_local = function(_,path) opened=path end
local file = os.tmpname()
io.open(file,"wb"):close()
assert(home.index:with_db(function(db)
    db:prepare("INSERT INTO files VALUES(?,?,?)"):bind("41",24,file):step()
    return true
end))
home:catalog_back()
find(home,"text","继续阅读").callback()
assert(opened == file)
os.remove(file)
-- Exercise the same ReaderReady/CloseDocument hooks used by KOReader, including
-- a pending page restored after reopening and completion on the last page.
local reader=require("suwayomi_kindle/reader")
local path=chapters.downloadPath(home.index,{manga="41",id=24,directory=require("datastorage"):getDataDir()})
assert(home.index:with_db(function(db)
    db:prepare("UPDATE files SET path=? WHERE manga=? AND id=?"):bind(path,"41",24):step()
    return true
end))
local page=4
local mock={settings_store={load=function(_,section) return home.settings[section] end},ui={
    document={file=path,getPageCount=function() return 8 end},
    getCurrentPage=function() return page end,
    paging={onGotoPage=function(_,p) page=p end},
    registerPostReaderReadyCallback=function(_,cb) cb() end,
}}
reader.onReaderReady(mock)
reader.onCloseDocument(mock)
page=1
reader.onReaderReady(mock)
assert(page==4)
page=8
reader.onCloseDocument(mock)
assert(chapters.nextUnread(home.index,"41").id==25)
local pending=require("suwayomi_kindle/records").status(home.index)
assert(pending.count==1)
home:set_tab("settings")
home.settings_route="sync"
home:refresh()
home:paintTo(device.screen.bb,0,0)
assert(find(home,"label","同步本地记录") and find(home,"label","从服务器同步"))
home.settings_route = "theme"
home:refresh()
local normal = home.previous_night_mode
find(home,"text","黑夜").callback()
assert(device.screen.night_mode and store:load("theme").mode == "night")
home:set_tab("library")
assert(check_footer() == y)
drawer = open()
assert(device.screen.night_mode)
drawer:dismiss()
UI:close(home)
assert((device.screen.night_mode == true) == normal)
home = require("suwayomi_kindle/ui/home"):new{settings_store=store}
assert(device.screen.night_mode and home.settings.theme.mode == "night")
UI:show(home)
home.settings_route = "theme"
home:refresh()
find(home,"text","白天").callback()
assert(not device.screen.night_mode and store:load("theme").mode == "day")
UI:close(home)
print("Fixed pagination and modal drawer navigation passed")
