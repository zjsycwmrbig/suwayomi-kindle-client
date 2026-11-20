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
    self.all_sources, self.pinned, self.directory = nil, nil, nil
    self.detail, self.catalog_message, self.shelf_requested = nil, nil, nil
    self.shelf_page, self.index = 1, nil
    self.task_page,self.task_view,self.task_message=1,"queue",nil
    self.task_filter,self.task_file_scope,self.task_folder="all","managed",nil
    self.task_selection,self.task_editing={},false
end

function Catalog:set_saved_connection(saved)
    local old = self.settings.connection
    if old.server_url ~= saved.server_url or old.auth_method ~= saved.auth_method
        or old.username ~= saved.username or old.password ~= saved.password then self:reset_catalog() end
    self.settings.connection = saved
end

function Catalog:catalog_back()
    if self.reader_origin and self.directory then self:close(); return end
    self:close_drawer()
    self:cancel_catalog()
    self.catalog_message = nil
    if self.directory then
        self.directory = nil
    elseif self.detail then
        self.detail = nil
    else
        self.browse.source, self.browse.results = nil, nil
    end
    self:refresh()
end

function Catalog:request_catalog(action, input, done, failed)
    self:cancel_catalog()
    local generation = self.generation
    self.catalog_message, self.pending = nil, action
    self:refresh()
    self.job = Worker.start(UI, self.settings.connection, action, input, function(data, err)
        if not self.alive or generation ~= self.generation then return end
        self.pending, self.job = nil, nil
        self.catalog_message = err
        if data then done(data) elseif failed then failed(err) end
        if err and self.directory then UI:show(require("ui/widget/infomessage"):new{text=err,timeout=3}) end
        if not self.alive then return end
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
    home:refresh()
    fetch_page(home, "POPULAR", nil, home.catalog_size, 1, true)
end

function Catalog:catalog_actions()
    if self.selected_tab == "settings" or self.settings.connection.server_url == "" then return end
    if self.selected_tab == "tasks" then return self:task_actions() end
    local source = not self.detail and self.selected_tab == "browse" and self.browse.source
    local pin
    if source then
        local pinned = self:source_pins()[source.id] == true
        pin = {icon="library",pinned and "取消置顶" or "置顶此源",function()
            local ok,err = self:local_index():setPinned(source.id,not pinned)
            if ok then self.pinned = nil else self.catalog_message = err end
            self:refresh()
        end}
    end
    if self.pending then
        return {{icon = "close", "取消请求", function()
            self:cancel_catalog()
            self.shelf_requested, self.browse.requested = true, true
            self.catalog_message = "请求已取消"
            self:refresh()
        end},pin}
    end
    if self.directory then
        local actions = {{icon="refresh","刷新章节",function() self:refresh_directory(true) end},
            {icon="popular",self.directory.unread_only and "显示全部章节" or "只看未读章节",function()
                self.directory.unread_only = not self.directory.unread_only
                self.directory.page,self.directory.target = 1,nil
                self:refresh()
            end},
            {icon="latest","定位首个未读",function() self:locate_unread(false); self:refresh() end}}
        self:add_download_actions(actions)
        return actions
    elseif self.detail then
        return {{icon="refresh","刷新详情",function() self:refresh_detail() end}}
    end
    if self.selected_tab == "library" then
        return {{icon = "refresh", "从服务器刷新", function() refresh_shelf(self) end}}
    end
    local b = self.browse
    if not b.source then return {{icon = "refresh", "刷新漫画源", function() self:fetch_sources() end}} end
    return {pin,{icon = "refresh", "刷新结果", function() fetch_page(self, b.mode, b.search, self.catalog_size, 1, true) end}}

end

function Catalog:local_index()
    self.index = self.index or Index.new(self.settings.connection)
    return self.index
end

function Catalog:source_pins()
    if not self.pinned then self.pinned = self:local_index():pins() or {} end
    return self.pinned
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
            home:open_detail(item)
        end
        local chapters = item.chapters and (item.chapters .. " 章") or "章节数待刷新"
        if item.unread then chapters = chapters .. " · " .. item.unread .. " 未读" end
        if grid then
            if i % 3 == 1 then tiles = Row:new{}; column[#column + 1] = tiles end
            tiles[#tiles + 1] = Tile:new{width = math.floor(width / 3), title = item.title, subtitle = chapters,
                poster_height = home.shelf_poster_height, path = Covers.path(home.settings.connection, item), callback = open}
        else
            local path = Covers.path(home.settings.connection, item)
            local shelf = home.selected_tab == "library"
            local poster = path and Image:new{original_in_nightmode = true, file = path,
                width = scale(shelf and 46 or 40), height = scale(shelf and 65 or 56)}
                or Icons.widget("library", scale(28))
            local credits = {}
            for _,key in ipairs({"author","source"}) do
                if item[key] and item[key] ~= "" then credits[#credits+1] = item[key] end
            end
            if shelf then chapters = chapters .. " · " .. (item.downloaded or 0) .. " 已下载" end
            column[#column + 1] = SettingRow:new{label = item.title, value = chapters,
                detail_line = #credits > 0 and table.concat(credits," · ") or nil,
                leading = poster, width = width, inset=4, leading_width=56, callback = open,
                row_height=shelf and 72 or 66}
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
    local pinned, regular = home:source_pins(), {}
    local selected = Languages.set(home.settings.browse.language)
    for _, source in ipairs(home.all_sources) do
        if (selected.all or selected[Languages.base(source.lang)])
            and (source.name:lower():find(b.filter or "", 1, true)) then
            local group = pinned[source.id] and items or regular
            group[#group+1] = source
        end
    end
    for _,source in ipairs(regular) do items[#items+1] = source end
    if #items == 0 then note(column, width, "没有符合语言和搜索条件的漫画源。"); return end
    local visible, page, pages = slice(items, b.sources_page, size)
    home.pagination = {page = page, total = pages, go = function(n) b.sources_page = n; home:refresh() end}
    for _, source in ipairs(visible) do
        column[#column+1] = SettingRow:new{width = width, label = source.name, value = (pinned[source.id] and "已置顶 · " or "") .. source.lang,
            callback = function() start_source(home, source) end}
    end
end

local function source_manga(home, column, width, size, grid)
    local b = home.browse
    buttons(home,column,width,{
        {"热门",function() fetch_page(home,"POPULAR",nil,size,1,true) end,b.mode=="POPULAR"},
        {"最新",b.source.latest and function() fetch_page(home,"LATEST",nil,size,1,true) end or nil,b.mode=="LATEST"},
    })
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
    if b.mode == "SEARCH" then note(column,width,"搜索 · " .. b.search) end
    if #items == 0 then note(column, width, "没有找到漫画。") end
    manga_list(home, column, width, items, grid)
end

function Catalog:build_catalog(screen_width, height)
    local width = screen_width - scale(48)
    local column = Column:new{align = "left", Space:new{width = scale(12)}}
    local grid = self.settings[self.selected_tab].view_mode == "grid"
    local size = grid and 3 * math.max(1, math.floor((height - scale(100)) / scale(172)))
        or math.max(1, math.floor((height - scale(100)) / scale(66)))
    if self.browse.source and self.selected_tab == "browse" and not self.detail then
        size = grid and 3 * math.max(1,math.floor((height-scale(132))/scale(172)))
            or math.max(1,math.floor((height-scale(132))/scale(66)))
    end
    self.shelf_poster_height = nil
    if self.selected_tab == "library" and not self.detail then
        local available = height - scale((self.pending or self.catalog_message) and 76 or 46)
        if grid then
            local ideal = math.floor((width / 3 - scale(10)) / 0.71)
            local captions = scale(54)
            local rows = math.max(1, math.floor(available / (ideal + captions) + 0.5))
            self.shelf_poster_height = math.max(1,math.min(ideal,math.floor(available / rows) - captions))
            size = rows * 3
        else
            size = math.max(1,math.floor(available / scale(72)))
        end
    end
    self.catalog_size = size
    if not self.directory then note(column, width, self.pending and "正在从服务器获取数据…" or self.catalog_message) end
    if self.settings.connection.server_url == "" then
        note(column, width, "先设置 Suwayomi 服务器地址。")
        buttons(self, column, width, {{"前往连接设置", function()
            self:set_tab("settings")
            self:open_connection_settings()
        end}})
    elseif self.directory then self:build_directory(column,width,height)
    elseif self.detail then
        self:build_detail(column,width)
        load_posters(self,{self.detail})
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
