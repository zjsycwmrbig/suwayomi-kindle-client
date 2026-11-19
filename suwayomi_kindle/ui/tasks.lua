local UI = require("ui/uimanager")
local Screen = require("device").screen
local Column = require("ui/widget/verticalgroup")
local Row = require("ui/widget/horizontalgroup")
local Gap = require("ui/widget/horizontalspan")
local Space = require("ui/widget/verticalspan")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local SettingRow = require("suwayomi_kindle/ui/setting_row")
local Button = require("suwayomi_kindle/ui/flat_button")
local Icons = require("suwayomi_kindle/ui/icons")
local Tasks = require("suwayomi_kindle/tasks")
local Downloads = require("suwayomi_kindle/downloads")
local Queue = require("suwayomi_kindle/queue")
local Page = {}
local states = {active="下载中",queued="排队中",paused="已暂停",failed="失败",saved="已下载"}
local filters = {
    {id="all",label="全部"},
    {id="active",label="下载中"},
    {id="queued",label="排队中"},
    {id="paused",label="暂停"},
    {id="failed",label="失败"},
}
local cleanups = {}

local function scale(n) return Screen:scaleBySize(n) end

local function notice(text)
    UI:show(require("ui/widget/infomessage"):new{text=text,timeout=3})
end

local function scheduler(home)
    return Queue.attach(home:local_index(),home.settings.connection,home.settings.download,home)
end

