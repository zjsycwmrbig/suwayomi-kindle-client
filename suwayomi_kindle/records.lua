local Records = {}
local bounds = {single = "id=?", before = "pos<?", after = "pos>?"}

-- A new sequence number protects changes made while an older upload is in flight.
function Records.mark(index, manga, chapter, range, read, page)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        local where = "manga=? AND " .. assert(bounds[range])
        local bound = range == "single" and chapter.id or chapter.pos
        local value
        if read ~= nil then value = read and 1 or 0 end
        local changes = {}
        local stmt = db:prepare("SELECT id,is_read,last_page FROM chapter WHERE " .. where):bind(manga,bound)
        for row in stmt:rows() do
            if (value ~= nil and tonumber(row[2]) ~= value) or (page ~= nil and tonumber(row[3]) ~= page) then
                changes[#changes+1] = tonumber(row[1])
            end
        end
        local pending = db:prepare([[INSERT OR REPLACE INTO pending(manga,id,is_read,page)
            VALUES(?,?,COALESCE(?,(SELECT is_read FROM pending WHERE manga=? AND id=?)),
            COALESCE(?,(SELECT page FROM pending WHERE manga=? AND id=?)))]])
        local update = db:prepare("UPDATE chapter SET is_read=COALESCE(?,is_read),last_page=COALESCE(?,last_page) WHERE manga=? AND id=?")
        local finish = db:prepare("INSERT OR REPLACE INTO finished VALUES(?,?,?)")
        local cancel = db:prepare("DELETE FROM queue WHERE manga=? AND id=?")
        for _,id in ipairs(changes) do
            pending:reset():bind(manga,id,value,manga,id,page,manga,id):step()
            update:reset():bind(value,page,manga,id):step()
            if read then finish:reset():bind(manga,id,os.time()):step() end
            if read then cancel:reset():bind(manga,id):step() end
        end
        local unread = tonumber(db:prepare("SELECT count(*) FROM chapter WHERE manga=? AND is_read=0"):bind(manga):step()[1])
        db:prepare("UPDATE manga SET unread=? WHERE id=?"):bind(unread,manga):step()
        db:exec("COMMIT")
        return {changes = #changes, unread = unread}
    end)
end

function Records.log(index,message)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        db:prepare("INSERT INTO sync_log(at,message) VALUES(?,?)"):bind(os.time(),message):step()
        db:exec("DELETE FROM sync_log WHERE seq <= (SELECT max(seq)-60 FROM sync_log); COMMIT")
        return true
    end)
end

function Records.status(index,page,limit)
    return index:with_db(function(db)
        local logs = {}
        limit=limit or 1
        local log_count=tonumber(db:rowexec("SELECT count(*) FROM sync_log"))
        local pages=math.max(1,math.ceil(log_count/limit))
        page=math.min(page or 1,pages)
        for row in db:prepare("SELECT at,message FROM sync_log ORDER BY seq DESC LIMIT ? OFFSET ?"):bind(limit,(page-1)*limit):rows() do
            logs[#logs+1] = os.date("%m-%d %H:%M",tonumber(row[1])) .. "  " .. row[2]
        end
        local n,seq = db:rowexec("SELECT count(*),COALESCE(max(seq),0) FROM pending")
        return {count=tonumber(n), cutoff=tonumber(seq), logs=logs, log_count=log_count, page=page, pages=pages}
    end)
end

function Records.push(index,client,cutoff)
    local after, sent, failed = 0, 0, 0
    while true do
        local batch, err = index:with_db(function(db)
            local rows = {}
            for r in db:prepare("SELECT seq,manga,id,is_read,page FROM pending WHERE seq>? AND seq<=? ORDER BY seq LIMIT 32")
                :bind(after,cutoff):rows() do
                rows[#rows+1] = {seq=tonumber(r[1]), manga=r[2], id=tonumber(r[3]), read=tonumber(r[4]), page=tonumber(r[5])}
            end
            return rows
        end)
        if not batch then return nil,err end
        if #batch == 0 then break end
        local ids={}
        for _,r in ipairs(batch) do ids[#ids+1]=r.id end
        local owners,owner_error=client:chapterOwners(ids)
        if not owners then return nil,"章节归属查询失败 · " .. owner_error end
        for _,r in ipairs(batch) do
            after = r.seq
            local read
            if r.read ~= nil then read = r.read == 1 end
            local ok, reason
            if owners[r.id]==r.manga then ok, reason=client:updateRecord(r.id,read,r.page,r.manga)
            else reason="服务器章节已删除或已不属于这部漫画。" end
            if ok then
                ok, reason = index:with_db(function(db)
                    db:prepare("DELETE FROM pending WHERE seq=?"):bind(r.seq):step()
                    return true
                end)
            end
            if not ok then
                failed = failed+1
                Records.log(index,"上传失败 · 漫画 " .. r.manga .. " / 章节 " .. r.id .. " · " .. reason)
                if reason:find("连接") or reason:find("认证") or reason:find("超时") then
                    return nil,"已上传 " .. sent .. " 项，剩余记录已保留。" .. reason
                end
            else sent = sent+1 end
        end
    end
    return {message=string.format("上传结束 · 成功 %d 项，失败 %d 项",sent,failed)}
end

-- Freeze the worklist before network I/O. Reading this connection's temporary
-- table does not hold a read transaction on the main chapter database.
local relevant = [[ WHERE opened IS NOT NULL OR id IN (
    SELECT id FROM directories UNION SELECT manga FROM pending UNION SELECT manga FROM files
    UNION SELECT manga FROM queue UNION SELECT manga FROM policy WHERE ahead>0)]]

function Records.pull(index,client,cutoff,all_chapters)
    local shelf,err = index:refresh(function(offset,limit) return client:libraryPage(offset,limit) end)
    if not shelf then return nil,"书架拉取失败 · " .. err end
    local chapters=require("suwayomi_kindle/chapters")
    return index:with_db(function(db)
        db:exec("CREATE TEMP TABLE targets AS SELECT id,title FROM manga" .. (all_chapters and "" or relevant))
        local count,failed=0,0
        for m in db:prepare("SELECT id,title FROM targets ORDER BY id"):rows() do
            local result,reason=chapters.refresh(index,client,m[1],false,cutoff)
            if result then count=count+1 else
                failed=failed+1
                Records.log(index,"目录拉取失败 · " .. m[2] .. " · " .. reason)
                if reason:find("连接") or reason:find("认证") or reason:find("超时") then
                    error("提示：书架已拉取，已更新 " .. count .. " 部目录。" .. reason)
                end
            end
        end
        return {message=string.format("书架 %d 部 · 目录成功 %d 部，失败 %d 部，跳过 %d 部",
            shelf.count,count,failed,math.max(0,shelf.count-count-failed))}
    end)
end

return Records
