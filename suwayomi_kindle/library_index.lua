-- Only manga summaries live here. SQLite readers see the previous complete
-- snapshot until the writer validates and commits the last server page.
local Storage = require("datastorage")
local SQLite = require("lua-ljsqlite3/init")
local sha256 = require("ffi/sha2").sha256
local Config = require("suwayomi_kindle/config")
local Index = {}
Index.__index = Index

function Index.new(config, root)
    root = root or Storage:getDataDir() .. "/suwayomi_kindle/library"
    require("util").makePath(root)
    local key = table.concat({assert(Config.normalize_server_url(config.server_url)), config.auth_method,
        config.auth_method ~= "none" and config.username or ""}, "\0")
    return setmetatable({path = root .. "/" .. sha256(key) .. ".sqlite3"}, Index)
end

local function with_db(index, action)
    local opened, db = pcall(SQLite.open, index.path)
    if not opened then return nil, "无法打开本地漫画索引。" end
    local ok, result = pcall(function()
        db:set_busy_timeout(300)
        if tonumber(db:rowexec("PRAGMA user_version")) < 7 then
            db:exec("PRAGMA journal_mode=WAL; BEGIN IMMEDIATE")
            local version = tonumber(db:rowexec("PRAGMA user_version"))
            if version == 0 then
                db:exec([[CREATE TABLE manga(id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT,
                        source TEXT, thumbnail TEXT, chapters INTEGER, unread INTEGER);
                    CREATE INDEX title_idx ON manga(title COLLATE NOCASE, id);
                    CREATE TABLE shelf(count INTEGER, synced INTEGER);
                    INSERT INTO shelf VALUES(0, 0)]])
            elseif version == 1 then
                db:exec([[ALTER TABLE manga ADD COLUMN chapters INTEGER;
                    ALTER TABLE manga ADD COLUMN unread INTEGER; UPDATE shelf SET synced=0]])
            end
            db:exec([[CREATE TABLE IF NOT EXISTS pins(id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS metadata(id TEXT PRIMARY KEY, description TEXT);
                CREATE TABLE IF NOT EXISTS directories(id TEXT PRIMARY KEY, count INTEGER);
                CREATE TABLE IF NOT EXISTS chapter(manga TEXT, id INTEGER, pos INTEGER, name TEXT,
                    scanlator TEXT, is_read INTEGER, PRIMARY KEY(manga,id), UNIQUE(manga,pos));
                CREATE INDEX IF NOT EXISTS unread_pos ON chapter(manga,is_read,pos);
                CREATE TABLE IF NOT EXISTS files(manga TEXT,id INTEGER,path TEXT,PRIMARY KEY(manga,id));
                CREATE INDEX IF NOT EXISTS files_path ON files(path);]])
            if version < 4 then
                db:exec([[ALTER TABLE chapter ADD COLUMN last_page INTEGER;
                    CREATE TABLE pending(seq INTEGER PRIMARY KEY AUTOINCREMENT,manga TEXT,id INTEGER,
                        is_read INTEGER,page INTEGER,UNIQUE(manga,id));
                    CREATE TABLE policy(manga TEXT PRIMARY KEY,ahead INTEGER DEFAULT 0,retention TEXT DEFAULT 'inherit');
                    CREATE TABLE queue(manga TEXT,id INTEGER,priority INTEGER,state TEXT,error TEXT,PRIMARY KEY(manga,id));
                    CREATE INDEX queue_state ON queue(state,priority,id);
                    CREATE TABLE file_stamp(manga TEXT,id INTEGER,bytes INTEGER,mtime INTEGER,inode TEXT,PRIMARY KEY(manga,id));
                    CREATE TABLE finished(manga TEXT,id INTEGER,at INTEGER,PRIMARY KEY(manga,id));
                    CREATE TABLE sync_log(seq INTEGER PRIMARY KEY,at INTEGER,message TEXT);]])
            end
            if version < 5 then
                db:exec([[ALTER TABLE queue ADD COLUMN ticket INTEGER;
                    CREATE INDEX queue_display ON queue(
                        CASE state WHEN 'active' THEN 0 WHEN 'queued' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END,priority);
                    CREATE TABLE queue_control(paused INTEGER, serial INTEGER);
                    INSERT INTO queue_control VALUES(0,0);
                    CREATE TABLE orphan(path TEXT PRIMARY KEY,reason TEXT NOT NULL);
                    CREATE TABLE scan_status(at INTEGER);]])
            end
            if version < 6 then
                db:exec([[ALTER TABLE queue ADD COLUMN pages_done INTEGER;
                    ALTER TABLE queue ADD COLUMN pages_total INTEGER;]])
            end
            if version < 7 then
                db:exec([[ALTER TABLE manga ADD COLUMN added INTEGER;
                    ALTER TABLE manga ADD COLUMN opened INTEGER;
                    CREATE INDEX shelf_added ON manga(added DESC,title COLLATE NOCASE,id);
                    CREATE INDEX shelf_opened ON manga(opened DESC,title COLLATE NOCASE,id);
                    CREATE INDEX shelf_unread ON manga(unread DESC,title COLLATE NOCASE,id);
                    CREATE INDEX shelf_chapters ON manga(chapters DESC,title COLLATE NOCASE,id);
                    UPDATE shelf SET synced=0;]])
            end
            db:exec("PRAGMA user_version=7; COMMIT")
        end
        return action(db)
    end)
    -- Closing rolls back an incomplete transaction and finalizes its statements.
    db:close()
    if not ok then return nil, tostring(result):match("提示：(.*)") or "本地漫画索引读写失败。" end
    return result
end

local function insert(stmt, item)
    stmt:reset():bind(item.id, item.title, item.author, item.source, item.thumbnail, item.chapters, item.unread, item.added):step()
end

function Index:refresh(fetch, limit)
    limit = limit or 64
    return with_db(self, function(db)
        db:exec("CREATE TEMP TABLE incoming AS SELECT * FROM manga LIMIT 0")
        local stmt = db:prepare("INSERT INTO incoming VALUES(?,?,?,?,?,?,?,?,NULL)")
        local offset, total = 0, nil
        repeat
            local page, err = fetch(offset, limit)
            if not page then error("提示：" .. err) end
            local n = #page.rows
            local next_offset = offset + n
            if (total and page.total ~= total) or page.total < next_offset or n > limit
                or page.more ~= (next_offset < page.total) or (page.more and n == 0) then
                error("提示：书架分页不一致，请重新拉取。")
            end
            total = page.total
            for _, item in ipairs(page.rows) do insert(stmt, item) end
            offset = next_offset
        until offset == total
        db:exec([[BEGIN IMMEDIATE;
            UPDATE incoming SET opened=(SELECT opened FROM manga WHERE manga.id=incoming.id);
            DELETE FROM manga; INSERT INTO manga SELECT * FROM incoming]])
        db:exec([[UPDATE manga SET unread=(SELECT count(*) FROM chapter c WHERE c.manga=manga.id AND is_read=0)
            WHERE id IN (SELECT DISTINCT manga FROM pending) AND id IN (SELECT id FROM directories)]])
        db:prepare("UPDATE shelf SET count=?, synced=?"):bind(total, os.time()):step()
        db:exec("COMMIT")
        return {count = total}
    end)
end

function Index:upsert(item)
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        local known = db:prepare("SELECT 1 FROM manga WHERE id=?"):bind(item.id):step()
        insert(db:prepare([[INSERT INTO manga(id,title,author,source,thumbnail,chapters,unread,added)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,
            author=excluded.author,source=excluded.source,thumbnail=excluded.thumbnail,
            chapters=excluded.chapters,unread=excluded.unread,added=coalesce(excluded.added,manga.added)]]), item)
        if not known then db:exec("UPDATE shelf SET count=count+1") end
        db:exec("COMMIT")
        return true
    end)
