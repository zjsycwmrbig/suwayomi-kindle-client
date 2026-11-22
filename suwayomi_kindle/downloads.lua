local lfs = require("libs/libkoreader-lfs")
local Downloads = {}
local retention = {inherit=true, never=true, ["0"]=true, ["1"]=true, ["3"]=true, ["5"]=true, ["10"]=true}

function Downloads.policy(index,manga)
    return index:with_db(function(db)
        local r = db:prepare("SELECT ahead,retention FROM policy WHERE manga=?"):bind(manga):step()
        return {ahead=r and tonumber(r[1]) or 0, retention=r and r[2] or "inherit"}
    end)
end

function Downloads.configure(index,manga,key,value)
    assert(key == "ahead" and (value == 0 or value == 1 or value == 3 or value == 5)
        or key == "retention" and retention[value])
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        db:prepare("INSERT OR IGNORE INTO policy(manga) VALUES(?)"):bind(manga):step()
        db:prepare("UPDATE policy SET " .. key .. "=? WHERE manga=?"):bind(value,manga):step()
        db:exec("COMMIT")
        return true
    end)
end

-- An automatic window counts already cached chapters toward its size.
function Downloads.enqueue(index,manga,mode,id)
    local priority = assert(({single=0,all=1,auto=2,next_auto=2})[mode])
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local sql = [[SELECT c.id,f.path FROM chapter c LEFT JOIN files f ON c.manga=f.manga AND c.id=f.id WHERE c.manga=?]]
        local select
        if mode == "auto" then
            db:prepare("DELETE FROM queue WHERE manga=? AND priority=2 AND state='queued' AND retries=0 AND repair=''"):bind(manga):step()
            select = db:prepare(sql .. [[ AND is_read=0 AND NOT EXISTS
                (SELECT 1 FROM auto_download_excluded e WHERE e.manga=c.manga AND e.id=c.id)
                ORDER BY pos LIMIT COALESCE((SELECT ahead FROM policy WHERE manga=?),0)]]):bind(manga,manga)
        elseif mode == "single" or mode == "next_auto" then
            select = db:prepare(sql .. " AND c.id=?"):bind(manga,id)
        else select = db:prepare(sql .. " ORDER BY pos"):bind(manga) end
        local insert = db:prepare([[INSERT INTO queue(manga,id,priority,state,error) VALUES(?,?,?,'queued',NULL) ON CONFLICT(manga,id)
            DO UPDATE SET priority=min(queue.priority,excluded.priority),
            state=CASE WHEN queue.state='failed' AND excluded.priority<2 THEN 'queued' ELSE queue.state END]])
        local count=0
        local include = priority < 2 and db:prepare("DELETE FROM auto_download_excluded WHERE manga=? AND id=?")
        for row in select:rows() do
            if include then include:reset():bind(manga,tonumber(row[1])):step() end
            if not row[2] or lfs.attributes(row[2],"mode") ~= "file" then
                insert:reset():bind(manga,tonumber(row[1]),priority):step()
                count=count+1
            end
        end
        db:exec("COMMIT")
        return {count=count}
    end)
end

-- Put one chapter directly into the source-repair path. The original source
-- is skipped, while the chapter's reading record and local metadata remain.
function Downloads.enqueueRepair(index,manga,id)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local active=db:prepare("SELECT 1 FROM queue WHERE manga=? AND id=? AND state='active'")
            :bind(manga,id):step()
        if active then db:exec("ROLLBACK"); return nil,"该章节正在下载，请先暂停任务。" end
        db:prepare([[INSERT INTO queue(manga,id,priority,state,error,repair,retries,retry_at)
            VALUES(?,?,0,'queued',NULL,'ready',0,0)
            ON CONFLICT(manga,id) DO UPDATE SET priority=0,state='queued',error=NULL,
                repair='ready',retries=0,retry_at=0]]):bind(manga,id):step()
        db:exec("COMMIT")
        return true
    end)
