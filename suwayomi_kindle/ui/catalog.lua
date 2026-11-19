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
local Pages = require("suwayomi_kindle/source_pages")
local Languages = require("suwayomi_kindle/languages")
local InputText = require("ui/widget/inputtext")
local Image = require("ui/widget/imagewidget")
local Icons = require("suwayomi_kindle/ui/icons")
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
    if self.pending == "sources" and not self.all_sources then self.browse.requested = false end
    if self.pending == "library" then self.shelf_requested = false end
    if self.job then self.job:cancel() end
    if self.poster_job then self.poster_job:cancel() end
    self.job, self.pending, self.poster_job, self.poster_key = nil, nil, nil, nil
    self.generation = (self.generation or 0) + 1
end

function Catalog:reset_catalog()
    self:cancel_catalog()
    self:reset_browse()
    self.all_sources = nil
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
    self:close_drawer()
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
        if self.input_form and self.input_form.capture and self.input_form.focused then
            self.input_form.redraw_on_blur = true
        else
            self:refresh()
        end
    end)
end

local function refresh_shelf(home)
    home.shelf_requested = true
    home:request_catalog("library", {}, function(data)
        home.catalog_message = "已刷新 " .. data.count .. " 部漫画"
    end)
end

function Catalog:fetch_sources()
    local b = self.browse
    b.requested = true
    self:request_catalog("sources", {language = "all"}, function(data)
        self.all_sources = data.sources
        b.sources_page = 1
    end)
end

local function fetch_page(home, mode, search, size, target, reset)
    local b = home.browse
    home:request_catalog("source_seek", {source = b.source, mode = mode, size = size,
        search = search, counts = not reset and b.counts or {}, ended = not reset and b.ended,
        target = target}, function(data)
        b.mode, b.search, b.page, b.slice = mode, search, data.remote, data.slice
        b.results, b.counts, b.ended = data.results, data.counts, data.ended
    end)
end

local function start_source(home, source)
    local b = home.browse
    b.source, b.results, b.counts, b.ended = source, nil, {}, false
    b.mode, b.page, b.slice, b.search, b.query = "POPULAR", 1, 1, nil, ""
    fetch_page(home, "POPULAR", nil, home.catalog_size, 1, true)
end