end

function Index:markOpened(id)
    return with_db(self,function(db)
        local millis = math.floor(require("socket").gettime()*1000)
        db:prepare("UPDATE manga SET opened=? WHERE id=?"):bind(millis,id):step()
        return true
    end)
end

local orders = {title="",opened="opened DESC,",added="added DESC,",unread="unread DESC,",chapters="chapters DESC,"}

function Index:page(page, limit, sort, search)
    return with_db(self, function(db)
        db:exec("BEGIN")
        local count, synced = db:rowexec("SELECT count,synced FROM shelf")
        count, synced = tonumber(count), tonumber(synced)
        local where,args="",{}
        if search and search~="" then
            where=" WHERE instr(lower(title),lower(?))>0 OR instr(lower(author),lower(?))>0"
            args={search,search}
            count=tonumber(db:prepare("SELECT count(*) FROM manga" .. where):bind(unpack(args)):step()[1])
        end
        page = math.max(1, math.min(page, math.ceil(count / limit)))
        args[#args+1],args[#args+2]=limit,(page-1)*limit
        local stmt = db:prepare([[SELECT id,title,author,source,thumbnail,chapters,unread,
            (SELECT count(*) FROM files WHERE files.manga=manga.id) FROM manga]] .. where ..
            " ORDER BY " .. (orders[sort] or "") .. "title COLLATE NOCASE,id LIMIT ? OFFSET ?"):bind(unpack(args))
        local items = {}
        for r in stmt:rows() do
            items[#items + 1] = {id = r[1], title = r[2], author = r[3], source = r[4],
                thumbnail = r[5], chapters = tonumber(r[6]), unread = tonumber(r[7]), downloaded = tonumber(r[8]), in_library = true}
        end
        return {count = count, synced = synced, page = page, items = items}
    end)
end

Index.with_db = with_db

function Index:remove(id)
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        db:prepare("DELETE FROM manga WHERE id=?"):bind(id):step()
        db:exec("UPDATE shelf SET count=(SELECT count(*) FROM manga); COMMIT")
        return true
    end)
end

function Index:pins()
    return with_db(self, function(db)
        local result = {}
        for row in db:prepare("SELECT id FROM pins"):rows() do result[row[1]] = true end
        return result
    end)
end

function Index:setPinned(id, pinned)
    return with_db(self, function(db)
        db:prepare(pinned and "INSERT OR IGNORE INTO pins VALUES(?)" or "DELETE FROM pins WHERE id=?"):bind(id):step()
        return true
    end)
end

return Index
