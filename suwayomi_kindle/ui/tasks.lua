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
local Records = require("suwayomi_kindle/records")
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

local function repair_selected(home,items)
    local selected=items or selection_items(home.task_selection)
    if #selected==0 then notice("请先选择下载任务。"); return end
    selected=Tasks.expandFiles(home:local_index(),selected)
    if not selected or #selected==0 then notice("所选内容中没有可下载的章节。"); return end
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("将所选 %d 个章节切换到备用源下载？原源将跳过，阅读记录会保留。",#selected),
        ok_text="换源下载",
        ok_callback=function()
            local result,err=Queue.repair(scheduler(home),selected)
            if not result then notice(err or "无法安排换源下载。"); return end
            clear_selection(home)
            notice(string.format("已安排 %d 个章节换源下载。",result.count))
            if home.alive then home:refresh() end
        end,
    })
end

local function rewrite_selected(home,items)
    local selected=items or selection_items(home.task_selection)
    if #selected==0 then notice("请先选择下载任务。"); return end
    selected=Tasks.expandFiles(home:local_index(),selected)
    if not selected or #selected==0 then notice("所选内容中没有可重写的章节。"); return end
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("删除所选 %d 个章节的旧文件和任务，并从原源重新下载？",#selected),
        ok_text="重写下载",
        ok_callback=function()
            local reader=require("apps/reader/readerui").instance
            local path=reader and reader.document and reader.document.file
            local result,err=Queue.rewrite(scheduler(home),selected,path)
            if not result then notice(err or "无法重写下载。"); return end
            clear_selection(home)
            notice(string.format("已重新安排 %d 个章节下载。",result.queued or 0))
            if home.alive then home:refresh() end
        end,
    })
end

local function mark_task(home,item)
    local read,err=Tasks.readState(home:local_index(),item.manga,item.id)
    if read==nil then notice(err or "章节已不在目录中。"); return end
    local result,mark_error=Records.mark(home:local_index(),item.manga,{id=item.id},"single",not read)
    if not result then notice(mark_error or "无法更新阅读状态。"); return end
    if result.changes>0 then
        require("suwayomi_kindle/sync_service").schedule(home:local_index(),home.settings.connection)
    end
    notice(string.format("已标记为%s。",read and "未读" or "已读"))
    home:refresh()
end

