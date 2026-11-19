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
        if continue then self:locate_unread(true) end
    end
    self:refresh()
end

function Manga:chapter_actions(row)
    if self.pending then return end
    local dialog
    local function action(label, callback)
        return {text=label,callback=function() UI:close(dialog); callback() end}
    end
    local id = self.detail.id
    local primary
    if row.path then primary = action("打开本地章节",function() self:open_local(row.path) end)
    else
        primary = action("下载此章",function()
            local directory = self.settings.download.directory
            if directory == "" then directory = require("apps/filemanager/filemanagerutil").getHomeFolder() end
            if directory == "." then directory = require("datastorage"):getDataDir() .. "/books" end
            self:request_catalog("download",{manga=id,id=row.id,directory=directory},function()
                self.catalog_message = row.name .. " 已下载"
            end)
        end)
    end
    dialog = require("ui/widget/buttondialog"):new{title=row.name,buttons={{primary},
        {action(row.read and "标为未读" or "标为已读",function()
            self:request_catalog("chapter_read",{manga=id,id=row.id,read=not row.read},function(data)
                self.detail.unread, self.detail.first_unread_id = data.unread,nil
                self.catalog_message = row.name .. (row.read and " 已标为未读" or " 已标为已读")
            end)
        end)}, {action("返回目录",function() end)}}}
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
        column[#column+1] = SettingRow:new{width=width,label=row.name,value=state,callback=function() self:chapter_actions(row) end}
    end
    self.pagination = {page=data.page,total=data.pages,go=function(n)
        dir.page,dir.target = n,nil
        self:refresh()
    end}
end

return Manga
