local UI = require("ui/uimanager")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Row = require("ui/widget/horizontalgroup")
local Tile = require("suwayomi_kindle/ui/manga_tile")
local Covers = require("suwayomi_kindle/covers")
local Worker = require("suwayomi_kindle/worker")
local Sources = require("suwayomi_kindle/browse_sources")
local Recommendations = require("suwayomi_kindle/recommendations")

local page_size = 3
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
    view.results = view.snapshot and Recommendations.results(view.snapshot, view.manga) or {}
    local pages = math.ceil(#view.results / page_size)
    view.page = math.max(1, math.min(view.page, pages))
end

function View:recommendation_state()
    local manga = self.detail and self.detail.id
    if not manga or not self.settings.recommendation.enabled then return end
    if not self.recommendation_view or self.recommendation_view.manga ~= manga then
        local data, err = self:local_index():recommendationData(manga)
        local view = {manga=manga, snapshot=data and data.snapshot, page=1, error=err}
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

function View:find_recommendations(view)
    if view.jobs or self.pending then return end
    local jobs, index = {}, self:local_index()
    view.jobs, view.error, view.page = jobs, nil, 1
    local config = self.settings.recommendation
    local limit = math.max(1, math.min(25, math.floor(config.limit)))

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

        local active, attempted, last_error = {}, {}, nil
        local function advance()
            if view.jobs ~= jobs then return end
            local count, completed = 0, 0
            for _ in pairs(active) do count = count + 1 end
            for _, item in ipairs(snapshot.items) do
                if not active[item.id] then
                    item.sources = item.sources or {}
                    local pending
                    for i, id in ipairs(snapshot.source_order) do
                        local cached = item.sources[id]
                        local tried = attempted[item.id] and attempted[item.id][id]
                        if not tried and (not cached or cached.failed or not fresh(cached.checked_at)) then
                            pending = sources[i]
                            break
                        end
                        if cached and #cached.matches > 0 then break end
                    end
                    if not pending then
                        completed = completed + 1
                    elseif count < 2 then
                        local id = pending.id
                        active[item.id], count = true, count + 1
                        attempted[item.id] = attempted[item.id] or {}
                        attempted[item.id][id] = true
                        run(item.id, "recommendation_source", {source=pending,item={
                            id=item.id, titles=item.titles, synonyms=item.synonyms, origin=view.manga,
                        }}, function(found, err)
                            active[item.id] = nil
                            local previous = item.sources[id]
                            if found then
                                found.checked_at = os.time()
                                item.sources[id] = found
                            else
                                last_error = err or "漫画源搜索失败。"
                                item.sources[id] = {failed=true, matches=previous and previous.matches or {}}
                            end
                            update_results(view)
                            save()
                            UI:nextTick(advance)
                        end)
                    end
                end
            end
            if completed == #snapshot.items then finish(last_error); return end
            view.busy = string.format("正在匹配漫画源… %d/%d", completed, #snapshot.items)
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
    if previous and previous.limit == limit and fresh(previous.fetched_at) then resolve_sources(); return end
    view.busy = "正在查询 AniList…"
    refresh()
    local media = self.detail.anilist_id or (previous and previous.media)
    run("ani", "anilist_recommend", {id=media, title=self.detail.title, limit=limit}, function(snapshot, err)
        if not snapshot then finish(err); return end
        if previous and previous.media == snapshot.media then
            local matches = {}
            for _, item in ipairs(previous.items) do matches[item.id] = item.sources end
            for _, item in ipairs(snapshot.items) do item.sources = matches[item.id] end
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
    note(column, width, "相似漫画 · AniList", 17)
    if view.busy then note(column, width, view.busy) end
    if view.error then note(column, width, view.error) end
    local count = #view.results
    if count == 0 then
        if not view.busy and not view.error then note(column, width, "暂未找到可读的推荐漫画。") end
        return
    end
    local tiles = Row:new{align="top"}
    local tile_width = math.floor(width / page_size)
    local first = (view.page - 1) * page_size + 1
    for i = first, math.min(count, first + page_size - 1) do
        local candidate = view.results[i]
        posters[#posters+1] = candidate
        tiles[#tiles+1] = Tile:new{width=tile_width, title=candidate.title,
            subtitle=candidate.author and candidate.author ~= "" and candidate.author or candidate.source,
            poster_height=math.floor((tile_width - 6) / 0.71),
            path=Covers.path(self.settings.connection, candidate),
            callback=function() self:open_recommended(view, candidate) end}
    end
    column[#column+1] = tiles
    self.pagination = {page=view.page, total=self:recommendation_page_count(view), page_size=page_size,
        item_count=count, go=function(page)
            view.page = page
            self.recommendation_scroll = true
            self:refresh()
        end}
end

function View:recommendation_page_count(view)
    return math.max(1, math.ceil(#view.results / page_size))
end

return View
