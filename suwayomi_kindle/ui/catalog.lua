local UI = require("ui/uimanager")
local Screen = require("device").screen
local Font = require("ui/font")
local Frame = require("ui/widget/container/framecontainer")
local Scroll = require("ui/widget/container/scrollablecontainer")
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local Gap = require("ui/widget/horizontalspan")
local Column = require("ui/widget/verticalgroup")
local Space = require("ui/widget/verticalspan")
local Paragraph = require("ui/widget/textboxwidget")
local Button = require("suwayomi_kindle/ui/flat_button")
local SettingRow = require("suwayomi_kindle/ui/setting_row")
local Tile = require("suwayomi_kindle/ui/manga_tile")
local Worker = require("suwayomi_kindle/worker")
local Index = require("suwayomi_kindle/library_index")
local Covers = require("suwayomi_kindle/covers")

local Catalog = {}
local function scale(n) return Screen:scaleBySize(n) end

function Catalog:reset_browse()
    self.browse = {sources_page = 1, mode = "POPULAR", page = 1, slice = 1}
end

function Catalog:cancel_catalog()
    if self.pending == "sources" and not self.browse.sources then self.browse.requested = false end
    if self.pending == "library" then self.shelf_requested = false end
    if self.job then self.job:cancel() end
    if self.poster_job then self.poster_job:cancel() end
    self.job, self.pending, self.poster_job, self.poster_key = nil, nil, nil, nil
    self.generation = (self.generation or 0) + 1
end

function Catalog:reset_catalog()
    self:cancel_catalog()
    self:reset_browse()
    self.detail, self.catalog_message, self.shelf_requested = nil, nil, nil
    self.shelf_page, self.index = 1, nil
end

function Catalog:set_saved_connection(saved)
    local old = self.settings.connection
    if old.server_url ~= saved.server_url or old.auth_method ~= saved.auth_method
        or old.username ~= saved.username or old.password ~= saved.password then self:reset_catalog() end
    self.settings.connection = saved
end

function Catalog:catalog_back()
    self:cancel_catalog()
    self.catalog_message = nil
    if self.detail then
        self.detail = nil
    else
        self.browse.source, self.browse.results = nil, nil
    end
    self:refresh()
end

function Catalog:request_catalog(action, input, done)
    self:cancel_catalog()
    local generation = self.generation
    self.catalog_message, self.pending = nil, action
    self:refresh()
    self.job = Worker.start(UI, self.settings.connection, action, input, function(data, err)
        if not self.alive or generation ~= self.generation then return end
        self.pending, self.job = nil, nil
        self.catalog_message = err
        if data then done(data) end
        self:refresh()
    end)
end

local function refresh_shelf(home)
    home.shelf_requested = true
    home:request_catalog("library", {}, function(data)
        home.catalog_message = "已拉取 " .. data.count .. " 部漫画"
    end)
end

local function fetch_sources(home)
    home.browse.requested = true
    home:request_catalog("sources", {language = home.settings.browse.language}, function(data)
        home.browse.sources = data.sources
        home.browse.sources_page = 1
    end)
end

local function fetch_page(home, mode, page, search, last_slice)
    local b = home.browse
    home:request_catalog("source_page", {source = b.source, mode = mode, page = page, search = search}, function(data)
        b.mode, b.page, b.search, b.results = mode, page, search, data
        b.slice = last_slice and math.huge or 1
    end)
end

local function ask_search(home)
    local Dialog = require("ui/widget/inputdialog")
    local d
    local function submit()
        local query = require("suwayomi_kindle/config").trim(d:getInputText())
        if query == "" then return end
        UI:close(d)
        fetch_page(home, "SEARCH", 1, query)
    end
    d = Dialog:new{title = "搜索漫画", input = home.browse.search or "", buttons = {{
        {text = "取消", callback = function() UI:close(d) end},
        {text = "搜索", is_enter_default = true, callback = submit},
    }}}
    UI:show(d)
    d:onShowKeyboard()
end

