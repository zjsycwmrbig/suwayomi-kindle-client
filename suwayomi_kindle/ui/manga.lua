local UI = require("ui/uimanager")
local Screen = require("device").screen
local Column = require("ui/widget/verticalgroup")
local Row = require("ui/widget/horizontalgroup")
local Gap = require("ui/widget/horizontalspan")
local Space = require("ui/widget/verticalspan")
local Frame = require("ui/widget/container/framecontainer")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Image = require("ui/widget/imagewidget")
local Icons = require("suwayomi_kindle/ui/icons")
local Button = require("suwayomi_kindle/ui/flat_button")
local SettingRow = require("suwayomi_kindle/ui/setting_row")
local Chapters = require("suwayomi_kindle/chapters")
local Covers = require("suwayomi_kindle/covers")
local Records = require("suwayomi_kindle/records")
local Downloads = require("suwayomi_kindle/downloads")
local Queue = require("suwayomi_kindle/queue")
local MangaStatus = require("suwayomi_kindle/manga_status")
local Manga = {}

local function scale(n) return Screen:scaleBySize(n) end
local function paragraph(column, width, value, size, bold)
    column[#column+1] = Text:new{text = value, width = width, face = Font:getFace("smallinfofont", size), bold = bold}
    column[#column+1] = Space:new{width = scale(8)}
end

function Manga:open_detail(item)
    self:cancel_catalog()
    self.detail, self.directory = item,nil
    if item.in_library then self:local_index():markOpened(item.id) end
    item.first_unread_id = nil
    item.description = Chapters.description(self:local_index(),item.id) or item.description
    self:refresh_detail(true)
end

function Manga:refresh_detail(on_open)
    local item = self.detail
    local function auto_search()
        if on_open and self.settings.recommendation.auto_search then
            local view = self:recommendation_state()
            if view then self:find_recommendations(view) end
        end
    end
    self:request_catalog("detail",{id=item.id},function(data)
        for key,value in pairs(data) do item[key] = value end
        local saved = require("suwayomi_kindle/library_index").new(self.settings.connection)
        if data.anilist_id ~= nil then
            saved:setAnilistId(item.id,data.anilist_id)
        elseif data.anilist_supported then
            saved:setAnilistId(item.id,nil)
        end
        auto_search()
    end, auto_search)
end

function Manga:build_detail(column,width)
    local item = self.detail
    local w, h = scale(100), scale(142)
    local path = Covers.path(self.settings.connection,item)
    local cover = path and Image:new{original_in_nightmode = true, file = path,width = w,height = h}
        or require("ui/widget/container/centercontainer"):new{dimen = require("ui/geometry"):new{w=w,h=h}, Icons.widget("library",scale(38))}
    local meta = Column:new{align = "left"}
    local text_width = width-w-scale(12)
    paragraph(meta,text_width,item.title,22,true)
    paragraph(meta,text_width,MangaStatus.label(item.status),15)
    if item.author and item.author ~= "" then paragraph(meta,text_width,item.author,16) end
    if item.source and item.source ~= "" then paragraph(meta,text_width,item.source,15) end
    if item.anilist_supported == false and item.anilist_id == nil and self.recommendation_view then
        paragraph(meta,text_width,"此源未提供 AniList 关联",13)
    end
    if item.chapters then
        local counts = item.chapters .. " 章"
        if item.unread then counts = counts .. " · " .. item.unread .. " 未读" end
        paragraph(meta,text_width,counts,15)
    end
    column[#column+1] = Row:new{align="top",cover,Gap:new{width=scale(12)},meta}
    column[#column+1] = Space:new{width = scale(18)}
    paragraph(column,width,"简介",18,true)
    paragraph(column,width,item.description and item.description ~= "" and item.description
        or (self.pending == "detail" and "正在获取简介…" or "暂无简介"),16)
end

function Manga:detail_footer(width)
    local item = self.detail
    local row = Row:new{}
    local gap, inset = scale(6), scale(10)
    local w = math.floor((width-2*inset-2*gap)/3)
    local function add(label, action)
        if #row > 0 then row[#row+1] = Gap:new{width=gap} end
        row[#row+1] = Button.new{text=label,width=w,compact=true,show_parent=self,
            enabled=self.pending ~= "membership",callback=action}
    end
    -- The full directory starts at the first unread chapter without opening
    -- or downloading it. "继续阅读" remains the explicit open action.
    add("全部章节", function() self:open_directory("locate") end)
    add("继续阅读", function() self:open_directory(true) end)
    add(item.in_library and "移除书架" or "加入书架",function()
        self:request_catalog("membership",{item=item,enabled=not item.in_library},function(result)
            item.in_library = result.enabled
            self.catalog_message = result.warning or (result.enabled and "已加入书架" or "已移出书架")
        end)
    end)
    return Frame:new{width=width,padding=inset,bordersize=0,row}
end

function Manga:open_local(path)
    self:close()
    UI:nextTick(function()
        local ReaderUI=require("apps/reader/readerui")
        local current=ReaderUI.instance
        if current and current.document then
            if current.document.file~=path then
                require("suwayomi_kindle/reader_navigation").switchDocument(current,path)
            end
        else ReaderUI:showReader(path) end
    end)
end

function Manga:locate_unread(open_file)
    local row,err = Chapters.nextUnread(self:local_index(),self.detail.id)
    if not row then
        self.catalog_message = err or (self.detail.chapters == 0 and "当前漫画没有章节。" or "所有章节均已读。")
    elseif open_file and row.path then
        self:open_local(row.path)
    else
        self.directory.unread_only = false
        self.directory.anchor, self.directory.target = row.pos,row.id
        self.catalog_message = open_file and "已定位到第一个未读章节，点选后可下载。" or nil
    end
end

function Manga:refresh_directory(force,continue,has_snapshot)
    local id = self.detail.id
    self:request_catalog("chapters",{id=id,force=force},function(result)
        self.detail.chapters,self.detail.unread = result.count,result.unread
        self.detail.first_unread_id = nil
        self:queue_chapters("auto")
        if continue then self:locate_unread(continue ~= "locate") end
    end,function(err)
        if continue and has_snapshot then
            self:locate_unread(continue ~= "locate")
            self.catalog_message = (err or "刷新失败。") .. " 已使用本地目录。"
        end
    end)
end

function Manga:open_directory(continue)
    self:cancel_catalog()
    self.directory,self.catalog_message = {page=1}, nil
    local snapshot,err = Chapters.page(self:local_index(),self.detail.id,1,1)
    if not snapshot then self.catalog_message = err
    elseif not snapshot.cached then self:refresh_directory(false,continue); return
    else
        local known = self.detail.first_unread_id
        local next_row = known ~= nil and Chapters.nextUnread(self:local_index(),self.detail.id)
        local stale = self.detail.chapters and snapshot.count ~= self.detail.chapters
            or known ~= nil and (next_row and next_row.id or false) ~= known
        if stale then self:refresh_directory(false,continue,true); return end
        self:queue_chapters("auto")
        if continue then self:locate_unread(continue ~= "locate") end
    end
    self:refresh()
end

function Manga:queue_chapters(mode,id)
    local index=self:local_index()
    local result,err=Downloads.enqueue(index,self.detail.id,mode,id)
    if not result then self.catalog_message=err; return end
    Queue.start(Queue.attach(index,self.settings.connection,self.settings.download,self),mode~="auto")
    if mode ~= "auto" then self.catalog_message = string.format("已安排 %d 章下载",result.count) end
end

function Manga:clean_chapters(manual, notify)
    local reader=require("apps/reader/readerui").instance
    local path=reader and reader.document and reader.document.file
    local result,err=Downloads.clean(self:local_index(),self.detail.id,self.settings.download.retention,manual,path)
    if not result then self.catalog_message="删除失败：" .. (err or "未知错误")
    elseif manual or notify or result.failed>0 then
        self.catalog_message=Downloads.summary(result)
    end
    if notify or (result and result.failed>0) then
        UI:show(require("ui/widget/infomessage"):new{text=self.catalog_message,timeout=6})
    end
    return result
end

local function confirm(text,callback)
    UI:show(require("ui/widget/confirmbox"):new{text=text,ok_callback=callback})
end

function Manga:add_download_actions(actions)
    local index,manga=self:local_index(),self.detail.id
    local function options(key,entries)
        local policy=Downloads.policy(index,manga)
        local menu={}
        for _,entry in ipairs(entries) do
            menu[#menu+1]={entry[2],function()
                local ok,err=Downloads.configure(index,manga,key,entry[1])
                if not ok then self.catalog_message=err
                elseif key=="ahead" then self:queue_chapters("auto")
                else self:clean_chapters(false,true) end
                self:refresh()
            end,icon=policy and policy[key]==entry[1] and "check" or nil}
        end
        return menu
    end
    actions[#actions+1]={"自动下载",children=function()
        return options("ahead",{{0,"关闭"},{1,"1 章"},{3,"3 章"},{5,"5 章"}})
    end}
    actions[#actions+1]={icon="download","全部下载",function()
        confirm("下载《" .. self.detail.title .. "》的全部缺失章节？",function() self:queue_chapters("all"); self:refresh() end)
    end}
    actions[#actions+1]={icon="trash","删除已读",function()
        confirm("删除本漫画所有已读章节的本地 CBZ？",function() self:clean_chapters(true,true); self:refresh() end)
    end}
    actions[#actions+1]={"删除策略",children=function()
        return options("retention",{{"inherit","跟随全局"},{"never","不删除"},{"0","直接删除"},
            {"1","保留 1 章"},{"3","保留 3 章"},{"5","保留 5 章"},{"10","保留 10 章"}})
    end}
end

function Manga:chapter_actions(row)
    local dialog
    local index=self:local_index()
    local item={manga=self.detail.id,id=row.id,path=row.path}
    local q=Queue.attach(index,self.settings.connection,self.settings.download,self)
    local function report(message)
        self.catalog_message=message
        self:refresh()
        UI:show(require("ui/widget/infomessage"):new{text=message,timeout=4})
    end
    local function open_path()
        local reader=require("apps/reader/readerui").instance
        return reader and reader.document and reader.document.file
    end
    local function pause_download()
        local ok,err=Queue.pause(q,true,item)
        report(ok and "下载任务已暂停。" or (err or "无法暂停下载。"))
    end
    local function retry_download()
        local ok,err=Queue.pause(q,false,item)
        report(ok and "已重新排队，优先使用原源。" or (err or "无法继续下载。"))
    end
    local function delete_download()
        local result,err=Queue.delete(q,{item},open_path())
        if not result then
            report("删除下载失败："..(err or "未知错误"))
        else
            local message=string.format("已删除下载任务 %d 个，文件 %d 个",result.tasks or 0,result.files or 0)
            if (result.kept or 0)>0 then message=message..string.format("；保留 %d 个正在阅读的文件",result.kept) end
            report(message)
        end
    end
    local function rewrite_download()
        local result,err=Queue.rewrite(q,{item},open_path())
        if not result then
            report("重写下载失败："..(err or "未知错误"))
        else
            report(string.format("已清理旧文件并安排 %d 章重新下载。",result.queued or 0))
        end
    end
    local function repair_download()
        local result,err=Queue.repair(q,{item})
        if not result then report(err or "无法安排换源下载。")
        else
            report("已安排换源下载，将按候选源顺序尝试。")
        end
    end
    local function mark(range,read)
        local result,err=Records.mark(self:local_index(),self.detail.id,row,range,read)
        if result then
            self.detail.unread,self.detail.first_unread_id=result.unread,nil
            self.catalog_message=string.format("已更新 %d 章，可在设置中同步",result.changes)
            if result.changes>0 then require("suwayomi_kindle/sync_service").schedule(self:local_index(),self.settings.connection) end
            if read then self:clean_chapters(false,false) end
            self:queue_chapters("auto")
        else self.catalog_message=err end
        self:refresh()
    end
    local function action(label,range,read)
        return {text=label,callback=function()
            UI:close(dialog)
            if range=="single" then mark(range,read)
            else confirm(label .. "？（不含本章）",function() mark(range,read) end) end
        end}
    end
    local buttons={}
    local function add(text,callback)
        buttons[#buttons+1]={{text=text,callback=function()
            UI:close(dialog)
            callback()
        end}}
    end
    if row.path then add("阅读本地文件",function() self:open_local(row.path) end) end
    if row.state=="active" or row.state=="queued" then
        add("暂停下载",pause_download)
    elseif row.state=="failed" or row.state=="paused" then
        add("重试原源",retry_download)
    end
    add("换源下载",function()
        confirm("跳过当前源并按候选顺序换源下载？",repair_download)
    end)
    if row.path or row.state then
        add("重写下载",function()
            confirm("删除旧文件并从原源重新下载这一章？",rewrite_download)
        end)
    end
    if row.path or row.state then
        add("删除下载",function()
            confirm("删除这一章的下载文件和下载任务？",delete_download)
        end)
    end
    buttons[#buttons+1]={action(row.read and "标为未读" or "标为已读","single",not row.read)}
    buttons[#buttons+1]={action("标记之前为已读","before",true)}
    buttons[#buttons+1]={action("标记之后为未读","after",false)}
    dialog=require("ui/widget/buttondialog"):new{title=row.name,buttons=buttons}
    UI:show(dialog)
end

function Manga:build_directory(column,width,height)
    local dir = self.directory
    local limit = math.max(1,math.floor((height-scale(12))/scale(66)))
    if dir.anchor then dir.page = math.ceil(dir.anchor/limit); dir.anchor = nil end
    local data,err = Chapters.page(self:local_index(),self.detail.id,dir.page,limit,dir.unread_only)
    if not data then paragraph(column,width,err,16); return end
    dir.page = data.page
    if data.count == 0 and not self.pending then
        paragraph(column,width,self.catalog_message or (data.cached and (dir.unread_only and "没有未读章节" or "暂无章节") or "目录尚未缓存，可在菜单中刷新。"),16)
    end
    for _,row in ipairs(data.items) do
        local state = row.read and "已读" or "未读"
        if row.path then
            state = state .. (row.missing_pages and (" · 残缺 · 缺 "..row.missing_pages.." 页") or " · 已下载")
        end
        if row.scanlator ~= "" then state = state .. " · " .. row.scanlator end
        if row.id == dir.target then state = "▶  " .. state end
        local busy=row.state=="queued" or row.state=="active"
        local icon = row.path and "book_open" or busy and "clock" or row.state=="failed" and "refresh"
            or row.state=="paused" and "play" or "download"
        if not row.path and row.state then
            local status = {queued="排队中",active="下载中",failed="下载失败",paused="已暂停"}
            state = state .. " · " .. (status[row.state] or row.state)
        end
        if row.error and row.state=="failed" then state=state .. " · " .. row.error end
        local function primary()
            if self.reader_origin then
                self:close()
                require("suwayomi_kindle/reader_navigation").select(self.plugin,row,false)
            elseif row.path then self:open_local(row.path)
            elseif row.state=="paused" then
                local q=Queue.attach(self:local_index(),self.settings.connection,self.settings.download,self)
                Queue.pause(q,false,{manga=self.detail.id,id=row.id})
            elseif not busy then self:queue_chapters("single",row.id); self:refresh() end
        end
        local IconButton = require("suwayomi_kindle/ui/header").IconButton
        local button_w,more_w=scale(46),scale(42)
        column[#column+1]=Row:new{
            SettingRow:new{width=width-button_w-more_w,hide_chevron=true,muted=row.read,leading=Icons.widget(row.read and "read" or "unread",scale(17)),
                inset=4,leading_width=28,label=row.name,value=state,callback=primary},
            IconButton:new{icon_name=icon,dimen=require("ui/geometry"):new{w=button_w,h=scale(66)},
                callback=(row.path or not busy) and primary or nil},
            IconButton:new{icon_name="chevron_right",
                dimen=require("ui/geometry"):new{w=more_w,h=scale(66)},callback=function() self:chapter_actions(row) end},
        }
    end
    self.pagination = {page=data.page,total=data.pages,page_size=limit,item_count=data.count,go=function(n)
        dir.page,dir.target = n,nil
        self:refresh()
    end}
end

return Manga
