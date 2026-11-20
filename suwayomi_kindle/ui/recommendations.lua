local UI = require("ui/uimanager")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Row = require("ui/widget/horizontalgroup")
local Gap = require("ui/widget/horizontalspan")
local Button = require("ui/widget/button")
local Screen = require("device").screen
local Tile = require("suwayomi_kindle/ui/manga_tile")
local Covers = require("suwayomi_kindle/covers")
local Worker = require("suwayomi_kindle/worker")
local Sources = require("suwayomi_kindle/browse_sources")
local Recommendations = require("suwayomi_kindle/recommendations")

local page_size = 4
local cache_seconds = 24 * 60 * 60
local View = {}

local function note(column, width, text, size)
    column[#column+1] = Text:new{text=text, width=width, face=Font:getFace("smallinfofont",size or 15)}
end

local function fresh(timestamp)
    local age = os.time() - (tonumber(timestamp) or 0)
    return age >= 0 and age < cache_seconds
end

local function update_results(view)
    local count = view.snapshot and #view.snapshot.items or 0
    view.page = math.max(1, math.min(view.page, math.ceil(count / page_size)))
    view.results = Recommendations.pageResults(view.snapshot, view.manga, view.page, page_size)
end

function View:recommendation_state()
    local manga = self.detail and self.detail.id
    if not manga or not self.settings.recommendation.enabled then return end
    if not self.recommendation_view or self.recommendation_view.manga ~= manga then
        local data, err = self:local_index():recommendationData(manga)
        local view = {manga=manga, snapshot=data and data.snapshot and data.snapshot.version == 2 and data.snapshot or nil, page=1, error=err}
        update_results(view)
        self.recommendation_view = view
    end
    return self.recommendation_view
end

function View:cancel_recommendations()
    local view = self.recommendation_view
    if not view or not view.jobs then return end
    local jobs = view.jobs
    view.jobs, view.busy = nil, nil
    for _, job in pairs(jobs) do if job then job:cancel() end end
end

function View:find_recommendations(view, page)
    if view.jobs or (not page and self.pending) then return end
    local jobs, index = {}, self:local_index()
    view.jobs, view.error, view.page = jobs, nil, page or 1
    update_results(view)
    local config = self.settings.recommendation
    local limit = math.max(1, math.min(50, math.floor(config.limit)))

    local function refresh()
        self.recommendation_scroll = true
        self:refresh()
    end
    local function save()
        local ok, err = index:saveRecommendations(view.manga, view.snapshot)
        if not ok then view.error = err end
    end
    local function run(key, action, input, done)
        local job = Worker.start(UI, self.settings.connection, action, input, function(data, err)
            if not self.alive or self.recommendation_view ~= view or view.jobs ~= jobs then return end
            jobs[key] = nil
            done(data, err)
        end)
        jobs[key] = job
    end
    local function finish(err)
        view.jobs, view.busy = nil, nil
        view.error = err or view.error
        refresh()
    end
    local function match(all)
        local snapshot = view.snapshot
        local history = self:source_history_data()
        local sources = Sources.list(all, self.settings.browse.language, nil, "opened", self:source_pins(), history.opened)
        snapshot.source_order = {}
        for i=1, math.min(#sources, config.sources) do snapshot.source_order[i] = sources[i].id end
        update_results(view)
        save()
        if #snapshot.source_order == 0 then finish("当前语言下没有可搜索的漫画源。"); return end

        local first = (view.page - 1) * page_size + 1
        local last = math.min(first + page_size - 1, #snapshot.items)
        local page_count = last - first + 1
        local active, attempted, errors = {}, {}, {}
        local function advance()
            if view.jobs ~= jobs then return end
            local completed = 0
            for n = first, last do
                local item = snapshot.items[n]
                if not active[item.id] then
                    item.sources = item.sources or {}
                    local pending
                    for i, id in ipairs(snapshot.source_order) do
                        local cached = item.sources[id]
                        local tried = attempted[item.id] and attempted[item.id][id]
                        if not tried and (not cached or not cached.verified or cached.failed or not fresh(cached.checked_at)) then
                            pending = sources[i]
                            break
                        end
                        if cached and cached.verified and #cached.matches > 0 and not cached.failed then
                            errors[item.id] = nil
                            break
                        end
                    end
                    if not pending then
                        completed = completed + 1
                    else
                        local id = pending.id
                        active[item.id] = true
                        attempted[item.id] = attempted[item.id] or {}
                        attempted[item.id][id] = true
                        run(item.id, "recommendation_source", {source=pending,item={
                            id=item.id, titles=item.titles, synonyms=item.synonyms, translations=item.translations, origin=view.manga,
                        }}, function(found, err)
                            active[item.id] = nil
                            local previous = item.sources[id]
                            if found then
                                item.translations = found.translations or item.translations
                                found.translations = nil
                                found.checked_at, found.verified = os.time(), true
                                item.sources[id] = found
                            else
                                errors[item.id] = err or "漫画源搜索失败。"
                                item.sources[id] = {failed=true, verified=previous and previous.verified, matches=previous and previous.matches or {}}
                            end
                            update_results(view)
                            save()
                            UI:nextTick(advance)
                        end)
                    end
                end
            end
            if completed == page_count then
                local _, err = next(errors)
                finish(err)
                return
            end
            view.busy = string.format("正在匹配漫画源… %d/%d", completed, page_count)
            refresh()
        end
        advance()
    end
    local function resolve_sources()
        if #view.snapshot.items == 0 then save(); finish(); return end
        if self.all_sources then match(self.all_sources); return end
        view.busy = "正在获取漫画源…"
        refresh()
        run("sources", "sources", {language="all"}, function(data, err)
            if not data then finish(err); return end
            self.all_sources = data.sources
            match(data.sources)
        end)
    end
    local previous = view.snapshot
    if previous and previous.version == 2 and (page or (previous.limit == limit and fresh(previous.fetched_at))) then
        resolve_sources(); return
    end
    view.busy = "正在查询 AniList…"
    refresh()
    local media = self.detail.anilist_id or (previous and previous.version == 2 and previous.media) or nil
    run("ani", "anilist_recommend", {id=media, title=self.detail.title, limit=limit}, function(snapshot, err)
        if not snapshot then finish(err); return end
        if previous and previous.media == snapshot.media then
            local matches = {}
            for _, item in ipairs(previous.items) do matches[item.id] = item end
            for _, item in ipairs(snapshot.items) do
                local old = matches[item.id]
                if old then item.sources, item.translations = old.sources, old.translations end
            end
            snapshot.source_order = previous.source_order
        end
        view.snapshot = snapshot
        update_results(view)
        save()
        resolve_sources()
    end)
end

function View:open_recommended(view, candidate)
    self.detail_stack = self.detail_stack or {}
    self.detail_stack[#self.detail_stack+1] = {item=self.detail, view=view}
    self:cancel_recommendations()
    self.recommendation_view = nil
    self:open_detail(candidate)
end

function View:build_recommendations(column, width, posters)
    local view = self:recommendation_state()
    if not view or not (view.snapshot or view.busy or view.error) then return end
    local count = view.snapshot and #view.snapshot.items or 0
    note(column, width, count > 0 and ("相似漫画 · AniList · " .. count .. " 部候选") or "相似漫画 · AniList", 17)
    if view.busy then note(column, width, view.busy) end
    if view.error then note(column, width, view.error) end
    if count == 0 then
        if not view.busy and not view.error then note(column, width, "无推荐漫画。") end
        return
    end
    local total = self:recommendation_page_count(view)
    local function go(page)
        if page < 1 or page > total or page == view.page then return end
        self:cancel_recommendations()
        self:find_recommendations(view, page)
    end
    local arrow_width = math.min(Screen:scaleBySize(36), math.floor(width / 12))
    local icon_size = math.min(Screen:scaleBySize(20), arrow_width)
    local function arrow(icon, target)
        return Button:new{icon=icon, enabled=target >= 1 and target <= total, show_parent=self,
            width=arrow_width, icon_width=icon_size, icon_height=icon_size,
            margin=0, bordersize=0, padding=0, padding_v=Screen:scaleBySize(12),
            callback=function() go(target) end}
    end
    local tiles = Row:new{align="center", allow_mirroring=false, arrow("chevron.left", view.page - 1)}
    local cover_space = width - 2 * arrow_width
    local tile_width = math.floor(cover_space / page_size)
    for _, slot in ipairs(view.results) do
        local item, candidate = slot.item, slot.match
        local title, subtitle, path, open
        if candidate then
            posters[#posters+1] = candidate
            title = candidate.title
            subtitle = candidate.author and candidate.author ~= "" and candidate.author or candidate.source
            path = Covers.path(self.settings.connection, candidate)
            open = function() self:open_recommended(view, candidate) end
        else
            title = item.title
            subtitle = "去探索搜索"
            open = function() self:search_recommended(item) end
        end
        tiles[#tiles+1] = Tile:new{width=tile_width, title=title, subtitle=subtitle,
            poster_height=math.floor((tile_width - 6) / 0.71), path=path, callback=open}
    end
    local visible = #view.results
    tiles[#tiles+1] = Gap:new{width=cover_space - visible * tile_width}
    tiles[#tiles+1] = arrow("chevron.right", view.page + 1)
    column[#column+1] = tiles
end

function View:recommendation_page_count(view)
    return math.max(1, math.ceil((view.snapshot and #view.snapshot.items or 0) / page_size))
end

return View