local task_dialog
task_dialog=function(home,item,label,from_queue)
    local dialog
    local buttons={}
    local function add(text,callback)
        buttons[#buttons+1]={{text=text,callback=function()
            UI:close(dialog)
            callback()
        end}}
    end
    local function detail_text()
        local state=states[item.state] or item.state or "未知"
        local parts={label,"章节："..(item.name or ("章节 "..tostring(item.id))),"状态："..state}
        if item.pages_total and item.state=="active" then
            parts[#parts+1]=string.format("进度：已写入 %d/%d 页",item.pages_done or 0,item.pages_total)
        end
        if item.repair=="ready" then parts[#parts+1]="换源：已排队"
        elseif item.repair=="ask" then parts[#parts+1]="换源：等待确认" end
        if item.error and item.error~="" then parts[#parts+1]="错误："..item.error end
        if item.path then parts[#parts+1]="本机文件："..item.path end
        return table.concat(parts,"\n")
    end
    add("任务详情",function() notice(detail_text()) end)
    if item.path and require("libs/libkoreader-lfs").attributes(item.path,"mode")=="file" then
        add("阅读本章",function() open_file(home,item) end)
    end
    if from_queue and (item.state=="active" or item.state=="queued") then
        add("暂停任务",function()
            local ok,err=Queue.pause(scheduler(home),true,item)
            if not ok then notice(err or "无法暂停任务。") end
        end)
    elseif from_queue and (item.state=="paused" or item.state=="failed") then
        add(item.state=="failed" and "重试原源" or "继续原源",function()
            local ok,err=Queue.pause(scheduler(home),false,item)
            if not ok then notice(err or "无法继续任务。") end
        end)
    end
    add("换源下载",function()
        UI:show(require("ui/widget/confirmbox"):new{
            text="跳过原源并为这一章搜索备用源？阅读记录会保留。",
            ok_text="换源下载",
            ok_callback=function()
                local result,err=Queue.repair(scheduler(home),{item})
                if not result then notice(err or "无法安排换源下载。"); return end
                notice("已安排换源下载。")
                if home.alive then home:refresh() end
            end,
        })
    end)
    add("重写下载",function()
        UI:show(require("ui/widget/confirmbox"):new{
            text="删除旧文件和任务，并从原源重新下载这一章？",
            ok_text="重写下载",
            ok_callback=function()
                local reader=require("apps/reader/readerui").instance
                local path=reader and reader.document and reader.document.file
                local result,err=Queue.rewrite(scheduler(home),{item},path)
                if not result then notice(err or "无法重写下载。"); return end
                notice("已重新安排下载。")
                if home.alive then home:refresh() end
            end,
        })
    end)
    add("切换已读状态",function() mark_task(home,item) end)
    if not from_queue then
        add("多选文件",function()
            home.task_editing,home.task_selection=true,{}
            toggle_selection(home,item)
        end)
    end
    add(from_queue and "删除任务及文件" or "删除文件",function()
        UI:show(require("ui/widget/confirmbox"):new{
            text="删除这一章的下载任务和本机文件？阅读记录会保留。",
            ok_text="删除",
            ok_callback=function()
                local reader=require("apps/reader/readerui").instance
                local path=reader and reader.document and reader.document.file
                local result,err=Queue.delete(scheduler(home),{item},path)
                if not result then notice(err or "删除失败。"); return end
                local message=string.format("已移除 %d 个任务并清理 %d 个文件。",result.tasks or 0,result.files or 0)
                if (result.kept or 0)>0 then message=message..string.format("保留 %d 个正在阅读的文件。",result.kept) end
                notice(message)
                if home.alive then home:refresh() end
            end,
        })
    end)
    dialog=require("ui/widget/buttondialog"):new{title=label,buttons=buttons}
    UI:show(dialog)
end

local function delete_selected(home,items)
    local index=home:local_index()
    local selected,err=Tasks.expandFiles(index,items or selection_items(home.task_selection))
    if not selected then notice(err); return end
    if #selected==0 then notice("请先选择下载文件。"); return end
    local root=Tasks.directory(home.settings.download.directory)
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("删除所选 %d 个本地章节文件？阅读记录会保留。",#selected),
        ok_callback=function()
            local count,failed,kept,missing,at=0,0,0,0,1
            local function step()
                local batch={}
                for i=at,math.min(#selected,at+31) do batch[#batch+1]=selected[i] end
                local reader=require("apps/reader/readerui").instance
                local path=reader and reader.document and reader.document.file
                local result,why=Tasks.deleteFiles(index,batch,root,path)
                if not result then notice(why); return end
                count,failed,kept=count+result.count,failed+result.failed,kept+result.kept
                missing=missing+(result.missing or 0)
                at=at+#batch
                if at<=#selected then UI:nextTick(step); return end
                local summary=string.format("已删除 %d 个文件，失败 %d 个，占用中 %d 个",count,failed,kept)
                if missing>0 then summary=summary .. string.format("，清理失效记录 %d 条",missing) end
                notice(summary)
                if home.alive and home.index==index then
                    clear_selection(home)
                    home:refresh()
                end
            end
            step()
        end,
    })
end

local function delete_tasks(home,items)
    local selected=items or selection_items(home.task_selection)
    if #selected==0 then notice("请先选择下载任务。"); return end
    local index=home:local_index()
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("删除所选 %d 个下载任务及对应的本机文件？阅读记录会保留。",#selected),
        ok_text="删除",
        ok_callback=function()
            if not home.alive or home.index~=index then return end
            local q=scheduler(home)
            local at,tasks,files,parts,kept,failed=1,0,0,0,0,0
            local function step()
                local batch={}
                for i=at,math.min(#selected,at+15) do batch[#batch+1]=selected[i] end
                local reader=require("apps/reader/readerui").instance
                local path=reader and reader.document and reader.document.file
                local result,err=Queue.delete(q,batch,path)
                if not result then notice(err); return end
                tasks,files,parts=tasks+result.tasks,files+result.files,parts+result.parts
                kept,failed=kept+result.kept,failed+result.failed
                at=at+#batch
                if at<=#selected then UI:nextTick(step); return end
                if home.alive and home.index==index then clear_selection(home); home:refresh() end
                local summary=string.format("已移除 %d 个任务，清理 %d 个章节文件、%d 个临时文件",tasks,files,parts)
                if kept>0 then summary=summary .. string.format("，保留 %d 个正在阅读的文件",kept) end
                if failed>0 then summary=summary .. string.format("，%d 个文件未能清理",failed) end
                notice(summary)
            end
            step()
        end,
    })
end

function Page:leave_task_folder()
    self.task_page,self.task_folder=self.task_folder_page or 1,nil
    clear_selection(self)
    self:refresh()
end

local function enter_folder(home,item)
    home.task_folder_page,home.task_folder,home.task_page=home.task_page,item,1
    clear_selection(home)
    home:refresh()
end

local function file_menu(home,item,label)
    if item.state~="folder" and item.state~="orphan" then
        task_dialog(home,item,label,false)
        return
    end
    local dialog
    local function action(text,fn)
        return {{text=text,callback=function() UI:close(dialog); fn() end}}
    end
    local folder=item.state=="folder"
    local buttons={}
    if folder then
        buttons[1]=action("查看章节文件",function()
            enter_folder(home,item)
        end)
    else buttons[1]=action("查看文件信息",function() notice(item.reason .. "\n" .. item.path) end) end
    buttons[#buttons+1]=action(folder and "多选文件夹" or "多选文件",function()
        home.task_editing,home.task_selection=true,{}
        toggle_selection(home,item)
    end)
    buttons[#buttons+1]=action(folder and "删除此漫画的下载" or "删除文件",function() delete_selected(home,{item}) end)
    dialog=require("ui/widget/buttondialog"):new{title=label,buttons=buttons}
    UI:show(dialog)
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
        end
        actions[#actions+1]={icon="refresh","换源重下所选",function() repair_selected(self) end}
        actions[#actions+1]={icon="download","重写所选",function() rewrite_selected(self) end}
        actions[#actions+1]={icon="trash","删除所选",function()
            if view=="queue" then delete_tasks(self) else delete_selected(self) end
        end}
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
        {icon="check",file_scope=="orphan" and "选择孤立文件" or self.task_folder and "选择文件" or "选择文件夹",function()
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
            self.task_file_scope,self.task_page,self.task_message,self.task_folder="orphan",1,nil,nil
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

-- Poll only while this page shows an active attempt. Compare the small active
-- set first so an unchanged counter does not repaint an e-ink screen.
local function watch_progress(home)
    if home.task_progress_timer then return end
    local function poll()
        home.task_progress_timer=nil
        if not home.alive or home.selected_tab~="tasks" or (home.task_view or "queue")~="queue" then return end
        local visible={}
        for _,item in ipairs(home.task_rows or {}) do
            if item.state=="active" then visible[item.key]=item end
        end
        if not next(visible) then return end
        if UI:getTopmostVisibleWidget()==home then
            local changed=home:local_index():with_db(function(db)
                for row in db:prepare("SELECT manga,id,pages_done,pages_total FROM queue WHERE state='active'"):rows() do
                    local key="queue:" .. row[1] .. ":" .. tonumber(row[2])
                    local item=visible[key]
                    if item and (item.pages_done~=tonumber(row[3]) or item.pages_total~=tonumber(row[4])) then return true end
                    visible[key]=nil
                end
                return next(visible)~=nil
            end)
            if changed then home:refresh(); return end
        end
        watch_progress(home)
    end
    home.task_progress_timer=poll
    UI:scheduleIn(1.5,poll)
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
                    self.task_file_scope,self.task_folder="managed",nil
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

    local reserved=scale(view=="queue" and 98 or 60)+(self.task_editing and scale(46) or 0)
    local limit=math.max(1,math.floor((height-reserved)/scale(66)))
    local data,err
    if self.settings.connection.server_url=="" then
        err="请先在设置中选择服务器。"
    else
        data,err=Tasks.page(self:local_index(),view,self.task_page or 1,limit,
            {filter=self.task_filter,file_scope=file_scope,manga=self.task_folder and self.task_folder.manga})
    end
    if self.task_editing then
        local selected=selection_count(self)
        local selected_w=scale(96)
        local button_w=math.floor((width-selected_w-scale(12))/2)
        local rows=data and data.rows or {}
        local all=#rows>0
        for _,item in ipairs(rows) do if not self.task_selection[item.key] then all=false; break end end
        column[#column+1]=Row:new{
            Text:new{width=selected_w,text=string.format("已选 %d",selected),
                face=Font:getFace("smallinfofont",16)},
            Button.new{text=all and "取消本页" or "全选本页",width=button_w,compact=true,show_parent=self,
                enabled=#rows>0,callback=function() select_page(self,rows) end},
            Gap:new{width=scale(6)},
            Button.new{text="删除所选",width=button_w,compact=true,
                filled=selected>0,enabled=selected>0,show_parent=self,callback=function()
                    if view=="queue" then
                        delete_tasks(self)
                    else delete_selected(self) end
                end},
        }
        column[#column+1]=Space:new{width=scale(8)}
    end

    if not data then
        column[#column+1]=Text:new{width=width,text=err,face=Font:getFace("smallinfofont",16)}
    else
        self.task_page,self.task_rows=data.page,data.rows
        self.pagination={page=data.page,total=data.pages,page_size=limit,item_count=data.count,
            go=function(n) self.task_page=n; self:refresh() end}
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
            if item.state=="active" then watch_progress(self) end
            local selected=self.task_selection and self.task_selection[item.key]
            local label,value
            if file_scope=="orphan" and view=="files" then
                label=(item.path:match("[^/]+$") or item.path)
                value=item.reason .. " · " .. (item.path:match("^(.*)/[^/]+$") or item.path)
            elseif item.state=="folder" then
                label=item.title or ("漫画 " .. item.manga)
                value=string.format("%d 个章节文件",item.file_count)
            elseif view=="files" then
                label=item.name or ("章节 " .. item.id)
                value=item.path:match("[^/]+$") or item.path
            else
                label=item.title or ("漫画 " .. tostring(item.manga))
                local state=data.paused and item.state=="queued" and "已暂停" or states[item.state] or item.state or ""
                if item.repair=="ready" then state="换源排队"
                elseif item.repair=="ask" then state="等待换源确认" end
                value=(item.name or ("章节 " .. tostring(item.id))) .. " · " .. state
                if item.pages_total and item.state=="active" then
                    value=value .. string.format(" · 已写入 %d/%d 页",item.pages_done,item.pages_total)
                end
                if item.error and item.error~="" then value=value .. " · " .. item.error end
            end
            if self.task_editing then label=(selected and "☑  " or "☐  ") .. label end
            local folder_actions=item.state=="folder" and not self.task_editing
            local menu_width=folder_actions and scale(52) or 0
            local row=SettingRow:new{width=width-menu_width,label=label,value=value,
                hide_chevron=folder_actions or self.task_editing,
                leading=selected and Icons.widget("check",scale(18)) or item.state=="folder" and Icons.widget("folder",scale(23)) or nil,
                callback=function()
                    if self.task_editing then toggle_selection(self,item)
                    elseif view=="queue" then
                        task_dialog(self,item,label,true)
                    elseif folder_actions then enter_folder(self,item)
                    else file_menu(self,item,label) end
                end}
            if folder_actions then
                local menu=require("suwayomi_kindle/ui/header").IconButton:new{icon_name="menu",
                    dimen=require("ui/geometry"):new{w=menu_width,h=row:getSize().h},
                    callback=function() file_menu(self,item,label) end}
                row=Row:new{row,menu}
            end
            column[#column+1]=row
        end
    end
    return self:settings_page_frame(screen_width,height,width,column)
end

return Page
