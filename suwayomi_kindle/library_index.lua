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
        db:set_busy_timeout(1000)
        if tonumber(db:rowexec("PRAGMA user_version")) < 17 then
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
            if version < 8 then
                db:exec([[CREATE TABLE source_opened(id TEXT PRIMARY KEY, opened INTEGER NOT NULL)]])
            end
            if version < 9 then
                db:exec([[ALTER TABLE queue ADD COLUMN target_path TEXT;
                    CREATE TABLE auto_download_excluded(manga TEXT,id INTEGER,PRIMARY KEY(manga,id))]])
            end
            if version < 10 then
                db:exec("ALTER TABLE manga ADD COLUMN status TEXT; UPDATE shelf SET synced=0")
            end
            if version < 11 then
                db:exec([[ALTER TABLE pins ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;
                    UPDATE pins SET priority=(SELECT count(*) FROM pins AS earlier WHERE earlier.rowid<=pins.rowid);
                    UPDATE pins SET priority=priority+1;
                    CREATE TABLE manga_recommendations(manga TEXT PRIMARY KEY, data TEXT NOT NULL)]])
            end
            if version < 12 then
                local has_legacy = db:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_default'")
                local default_id = has_legacy and db:rowexec("SELECT id FROM source_default WHERE id IS NOT NULL LIMIT 1")
                if default_id then
                    db:exec("UPDATE pins SET priority=priority+1")
                    db:prepare("INSERT OR REPLACE INTO pins(id,priority) VALUES(?,1)"):bind(default_id):step()
                end
                db:exec("DROP TABLE IF EXISTS anilist_bindings; DROP TABLE IF EXISTS source_default")
            end
            if version < 13 then
                db:exec("ALTER TABLE manga ADD COLUMN anilist_id INTEGER")
            end
            if version < 14 then
                db:exec([[ALTER TABLE queue ADD COLUMN retries INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE queue ADD COLUMN retry_at INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE queue ADD COLUMN repair TEXT NOT NULL DEFAULT '';
                    CREATE TABLE repair_cache(id TEXT PRIMARY KEY,expires INTEGER NOT NULL,data TEXT NOT NULL)]])
                db:prepare([[CREATE TRIGGER restart_failed AFTER UPDATE OF state ON queue
                    WHEN OLD.state='failed' AND NEW.state='queued' AND NEW.repair=OLD.repair
                    BEGIN UPDATE queue SET repair='',retries=0,retry_at=0 WHERE manga=NEW.manga AND id=NEW.id; END]]):step()
            end
            if version < 15 then
                db:exec([[CREATE TABLE IF NOT EXISTS repair_match(manga TEXT,id INTEGER,original_name TEXT,
                    remote_manga TEXT,remote_id INTEGER,remote_name TEXT,remote_title TEXT,PRIMARY KEY(manga,id))]])
                db:prepare([[CREATE TRIGGER IF NOT EXISTS remove_repair_match AFTER DELETE ON manga
                    BEGIN DELETE FROM repair_match WHERE manga=OLD.id; END]]):step()
            end
            if version < 16 then
                db:exec("CREATE TABLE repair_log(seq INTEGER PRIMARY KEY, at INTEGER NOT NULL, chapter TEXT NOT NULL, message TEXT NOT NULL)")
            end
            if version < 17 then
                db:exec("CREATE TABLE missing_pages(manga TEXT,id INTEGER,count INTEGER NOT NULL,PRIMARY KEY(manga,id))")
                db:prepare([[CREATE TRIGGER remove_missing_pages AFTER DELETE ON files
                    BEGIN DELETE FROM missing_pages WHERE manga=OLD.manga AND id=OLD.id; END]]):step()
            end
            db:exec("PRAGMA user_version=17; COMMIT")
        end
        return action(db)
    end)
    -- Closing rolls back an incomplete transaction and finalizes its statements.
    db:close()
    if not ok then return nil, tostring(result):match("提示：(.*)") or "本地漫画索引读写失败。" end
    return result