end

function Downloads.claim(index,directory)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local row = db:prepare([[SELECT q.manga,q.id,q.repair FROM queue q JOIN chapter c ON c.manga=q.manga AND c.id=q.id
            WHERE q.state='queued' AND q.retry_at<=strftime('%s','now') AND
                (q.repair<>'ready' OR NOT EXISTS(SELECT 1 FROM queue WHERE state='active' AND repair='ready'))
                AND (SELECT paused FROM queue_control)=0 ORDER BY q.priority,q.rowid LIMIT 1]]):step()
        local job
        if row then
            db:exec("UPDATE queue_control SET serial=serial+1")
            job = {repair=row[3]=="ready",manga=row[1],id=tonumber(row[2]),ticket=tonumber(db:rowexec("SELECT serial FROM queue_control")),directory=directory}
            local path = directory and require("suwayomi_kindle/chapters").downloadPath(index,job) or nil
            db:prepare([[UPDATE queue SET state='active',retry_at=0,error=NULL,pages_done=NULL,pages_total=NULL,
                ticket=?,target_path=coalesce(?,target_path) WHERE manga=? AND id=?]]):bind(job.ticket,path,job.manga,job.id):step()
        end
        db:exec("COMMIT")
        return job or false
    end)
end

-- A ticket identifies one attempt, including the confirmation shown to the user.
function Downloads.sourceFailure(index,job,settings,reason,pages_exhausted)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local row=db:prepare([[SELECT q.retries,q.priority,m.title,c.name FROM queue q
            JOIN manga m ON m.id=q.manga JOIN chapter c ON c.manga=q.manga AND c.id=q.id
            WHERE q.manga=? AND q.id=? AND q.ticket=? AND q.state='active']])
            :bind(job.manga,job.id,job.ticket):step()
        local state={action="failed"}
        if row then
            local retries,priority=tonumber(row[1]),tonumber(row[2])
            if not pages_exhausted and retries<math.min(require("suwayomi_kindle/settings_store").max_retries,settings.retries or 2) then
                db:prepare([[UPDATE queue SET state='queued', retries=retries+1,retry_at=?,error=? WHERE ticket=?]])
                    :bind(os.time()+math.min(60,2^retries),reason,job.ticket):step()
                state.action="retry"
            elseif priority==0 then
                db:prepare("UPDATE queue SET state='failed',repair='ask',error=? WHERE ticket=?"):bind(reason,job.ticket):step()
                state={action="ask",title=row[3],name=row[4],attempts=not pages_exhausted and retries+1 or nil}
            elseif (priority==1 and settings.repair_batch) or (priority==2 and settings.repair_auto) then
                db:prepare("UPDATE queue SET state='queued',repair='ready',retry_at=0,error=? WHERE ticket=?"):bind(reason,job.ticket):step()
                state.action="repair"
            end
        end
        db:exec("COMMIT")
        return state
    end)
end

function Downloads.confirmRepair(index,job,accept)
    return index:with_db(function(db)
        local state,phase=accept and "queued" or "failed",accept and "ready" or ""
        db:prepare([[UPDATE queue SET state=?,repair=?,retry_at=0 WHERE manga=? AND id=?
            AND ticket=? AND state='failed' AND repair='ask' AND manga IN (SELECT id FROM manga)]])
            :bind(state,phase,job.manga,job.id,job.ticket):step()
        return tonumber(db:rowexec("SELECT changes()"))==1
    end)
end

function Downloads.nextRetry(index)
    return index:with_db(function(db)
        return tonumber((db:rowexec([[SELECT min(retry_at) FROM queue WHERE state='queued'
            AND retry_at>0 AND (SELECT paused FROM queue_control)=0]])))
    end)
end

