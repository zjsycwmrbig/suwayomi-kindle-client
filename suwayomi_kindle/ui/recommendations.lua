local UI = require("ui/uimanager")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Row = require("ui/widget/horizontalgroup")
local SettingRow = require("suwayomi_kindle/ui/setting_row")
local Button = require("suwayomi_kindle/ui/flat_button")
local Worker = require("suwayomi_kindle/worker")
local Sources = require("suwayomi_kindle/browse_sources")
local Recommendations = require("suwayomi_kindle/recommendations")
local page_size = 3
local View = {recommendation_page_size=page_size}

local function note(column, width, text, size)
    column[#column+1] = Text:new{text=text, width=width, face=Font:getFace("smallinfofont",size or 15)}
end

function View:recommendation_state()
    local manga = self.detail and self.detail.id
    if not manga or not self.settings.recommendation.enabled then return end
    if not self.recommendation_view or self.recommendation_view.manga~=manga then
        local data, err = self:local_index():recommendationData(manga)
        self.recommendation_view = {manga=manga, data=data, page=1, error=err}
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

local function ordered_sources(home, sources)
    local history = home:source_history_data()
    return Sources.list(sources,home.settings.browse.language,nil,"opened",home:source_pins(),history.opened)
end

local function selected_sources(home, sources)
    local ranked = ordered_sources(home,sources)
    local limit = math.max(1,math.min(5,math.floor(home.settings.recommendation.sources)))
    for i=#ranked,limit+1,-1 do ranked[i]=nil end
    return ranked
end

function View:match_recommendation_page(view, items, force)
    if view.busy or #items==0 then return end
    local home, index = self, self:local_index()
    local jobs, next_source, active = {}, 1, 0
    local sources
    view.jobs, view.busy, view.error = jobs, "正在匹配漫画源…", nil
    local function current()
        return home.alive and home.recommendation_view==view and view.jobs==jobs
    end
    local function save()
        local ok, err = index:saveRecommendations(view.manga,view.data.snapshot)
        if not ok then view.error=err end
    end
    local function refresh()
        home.recommendation_scroll = true
        home:refresh()
    end
    local function advance()
        if not current() then return end
        while active<2 and sources[next_source] do
            local source = sources[next_source]
            local batch = {}
            next_source=next_source+1
            for _, item in ipairs(items) do
                local cached = item.sources and item.sources[source.id]
                if force or not cached or cached.failed then batch[#batch+1]=item end
            end
            if #batch>0 then
                active=active+1
                jobs[source.id] = Worker.start(UI,home.settings.connection,"recommendation_source",{
                    source=source, items=batch,
                },function(result)
                    if not current() then return end
                    active=active-1
                    jobs[source.id]=nil
                    for _, item in ipairs(batch) do
                        item.sources=item.sources or {}
                        local previous = item.sources[source.id]
                        local found = result and result[tostring(item.id)]
                        item.sources[source.id] = found and not found.failed and found
                            or {failed=true,matches=found and #found.matches>0 and found.matches
                                or previous and previous.matches or {}}
                    end
                    save()
                    UI:nextTick(advance)
                end)
            end
        end
        if active==0 then view.jobs,view.busy=nil,nil end
        refresh()
    end
    local function begin(all)
        sources=selected_sources(home,all)
        if #sources==0 then
            view.jobs,view.busy=nil,nil
            view.error="当前语言下没有可搜索的漫画源。"
            refresh()
            return
        end
        advance()
    end
    refresh()
    if self.all_sources then begin(self.all_sources); return end
    jobs.sources=Worker.start(UI,self.settings.connection,"sources",{language="all"},function(data,err)
        if not current() then return end
        jobs.sources=nil
        if data then self.all_sources=data.sources; begin(data.sources)
        else view.jobs,view.busy,view.error=nil,nil,err; refresh() end
    end)
end

local function collect_page(view, items)
    local visible = {}
    local first = (view.page-1)*page_size+1
    for i=first,math.min(#items,first+page_size-1) do visible[#visible+1]=items[i] end
    return visible
end

function View:find_recommendations(view)
    if view.busy or self.pending then return end
    local index = self:local_index()
    local function perform(action, params, done)
        local jobs = {}
        view.jobs,view.busy,view.error=jobs,"正在查询 AniList…",nil
        self.recommendation_scroll=true
        self:refresh()
        jobs.ani=Worker.start(UI,self.settings.connection,action,params,function(data,err)
            if not self.alive or self.recommendation_view~=view or view.jobs~=jobs then return end
            view.jobs,view.busy,view.error=nil,nil,err
            if data then done(data) end
            self.recommendation_scroll=true
            self:refresh()
        end)
    end
    local function fetch(media)
        local limit = math.max(1,math.min(25,math.floor(self.settings.recommendation.limit)))
        perform("anilist_recommend",{id=media,limit=limit},function(snapshot)
            local old = view.data.snapshot
            if old and old.media==snapshot.media then
                local previous={}
                for _, item in ipairs(old.items) do previous[item.id]=item.sources end
                for _, item in ipairs(snapshot.items) do item.sources=previous[item.id] end
            end
            local ok,err=index:saveRecommendations(view.manga,snapshot)
            view.data.snapshot,view.page,view.error=snapshot,1,not ok and err or nil
            self:match_recommendation_page(view,collect_page(view,snapshot.items),true)
        end)
    end
    if view.data.snapshot then fetch(view.data.media or view.data.snapshot.media); return end
    local title=require("suwayomi_kindle/config").trim(self.detail.title)
    perform("anilist_identify",{title=title},function(items)
        if #items==0 then view.error="AniList 未找到对应作品。"; return end
        view.data.media=items[1].id
        fetch(items[1].id)
    end)
end

function View:open_recommended(view,candidate)
    self.detail_stack=self.detail_stack or {}
    self.detail_stack[#self.detail_stack+1]={item=self.detail,view=view}
    self:cancel_recommendations()
    self.recommendation_view=nil
    self:open_detail(candidate)
end

local function collect_results(home, view)
    local available = home.all_sources and ordered_sources(home,home.all_sources)
    local pins, results, seen = home:source_pins(), {}, {}
    local snapshot=view and view.data and view.data.snapshot
    for order, item in ipairs(snapshot and snapshot.items or {}) do
        local sources=available
        if not sources then
            sources={}
            for id in pairs(item.sources or {}) do sources[#sources+1]={id=id} end
            table.sort(sources,function(a,b)
                local pa,pb=pins[a.id] or 0,pins[b.id] or 0
                if (pa>0)~=(pb>0) then return pa>0 end
                if pa~=pb then return pa<pb end
                return a.id<b.id
            end)
        end
        local rows=Recommendations.matches(item,sources)
        for _,row in ipairs(rows) do
            local candidate=row.item
            local dedupe=candidate.source_id..":"..candidate.id
            if not seen[dedupe] then
                seen[dedupe]=true
                results[#results+1]={candidate=candidate,source_position=row.position,recommendation_order=order}
            end
        end
    end
    table.sort(results,function(a,b)
        if a.candidate.in_library~=b.candidate.in_library then return a.candidate.in_library end
        if a.source_position~=b.source_position then return a.source_position<b.source_position end
        if a.recommendation_order~=b.recommendation_order then return a.recommendation_order<b.recommendation_order end
        return a.candidate.id<b.candidate.id
    end)
    return results
end

function View:build_recommendations(column, width)
    local view=self:recommendation_state()
    if not view then return end
    if not view.data then note(column,width,view.error or "无法读取推荐缓存。"); return end
    local snapshot=view.data.snapshot
    if not snapshot and not view.busy and not view.error then return end
    note(column,width,"相似漫画 · AniList",17)
    if view.busy then note(column,width,view.busy) end
    if view.error then note(column,width,view.error) end
    if not snapshot then return end
    local results=collect_results(self,view)
    if #results==0 then
        note(column,width,view.busy and "正在搜索可读漫画…" or view.error or "暂未找到可读的推荐漫画。")
        return
    end
    local items=collect_page(view,results)
    for _,result in ipairs(items) do
        local candidate=result.candidate
        local value=candidate.source
        if candidate.author and candidate.author~="" then value=value.." · "..candidate.author end
        if candidate.chapters then value=value.." · "..candidate.chapters.." 章" end
        column[#column+1]=SettingRow:new{width=width,inset=4,row_height=62,label=candidate.title,value=value,
            callback=function() self:open_recommended(view,candidate) end}
    end
    local count=#results
    self.pagination={page=view.page,total=math.ceil(count/page_size),page_size=page_size,item_count=count,busy=view.busy~=nil,go=function(page)
        view.page=page
        self.recommendation_scroll=true
        self:refresh()
    end}
end

function View:recommendation_page_count(view)
    return math.max(1,math.ceil(#collect_results(self,view)/page_size))
end

return View