function Catalog:catalog_actions()
    if self.selected_tab == "settings" or self.settings.connection.server_url == "" then return end
    if self.pending then
        return {{icon = "close", "取消请求", function()
            self:cancel_catalog()
            self.shelf_requested, self.browse.requested = true, true
            self.catalog_message = "请求已取消"
            self:refresh()
        end}}
    end
    if self.detail then
        if self.selected_tab == "browse" and not self.detail.in_library then
            return {{icon = "library", "加入书架", function()
                local item = self.detail
                self:request_catalog("add", item, function(data)
                    item.in_library = true
                    self.catalog_message = data.warning or "已加入书架"
                end)
            end}}
        end
        return
    end
    if self.selected_tab == "library" then
        return {{icon = "refresh", "从服务器刷新", function() refresh_shelf(self) end}}
    end
    local b = self.browse
    if not b.source then return {{icon = "refresh", "刷新漫画源", function() self:fetch_sources() end}} end
    local actions = {{icon = "refresh", "刷新结果", function() fetch_page(self, b.mode, b.search, self.catalog_size, 1, true) end},
        {icon = "popular", "热门", function() fetch_page(self, "POPULAR", nil, self.catalog_size, 1, true) end}}
    if b.source.latest then
        actions[#actions+1] = {icon = "latest", "最新", function() fetch_page(self, "LATEST", nil, self.catalog_size, 1, true) end}
    end
    return actions
end

-- The same inline field searches installed sources or the selected source.
local function search_bar(home, column, width, source, submit)
    local b = home.browse
    local key = source and "query" or "source_query"
    local button_w, gap = scale(58), scale(6)
    local padding, border = scale(6), scale(1)
    local field
    local function apply()
        local text = require("suwayomi_kindle/config").trim(field:getText():gsub("[\r\n]", ""))
        home:finish_field()
        submit(text)
    end
    field = InputText:new{parent = home, focused = false, width = width - button_w - gap - 2*(padding+border),
        height = scale(24), padding = padding, margin = 0, bordersize = border, scroll = true,
        text = b[key] or "", hint = source and "在这个源中搜索漫画" or "查找漫画源",
        face = Font:getFace("smallinfofont", 16), enter_callback = apply}
    home:bind_keyboard_close(field)
    home.input_form = {fields = {}, capture = function() b[key] = field:getText() end}
    column[#column+1] = Row:new{field, Gap:new{width = gap},
        Button.new{text = "搜索", compact = true, width = button_w, show_parent = home, callback = apply}}
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
    local ids, missing = {}, false
    for _, item in ipairs(items) do
        ids[#ids + 1] = item.id
        if not Covers.path(home.settings.connection, item) then missing = true end
    end
    local key = table.concat(ids, ",")
    if home.pending or home.poster_key == key then return end
    if home.poster_job then home.poster_job:cancel() end
    home.poster_key, home.poster_job = key, nil
    if not missing then return end
    defer(home, function()
        if home.poster_key ~= key then return end
        home.poster_job = Worker.start(UI, home.settings.connection, "covers", items, function(data)
            if not home.alive or home.poster_key ~= key then return end
            home.poster_job = nil
            if data and data.changed and not (home.input_form and home.input_form.focused) then home:refresh() end
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
        local chapters = item.chapters and (item.chapters .. " 章") or "章节数待刷新"
        if item.unread then chapters = chapters .. " · " .. item.unread .. " 未读" end
        if grid then
            if i % 3 == 1 then tiles = Row:new{}; column[#column + 1] = tiles end
            tiles[#tiles + 1] = Tile:new{width = math.floor(width / 3), title = item.title, subtitle = chapters,
                path = Covers.path(home.settings.connection, item), callback = open}
        else
            local path = Covers.path(home.settings.connection, item)
            local poster = path and Image:new{file = path, width = scale(40), height = scale(56)}
                or Icons.widget("library", scale(28))
            column[#column + 1] = SettingRow:new{label = item.title, value = chapters .. "  " .. (item.author ~= "" and item.author or item.source),
                leading = poster, width = width, callback = open}
        end
    end
    load_posters(home, items)
end

local function library(home, column, width, size, grid)
    home.index = home.index or Index.new(home.settings.connection)
    local data, err = home.index:page(home.shelf_page, size)
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
    note(column, width, data.count .. " 部漫画")
    manga_list(home, column, width, data.items, grid)
    home.pagination = {page = data.page, total = pages, go = function(n)
        home.shelf_page = n
        home:refresh()
    end}
end

local function sources(home, column, width, size)
    local b = home.browse
    search_bar(home, column, width, false, function(query)
        b.filter, b.sources_page = query:lower(), 1
        home:refresh()
    end)
    if not b.requested and not home.all_sources then
        b.requested = true
        defer(home, function() home:fetch_sources() end)
    end
    if not home.all_sources then return end
    local items = {}
    local selected = Languages.set(home.settings.browse.language)
    for _, source in ipairs(home.all_sources) do
        if (selected.all or selected[Languages.base(source.lang)])
            and (source.name:lower():find(b.filter or "", 1, true)) then items[#items+1] = source end
    end
    if #items == 0 then note(column, width, "没有符合语言和搜索条件的漫画源。"); return end
    local visible, page, pages = slice(items, b.sources_page, size)
    home.pagination = {page = page, total = pages, go = function(n) b.sources_page = n; home:refresh() end}
    for _, source in ipairs(visible) do
        column[#column+1] = SettingRow:new{width = width, label = source.name, value = source.lang,
            callback = function() start_source(home, source) end}
    end
end

local function source_manga(home, column, width, size, grid)
    local b = home.browse
    search_bar(home, column, width, true, function(query)
        fetch_page(home, query ~= "" and "SEARCH" or "POPULAR", query ~= "" and query or nil, size, 1, true)
    end)
    if not b.results then return end
    local items, part, parts = slice(b.results.mangas, b.slice, size)
    b.slice = part
    local before = Pages.before(b.counts, b.page, size)
    local total = b.ended and Pages.before(b.counts, #b.counts+1, size) or nil
    home.pagination = {page = before+part, total = total, busy = home.pending ~= nil, go = function(n)
        if type(n) == "number" and n > before and n <= before+parts then
            b.slice = n-before
            home:refresh()
        else
            fetch_page(home, b.mode, b.search, size, n, false)
        end
    end}
    note(column, width, b.mode == "SEARCH" and ("搜索 · " .. b.search) or (b.mode == "LATEST" and "最新" or "热门"))
    if #items == 0 then note(column, width, "没有找到漫画。") end
    manga_list(home, column, width, items, grid)
end

local function detail(home, column, width)
    local item = home.detail
    note(column, width, item.title)
    if item.source and item.source ~= "" then note(column, width, "来源 · " .. item.source) end
    if item.author and item.author ~= "" then note(column, width, "作者 · " .. item.author) end
    note(column, width, item.chapters and ("共 " .. item.chapters .. " 章") or "章节数待刷新")
    if item.unread then note(column, width, "未读 " .. item.unread .. " 章") end
    if item.in_library then note(column, width, "已在书架") end
    note(column, width, item.description)
end

function Catalog:build_catalog(screen_width, height)
    local width = screen_width - scale(48)
    local column = Column:new{align = "left", Space:new{width = scale(12)}}
    local grid = self.settings[self.selected_tab].view_mode == "grid"
    local size = grid and 3 * math.max(1, math.floor((height - scale(100)) / scale(172)))
        or math.max(1, math.floor((height - scale(100)) / scale(66)))
    self.catalog_size = size
    note(column, width, self.pending and "正在从服务器获取数据…" or self.catalog_message)
    if self.settings.connection.server_url == "" then
        note(column, width, "先设置 Suwayomi 服务器地址。")
        buttons(self, column, width, {{"前往连接设置", function()
            self:set_tab("settings")
            self:open_connection_settings()
        end}})
    elseif self.detail then detail(self, column, width)
    elseif self.selected_tab == "library" then library(self, column, width, size, grid)
    elseif self.browse.source then source_manga(self, column, width, size, grid)
    else sources(self, column, width, math.max(1, math.floor((height - scale(100)) / scale(66)))) end
    local viewport = Scroll:new{dimen = Geom:new{w = width + Scroll:getScrollbarWidth(), h = height},
        show_parent = self, column}
    if self.input_form then
        self.input_form.viewport, self.input_form.height = viewport, height
    end
    self.cropping_widget = viewport
    return Frame:new{width = screen_width, height = height, padding = 0, bordersize = 0,
        padding_left = scale(24), viewport}
end

return Catalog
