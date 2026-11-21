local Log = {}

function Log.add(index, job, message)
    return index:with_db(function(db)
        db:exec("BEGIN IMMEDIATE")
        db:prepare([[INSERT INTO repair_log(at,chapter,message) VALUES(?,substr(coalesce((
            SELECT m.title || ' · ' || c.name FROM manga m JOIN chapter c ON c.manga=m.id
            WHERE m.id=? AND c.id=?),?),1,120),substr(?,1,240))]])
            :bind(os.time(),job.manga,job.id,job.manga.."/"..job.id,message):step()
        db:exec("DELETE FROM repair_log WHERE seq <= (SELECT max(seq)-100 FROM repair_log); COMMIT")
        return true
    end)
end

function Log.recent(index)
    return index:with_db(function(db)
        local entries = {}
        for row in db:prepare("SELECT at,chapter,message FROM repair_log ORDER BY seq DESC LIMIT 100"):rows() do
            entries[#entries+1] = os.date("%m-%d %H:%M:%S",tonumber(row[1])).."  "..row[2].."\n"..row[3]
        end
        return entries
    end)
end

return Log
