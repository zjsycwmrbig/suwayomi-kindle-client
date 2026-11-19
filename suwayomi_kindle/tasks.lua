local lfs = require("libs/libkoreader-lfs")
local Tasks = {}
local filters = {all=true,active=true,queued=true,paused=true,failed=true}

function Tasks.directory(configured)
    local path = configured
    if path == "" then path = require("apps/filemanager/filemanagerutil").getHomeFolder() end
    if path == "." then path = require("datastorage"):getDataDir() .. "/books" end
    return path
end

local queries = {
    queue = {from = [[queue q LEFT JOIN manga m ON m.id=q.manga
        LEFT JOIN chapter c ON c.manga=q.manga AND c.id=q.id]],
        fields = "q.manga,q.id,m.title,c.name,q.state,q.error,NULL",
        order = "CASE q.state WHEN 'active' THEN 0 WHEN 'queued' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END,q.priority,q.rowid"},
    files = {from = [[files f LEFT JOIN manga m ON m.id=f.manga
        LEFT JOIN chapter c ON c.manga=f.manga AND c.id=f.id]],
        fields = "f.manga,f.id,m.title,c.name,'saved',NULL,f.path", order = "m.title,c.pos,f.id"},
    orphan = {from = "orphan", fields = "NULL,NULL,NULL,NULL,'orphan',reason,path", order = "path"},
}

local queue_where = {
    all = nil,
    active = "q.state='active'",
    queued = "q.state='queued' AND (SELECT paused FROM queue_control)=0",
    paused = "q.state='paused' OR (q.state='queued' AND (SELECT paused FROM queue_control)=1)",
    failed = "q.state='failed'",
}

function Tasks.counts(index)
    return index:with_db(function(db)
        return {
            queue=tonumber(db:rowexec("SELECT count(*) FROM queue")),
            files=tonumber(db:rowexec("SELECT count(*) FROM files")),
        }
    end)
end

function Tasks.page(index,view,page,limit,options)
    options = options or {}
    if view == "orphan" then view,options.file_scope="files","orphan" end
    local query = assert(queries[view])
    local filter = options.filter or "all"
    assert(filters[filter])
    local scope = options.file_scope or "managed"
    local from,where,count_from = query.from,queue_where[filter],"queue q"
    if view == "files" then
        if scope == "orphan" then
            from,where,count_from = queries.orphan.from,queue_where.all,"orphan"
            query = queries.orphan
        else
            where = queue_where.all
            count_from = "files f"
        end
    end
    return index:with_db(function(db)
        db:exec("BEGIN")
        local count = tonumber(db:rowexec("SELECT count(*) FROM " .. count_from
            .. (where and " WHERE " .. where or "")))
        local pages = math.max(1,math.ceil(count/limit))
        page = math.min(pages,math.max(1,page))
        local stmt = db:prepare("SELECT " .. query.fields .. " FROM " .. from
            .. (where and " WHERE " .. where or "") ..
            " ORDER BY " .. query.order .. " LIMIT ? OFFSET ?"):bind(limit,(page-1)*limit)
        local rows = {}
        for r in stmt:rows() do
            local item = {manga=r[1],id=tonumber(r[2]),title=r[3],name=r[4],state=r[5],reason=r[6],path=r[7]}
            if scope == "orphan" then item.key="orphan:" .. item.path
            elseif item.manga and item.id then item.key=view .. ":" .. item.manga .. ":" .. item.id end
            rows[#rows+1] = item
        end
        return {rows=rows,page=page,pages=pages,count=count,filter=filter,file_scope=scope,
            paused=tonumber(db:rowexec("SELECT paused FROM queue_control"))==1,
            scanned=tonumber((db:rowexec("SELECT max(at) FROM scan_status")))}
    end)
end

function Tasks.setPaused(index,paused,task)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        if task then
            -- Releasing one task after "pause all" must leave its siblings paused.
            if not paused and tonumber(db:rowexec("SELECT paused FROM queue_control"))==1 then
                db:exec("UPDATE queue SET state='paused' WHERE state='queued'; UPDATE queue_control SET paused=0")
            end
            local allowed = paused and "state IN ('active','queued')" or "state IN ('failed','paused')"
            db:prepare("UPDATE queue SET state=?,ticket=NULL,error=NULL WHERE manga=? AND id=? AND " .. allowed)
                :bind(paused and "paused" or "queued",task.manga,task.id):step()
        else
            db:prepare("UPDATE queue_control SET paused=?"):bind(paused and 1 or 0):step()
            if paused then db:exec("UPDATE queue SET state='queued',ticket=NULL WHERE state='active'")
            else db:exec("UPDATE queue SET state='queued',ticket=NULL,error=NULL WHERE state IN ('paused','failed')") end
        end
        db:exec("COMMIT")
        return true
    end)
end

