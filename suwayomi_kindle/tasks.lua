local lfs = require("libs/libkoreader-lfs")
local Tasks = {}
local filters = {all=true,active=true,queued=true,paused=true,failed=true}
local module_file = debug.getinfo(1,"S").source:sub(2)
local plugin_root = module_file:match("^(.*)/suwayomi_kindle/tasks%.lua$") or "."
if plugin_root:sub(1,1) ~= "/" then
    local relative = plugin_root:gsub("^%./", "")
    plugin_root = lfs.currentdir() .. (relative == "." and "" or "/" .. relative)
end

function Tasks.directory(configured)
    if not configured or configured == "" then return plugin_root .. "/downloads" end
    if configured == "." then return require("datastorage"):getDataDir() .. "/books" end
    return configured
end

local queries = {
    queue = {from = [[queue q LEFT JOIN manga m ON m.id=q.manga
        LEFT JOIN chapter c ON c.manga=q.manga AND c.id=q.id]],
        fields = "q.manga,q.id,m.title,c.name,q.state,q.error,NULL,q.pages_done,q.pages_total",
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
    local filter = options.filter or "all"
    assert(filters[filter])
    local scope = options.file_scope or "managed"
    local folders = view=="files" and scope=="managed" and not options.manga
    local query = assert(queries[scope=="orphan" and view=="files" and "orphan" or view])
    local count_sql, list_sql
    local args = {}
    if folders then
        count_sql = "SELECT count(DISTINCT manga) FROM files"
        list_sql = [[SELECT f.manga,NULL,m.title,NULL,'folder',NULL,NULL,count(*)
            FROM files f LEFT JOIN manga m ON m.id=f.manga GROUP BY f.manga ORDER BY m.title COLLATE NOCASE,f.manga]]
    else
        local where = ""
        if view=="queue" and queue_where[filter] then where = " WHERE " .. queue_where[filter]
        elseif view=="files" and scope=="managed" then where,args = " WHERE f.manga=?",{options.manga} end
        local base = view=="queue" and "queue q" or scope=="orphan" and "orphan" or "files f"
        count_sql = "SELECT count(*) FROM " .. base .. where
        list_sql = "SELECT " .. query.fields .. " FROM " .. query.from .. where .. " ORDER BY " .. query.order
    end
    return index:with_db(function(db)
        db:exec("BEGIN")
        local counter = db:prepare(count_sql)
        if #args>0 then counter:bind(args[1]) end
        local count = tonumber(counter:step()[1])
        local pages = math.max(1,math.ceil(count/limit))
        page = math.min(pages,math.max(1,page))
        args[#args+1] = limit
        args[#args+1] = (page-1)*limit
        local stmt = db:prepare(list_sql .. " LIMIT ? OFFSET ?"):bind(unpack(args))
        local rows = {}
        for r in stmt:rows() do
            local item = {manga=r[1],id=tonumber(r[2]),title=r[3],name=r[4],state=r[5],reason=r[6],path=r[7]}
            if folders then
                item.key,item.file_count = "folder:" .. item.manga,tonumber(r[8])
            elseif view=="queue" then
                item.key,item.error = "queue:" .. item.manga .. ":" .. item.id,r[6]
                item.pages_done,item.pages_total = tonumber(r[8]),tonumber(r[9])
            elseif scope == "orphan" then item.key="orphan:" .. item.path
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

-- Freeze the exact paths covered by a confirmation. Files added later are
-- outside that selection, even when they belong to one of the chosen folders.
function Tasks.expandFiles(index,selection)
    return index:with_db(function(db)
        db:exec("BEGIN")
        local files,seen = {},{}
        local function add(item)
            if item.path and not seen[item.path] then
                files[#files+1],seen[item.path] = item,true
            end
        end
        local stmt = db:prepare("SELECT id,path FROM files WHERE manga=?")
        for _,item in pairs(selection) do
            if item.state=="folder" then
                for row in stmt:reset():bind(item.manga):rows() do
                    add({manga=item.manga,id=tonumber(row[1]),path=row[2]})
                end
            else add(item) end
        end
        return files
    end)
end

local function normalized(path)
    return path and path:gsub("/+$","")
end

local function inside(path,root)
    path,root=normalized(path),normalized(root)
    return path and root and path:sub(1,#root+1)==root .. "/"
end

local function delete_files(db,index,selections,root,open_path)
        local count,failed,kept,missing=0,0,0,0
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
            local stat, errno
            if acceptable then
                local message
                stat,message,errno=lfs.symlinkattributes(path)
            end
            local stamp
            if stat and item.manga and item.id then
                stamp=db:prepare("SELECT bytes,mtime FROM file_stamp WHERE manga=? AND id=?")
                    :bind(item.manga,item.id):step()
            end
            local replaced=stamp and (tonumber(stamp[1])~=stat.size or tonumber(stamp[2])~=stat.modification)
            local absent=acceptable and not stat and errno==2
            if path and path==open_path then
                kept=kept+1
            elseif absent or (acceptable and stat and stat.mode=="file" and not replaced and os.remove(path)) then
                if item.manga and item.id then
                    db:prepare("DELETE FROM files WHERE manga=? AND id=? AND path=?"):bind(item.manga,item.id,path):step()
                    db:prepare("DELETE FROM file_stamp WHERE manga=? AND id=?"):bind(item.manga,item.id):step()
                end
                db:prepare("DELETE FROM orphan WHERE path=?"):bind(path):step()
                if absent then missing=missing+1 else count=count+1 end
            else failed=failed+1 end
        end
        return {count=count,failed=failed,kept=kept,missing=missing}
end

-- Delete only the exact indexed copy or a scanned orphan below the download root.
function Tasks.deleteFiles(index,selections,root,open_path)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local result=delete_files(db,index,selections,root,open_path)
        db:exec("COMMIT")
        return result
    end)
end

local function clear_parts(path,suffix)
    if not path or path:sub(-#suffix)~=suffix then return 0,0 end
    local dir,name=path:match("^(.*)/([^/]+)$")
    local dir_suffix=suffix:match("^(.*)/[^/]+$")
    local real_dir=require("ffi/util").realpath(dir)
    if not real_dir then
        local _,_,errno=lfs.symlinkattributes(dir)
        return 0,errno==2 and 0 or 1
    end
    if real_dir:sub(-#dir_suffix)~=dir_suffix then return 0,1 end
    local ok,iter,handle=pcall(lfs.dir,real_dir)
    if not ok or not iter then return 0,1 end
    local removed,failed=0,0
    for file in iter,handle do
        if file:sub(1,#name)==name and file:sub(#name+1):match("^%.%d+%.part$") then
            local part=real_dir.."/"..file
            local mode,_,errno=lfs.symlinkattributes(part,"mode")
            if mode=="file" and os.remove(part) then removed=removed+1
            elseif errno~=2 then failed=failed+1 end
        end
    end
    return removed,failed
end

function Tasks.deleteQueue(index,selections,root,open_path)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local read=db:prepare([[SELECT q.state,q.target_path,f.path FROM queue q
            LEFT JOIN files f USING(manga,id) WHERE q.manga=? AND q.id=?]])
        local saved=db:prepare("SELECT path FROM files WHERE manga=? AND id=?")
        local remove=db:prepare("DELETE FROM queue WHERE manga=? AND id=?")
        local exclude=db:prepare("INSERT OR IGNORE INTO auto_download_excluded VALUES(?,?)")
        local scope=assert(index.path:match("/(%x+)%.sqlite3$"))
        local result={tasks=0,parts=0,failed=0,stopped={}}
        local files={}
        for _,item in ipairs(selections) do
            local manga,id=tostring(item.manga),tonumber(item.id)
            if manga:match("^%d+$") and id and id>0 and id%1==0 then
                local row=read:reset():bind(manga,id):step()
                -- A selected task may finish while its confirmation is open.
                local finished=not row and saved:reset():bind(manga,id):step()
                if row or finished then
                    local path=row and row[3] or finished and finished[1]
                    if path then files[#files+1]={manga=manga,id=id,path=path} end
                    remove:reset():bind(manga,id):step()
                    exclude:reset():bind(manga,id):step()
                    result.stopped[#result.stopped+1]={manga=manga,id=id}
                    result.tasks=result.tasks+1
                    local suffix="/Suwayomi/"..scope.."/"..manga.."/"..id..".cbz"
                    local fallback=normalized(root)..suffix
                    local target=row and row[2] or fallback
                    local parts,failed=clear_parts(target,suffix)
                    result.parts,result.failed=result.parts+parts,result.failed+failed
                    if target~=fallback then
                        parts,failed=clear_parts(fallback,suffix)
                        result.parts,result.failed=result.parts+parts,result.failed+failed
                    end
                end
            end
        end
        local cleanup=delete_files(db,index,files,root,open_path)
        result.files,result.kept,result.missing=cleanup.count,cleanup.kept,cleanup.missing
        result.failed=result.failed+cleanup.failed
        db:exec("COMMIT")
        return result
    end)
end

-- Scan off the UI thread. Publish only a complete inventory, using a temp
-- table so directory traversal holds no write lock on the downloads queue.
function Tasks.scan(index,root)
    return index:with_db(function(db)
        db:exec("CREATE TEMP TABLE disk(path TEXT PRIMARY KEY)")
        local add = db:prepare("INSERT OR IGNORE INTO disk VALUES(?)")
        local pending,seen = {},{}
        -- A fresh install has no default download directory until the first write.
        if root~=Tasks.directory() or lfs.symlinkattributes(root) then pending[1]=root end
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
