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
        if tonumber(db:rowexec("PRAGMA user_version")) < 3 then
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
                PRAGMA user_version=3; COMMIT]])
        end
        return action(db)
    end)
    -- Closing rolls back an incomplete transaction and finalizes its statements.
    db:close()
    if not ok then return nil, tostring(result):match("提示：(.*)") or "本地漫画索引读写失败。" end
    return result
end

local function insert(stmt, item)
    stmt:reset():bind(item.id, item.title, item.author, item.source, item.thumbnail, item.chapters, item.unread):step()
end

function Index:refresh(fetch, limit)
    limit = limit or 64
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE; DELETE FROM manga")
        local stmt = db:prepare("INSERT INTO manga VALUES(?,?,?,?,?,?,?)")
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
        db:prepare("UPDATE shelf SET count=?, synced=?"):bind(total, os.time()):step()
        db:exec("COMMIT")
        return {count = total}
    end)
end

function Index:upsert(item)
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE")
        local known = db:prepare("SELECT 1 FROM manga WHERE id=?"):bind(item.id):step()
        insert(db:prepare("INSERT OR REPLACE INTO manga VALUES(?,?,?,?,?,?,?)"), item)
        if not known then db:exec("UPDATE shelf SET count=count+1") end
        db:exec("COMMIT")
        return true
    end)
end

function Index:page(page, limit)
    return with_db(self, function(db)
        db:exec("BEGIN")
        local count, synced = db:rowexec("SELECT count,synced FROM shelf")
        count, synced = tonumber(count), tonumber(synced)
        page = math.max(1, math.min(page, math.ceil(count / limit)))
        local stmt = db:prepare([[SELECT id,title,author,source,thumbnail,chapters,unread FROM manga
            ORDER BY title COLLATE NOCASE,id LIMIT ? OFFSET ?]]):bind(limit, (page - 1) * limit)
        local items = {}
        for r in stmt:rows() do
            items[#items + 1] = {id = r[1], title = r[2], author = r[3], source = r[4],
                thumbnail = r[5], chapters = tonumber(r[6]), unread = tonumber(r[7]), in_library = true}
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
