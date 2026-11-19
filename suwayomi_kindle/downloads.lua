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
    local priority = assert(({single=0,all=1,auto=2})[mode])
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local sql = [[SELECT c.id,f.path FROM chapter c LEFT JOIN files f ON c.manga=f.manga AND c.id=f.id WHERE c.manga=?]]
        local select
        if mode == "auto" then
            db:prepare("DELETE FROM queue WHERE manga=? AND priority=2 AND state='queued'"):bind(manga):step()
            select = db:prepare(sql .. " AND is_read=0 ORDER BY pos LIMIT COALESCE((SELECT ahead FROM policy WHERE manga=?),0)"):bind(manga,manga)
        elseif mode == "single" then
            select = db:prepare(sql .. " AND c.id=?"):bind(manga,id)
        else select = db:prepare(sql .. " ORDER BY pos"):bind(manga) end
        local insert = db:prepare([[INSERT INTO queue VALUES(?,?,?,'queued',NULL) ON CONFLICT(manga,id)
            DO UPDATE SET priority=min(queue.priority,excluded.priority),
            state=CASE WHEN queue.state='failed' AND excluded.priority<2 THEN 'queued' ELSE queue.state END]])
        local count=0
        for row in select:rows() do
            if not row[2] or lfs.attributes(row[2],"mode") ~= "file" then
                insert:reset():bind(manga,tonumber(row[1]),priority):step()
                count=count+1
            end
        end
        db:exec("COMMIT")
        return {count=count}
    end)
end

function Downloads.claim(index)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local row = db:prepare([[SELECT q.manga,q.id FROM queue q JOIN chapter c ON c.manga=q.manga AND c.id=q.id
            WHERE q.state='queued' ORDER BY q.priority,q.rowid LIMIT 1]]):step()
        local job
        if row then
            job = {manga=row[1],id=tonumber(row[2])}
            db:prepare("UPDATE queue SET state='active',error=NULL WHERE manga=? AND id=?"):bind(job.manga,job.id):step()
        end
        db:exec("COMMIT")
        return job or false
    end)
end

function Downloads.finish(index,job,reason)
    return index:with_db(function(db)
        if reason then
            db:prepare("UPDATE queue SET state='failed',error=? WHERE manga=? AND id=?"):bind(reason,job.manga,job.id):step()
        else
            db:prepare("DELETE FROM queue WHERE manga=? AND id=? AND state='active'"):bind(job.manga,job.id):step()
        end
        return true
    end)
end

-- Only unlink indexed CBZs in this account's managed namespace. Retain
-- KOReader sidecars and progress. Defer the current reader's file until close.
function Downloads.clean(index,manga,global,manual,open_path)
    local policy,err = Downloads.policy(index,manga)
    if not policy then return nil,err end
    local keep = manual and 0 or tonumber(policy.retention == "inherit" and global or policy.retention)
    if not keep then return {count=0,failed=0} end
    local scope = assert(index.path:match("/(%x+)%.sqlite3$"))
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local rows = {}
        for r in db:prepare([[SELECT f.id,f.path,s.bytes,s.mtime,s.inode FROM files f
            LEFT JOIN file_stamp s ON s.manga=f.manga AND s.id=f.id JOIN chapter c ON c.id=f.id AND c.manga=f.manga
            LEFT JOIN finished t ON t.id=f.id AND t.manga=f.manga WHERE f.manga=? AND c.is_read=1
            ORDER BY COALESCE(t.at,0) DESC,c.pos DESC]]):bind(manga):rows() do
            rows[#rows+1]={id=tonumber(r[1]),path=r[2],bytes=tonumber(r[3]),mtime=tonumber(r[4]),inode=r[5]}
        end
        local count,failed,kept=0,0,0
        local forget=db:prepare("DELETE FROM files WHERE manga=? AND id=? AND path=?")
        for _,r in ipairs(rows) do
            local suffix="/Suwayomi/" .. scope .. "/" .. manga .. "/" .. r.id .. ".cbz"
            local stat,_,errno=lfs.symlinkattributes(r.path)
            local mode=stat and stat.mode
            local replaced=stat and r.bytes and (r.bytes~=stat.size or r.mtime~=stat.modification or r.inode~=tostring(stat.ino))
            if not mode and errno==2 then
                forget:reset():bind(manga,r.id,r.path):step()
            elseif r.path:sub(-#suffix)~=suffix or mode~="file" or replaced then failed=failed+1
            elseif kept<keep then kept=kept+1
            elseif r.path~=open_path then
                if os.remove(r.path) then
                    forget:reset():bind(manga,r.id,r.path):step()
                    count=count+1
                else failed=failed+1 end
            end
        end
        db:prepare("DELETE FROM file_stamp WHERE manga=? AND id NOT IN (SELECT id FROM files WHERE manga=?)")
            :bind(manga,manga):step()
        db:exec("COMMIT")
        return {count=count,failed=failed}
    end)
end

return Downloads
