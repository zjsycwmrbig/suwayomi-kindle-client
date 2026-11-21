-- One scheduler per account in the KOReader process. Reader and catalog share
-- the scheduler; closing a catalog window does not discard active downloads.
local UI = require("ui/uimanager")
local Worker = require("suwayomi_kindle/worker")
local Downloads = require("suwayomi_kindle/downloads")
local Tasks = require("suwayomi_kindle/tasks")
local Log = require("suwayomi_kindle/repair_log")
local Queue = {}
local sessions = {}

function Queue.attach(index,config,settings,owner)
    local q = sessions[index.path]
    if not q then
        q = {active=0,index=index,jobs={},listeners={}}
        sessions[index.path] = q
        index:with_db(function(db)
            db:exec([[UPDATE queue SET state='failed',error='换源中断，可重新下载。' WHERE state='active' AND repair='ready';
                UPDATE queue SET state='queued' WHERE state='active']])
            return true
        end)
    end
    q.config,q.settings = config,settings
    if owner then q.owner=owner end
    return q
end

function Queue.detach(index,owner)
    local q=index and sessions[index.path]
    if q and q.owner==owner then q.owner=nil end
end

local function redraw(q,manga)
    local home=q.owner
    if home and home.alive and home.index and home.index.path==q.index.path and (home.selected_tab=="tasks" or (home.directory
        and (not manga or home.detail.id==manga))) then home:refresh() end
end

function Queue.askRepair(q,job,details,reason)
    local function answer(accept)
        if Downloads.confirmRepair(q.index,job,accept) then
            Log.add(q.index,job,accept and "已确认换源" or "已取消换源")
            if not accept then Queue.notify(q,job,nil,reason) end
            redraw(q,job.manga)
            Queue.start(q)
        end
    end
    UI:show(require("ui/widget/confirmbox"):new{
        text=string.format("《%s》%s 下载失败%s。\n%s\n尝试换源下载这一章？",details.title,details.name,
            details.attempts and ("（已尝试 "..details.attempts.." 次）") or "",reason),
        ok_text="尝试换源",cancel_text="保留失败",
        ok_callback=function() answer(true) end,cancel_callback=function() answer(false) end,
    })
end

function Queue.start(q,resume)
    if resume then q.waiting=false end
    if q.scheduled or q.waiting then return end
    q.scheduled=true
    UI:nextTick(function()
        q.scheduled=false
        local started=false
        while not q.waiting and q.active < math.min(5, tonumber(q.settings.max_parallel) or 1) do
            local job = Downloads.claim(q.index,Tasks.directory(q.settings.directory))
            if not job then break end
            job.allow_missing_pages = q.settings.allow_missing_pages == true
            job.page_retries = q.settings.retries
            q.active=q.active+1
            started=true
            q.jobs[job.ticket]=job
            if job.repair then Log.add(q.index,job,"开始搜索备用源") end
            job.handle=Worker.start(UI,q.config,"download",job,function(data,err)
                if not q.jobs[job.ticket] then return end
                q.jobs[job.ticket]=nil
                q.active=q.active-1
                local source_error=data and data.source_error
                local exhausted=data and data.pages_exhausted
                if source_error then data,err=nil,source_error end
                local offline=not job.repair and err and (err:find("无法连接服务器",1,true)
                    or err:find("连接超时",1,true) or err:find("认证失败",1,true))
                local decision=source_error and not offline and Downloads.sourceFailure(q.index,job,q.settings,err,exhausted)
                if job.repair then
                    Log.add(q.index,job,data and "换源下载成功" or ("换源下载失败 · "..(err or "未知原因")))
                elseif decision then
                    local message = ({retry="原源失败，准备重试",ask="等待手动确认换源",
                        repair="已加入自动换源队列",failed="原源失败，未启动换源"})[decision.action]
                    Log.add(q.index,job,message.." · "..err)
                end
                if not decision or decision.action=="failed" then
                    Downloads.finish(q.index,job,not data and (err or "下载失败。") or nil)
                    Queue.notify(q,job,data,err)
                elseif decision.action=="ask" and ((q.owner and q.owner.alive) or q.listeners[job.manga.."/"..job.id]) then
                    Queue.askRepair(q,job,decision,err)
                end
                if offline then
                    q.waiting=true
                    Queue.notifyWaiting(q,err)
                end
                redraw(q,job.manga)
                Queue.start(q)
            end)
        end
        if q.retry_timer then UI:unschedule(q.retry_timer); q.retry_timer=nil end
        if not q.waiting and q.active < math.min(5, tonumber(q.settings.max_parallel) or 1) then
            local at=Downloads.nextRetry(q.index)
            if at then
                q.retry_timer=function() q.retry_timer=nil; Queue.start(q) end
                UI:scheduleIn(math.max(0.1,at-os.time()),q.retry_timer)
            end
        end
        if started then redraw(q) end
    end)
