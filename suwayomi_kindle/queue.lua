-- One scheduler per account in the KOReader process. Reader and catalog share
-- the scheduler; closing a catalog window does not discard active downloads.
local UI = require("ui/uimanager")
local Worker = require("suwayomi_kindle/worker")
local Downloads = require("suwayomi_kindle/downloads")
local Queue = {}
local sessions = {}

function Queue.attach(index,config,settings,owner)
    local q = sessions[index.path]
    if not q then
        q = {active=0,index=index}
        sessions[index.path] = q
        index:with_db(function(db) db:exec("UPDATE queue SET state='queued' WHERE state='active'"); return true end)
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
    if home and home.alive and home.index and home.index.path==q.index.path and home.directory
        and (not manga or home.detail.id==manga) then home:refresh() end
end

function Queue.start(q,resume)
    if resume then q.waiting=false end
    if q.scheduled or q.waiting then return end
    q.scheduled=true
    UI:nextTick(function()
        q.scheduled=false
        local started=false
        while not q.waiting and q.active < (tonumber(q.settings.max_parallel) or 1) do
            local job = Downloads.claim(q.index)
            if not job then break end
            job.directory = q.settings.directory
            if job.directory == "" then job.directory = require("apps/filemanager/filemanagerutil").getHomeFolder() end
            if job.directory == "." then job.directory = require("datastorage"):getDataDir() .. "/books" end
            q.active=q.active+1
            started=true
            Worker.start(UI,q.config,"download",job,function(data,err)
                q.active=q.active-1
                Downloads.finish(q.index,job,not data and (err or "下载失败。") or nil)
                if err and (err:find("连接") or err:find("超时") or err:find("认证")) then q.waiting=true end
                redraw(q,job.manga)
                Queue.start(q)
            end)
        end
        if started then redraw(q) end
    end)
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