local function note(column, width, value)
    if not value or value == "" then return end
    column[#column + 1] = Space:new{width = scale(6)}
    column[#column + 1] = Paragraph:new{text = value, width = width, face = Font:getFace("smallinfofont", 16)}
end

-- Each action is {label, callback, selected}. A missing callback disables it.
local function buttons(home, column, width, actions)
    local row = Row:new{}
    local gap = scale(6)
    local w = math.floor((width - gap * (#actions - 1)) / #actions)
    for i, action in ipairs(actions) do
        if i > 1 then row[#row + 1] = Gap:new{width = gap} end
        row[#row + 1] = Button.new{text = action[1], callback = action[2], enabled = action[2] ~= nil,
            filled = action[3], width = w, show_parent = home}
    end
    column[#column + 1] = row
    column[#column + 1] = Space:new{width = scale(6)}
end

local function pager(home, column, width, prev, next_page)
    if prev or next_page then buttons(home, column, width, {{"上一页", prev}, {"下一页", next_page}}) end
end

local function slice(items, page, size)
    local pages = math.max(1, math.ceil(#items / size))
    page = math.max(1, math.min(pages, page))
    local result = {}
    for i = (page - 1) * size + 1, math.min(#items, page * size) do result[#result + 1] = items[i] end
    return result, page, pages
end

local function defer(home, task)
    local generation = home.generation
    UI:nextTick(function()
        if home.alive and home.generation == generation then task(home) end
    end)
end

local function load_posters(home, items)
    local ids, missing = {}, {}
    for _, item in ipairs(items) do
        ids[#ids + 1] = item.id
        if not Covers.path(home.settings.connection, item) then missing[#missing + 1] = item end
    end
    local key = table.concat(ids, ",")
    if home.pending or home.poster_key == key then return end
    if home.poster_job then home.poster_job:cancel() end
    home.poster_key, home.poster_job = key, nil
    if #missing == 0 then return end
    defer(home, function()
        if home.poster_key ~= key then return end
        home.poster_job = Worker.start(UI, home.settings.connection, "covers", missing, function(data)
            if not home.alive or home.poster_key ~= key then return end
            home.poster_job = nil
            if data and data.changed then home:refresh() end
        end)
    end)
end

local function manga_list(home, column, width, items, grid)
    local tiles
    for i, item in ipairs(items) do
        local function open()
            home:cancel_catalog()
            home.detail, home.catalog_message = item, nil
            home:refresh()
        end
        if grid then
            if i % 3 == 1 then tiles = Row:new{}; column[#column + 1] = tiles end
            tiles[#tiles + 1] = Tile:new{width = math.floor(width / 3), title = item.title,
                path = Covers.path(home.settings.connection, item), callback = open}
        else
            column[#column + 1] = SettingRow:new{label = item.title, value = item.author ~= "" and item.author or item.source,
                width = width, callback = open}
        end
    end
    if grid then load_posters(home, items) end
end

local function library(home, column, width, size, grid)
    home.index = home.index or Index.new(home.settings.connection)
    local data, err = home.index:page(home.shelf_page, size)
    buttons(home, column, width, {{home.pending and "正在拉取…" or "从服务器拉取书架",
        not home.pending and function() refresh_shelf(home) end or nil}})
    if not data then note(column, width, err); return end
    home.shelf_page = data.page
    if data.synced == 0 and not home.shelf_requested then
        home.shelf_requested = true
        defer(home, refresh_shelf)
    end
    if data.count == 0 then
        note(column, width, data.synced == 0 and "还没有本地书架记录。" or "服务器书架为空。")
        return
    end
    local pages = math.ceil(data.count / size)
    note(column, width, data.count .. " 部 · 第 " .. data.page .. " / " .. pages .. " 页")
    manga_list(home, column, width, data.items, grid)
    local function turn(delta) home.shelf_page = home.shelf_page + delta; home:refresh() end
    pager(home, column, width, data.page > 1 and function() turn(-1) end,
        data.page < pages and function() turn(1) end)
end

local function sources(home, column, width, size)
    local b = home.browse
    if not b.requested then
        b.requested = true
        defer(home, fetch_sources)
    end
    buttons(home, column, width, {{home.pending and "正在获取…" or "刷新漫画源",
        not home.pending and function() fetch_sources(home) end or nil}})
    if not b.sources then return end
    if #b.sources == 0 then note(column, width, "当前语言下没有漫画源，可在「设置 → 浏览」更改语言。"); return end
    local items, page, pages = slice(b.sources, b.sources_page, size)
    note(column, width, #b.sources .. " 个源 · 第 " .. page .. " / " .. pages .. " 页")
    for _, source in ipairs(items) do
        column[#column + 1] = SettingRow:new{width = width, label = source.name, value = source.lang,
            callback = function()
                b.source, b.results, b.mode, b.page, b.slice, b.search = source, nil, "POPULAR", 1, 1, nil
                fetch_page(home, "POPULAR", 1)
            end}
    end
    local function turn(delta) b.sources_page = page + delta; home:refresh() end
    pager(home, column, width, page > 1 and function() turn(-1) end, page < pages and function() turn(1) end)
end

local function source_manga(home, column, width, size, grid)
    local b = home.browse
    local actions = {{"热门", function() fetch_page(home, "POPULAR", 1) end, b.mode == "POPULAR"}}
    if b.source.latest then
        actions[#actions + 1] = {"最新", function() fetch_page(home, "LATEST", 1) end, b.mode == "LATEST"}
    end
    actions[#actions + 1] = {"搜索", function() ask_search(home) end, b.mode == "SEARCH"}
    buttons(home, column, width, actions)
    if home.pending then note(column, width, "正在获取漫画…") end
    if not b.results then return end
    local items, page, pages = slice(b.results.mangas, b.slice, size)
    b.slice = page
    note(column, width, (b.mode == "SEARCH" and "搜索「" .. b.search .. "」 · " or "")
        .. "源页 " .. b.page .. (pages > 1 and " · 第 " .. page .. " / " .. pages .. " 屏" or ""))
    if #items == 0 then note(column, width, "这一页没有漫画。") end
    manga_list(home, column, width, items, grid)
    local function turn(delta)
        if page + delta >= 1 and page + delta <= pages then
            b.slice = page + delta
            home:refresh()
        else
            fetch_page(home, b.mode, b.page + delta, b.search, delta < 0)
        end
    end
    pager(home, column, width, (page > 1 or b.page > 1) and function() turn(-1) end,
        (page < pages or b.results.has_next) and function() turn(1) end)
end

local function detail(home, column, width)
    local item = home.detail
    note(column, width, item.source)
    note(column, width, item.author)
    if home.selected_tab == "browse" then
        local function add()
            home:request_catalog("add", item, function(data)
                item.in_library = true
                home.catalog_message = data.warning or "已加入书架。"
            end)
        end
        buttons(home, column, width, {{item.in_library and "已在书架" or home.pending and "正在加入…" or "加入书架",
            not item.in_library and not home.pending and add or nil}})
    end
    note(column, width, item.description)
end

function Catalog:build_catalog(screen_width, height)
    local width = screen_width - scale(48)
    local column = Column:new{align = "left", Space:new{width = scale(12)}}
    local grid = self.settings[self.selected_tab].view_mode == "grid"
    local size = grid and 3 * math.max(1, math.floor((height - scale(174)) / scale(150)))
        or math.max(1, math.floor((height - scale(174)) / scale(66)))
    if self.settings.connection.server_url == "" then
        note(column, width, "先设置 Suwayomi 服务器地址。")
        buttons(self, column, width, {{"前往连接设置", function()
            self:set_tab("settings")
            self:open_connection_settings()
        end}})
    elseif self.detail then detail(self, column, width)
    elseif self.selected_tab == "library" then library(self, column, width, size, grid)
    elseif self.browse.source then source_manga(self, column, width, size, grid)
    else sources(self, column, width, math.max(1, math.floor((height - scale(174)) / scale(66)))) end
    note(column, width, self.catalog_message)
    local viewport = Scroll:new{dimen = Geom:new{w = width + Scroll:getScrollbarWidth(), h = height},
        show_parent = self, column}
    self.cropping_widget = viewport
    return Frame:new{width = screen_width, height = height, padding = 0, bordersize = 0,
        padding_left = scale(24), viewport}
end

return Catalog