function Downloads.finish(index,job,reason)
    return index:with_db(function(db)
        if reason then
            db:prepare("UPDATE queue SET state='failed',error=? WHERE manga=? AND id=? AND state='active' AND ticket=?"):bind(reason,job.manga,job.id,job.ticket):step()
        else
            db:prepare("DELETE FROM queue WHERE manga=? AND id=? AND state='active' AND ticket=?"):bind(job.manga,job.id,job.ticket):step()
        end
        return true
    end)
end

-- Only unlink indexed CBZs in this account's managed namespace. Retain
-- KOReader sidecars and progress. Defer the current reader's file until close.
function Downloads.clean(index,manga,global,manual,open_path,destination)
    local policy,err = Downloads.policy(index,manga)
    if not policy then return nil,err end
    local keep = manual and 0 or tonumber(policy.retention == "inherit" and global or policy.retention)
    if not keep then return {count=0,failed=0,kept=0,missing=0,scanned=0,retention="never"} end
    local scope = assert(index.path:match("/(%x+)%.sqlite3$"))
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local rows = {}
        for r in db:prepare([[SELECT f.id,f.path,s.bytes,s.mtime FROM files f
            LEFT JOIN file_stamp s ON s.manga=f.manga AND s.id=f.id JOIN chapter c ON c.id=f.id AND c.manga=f.manga
            LEFT JOIN finished t ON t.id=f.id AND t.manga=f.manga WHERE f.manga=? AND c.is_read=1
            ORDER BY COALESCE(t.at,0) DESC,c.pos DESC]]):bind(manga):rows() do
            rows[#rows+1]={id=tonumber(r[1]),path=r[2],bytes=tonumber(r[3]),mtime=tonumber(r[4])}
        end
        local count,failed,kept,missing=0,0,0,0
        local forget=db:prepare("DELETE FROM files WHERE manga=? AND id=? AND path=?")
        local forget_queue=db:prepare("DELETE FROM queue WHERE manga=? AND id=?")
        for _,r in ipairs(rows) do
            local suffix="/Suwayomi/" .. scope .. "/" .. manga .. "/" .. r.id .. ".cbz"
            local stat,_,errno=lfs.symlinkattributes(r.path)
            local mode=stat and stat.mode
            -- Kindle's FUSE mount may reassign inode numbers after a reboot.
            -- Size and mtime remain stable for untouched managed archives.
            local replaced=stat and r.bytes and (r.bytes~=stat.size or r.mtime~=stat.modification)
            if not mode and errno==2 then
                forget:reset():bind(manga,r.id,r.path):step()
                missing=missing+1
            elseif r.path:sub(-#suffix)~=suffix or mode~="file" or replaced then failed=failed+1
            elseif kept<keep then kept=kept+1
            elseif r.path==open_path or r.path==destination then kept=kept+1
            elseif r.path~=open_path and r.path~=destination then
                if os.remove(r.path) then
                    forget:reset():bind(manga,r.id,r.path):step()
                    forget_queue:reset():bind(manga,r.id):step()
                    count=count+1
                else failed=failed+1 end
            end
        end
        db:prepare("DELETE FROM file_stamp WHERE manga=? AND id NOT IN (SELECT id FROM files WHERE manga=?)")
            :bind(manga,manga):step()
        db:exec("COMMIT")
        return {count=count,failed=failed,kept=kept,missing=missing,scanned=#rows,retention=policy.retention}
    end)
end

function Downloads.summary(result)
    if not result then return "删除失败。" end
    if result.scanned==0 then return "没有可删除的已读下载。" end
    if result.retention=="never" then return "当前删除策略为“不删除”。" end
    local parts={string.format("已删除 %d 章",result.count)}
    if result.failed>0 then parts[#parts+1]=string.format("失败 %d 章",result.failed) end
    if result.kept>0 then parts[#parts+1]=string.format("保留 %d 章（含当前阅读）",result.kept) end
    if result.missing>0 then parts[#parts+1]=string.format("清理失效记录 %d 条",result.missing) end
    return table.concat(parts,"；")
end

return Downloads
