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
local Manga = {}

local function scale(n) return Screen:scaleBySize(n) end
local function paragraph(column, width, value, size, bold)
    column[#column+1] = Text:new{text = value, width = width, face = Font:getFace("smallinfofont", size), bold = bold}
    column[#column+1] = Space:new{width = scale(8)}
end

function Manga:open_detail(item)
    self:cancel_catalog()
    self.detail, self.directory = item,nil
    item.first_unread_id = nil
    item.description = Chapters.description(self:local_index(),item.id) or item.description
    self:refresh_detail()
end

function Manga:refresh_detail()
    local item = self.detail
    self:request_catalog("detail",{id=item.id},function(data)
        for key,value in pairs(data) do item[key] = value end
    end)
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
    if item.author and item.author ~= "" then paragraph(meta,text_width,item.author,16) end
    if item.source and item.source ~= "" then paragraph(meta,text_width,item.source,15) end
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
    add("全部章节", function() self:open_directory(false) end)
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
    UI:nextTick(function() require("apps/reader/readerui"):showReader(path) end)
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
        if continue then self:locate_unread(true) end
    end,function(err)
        if continue and has_snapshot then
            self:locate_unread(true)
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
        if continue then self:locate_unread(true) end
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

function Manga:clean_chapters(manual)
    local reader=require("apps/reader/readerui").instance
    local path=reader and reader.document and reader.document.file
    local result,err=Downloads.clean(self:local_index(),self.detail.id,self.settings.download.retention,manual,path)
    if not result then self.catalog_message=err
    elseif manual or result.failed>0 then
        self.catalog_message=string.format("已删除 %d 章，失败 %d 章",result.count,result.failed)
    end
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
                else self:clean_chapters(false) end
                self:refresh()
            end,icon=policy and policy[key]==entry[1] and "check" or nil}
        end
        return menu
    end
    actions[#actions+1]={"自动下载",children=function()
        return options("ahead",{{0,"关闭"},{1,"1 章"},{3,"3 章"},{5,"5 章"}})
    end}
    actions[#actions+1]={"全部下载",function()
        confirm("下载本漫画的全部缺失章节？",function() self:queue_chapters("all"); self:refresh() end)
    end}
    actions[#actions+1]={"删除已读",function()
        confirm("删除本漫画所有已读章节的本地 CBZ？",function() self:clean_chapters(true); self:refresh() end)
    end}
    actions[#actions+1]={"删除策略",children=function()
        return options("retention",{{"inherit","跟随全局"},{"never","不删除"},{"0","直接删除"},
            {"1","保留 1 章"},{"3","保留 3 章"},{"5","保留 5 章"},{"10","保留 10 章"}})
    end}
end

function Manga:chapter_actions(row)
    local dialog
    local function mark(range,read)
        local result,err=Records.mark(self:local_index(),self.detail.id,row,range,read)
        if result then
            self.detail.unread,self.detail.first_unread_id=result.unread,nil
            self.catalog_message=string.format("已更新 %d 章，可在设置中同步",result.changes)
            if result.changes>0 then require("suwayomi_kindle/sync_service").schedule(self:local_index(),self.settings.connection) end
            if read then self:clean_chapters(false) end
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
    dialog=require("ui/widget/buttondialog"):new{title=row.name,buttons={
        {action(row.read and "标为未读" or "标为已读","single",not row.read)},
        {action("标记之前为已读","before",true)},
        {action("标记之后为未读","after",false)},
    }}
    UI:show(dialog)
end

function Manga:build_directory(column,width,height)
    local dir = self.directory
    local limit = math.max(1,math.floor((height-scale(85))/scale(66)))
    if dir.anchor then dir.page = math.ceil(dir.anchor/limit); dir.anchor = nil end
    local data,err = Chapters.page(self:local_index(),self.detail.id,dir.page,limit,dir.unread_only)
    if not data then paragraph(column,width,err,16); return end
    dir.page = data.page
    paragraph(column,width,self.detail.title .. (dir.unread_only and " · 未读" or ""),18,true)
    if data.count == 0 and not self.pending then
        paragraph(column,width,data.cached and (dir.unread_only and "没有未读章节" or "暂无章节") or "目录尚未缓存，可在菜单中刷新。",16)
    end
    for _,row in ipairs(data.items) do
        local state = row.read and "已读" or "未读"
        if row.path then state = state .. " · 已下载" end
        if row.scanlator ~= "" then state = state .. " · " .. row.scanlator end
        if row.id == dir.target then state = "▶  " .. state end
        local busy=row.state=="queued" or row.state=="active"
        local label=row.path and "阅读" or row.state=="queued" and "排队中"
            or row.state=="active" and "下载中" or row.state=="failed" and "重试" or "下载"
        if row.error and row.state=="failed" then state=state .. " · " .. row.error end
        local function primary()
            if row.path then self:open_local(row.path)
            elseif not busy then self:queue_chapters("single",row.id); self:refresh() end
        end
        local button_w,more_w=scale(64),scale(42)
        column[#column+1]=Row:new{
            SettingRow:new{width=width-button_w-more_w,hide_chevron=true,label=row.name,value=state,callback=primary},
            Button.new{text=label,width=button_w,compact=true,enabled=not busy,show_parent=self,callback=primary},
            require("suwayomi_kindle/ui/header").IconButton:new{icon_name="chevron_right",
                dimen=require("ui/geometry"):new{w=more_w,h=scale(66)},callback=function() self:chapter_actions(row) end},
        }
    end
    self.pagination = {page=data.page,total=data.pages,go=function(n)
        dir.page,dir.target = n,nil
        self:refresh()
    end}
end

return Manga