end

local function insert(stmt, item)
    stmt:reset():bind(item.id, item.title, item.author, item.source, item.thumbnail, item.chapters, item.unread, item.added,
        item.status,item.anilist_id):step()
end

function Index:refresh(fetch, limit)
    limit = limit or 64
    return with_db(self, function(db)
        db:exec([[CREATE TEMP TABLE incoming(id TEXT PRIMARY KEY,title TEXT NOT NULL,author TEXT,
            source TEXT,thumbnail TEXT,chapters INTEGER,unread INTEGER,added INTEGER,status TEXT,anilist_id INTEGER) WITHOUT ROWID]])
        local stmt = db:prepare("INSERT INTO incoming VALUES(?,?,?,?,?,?,?,?,?,?)")
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
            db:exec("BEGIN")
            for _, item in ipairs(page.rows) do insert(stmt, item) end
            db:exec("COMMIT")
            offset = next_offset
        until offset == total
        -- Resolve pending reads against the current local directory under the same
        -- write lock as publication. No shelf row is replaced just to preserve opened.
        db:exec([[BEGIN IMMEDIATE;
            UPDATE incoming SET unread=(SELECT count(*) FROM chapter c WHERE c.manga=incoming.id AND is_read=0)
                WHERE id IN (SELECT manga FROM pending) AND id IN (SELECT id FROM directories);
            DELETE FROM manga WHERE id NOT IN (SELECT id FROM incoming);
            INSERT INTO manga(id,title,author,source,thumbnail,chapters,unread,added,status,anilist_id)
                SELECT * FROM incoming WHERE true
                ON CONFLICT(id) DO UPDATE SET
                    (title,author,source,thumbnail,chapters,unread,added,status)=
                    (excluded.title,excluded.author,excluded.source,excluded.thumbnail,excluded.chapters,excluded.unread,excluded.added,excluded.status),
                    anilist_id=coalesce(excluded.anilist_id,manga.anilist_id)
                WHERE (title,author,source,thumbnail,chapters,unread,added,status,anilist_id) IS NOT
                    (excluded.title,excluded.author,excluded.source,excluded.thumbnail,excluded.chapters,
                    excluded.unread,excluded.added,excluded.status,coalesce(excluded.anilist_id,manga.anilist_id))]])
        db:prepare("UPDATE shelf SET count=?, synced=?"):bind(total, os.time()):step()
        db:exec("COMMIT")
        return {count = total}
    end)
end

function Index:upsert(item)
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        local known = db:prepare("SELECT 1 FROM manga WHERE id=?"):bind(item.id):step()
        insert(db:prepare([[INSERT INTO manga(id,title,author,source,thumbnail,chapters,unread,added,status,anilist_id)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,
            author=excluded.author,source=excluded.source,thumbnail=excluded.thumbnail,
            chapters=excluded.chapters,unread=excluded.unread,added=coalesce(excluded.added,manga.added),
            status=coalesce(excluded.status,manga.status),anilist_id=coalesce(excluded.anilist_id,manga.anilist_id)]]), item)
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
            if count==0 then return {count=0,synced=synced,page=1,items={}} end
        end
        page = math.max(1, math.min(page, math.ceil(count / limit)))
        args[#args+1],args[#args+2]=limit,(page-1)*limit
        local stmt = db:prepare([[SELECT id,title,author,source,thumbnail,chapters,unread,status,anilist_id,
            (SELECT count(*) FROM files WHERE files.manga=manga.id) FROM manga]] .. where ..
            " ORDER BY " .. (orders[sort] or "") .. "title COLLATE NOCASE,id LIMIT ? OFFSET ?"):bind(unpack(args))
        local items = {}
        for r in stmt:rows() do
            items[#items + 1] = {id = r[1], title = r[2], author = r[3], source = r[4],
                thumbnail = r[5], chapters = tonumber(r[6]), unread = tonumber(r[7]), status = r[8], anilist_id = tonumber(r[9]),
                downloaded = tonumber(r[10]), in_library = true}
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
        for row in db:prepare("SELECT id,priority FROM pins"):rows() do result[row[1]] = tonumber(row[2]) end
        return result
    end)
