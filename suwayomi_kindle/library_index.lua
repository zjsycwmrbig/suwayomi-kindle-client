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
        if tonumber(db:rowexec("PRAGMA user_version")) == 0 then
            db:exec([[PRAGMA journal_mode=WAL; BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS manga(id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT, source TEXT, thumbnail TEXT);
                CREATE INDEX IF NOT EXISTS title_idx ON manga(title COLLATE NOCASE, id);
                CREATE TABLE IF NOT EXISTS shelf(count INTEGER, synced INTEGER);
                INSERT INTO shelf SELECT 0, 0 WHERE NOT EXISTS (SELECT 1 FROM shelf);
                PRAGMA user_version=1; COMMIT]])
        end
        return action(db)
    end)
    -- Closing rolls back an incomplete transaction and finalizes its statements.
    db:close()
    if not ok then return nil, tostring(result):match("提示：(.*)") or "本地漫画索引读写失败。" end
    return result
end

local function insert(stmt, item)
    stmt:reset():bind(item.id, item.title, item.author, item.source, item.thumbnail):step()
end

function Index:refresh(fetch, limit)
    limit = limit or 64
    return with_db(self, function(db)
        db:exec("BEGIN IMMEDIATE; DELETE FROM manga")
        local stmt = db:prepare("INSERT INTO manga VALUES(?,?,?,?,?)")
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
        insert(db:prepare("INSERT OR REPLACE INTO manga VALUES(?,?,?,?,?)"), item)
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
        local stmt = db:prepare([[SELECT id,title,author,source,thumbnail FROM manga
            ORDER BY title COLLATE NOCASE,id LIMIT ? OFFSET ?]]):bind(limit, (page - 1) * limit)
        local items = {}
        for r in stmt:rows() do
            items[#items + 1] = {id = r[1], title = r[2], author = r[3], source = r[4],
                thumbnail = r[5], in_library = true}
        end
        return {count = count, synced = synced, page = page, items = items}
    end)
end

return Index
