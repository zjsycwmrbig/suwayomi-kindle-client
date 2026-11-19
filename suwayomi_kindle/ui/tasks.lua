local UI = require("ui/uimanager")
local Screen = require("device").screen
local Column = require("ui/widget/verticalgroup")
local Space = require("ui/widget/verticalspan")
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Row = require("suwayomi_kindle/ui/setting_row")
local Tasks = require("suwayomi_kindle/tasks")
local Downloads = require("suwayomi_kindle/downloads")
local Queue = require("suwayomi_kindle/queue")
local Page = {}
local states = {active="下载中",queued="排队中",paused="已暂停",failed="失败",saved="已下载"}
local cleanups = {}

local function notice(text)
    UI:show(require("ui/widget/infomessage"):new{text=text})
end

local function scheduler(home)
    return Queue.attach(home:local_index(),home.settings.connection,home.settings.download,home)
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
            if home.alive and home.index==index then
                home.task_message=string.format("已删除 %d 章，失败 %d 项",count,failed)
                home:refresh()
            end
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

function Page:task_actions()
    local function view(which)
        self.task_view,self.task_page,self.task_message=which,1,nil
        self:refresh()
    end
    local function pause(value,task)
        local ok,err=Queue.pause(scheduler(self),value,task)
        if not ok then notice(err) end
    end
    local actions={
        {"暂停全部任务",function() pause(true) end},
        {"继续全部任务",function() pause(false) end},
        {"删除所有已读下载",function()
            UI:show(require("ui/widget/confirmbox"):new{
                text="删除当前账号所有已读章节的本地 CBZ？阅读记录和正在阅读的文件会保留。",
                ok_callback=function() clean_all(self) end})
        end},
        {"扫描孤立下载",function()
            if self.pending=="scan_downloads" then return end
            self.task_view,self.task_page,self.task_message="orphan",1,nil
            self:request_catalog("scan_downloads",{directory=Tasks.directory(self.settings.download.directory)},function(result)
                self.task_message="扫描完成，发现 " .. result.count .. " 个孤立文件"
            end,function(err) self.task_message=err end)
        end},
    }
    if self.task_view~="queue" and self.task_view then
        actions[#actions+1]={"查看下载任务",function() view("queue") end}
    end
    if self.task_view~="files" then actions[#actions+1]={"查看已下载文件",function() view("files") end} end
    if self.task_view~="orphan" then actions[#actions+1]={"查看孤立文件",function() view("orphan") end} end
    return actions
end

function Page:build_tasks(screen_width,height)
    local scale=function(n) return Screen:scaleBySize(n) end
    local width=screen_width-scale(48)
    local column=Column:new{align="left",Space:new{width=scale(10)}}
    local function note(text)
        column[#column+1]=Text:new{width=width,text=text,face=Font:getFace("smallinfofont",16)}
        column[#column+1]=Space:new{width=scale(6)}
    end
    local view=self.task_view or "queue"
    if self.settings.connection.server_url=="" then note("请先在设置中选择服务器。")
    else
        local data,err=Tasks.page(self:local_index(),view,self.task_page or 1,math.max(1,math.floor((height-scale(68))/scale(66))))
        if not data then note(err)
        else
            self.task_page=data.page
            self.pagination={page=data.page,total=data.pages,go=function(n) self.task_page=n; self:refresh() end}
            local title=({queue="下载队列",files="本地下载",orphan="孤立文件"})[view]
            note(title .. " · " .. data.count .. (view=="queue" and data.paused and " · 全部已暂停" or ""))
            if self.pending=="scan_downloads" then note("正在扫描下载目录…")
            elseif self.task_message then note(self.task_message)
            elseif data.count==0 then
                note(view=="orphan" and (data.scanned and "上次扫描未发现孤立文件。" or "可从左侧菜单扫描下载目录。")
                    or view=="files" and "还没有已下载的章节。" or "当前没有待处理的下载任务。")
            end
            for _,item in ipairs(data.rows) do
                local file=item.path and item.path:match("[^/]+$")
                local label=item.name or file or ("章节 " .. item.id)
                local state=states[item.state]
                if data.paused and item.state=="queued" then state="已暂停" end
                local detail=view=="orphan" and (item.reason .. " · " .. item.path)
                    or ((item.title or ("漫画 " .. item.manga)) .. " · " .. state .. (item.reason and " · "..item.reason or ""))
                column[#column+1]=Row:new{width=width,label=label,value=detail,callback=function()
                    if view=="orphan" then notice(item.reason .. "\n" .. item.path)
                    elseif view=="files" then
                        if require("libs/libkoreader-lfs").attributes(item.path,"mode")=="file" then self:open_local(item.path)
                        else notice("本地文件已不存在。") end
                    else
                        local paused=item.state=="paused" or item.state=="failed" or (data.paused and item.state=="queued")
                        local dialog
                        dialog=require("ui/widget/buttondialog"):new{title=label,buttons={{{text=paused and "继续任务" or "暂停任务",callback=function()
                            UI:close(dialog)
                            local ok,why=Queue.pause(scheduler(self),not paused,item)
                            if not ok then notice(why) end
                        end}}}}
                        UI:show(dialog)
                    end
                end}
            end
        end
    end
    return self:settings_page_frame(screen_width,height,width,column)
end

return Page
