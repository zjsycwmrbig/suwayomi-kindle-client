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
local BrowseSources = require("suwayomi_kindle/browse_sources")
local InputText = require("ui/widget/inputtext")
local Image = require("ui/widget/imagewidget")
local Icons = require("suwayomi_kindle/ui/icons")
local Paragraph = require("ui/widget/textboxwidget")
local Button = require("suwayomi_kindle/ui/flat_button")
local SourceControl = require("suwayomi_kindle/ui/source_control")
local SettingRow = require("suwayomi_kindle/ui/setting_row")
local Progress = require("suwayomi_kindle/ui/reading_progress")
local MangaStatus = require("suwayomi_kindle/manga_status")
local Tile = require("suwayomi_kindle/ui/manga_tile")
local Worker = require("suwayomi_kindle/worker")
local Index = require("suwayomi_kindle/library_index")
local Covers = require("suwayomi_kindle/covers")

local Catalog = {}
local function scale(n) return Screen:scaleBySize(n) end

function Catalog:reset_browse()
    self.browse = {sources_page = 1, mode = "POPULAR", page = 1, slice = 1, auto_open = true}
end

function Catalog:cancel_catalog()
    self:cancel_recommendations()
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
    self.all_sources, self.pinned, self.source_history, self.directory = nil, nil, nil, nil
    self.detail, self.catalog_message, self.shelf_requested = nil, nil, nil
    self.detail_stack, self.recommendation_view = nil, nil
    self.shelf_page, self.index, self.shelf_search = 1, nil, nil
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
        local previous = self.detail_stack and table.remove(self.detail_stack)
        self.detail = previous and previous.item or nil
        self.recommendation_view = previous and previous.view or nil
    else
        self.browse.source, self.browse.results = nil, nil
        self.browse.auto_open = false
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
        if home.anilist_sync ~= true then
            home.anilist_sync = true
            Worker.start(UI, home.settings.connection, "anilist_snapshots", {complete=data.count <= 500}, function()
                home.anilist_sync = nil
            end)
        end
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

local function fetch_page(home, mode, search, size, target, reset, by_item, recommended_item)
    local b = home.browse
    home:request_catalog("source_seek", {source = b.source, mode = mode, size = size,
        search = search, counts = not reset and b.counts or {}, ended = not reset and b.ended,
        target = target, by_item = by_item, recommended_item = recommended_item,
        search_languages = recommended_item and home.settings.recommendation.search_languages}, function(data)
        if data.search and b.query == search then b.query = data.search end
        search = data.search or search
        b.mode, b.search, b.page, b.slice = mode, search, data.remote, data.slice
        b.results, b.counts, b.ended = data.results, data.counts, data.ended
    end)
end

local function start_source(home, source, manual)
    local b = home.browse
    b.auto_open = false
    local err
    if manual then
        local saved
        saved, err = home:local_index():markSourceOpened(source.id)
        if saved then home.source_history = nil end
    end
    b.source, b.results, b.counts, b.ended = source, nil, {}, false
    local item = b.recommended_item
    b.recommended_item = nil
    local settings = home.settings.recommendation
    local query = item and require("suwayomi_kindle/recommendations").preferredTitle(item,settings.search_languages)
    b.mode, b.page, b.slice, b.search, b.query = query and "SEARCH" or "POPULAR", 1, 1, query, query or ""
    home:refresh()
    fetch_page(home, b.mode, query, home.catalog_size, 1, true, nil, item)
    if err then UI:show(require("ui/widget/infomessage"):new{text=err,timeout=3}) end
end

function Catalog:search_recommended(item)
    self:cancel_catalog()
    self:close_drawer()
    self.detail, self.directory, self.reader_origin = nil, nil, nil
    self.detail_stack, self.recommendation_view = nil, nil
    self.catalog_message = nil
    self:reset_browse()
    self.browse.recommended_item = item
    if self.selected_tab == "browse" then self:refresh() else self:set_tab("browse") end
end