local function selection_items(selection)
    local items={}
    for _,item in pairs(selection or {}) do items[#items+1]=item end
    return items
end

local function selection_count(home)
    local count=0
    for _ in pairs(home.task_selection or {}) do count=count+1 end
    return count
end

local function clear_selection(home)
    home.task_selection,home.task_editing={},false
end

local function toggle_selection(home,item)
    if not home.task_selection then home.task_selection={} end
    if home.task_selection[item.key] then home.task_selection[item.key]=nil
    else home.task_selection[item.key]=item end
    home:refresh()
end

local function open_file(home,item)
    if item.path and require("libs/libkoreader-lfs").attributes(item.path,"mode")=="file" then
        home:open_local(item.path)
    else notice("本地文件已不存在。") end
end

local function clean_all(home)
    local index=home:local_index()
    if cleanups[index.path] then return end
    local mangas,err=index:with_db(function(db)
        local list={}
        for r in db:prepare([[SELECT DISTINCT f.manga FROM files f JOIN chapter c ON c.manga=f.manga
            AND c.id=f.id WHERE c.is_read=1]]):rows() do list[#list+1]=r[1] end
        return list
    end)
    if not mangas then notice(err); return end
    local count,failed,at=0,0,0
    cleanups[index.path]=true
    local function step()
        at=at+1
        if not mangas[at] then
            cleanups[index.path]=nil
            notice(string.format("已删除 %d 章，失败 %d 项",count,failed))
            if home.alive and home.index==index then home:refresh() end
            return
        end
        local reader=require("apps/reader/readerui").instance
        local path=reader and reader.document and reader.document.file
        local result=Downloads.clean(index,mangas[at],"0",true,path)
        count=count+(result and result.count or 0)
        failed=failed+(result and result.failed or 1)
        UI:nextTick(step)
    end
    UI:nextTick(step)
end

local function retry_selected(home,data)
    local selected=selection_items(home.task_selection)
    if #selected==0 then notice("请先选择下载任务。"); return end
    local result,err=Tasks.retry(home:local_index(),selected)
    if not result then notice(err); return end
    if result.count==0 then
        notice("所选任务中没有可重试的失败或暂停项。")
    else
        if not data.paused then Queue.start(scheduler(home),true) end
        notice(string.format("已安排 %d 项重试%s",result.count,data.paused and "；队列仍处于暂停状态" or ""))
    end
    clear_selection(home)
    home.task_page=1
    home:refresh()
end

local function delete_selected(home)
    local selected=selection_items(home.task_selection)
    if #selected==0 then notice("请先选择下载文件。"); return end
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("删除所选 %d 个本地文件？阅读记录会保留。",#selected),
        ok_callback=function()
            local reader=require("apps/reader/readerui").instance
            local path=reader and reader.document and reader.document.file
            local result,err=Tasks.deleteFiles(home:local_index(),selected,
                Tasks.directory(home.settings.download.directory),path)
            if not result then notice(err)
            else
                notice(string.format("已删除 %d 个文件，失败 %d 个，占用中 %d 个",
                    result.count,result.failed,result.kept))
            end
            clear_selection(home)
            home.task_page=1
            home:refresh()
        end,
    })
end

local function select_page(home,rows)
    local all=true
    for _,item in ipairs(rows) do
        if not home.task_selection[item.key] then all=false; break end
    end
    for _,item in ipairs(rows) do
        if all then home.task_selection[item.key]=nil else home.task_selection[item.key]=item end
    end
    home:refresh()
end

function Page:task_actions()
    local view=self.task_view or "queue"
    local file_scope=self.task_file_scope or "managed"
    local function pause(value)
        local ok,err=Queue.pause(scheduler(self),value)
        if not ok then notice(err) end
    end
    if self.task_editing then
        local actions={{icon="close","退出选择",function() clear_selection(self); self:refresh() end}}
        if view=="queue" then
            actions[#actions+1]={icon="refresh","重试所选",function()
                local data=Tasks.page(self:local_index(),"queue",1,1,{filter=self.task_filter})
                retry_selected(self,data or {})
            end}
        else
            actions[#actions+1]={icon="close","删除所选",function() delete_selected(self) end}
        end
        return actions
    end
    if view=="queue" then
        return {
            {icon="pause","暂停全部任务",function() pause(true) end},
            {icon="play","继续全部任务",function() pause(false) end},
            {icon="check","选择任务",function()
                self.task_selection,self.task_editing={},true
                self:refresh()
            end},
        }
    end
    local actions={
        {icon="check",file_scope=="orphan" and "选择孤立文件" or "选择文件",function()
            self.task_selection,self.task_editing={},true
            self:refresh()
        end},
    }
    if file_scope=="orphan" then
        actions[#actions+1]={icon="refresh","重新扫描",function()
            self.task_page,self.task_message=1,nil
            self:request_catalog("scan_downloads",{directory=Tasks.directory(self.settings.download.directory)},function(result)
                self.task_message="扫描完成，发现 " .. result.count .. " 个孤立文件"
            end,function(err) notice(err) end)
        end}
        actions[#actions+1]={icon="library","查看已下载文件",function()
            self.task_file_scope,self.task_page="managed",1
            clear_selection(self)
            self:refresh()
        end}
    else
        actions[#actions+1]={icon="warning","扫描孤立下载",function()
            if self.pending=="scan_downloads" then return end
            self.task_file_scope,self.task_page,self.task_message="orphan",1,nil
            clear_selection(self)
            self:refresh()
            self:request_catalog("scan_downloads",{directory=Tasks.directory(self.settings.download.directory)},function(result)
                self.task_message="扫描完成，发现 " .. result.count .. " 个孤立文件"
            end,function(err) notice(err) end)
        end}
        actions[#actions+1]={icon="close","删除所有已读下载",function()
            UI:show(require("ui/widget/confirmbox"):new{
                text="删除当前账号所有已读章节的本地 CBZ？阅读记录和正在阅读的文件会保留。",
                ok_callback=function() clean_all(self) end})
        end}
    end
    return actions
end

function Page:build_tasks(screen_width,height)
    local width=screen_width-scale(48)
    local view=self.task_view or "queue"
    local file_scope=self.task_file_scope or "managed"
    local counts={}
    if self.settings.connection.server_url~="" then counts=Tasks.counts(self:local_index()) or {} end
    local column=Column:new{align="left",Space:new{width=scale(8)}}

    local switch=Row:new{}
    local switch_w=math.floor((width-scale(6))/2)
    for _,option in ipairs({
        {id="queue",label="下载队列" .. (counts.queue~=nil and " · " .. counts.queue or "")},
        {id="files",label="下载文件" .. (counts.files~=nil and " · " .. counts.files or "")},
    }) do
        if #switch>0 then switch[#switch+1]=Gap:new{width=scale(6)} end
        switch[#switch+1]=Button.new{text=option.label,width=switch_w,compact=false,filled=view==option.id,
            show_parent=self,callback=function()
                if view~=option.id then
                    self.task_view,self.task_page,self.task_message=option.id,1,nil
                    self.task_file_scope="managed"
                    clear_selection(self)
                    self:refresh()
                end
            end}
    end
    column[#column+1]=switch
    column[#column+1]=Space:new{width=scale(8)}

    if view=="queue" then
        local filter_row=Row:new{}
        local gap=scale(4)
        local filter_w=math.floor((width-gap*(#filters-1))/#filters)
        for i,filter in ipairs(filters) do
            if i>1 then filter_row[#filter_row+1]=Gap:new{width=gap} end
            filter_row[#filter_row+1]=Button.new{text=filter.label,width=filter_w,compact=true,
                filled=(self.task_filter or "all")==filter.id,show_parent=self,callback=function()
                    self.task_filter,self.task_page,self.task_message=filter.id,1,nil
                    clear_selection(self)
                    self:refresh()
                end}
        end
        column[#column+1]=filter_row
        column[#column+1]=Space:new{width=scale(8)}
    end

    if self.task_editing then
        local selected=selection_count(self)
        local selected_w=scale(96)
        local button_w=math.floor((width-selected_w-scale(12))/2)
        local rows=self.task_rows or {}
        local all=#rows>0
        for _,item in ipairs(rows) do if not self.task_selection[item.key] then all=false; break end end
        column[#column+1]=Row:new{
            Text:new{width=selected_w,text=string.format("已选 %d",selected),
                face=Font:getFace("smallinfofont",16)},
            Button.new{text=all and "取消本页" or "全选本页",width=button_w,compact=true,show_parent=self,
                enabled=#rows>0,callback=function() select_page(self,rows) end},
            Gap:new{width=scale(6)},
            Button.new{text=view=="queue" and "重试所选" or "删除所选",width=button_w,compact=true,
                filled=selected>0,enabled=selected>0,show_parent=self,callback=function()
                    if view=="queue" then
                        local data=Tasks.page(self:local_index(),"queue",1,1,{filter=self.task_filter})
                        retry_selected(self,data or {})
                    else delete_selected(self) end
                end},
        }
        column[#column+1]=Space:new{width=scale(8)}
    end

    local reserved=scale(84)+(self.task_editing and scale(46) or 0)
    local limit=math.max(1,math.floor((height-reserved)/scale(66)))
    local data,err
    if self.settings.connection.server_url=="" then
        err="请先在设置中选择服务器。"
    else
        data,err=Tasks.page(self:local_index(),view,self.task_page or 1,limit,
            {filter=self.task_filter,file_scope=file_scope})
    end
    if not data then
        column[#column+1]=Text:new{width=width,text=err,face=Font:getFace("smallinfofont",16)}
    else
        self.task_page,self.task_rows=data.page,data.rows
        self.pagination={page=data.page,total=data.pages,go=function(n) self.task_page=n; self:refresh() end}
        if self.pending=="scan_downloads" then
            column[#column+1]=Text:new{width=width,text="正在扫描下载目录…",face=Font:getFace("smallinfofont",16)}
            column[#column+1]=Space:new{width=scale(6)}
        elseif data.count==0 then
            local empty=view=="queue" and (self.task_filter~="all" and "当前筛选下没有任务。" or "下载队列为空。")
                or file_scope=="orphan" and (data.scanned and "扫描结果中没有孤立文件。" or "可在菜单中扫描下载目录。")
                or "还没有已下载的章节。"
            column[#column+1]=Text:new{width=width,text=empty,face=Font:getFace("smallinfofont",16)}
            column[#column+1]=Space:new{width=scale(6)}
        end
        for _,item in ipairs(data.rows) do
            local selected=self.task_selection and self.task_selection[item.key]
            local label,value
            if file_scope=="orphan" and view=="files" then
                label=(item.path:match("[^/]+$") or item.path)
                value=item.reason .. " · " .. (item.path:match("^(.*)/[^/]+$") or item.path)
            else
                label=item.title or ("漫画 " .. tostring(item.manga))
                local state=data.paused and item.state=="queued" and "已暂停" or states[item.state] or item.state or ""
                value=(item.name or ("章节 " .. tostring(item.id))) .. " · " .. state
                if item.error and item.error~="" then value=value .. " · " .. item.error end
            end
            if self.task_editing then label=(selected and "☑  " or "☐  ") .. label end
            column[#column+1]=SettingRow:new{width=width,label=label,value=value,
                leading=selected and Icons.widget("check",scale(18)) or nil,
                callback=function()
                    if self.task_editing then toggle_selection(self,item)
                    elseif view=="queue" then
                        local retry=item.state=="failed"
                        local resume=item.state=="paused" or retry or (data.paused and item.state=="queued")
                        local dialog
                        dialog=require("ui/widget/buttondialog"):new{title=label,buttons={{{text=resume and (retry and "重试任务" or "继续任务") or "暂停任务",
                            callback=function()
                                UI:close(dialog)
                                local ok,why=Queue.pause(scheduler(self),not resume,item)
                                if not ok then notice(why) end
                            end}}}}
                        UI:show(dialog)
                    elseif file_scope=="orphan" then
                        notice(item.reason .. "\n" .. item.path)
                    else open_file(self,item) end
                end}
        end
    end
    return self:settings_page_frame(screen_width,height,width,column)
end

return Page