end

local function key(job) return job.manga .. "/" .. job.id end

function Queue.watch(q,job,callback)
    local k=key(job)
    local listeners=q.listeners[k] or {}
    q.listeners[k]=listeners
    listeners[callback]=true
    return function()
        listeners[callback]=nil
        if not next(listeners) and q.listeners[k]==listeners then q.listeners[k]=nil end
    end
end

function Queue.notify(q,job,data,err)
    local k=key(job)
    local listeners=q.listeners[k]
    q.listeners[k]=nil
    for callback in pairs(listeners or {}) do callback(data,err) end
end

function Queue.notifyWaiting(q,message)
    local listeners=q.listeners
    q.listeners={}
    for _,group in pairs(listeners) do
        for callback in pairs(group) do callback(nil,message) end
    end
end

function Queue.pause(q,paused,task)
    local ok,err=Tasks.setPaused(q.index,paused,task)
    if not ok then return nil,err end
    if paused then
        for ticket,job in pairs(q.jobs) do
            if not task or key(task)==key(job) then
                q.jobs[ticket]=nil
                q.active=q.active-1
                if job.handle then job.handle:cancel() end
            end
        end
        if task then Queue.notify(q,task,nil,"下载已暂停。")
        else Queue.notifyWaiting(q,"下载已暂停。") end
    end
    redraw(q)
    Queue.start(q,not paused)
    return true
end

function Queue.delete(q,items,open_path)
    local result,err=Tasks.deleteQueue(q.index,items,Tasks.directory(q.settings.directory),open_path)
    if not result then return nil,err end
    local removed={}
    for _,item in ipairs(result.stopped) do removed[key(item)]=true end
    for ticket,job in pairs(q.jobs) do
        if removed[key(job)] then
            q.jobs[ticket]=nil
            q.active=q.active-1
            if job.handle then job.handle:cancel() end
        end
    end
    for _,item in ipairs(result.stopped) do Queue.notify(q,item,nil,"下载任务已删除。") end
    Queue.start(q)
    redraw(q)
    return result
end

-- Re-evaluate only mangas with local files or an enabled download window.
-- Run one manga per UI tick and recheck the open reader before unlinking.
function Queue.reconcile(index,config,settings)
    local mangas=index:with_db(function(db)
        local list={}
        for r in db:prepare("SELECT DISTINCT manga FROM files UNION SELECT manga FROM policy WHERE ahead>0"):rows() do
            list[#list+1]=r[1]
        end
        return list
    end)
    if not mangas then return end
    local n=0
    local function next_manga()
        n=n+1
        local manga=mangas[n]
        if not manga then Queue.start(Queue.attach(index,config,settings)); return end
        local reader=require("apps/reader/readerui").instance
        local path=reader and reader.document and reader.document.file
        Downloads.clean(index,manga,settings.retention,false,path)
        Downloads.enqueue(index,manga,"auto")
        UI:nextTick(next_manga)
    end
    UI:nextTick(next_manga)
end

return Queue