local shelf_sorts = {
    {"opened","最近打开"},{"added","添加时间"},{"title","书名"},{"unread","未读数"},{"chapters","章节数"},
}

local function pin_source(home, id, pinned)
    local ok, err = home:local_index():setPinned(id, pinned)
    if ok then home.pinned = nil else home.catalog_message = err end
    home:refresh()
end

local function shelf_actions(home,refresh)
    return {refresh,{icon="search",home.shelf_search and "退出书架搜索" or "搜索书架",function()
        if home.shelf_search then home.shelf_search=nil else home.shelf_search={} end
        home.shelf_page=1
        home:refresh()
    end},{"排序",children=function()
        local items={}
        for _,sort in ipairs(shelf_sorts) do
            items[#items+1]={sort[2],icon=home.settings.library.sort==sort[1] and "check" or nil,function()
                local saved,err=home.settings_store:update("library",{sort=sort[1]})
                if saved then home.settings.library,home.shelf_page=saved,1 else home.catalog_message=err end
                home:refresh()
            end}
        end
        return items
    end}}
end

function Catalog:catalog_actions()
    if self.selected_tab == "settings" or self.settings.connection.server_url == "" then return end
    if self.selected_tab == "tasks" then return self:task_actions() end
    local source = not self.detail and self.selected_tab == "browse" and self.browse.source
    local pin
    if source then
        local pinned = self:source_pins()[source.id]
        pin = {icon="library",pinned and "取消置顶" or "置顶此源",function()
            pin_source(self, source.id, not pinned)
        end}
    end
    if self.pending then
        local cancel = {icon = "close", "取消请求", function()
            self:cancel_catalog()
            self.shelf_requested, self.browse.requested = true, true
            self.catalog_message = "请求已取消"
            self:refresh()
        end}
        if self.pending=="library" then return shelf_actions(self,cancel) end
        return {cancel,pin}
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
        local actions={{icon="refresh","刷新详情",function() self:refresh_detail() end}}
        if self.settings.recommendation.enabled then
            actions[#actions+1]={icon="search","查找相似漫画",function()
                local view=self:recommendation_state()
                if view then self:find_recommendations(view) end
            end}
        end
        return actions
    end
    if self.selected_tab == "library" then
        return shelf_actions(self,{icon="refresh","从服务器刷新",function() refresh_shelf(self) end})
    end
    local b = self.browse
    if not b.source then return {{icon = "refresh", "刷新漫画源", function() self:fetch_sources() end}} end
    return {pin,{icon = "browse", "切换漫画源", function() self:catalog_back() end},
        {icon = "refresh", "刷新结果", function() fetch_page(self, b.mode, b.search, self.catalog_size, 1, true) end}}

end

function Catalog:local_index()
    self.index = self.index or Index.new(self.settings.connection)
    return self.index
end

function Catalog:source_pins()
    if not self.pinned then self.pinned = self:local_index():pins() or {} end
    return self.pinned
end

function Catalog:source_history_data()
    if not self.source_history then self.source_history = self:local_index():sourceHistory() or {opened={}} end
    return self.source_history
end

-- The same inline field searches installed sources or the selected source.
local function search_bar(home, column, width, source, submit, shelf)
    local b = shelf or home.browse
    local key = (shelf or source) and "query" or "source_query"
    local initial_query = b[key] or ""
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
        text = initial_query, hint = shelf and "搜索书名或作者" or source and "在这个源中搜索漫画" or "查找漫画源",
        face = Font:getFace("smallinfofont", 16), enter_callback = apply}
    home:bind_keyboard_close(field)
    home.input_form = {fields = {}, capture = function()
        local text = field:getText()
        if text ~= initial_query then b[key] = text end
    end}
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