function Tasks.retry(index,selections)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local retry=db:prepare([[UPDATE queue SET state='queued',ticket=NULL,error=NULL
            WHERE manga=? AND id=? AND state IN ('failed','paused')]])
        local count=0
        for _,item in pairs(selections or {}) do
            if item.manga and item.id then
                retry:reset():bind(item.manga,item.id):step()
                count=count+(tonumber(db:rowexec("SELECT changes()")) or 0)
            end
        end
        db:exec("COMMIT")
        return {count=count}
    end)
end

local function normalized(path)
    return path and path:gsub("/+$","")
end

local function inside(path,root)
    path,root=normalized(path),normalized(root)
    return path and root and path:sub(1,#root+1)==root .. "/"
end

-- Delete only the exact indexed copy or a scanned orphan below this account's
-- configured download root. The open reader file and unknown paths are kept.
function Tasks.deleteFiles(index,selections,root,open_path)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local count,failed,kept=0,0,0
        local scope=index.path:match("/(%x+)%.sqlite3$")
        for _,item in pairs(selections or {}) do
            local path=item.path
            local indexed
            if item.manga and item.id then
                indexed=db:prepare("SELECT path FROM files WHERE manga=? AND id=?"):bind(item.manga,item.id):step()
                indexed=indexed and indexed[1]
            else
                indexed=db:prepare("SELECT path FROM orphan WHERE path=?"):bind(path):step()
                indexed=indexed and indexed[1]
            end
            local acceptable=path and indexed==path
            if acceptable and item.manga and item.id and scope then
                acceptable=path:sub(-#("/Suwayomi/"..scope.."/"..item.manga.."/"..item.id..".cbz"))
                    =="/Suwayomi/"..scope.."/"..item.manga.."/"..item.id..".cbz"
            elseif acceptable then acceptable=inside(path,root) end
            local stat=acceptable and lfs.symlinkattributes(path)
            if path==open_path then
                kept=kept+1
            elseif not acceptable or not stat or stat.mode~="file" then
                failed=failed+1
            elseif os.remove(path) then
                if item.manga and item.id then
                    db:prepare("DELETE FROM files WHERE manga=? AND id=? AND path=?"):bind(item.manga,item.id,path):step()
                    db:prepare("DELETE FROM file_stamp WHERE manga=? AND id=?"):bind(item.manga,item.id):step()
                else
                    db:prepare("DELETE FROM orphan WHERE path=?"):bind(path):step()
                end
                count=count+1
            else failed=failed+1 end
        end
        db:exec("COMMIT")
        return {count=count,failed=failed,kept=kept}
    end)
end

-- Scan off the UI thread. Publish only a complete inventory, using a temp
-- table so directory traversal holds no write lock on the downloads queue.
function Tasks.scan(index,root)
    return index:with_db(function(db)
        db:exec("CREATE TEMP TABLE disk(path TEXT PRIMARY KEY)")
        local add = db:prepare("INSERT OR IGNORE INTO disk VALUES(?)")
        local pending,seen = {root},{}
        local scope = assert(index.path:match("/(%x+)%.sqlite3$"))
        local marker = "/Suwayomi/" .. scope .. "/"
        for row in db:prepare("SELECT path FROM files"):rows() do
            local start = row[1]:find(marker,1,true)
            if start then
                local old = row[1]:sub(1,start+#marker-2)
                if lfs.symlinkattributes(old,"mode")=="directory" then pending[#pending+1]=old end
            end
        end
        while #pending>0 do
            local dir = table.remove(pending):gsub("/+$","")
            if dir=="" then dir="/" end
            if not seen[dir] then
                seen[dir]=true
                local ok,iter,handle = pcall(lfs.dir,dir)
                if not ok or not iter then error("提示：无法扫描目录 " .. dir) end
                for name in iter,handle do
                    if name:sub(1,1)~="." then
                        local path=(dir=="/" and "" or dir) .. "/" .. name
                        local mode=lfs.symlinkattributes(path,"mode")
                        if mode=="directory" and not name:match("%.sdr$") then pending[#pending+1]=path
                        elseif mode=="file" and name:lower():match("%.cbz$") then add:reset():bind(path):step() end
                    end
                end
            end
        end
        db:exec("BEGIN IMMEDIATE; DELETE FROM orphan")
        db:prepare([[INSERT INTO orphan SELECT d.path,CASE WHEN f.path IS NULL THEN
            CASE WHEN instr(d.path,'/Suwayomi/')>0 AND instr(d.path,?)=0 THEN '其他账号或服务器目录'
                 ELSE '本地文件未登记' END
            WHEN m.id IS NULL THEN '漫画不在书架' ELSE '章节不在目录' END
            FROM disk d LEFT JOIN files f ON f.path=d.path LEFT JOIN manga m ON m.id=f.manga
            LEFT JOIN chapter c ON c.manga=f.manga AND c.id=f.id
            WHERE f.path IS NULL OR m.id IS NULL OR c.id IS NULL]]):bind(marker):step()
        db:exec("DELETE FROM scan_status; INSERT INTO scan_status VALUES(strftime('%s','now')); COMMIT")
        return {count=tonumber(db:rowexec("SELECT count(*) FROM orphan"))}
    end)
end

return Tasks