end

function Index:setPinned(id, pinned)
    return with_db(self, function(db)
        if pinned then
            db:exec("BEGIN IMMEDIATE")
            local present=db:prepare("SELECT 1 FROM pins WHERE id=?"):bind(id):step()
            if not present then
                db:exec("UPDATE pins SET priority=priority+1")
                db:prepare("INSERT INTO pins(id,priority) VALUES(?,1)"):bind(id):step()
            else
                local row=db:prepare("SELECT priority FROM pins WHERE id=?"):bind(id):step()
                if row and tonumber(row[1])~=1 then
                    db:exec("UPDATE pins SET priority=priority+1 WHERE priority<"..tonumber(row[1]))
                    db:prepare("UPDATE pins SET priority=1 WHERE id=?"):bind(id):step()
                end
            end
            db:exec("COMMIT")
        else
            db:exec("BEGIN IMMEDIATE")
            local row=db:prepare("SELECT priority FROM pins WHERE id=?"):bind(id):step()
            db:prepare("DELETE FROM pins WHERE id=?"):bind(id):step()
            if row then db:prepare("UPDATE pins SET priority=priority-1 WHERE priority>?"):bind(row[1]):step() end
            db:exec("COMMIT")
        end
        return true
    end)
end

function Index:moveSource(id,direction)
    assert(direction=="up" or direction=="down")
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        local row=db:prepare("SELECT priority FROM pins WHERE id=?"):bind(id):step()
        if row then
            local compare,order=direction=="up" and "<" or ">",direction=="up" and "DESC" or "ASC"
            local neighbor=db:prepare("SELECT id,priority FROM pins WHERE priority"..compare.."? ORDER BY priority "..order.." LIMIT 1")
                :bind(row[1]):step()
            if neighbor then
                local update=db:prepare("UPDATE pins SET priority=? WHERE id=?")
                update:bind(row[1],neighbor[1]):step()
                update:reset():bind(neighbor[2],id):step()
            end
        end
        db:exec("COMMIT")
        return true
    end)
end

function Index:recommendationData(id)
    return with_db(self, function(db)
        local row = db:prepare("SELECT data FROM manga_recommendations WHERE manga=?"):bind(id):step()
        local data = row and require("dkjson").decode(row[1])
        return {snapshot = type(data)=="table" and data or nil}
    end)
end

function Index:applyAnilistSnapshots(snapshots)
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        local update = db:prepare("UPDATE manga SET anilist_id=? WHERE id=? AND (anilist_id IS NULL OR anilist_id<>?)")
        for _, row in ipairs(snapshots.rows or {}) do
            update:reset():bind(row.anilist_id,row.id,row.anilist_id):step()
        end
        db:exec("COMMIT")
        return true
    end)
end

function Index:setAnilistId(id, anilist_id)
    return with_db(self, function(db)
        db:prepare("UPDATE manga SET anilist_id=? WHERE id=?"):bind(anilist_id,id):step()
        return true
    end)
end

function Index:saveRecommendations(id, snapshot)
    return with_db(self, function(db)
        db:prepare("INSERT OR REPLACE INTO manga_recommendations VALUES(?,?)")
            :bind(id,require("dkjson").encode(snapshot)):step()
        return true
    end)
end

function Index:sourceHistory()
    return with_db(self, function(db)
        db:exec("BEGIN")
        local history = {opened = {}}
        for row in db:prepare("SELECT id,opened FROM source_opened"):rows() do
            history.opened[row[1]] = tonumber(row[2])
        end
        return history
    end)
end

function Index:markSourceOpened(id)
    return with_db(self, function(db)
        db:prepare([[INSERT OR REPLACE INTO source_opened(id,opened)
            SELECT ?,coalesce(max(opened),0)+1 FROM source_opened]]):bind(id):step()
        return true
    end)
end

return Index