local function restore_browse_source(home)
    local b = home.browse
    if not b.auto_open or not home.all_sources or home.pending then return end
    b.auto_open = false
    local source = BrowseSources.landing(home.all_sources, home.settings.browse.language, home:source_history_data(),
        home:source_pins())
    if not source and b.recommended_item then
        source = BrowseSources.list(home.all_sources, home.settings.browse.language, nil, "opened",
            home:source_pins(), home:source_history_data().opened)[1]
    end
    if source and (not b.source or b.source.id ~= source.id or not b.results) then
        defer(home, function()
            if home.browse == b and home.selected_tab == "browse" then start_source(home, source, false) end
        end)
    end
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
            if data and data.changed and not (home.input_form and home.input_form.focused) then
                home:refresh()
            end
        end)
    end)
end

local function manga_list(home, column, width, items, grid, poster_height)
    local tiles
    for i, item in ipairs(items) do
        local function open()
            home:open_detail(item)
        end
        local continue = home.selected_tab=="library" and function()
            home:local_index():markOpened(item.id)
            home.detail=item
            home:open_directory(true)
        end or nil
        local chapters = item.chapters and (item.chapters .. " 章") or "章节数待刷新"
        local status = MangaStatus.label(item.status)
        local shelf = home.selected_tab == "library"
        if not shelf and item.unread then chapters = chapters .. " · " .. item.unread .. " 未读" end
        if grid then
            if i % 3 == 1 then tiles = Row:new{}; column[#column + 1] = tiles end
            local subtitle, badge, short_badge = chapters
            if shelf then
                subtitle = item.author and item.author:match("%S") and item.author or "作者未知"
                badge, short_badge = require("suwayomi_kindle/progress").badge(item.chapters, item.unread)
            elseif item.author and item.author:match("%S") then
                subtitle = item.author
            end
            tiles[#tiles + 1] = Tile:new{width = math.floor(width / 3), title = item.title, subtitle = subtitle,
                badge = badge, short_badge = short_badge, status_badge = status,
                poster_height = poster_height, path = Covers.path(home.settings.connection, item), callback = open, hold_callback = continue}
        else
            local path = Covers.path(home.settings.connection, item)
            local poster = path and Image:new{original_in_nightmode = true, file = path,
                width = scale(46), height = scale(65)}
                or Icons.widget("library", scale(28))
            local credits = {}
            for _,key in ipairs(shelf and {"author","source"} or {"author"}) do
                if item[key] and item[key] ~= "" then credits[#credits+1] = item[key] end
            end
            if shelf then chapters = chapters .. " · " .. (item.downloaded or 0) .. " 已下载" end
            if not shelf and item.in_library then chapters = chapters .. " · 已入书架" end
            column[#column + 1] = SettingRow:new{label = item.title, value = status .. " · " .. chapters,
                detail_line = #credits > 0 and table.concat(credits," · ") or nil,
                leading = poster, trailing=shelf and Progress.new(item.chapters,item.unread) or nil, hide_chevron=shelf, width = width, inset=4, leading_width=56, callback = open, hold_callback=continue,
                row_height=72}
        end
    end
    load_posters(home, items)
end

local function library(home, column, width, size, grid, poster_height)
    home.index = home.index or Index.new(home.settings.connection)
    local search=home.shelf_search
    if search then
        search_bar(home,column,width,false,function(query)
            search.filter,home.shelf_page=query,1
            home:refresh()
        end,search)
    end
    local data, err = home.index:page(home.shelf_page, size, home.settings.library.sort, search and search.filter)
    if not data then note(column, width, err); return end
    home.shelf_page = data.page
    if data.synced == 0 and not home.shelf_requested then
        home.shelf_requested = true
        defer(home, refresh_shelf)
    end
    if data.count == 0 then
        note(column, width, search and search.filter and search.filter~="" and "没有匹配的漫画。" or data.synced == 0 and "还没有本地书架记录。" or "服务器书架为空。")
        return
    end
    local pages = math.ceil(data.count / size)
    note(column, width, data.count .. " 部漫画")
    manga_list(home, column, width, data.items, grid, poster_height)
    home.pagination = {page = data.page, total = pages, page_size = size, item_count = data.count, go = function(n)
        home.shelf_page = n
        home:refresh()
    end}
end

local function sources(home, column, width, size)
    local b = home.browse
    if b.recommended_item then note(column, width, "搜索漫画 · " .. b.recommended_item.title) end
    search_bar(home, column, width, false, function(query)
        b.filter, b.sources_page = query:lower(), 1
        home:refresh()
    end)
    if not b.requested and not home.all_sources then
        b.requested = true
        defer(home, function() home:fetch_sources() end)
    end
    if not home.all_sources then return end
    local pinned, history = home:source_pins(), home:source_history_data()
    local all = BrowseSources.list(home.all_sources, home.settings.browse.language, nil,
        home.settings.browse.sort, pinned, history.opened)
    local items, positions, pin_count, priority = {}, {}, 0, 0
    for _, source in ipairs(all) do
        if pinned[source.id] then
            priority=priority+1
            positions[source.id], pin_count = priority, priority
        end
        if source.name:lower():find(b.filter or "", 1, true) then items[#items+1] = source end
    end
    if #items == 0 then note(column, width, "没有符合语言和搜索条件的漫画源。"); return end
    local visible, page, pages = slice(items, b.sources_page, size)
    b.sources_page = page
    home.pagination = {page = page, total = pages, page_size = size, item_count = #items,
        go = function(n) b.sources_page = n; home:refresh() end}
    for _, source in ipairs(visible) do
        local tags = {Languages.label(Languages.base(source.lang))}
        local rank = positions[source.id]
        if rank then tags[#tags+1] = rank == 1 and "默认源" or ("优先级 " .. rank) end
        local button_width = scale(42)
        local function move(direction)
            return function()
                local ok, err = home:local_index():moveSource(source.id, direction)
                if ok then home.pinned = nil else home.catalog_message = err end
                home:refresh()
            end
        end
        local line = Row:new{SettingRow:new{width = width - 3*button_width, hide_chevron = true, inset = 4,
            label = source.name, value = table.concat(tags," · "), callback = function() start_source(home, source, true) end}}
        local function control(icon, label, enabled, fn)
            line[#line+1]=SourceControl:new{icon=icon,label=label,callback=fn,enabled=not not enabled}
        end
        control(rank and "pin_active" or "pin",rank and "取消置顶" or "置顶",true,
            function() pin_source(home, source.id, not rank) end)
        control("move_up","上调",rank and rank>1,rank and rank>1 and move("up") or nil)
        control("move_down","下调",rank and rank<pin_count,rank and rank<pin_count and move("down") or nil)
        column[#column+1] = line
    end
end

local function source_controls(home, column, width)
    local b = home.browse
    buttons(home,column,width,{
        {"热门",function() fetch_page(home,"POPULAR",nil,home.catalog_size,1,true) end,b.mode=="POPULAR"},
        {"最新",b.source.latest and function() fetch_page(home,"LATEST",nil,home.catalog_size,1,true) end or nil,b.mode=="LATEST"},
    })
    search_bar(home, column, width, true, function(query)
        fetch_page(home, query ~= "" and "SEARCH" or "POPULAR", query ~= "" and query or nil, home.catalog_size, 1, true)
    end)
end

local function source_manga(home, column, width, size, grid, poster_height)
    local b = home.browse
    if not b.results then return end
    local items, part, parts = slice(b.results.mangas, b.slice, size)
    b.slice = part
    local before = Pages.before(b.counts, b.page, size)
    local total = b.ended and Pages.before(b.counts, #b.counts+1, size) or nil
    local item_before = Pages.itemsBefore(b.counts, b.page)
    local item_count = b.ended and Pages.itemsBefore(b.counts, #b.counts+1) or nil
    local function go_item(n)
        if n > item_before and n <= item_before + #b.results.mangas then
            b.slice = math.ceil((n - item_before) / size)
            home:refresh()
        else
            fetch_page(home, b.mode, b.search, size, n, false, true)
        end
    end
    home.pagination = {page = before+part, total = total, busy = home.pending ~= nil,
        item_count = item_count, go_item = item_count ~= 0 and go_item or nil, go = function(n)
        if type(n) == "number" and n > before and n <= before+parts then
            b.slice = n-before
            home:refresh()
        else
            fetch_page(home, b.mode, b.search, size, n, false)
        end
    end}
    if #items == 0 then note(column, width, "没有找到漫画。") end
    manga_list(home, column, width, items, grid, poster_height)
end

local function grid_layout(width, available, captions)
    local ideal = math.floor((width / 3 - scale(10)) / 0.71)
    captions = scale(captions or 54)
    local rows = math.max(1, math.floor(available / (ideal + captions) + 0.5))
    return rows * 3, math.max(1, math.min(ideal, math.floor(available / rows) - captions))
end

function Catalog:build_catalog(screen_width, height, detail_scroll)
    local browsing = self.selected_tab == "browse" and not self.detail
    local browsing_results = browsing and self.browse.source
    local inset = scale(browsing_results and 12 or 24)
    local width = screen_width - inset * 2
    local column = Column:new{align = "left", Space:new{width = scale(browsing_results and 6 or 12)}}
    local recommendations, detail_item
    local recommendation_inset = scale(6)
    if not self.directory then
        local loading = self.pending and not (browsing_results and self.browse.results)
        note(column, width, loading and "正在从服务器获取数据…" or self.catalog_message)
    end
    local grid = self.settings[self.selected_tab].view_mode == "grid"
    local size, poster_height = math.max(1, math.floor((height - scale(56)) / scale(66)))
    if browsing_results then
        source_controls(self, column, width)
        local used = 0
        for _, widget in ipairs(column) do used = used + widget:getSize().h end
        local available = height - used
        if grid then size, poster_height = grid_layout(width, available, 68)
        else size = math.max(1, math.floor(available / scale(72))) end
    elseif self.selected_tab == "library" and not self.detail then
        local available = height - scale((self.pending or self.catalog_message) and 76 or 46)
        if self.shelf_search then available=available-scale(44) end
        if grid then
            size, poster_height = grid_layout(width, available)
        else
            size = math.max(1,math.floor(available / scale(72)))
        end
    end
    self.catalog_size = size
    if self.settings.connection.server_url == "" then
        note(column, width, "先设置 Suwayomi 服务器地址。")
        buttons(self, column, width, {{"前往连接设置", function()
            self:set_tab("settings")
            self:open_connection_settings()
        end}})
    elseif self.directory then self:build_directory(column,width,height)
    elseif self.detail then
        detail_item = self.detail
        self:build_detail(column,width)
        local posters = {detail_item}
        recommendations = self:build_recommendations(screen_width - 2 * recommendation_inset,height,posters)
        load_posters(self,posters)
    elseif self.selected_tab == "library" then library(self, column, width, size, grid, poster_height)
    else
        restore_browse_source(self)
        if browsing_results then source_manga(self, column, width, size, grid, poster_height)
        else sources(self, column, width, size) end
    end
    local scroll_height = height - (recommendations and recommendations:getSize().h or 0)
    local viewport = Scroll:new{dimen = Geom:new{w = width + Scroll:getScrollbarWidth(), h = scroll_height},
        show_parent = self, detail_item = detail_item, column}
    if self.input_form then
        self.input_form.viewport, self.input_form.height = viewport, height
    end
    self.cropping_widget = viewport
    if detail_item and detail_scroll and detail_scroll > 0 then
        viewport:initState()
        if viewport._is_scrollable then viewport:_scrollBy(0, detail_scroll) end
    end
    local function in_frame(widget, left, frame_height)
        return Frame:new{width = screen_width, height = frame_height, padding = 0, bordersize = 0,
            padding_left = left, widget}
    end
    local scroll_frame = in_frame(viewport, inset, scroll_height)
    if recommendations then
        return Column:new{align="left", scroll_frame,
            in_frame(recommendations, recommendation_inset, height - scroll_height)}
    end
    return scroll_frame
end

return Catalog
