local lfs = require("libs/libkoreader-lfs")
local Chapters = {}

-- Replace only this manga's directory. Local files have their own table so
-- refreshing metadata or removing shelf membership preserves downloaded CBZs.
function Chapters.refresh(index, client, id, force, pull_cutoff)
    local limit = 100
    local page, err = client:chapterPage(id, 0, limit)
    if not page then return nil, err end
    if force or (page.totalCount == 0 and not pull_cutoff) then
        local fetched
        fetched, err = client:request([[mutation($id:Int!){fetchChapters(input:{mangaId:$id}){__typename}}]], {id = tonumber(id)})
        if not fetched then return nil, err end
        page, err = client:chapterPage(id, 0, limit)
        if not page then return nil, err end
    end
    return index:with_db(function(db)
        -- Stage network pages in a connection-local table. The shared database
        -- needs a write lock only for the final swap.
        db:exec([[CREATE TEMP TABLE incoming(manga TEXT,id INTEGER,pos INTEGER,name TEXT,scanlator TEXT,is_read INTEGER,last_page INTEGER)]])
        local add = db:prepare("INSERT INTO incoming VALUES(?,?,?,?,?,?,?)")
        local total, count, unread = page.totalCount, 0, 0
        while true do
            if total ~= page.totalCount or #page.nodes > limit or count + #page.nodes > total
                or page.pageInfo.hasNextPage ~= (count + #page.nodes < total)
                or (#page.nodes == 0 and count < total) then error("提示：目录已变化，请重新刷新。") end
            for _, row in ipairs(page.nodes) do
                assert(type(row.id) == "number" and type(row.isRead) == "boolean" and type(row.name) == "string")
                count = count + 1
                if not row.isRead then unread = unread + 1 end
                add:reset():bind(id,row.id,count,row.name,row.scanlator or "",row.isRead and 1 or 0,row.lastPageRead):step()
            end
            if count == total then break end
            page, err = client:chapterPage(id, count, limit)
            if not page then error("提示：" .. err) end
        end
        db:exec("BEGIN IMMEDIATE")
        db:prepare("DELETE FROM chapter WHERE manga=?"):bind(id):step()
        db:exec("INSERT INTO chapter SELECT * FROM incoming")
        db:prepare("DELETE FROM repair_match WHERE manga=? AND id NOT IN (SELECT id FROM incoming)"):bind(id):step()
        db:prepare("DELETE FROM queue WHERE manga=? AND id NOT IN (SELECT id FROM chapter WHERE manga=?) AND state<>'active'")
            :bind(id,id):step()
        if pull_cutoff then
            db:prepare("DELETE FROM pending WHERE manga=? AND seq<=?"):bind(id,pull_cutoff):step()
        end
        db:prepare([[UPDATE chapter AS c SET
            is_read=COALESCE((SELECT p.is_read FROM pending p WHERE p.manga=c.manga AND p.id=c.id),is_read),
            last_page=COALESCE((SELECT p.page FROM pending p WHERE p.manga=c.manga AND p.id=c.id),last_page)
            WHERE manga=? AND id IN (SELECT id FROM pending WHERE manga=?)]]):bind(id,id):step()
        unread = tonumber(db:prepare("SELECT count(*) FROM chapter WHERE manga=? AND is_read=0"):bind(id):step()[1])
        db:prepare("INSERT OR REPLACE INTO directories VALUES(?,?)"):bind(id,count):step()
        db:prepare("UPDATE manga SET chapters=?,unread=? WHERE id=?"):bind(count,unread,id):step()
        db:exec("COMMIT")
        return {count = count, unread = unread}
    end)
end

local columns = [[SELECT c.id,c.pos,c.name,c.scanlator,c.is_read,f.path,
    CASE WHEN q.state='queued' AND (SELECT paused FROM queue_control)=1 THEN 'paused' ELSE q.state END,q.error,p.count FROM chapter c
    LEFT JOIN queue q ON c.manga=q.manga AND c.id=q.id
    LEFT JOIN missing_pages p ON c.manga=p.manga AND c.id=p.id
    LEFT JOIN files f ON c.manga=f.manga AND c.id=f.id WHERE c.manga=? ]]

local function chapter(row)
    local path = row[6]
    return {id = tonumber(row[1]), pos = tonumber(row[2]), name = row[3], scanlator = row[4],
        state = row[7], error = row[8], missing_pages=tonumber(row[9]), read = tonumber(row[5]) == 1, path = path and lfs.attributes(path,"mode") == "file" and path or nil}
end

function Chapters.page(index, id, page, limit, unread_only)
    return index:with_db(function(db)
        db:exec("BEGIN")
        local dir = db:prepare("SELECT count FROM directories WHERE id=?"):bind(id):step()
        local count = dir and tonumber(dir[1]) or 0
        if unread_only then
            count = tonumber(db:prepare("SELECT count(*) FROM chapter WHERE manga=? AND is_read=0"):bind(id):step()[1])
        end
        local pages = math.max(1,math.ceil(count/limit))
        page = math.max(1,math.min(page,pages))
        local items = {}
        local stmt
        if unread_only then
            stmt = db:prepare(columns .. "AND c.is_read=0 ORDER BY c.pos LIMIT ? OFFSET ?"):bind(id,limit,(page-1)*limit)
        else
            stmt = db:prepare(columns .. "AND c.pos>? ORDER BY c.pos LIMIT ?"):bind(id,(page-1)*limit,limit)
        end
        for row in stmt:rows() do
            items[#items+1] = chapter(row)
        end
        return {page = page, pages = pages, count = count, cached = dir ~= nil, items = items}
    end)
end

function Chapters.locate(index,manga,id,offset)
    return index:with_db(function(db)
        local row = db:prepare(columns .. "AND c.pos=(SELECT pos FROM chapter WHERE manga=? AND id=?)+?")
            :bind(manga,manga,id,offset or 0):step()
        return row and chapter(row) or false
    end)
end

function Chapters.nextUnread(index,id)
    return index:with_db(function(db)
        local row = db:prepare(columns .. "AND c.is_read=0 ORDER BY c.pos LIMIT 1"):bind(id):step()
        return row and chapter(row) or false
    end)
end

function Chapters.setRead(index, manga, id, read)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        db:prepare("UPDATE chapter SET is_read=? WHERE manga=? AND id=?"):bind(read and 1 or 0,manga,id):step()
        local n = tonumber(db:prepare("SELECT count(*) FROM chapter WHERE manga=? AND is_read=0"):bind(manga):step()[1])
        db:prepare("UPDATE manga SET unread=? WHERE id=?"):bind(n,manga):step()
        db:exec("COMMIT")
        return {unread = n}
    end)
end

function Chapters.description(index,id)
    return index:with_db(function(db)
        local row = db:prepare("SELECT description FROM metadata WHERE id=?"):bind(id):step()
        return row and row[1]
    end)
end

function Chapters.saveDescription(index,item)
    return index:with_db(function(db)
        db:prepare("INSERT OR REPLACE INTO metadata VALUES(?,?)"):bind(item.id,item.description):step()
        return true
    end)
end

local function image_type(bytes)
    if not bytes then return end
    if bytes:sub(1,3) == "\255\216\255" then return "jpg" end
    if bytes:sub(1,8) == "\137PNG\r\n\26\n" then return "png" end
    if bytes:sub(1,3) == "GIF" then return "gif" end
    if bytes:sub(1,4) == "RIFF" and bytes:sub(9,12) == "WEBP" then return "webp" end
    if bytes:sub(5,12) == "ftypavif" then return "avif" end
end

local module_dir = debug.getinfo(1,"S").source:sub(2):match("^(.*)/suwayomi_kindle/chapters%.lua$") or "."
local placeholders = {}
local function placeholder(page)
    local index = (page - 1) % 3 + 1
    if not placeholders[index] then
        local file = assert(io.open(module_dir.."/resources/missing-page-"..index..".png", "rb"))
        local bytes = file:read("*a")
        file:close()
        assert(image_type(bytes)=="png")
        placeholders[index] = bytes
    end
    return placeholders[index]
end

function Chapters.downloadPath(index,input)
    local scope = assert(index.path:match("/(%x+)%.sqlite3$"))
    return input.directory .. "/Suwayomi/" .. scope .. "/" .. tostring(assert(tonumber(input.manga)))
        .. "/" .. tostring(assert(tonumber(input.id))) .. ".cbz"
end

function Chapters.pages(client,manga,id)
    local data,err=client:request([[mutation($id:Int!){fetchChapterPages(input:{chapterId:$id}){
        pages chapter{id manga{id}}}}]],{id=id})
    local result=data and data.fetchChapterPages
    if not result or not result.chapter or result.chapter.id~=id or not result.chapter.manga
        or tostring(result.chapter.manga.id)~=manga or type(result.pages)~="table" or #result.pages==0 then
        return nil,err or "没有可下载的漫画页。"
    end
    return result.pages
end

function Chapters.download(index, client, input)
    local id, manga = assert(tonumber(input.id)), tostring(assert(tonumber(input.manga)))
    local pages,err
    if input.match and input.match.pages then pages=input.match.pages
    else pages,err=Chapters.pages(client,input.remote_manga or manga,input.remote_id or id) end
    if not pages then return nil,err,"source" end
    local path = Chapters.downloadPath(index,input)
    require("util").makePath(path:match("^(.*)/"))
    local tmp = path .. "." .. require("ffi").C.getpid() .. ".part"
    local writer = require("ffi/archiver").Writer:new()
    if not writer:open(tmp, "zip") then return nil, "无法创建章节文件，请检查下载目录。" end
    writer:setZipCompression("store")
    local missing, done = {}, 0
    local page_error
    -- Publish only completed CBZ entries. A superseded worker cannot update its replacement.
    local last_report
    local function report(done, force)
        if not input.ticket then return end
        local now = os.time()
        if not force and now == last_report then return end
        last_report = now
        index:with_db(function(db)
            db:prepare([[UPDATE queue SET pages_done=?, pages_total=?
                WHERE manga=? AND id=? AND state='active' AND ticket=?]])
                :bind(done,#pages,manga,id,input.ticket):step()
            return true
        end)
    end
    report(0,true)
    -- CBZ pages sort by filename; a recovered page keeps its original position.
    local function fetch(i)
        local bytes, reason = client:pageImage(pages[i])
        local ext = image_type(bytes)
        if not ext then
            missing[#missing+1] = i
            page_error = reason or "图片获取失败或格式无效。"
            return
        end
        assert(writer:addFileFromMemory(string.format("%05d.%s",i,ext),bytes))
        done = done+1
        report(done,done==1 or done==#pages)
    end
    local ok = pcall(function()
        for i=1,#pages do fetch(i) end
        local retries = math.min(require("suwayomi_kindle/settings_store").max_retries, input.page_retries or 2)
        for attempt=1,retries do
            if #missing==0 then break end
            local retry = missing
            missing = {}
            for _,i in ipairs(retry) do fetch(i) end
        end
        if #missing>0 and done>0 and input.allow_missing_pages then
            for _,i in ipairs(missing) do
                assert(writer:addFileFromMemory(string.format("%05d.png",i),placeholder(i)))
            end
        end
    end)
    writer:close()
    if not ok then
        os.remove(tmp)
        return nil,"章节图片处理或写入失败，请检查剩余空间。"
    end
    if #missing>0 and (done==0 or not input.allow_missing_pages) then
        os.remove(tmp)
        return nil,string.format("缺 %d 页（第 %d 页等）· %s",#missing,missing[1],page_error),"missing_pages"
    end
    -- Reopen the completed archive before publishing it, including its last page.
    local reader = require("ffi/archiver").Reader:new()
    local count = 0
    if ok and reader:open(tmp) then
        for entry in reader:iterate() do if entry.size > 0 then count = count + 1 end end
        ok = not reader.err
        reader:close()
    end
    if not ok or count ~= #pages then
        os.remove(tmp)
        return nil,"章节文件校验或保存失败，请检查剩余空间。"
    end
    local saved,save_error=index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        if not db:prepare("SELECT 1 FROM chapter WHERE manga=? AND id=?"):bind(manga,id):step() then
            error("提示：该章节已从目录移除。")
        end
        if input.ticket and not db:prepare("SELECT 1 FROM queue WHERE manga=? AND id=? AND ticket=? AND state='active'")
            :bind(manga,id,input.ticket):step() then error("提示：下载任务已暂停。") end
        if input.remote_id and not db:prepare("SELECT 1 FROM manga WHERE id=?"):bind(manga):step() then
            error("提示：漫画已移出书架。")
        end
        if not os.rename(tmp,path) then error("提示：无法保存 CBZ，请检查下载目录和剩余空间。") end
        local stat=assert(lfs.attributes(path))
        db:prepare("INSERT OR REPLACE INTO file_stamp VALUES(?,?,?,?,?)")
            :bind(manga,id,stat.size,stat.modification,tostring(stat.ino)):step()
        db:prepare("INSERT OR REPLACE INTO files VALUES(?,?,?)"):bind(manga,id,path):step()
        if #missing>0 then
            db:prepare("INSERT OR REPLACE INTO missing_pages VALUES(?,?,?)"):bind(manga,id,#missing):step()
        else
            db:prepare("DELETE FROM missing_pages WHERE manga=? AND id=?"):bind(manga,id):step()
        end
        if input.match then
            local match=input.match
            db:prepare("INSERT OR REPLACE INTO repair_match VALUES(?,?,?,?,?,?,?)")
                :bind(manga,id,match.original_name,match.manga,match.id,match.name,match.title):step()
        end
        db:prepare("DELETE FROM queue WHERE manga=? AND id=?"):bind(manga,id):step()
        db:exec("COMMIT")
        return {path = path, missing_pages = #missing}
    end)
    if not saved then os.remove(tmp) end
    return saved,save_error
end

return Chapters
