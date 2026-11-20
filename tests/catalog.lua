local path = debug.getinfo(1, "S").source:sub(2)
package.path = assert(path:match("^(.*)/tests/catalog%.lua$")) .. "/?.lua;" .. package.path
local Connection = require("suwayomi_kindle/connection")
local Index = require("suwayomi_kindle/library_index")
local json = require("dkjson")
local config = {server_url = "http://example.test", auth_method = "basic_auth", username = "tester", password = "secret"}
local function mock(body, inspect)
    return assert(Connection.open(config, function(_, request)
        if inspect then inspect(json.decode(request)) end
        return {ok = true, body = body}
    end))
end

local client = mock([[{"data":{"sources":{"nodes":[
    {"id":"4","displayName":"D","lang":"en-US"},
    {"id":"3","name":"C","lang":"zh-Hant"},
    {"id":"2","name":"B","lang":"zh_Hans"},
    {"id":"1","name":"A","lang":"zh"}]}}}]])
assert(#client:sources("zh").sources == 3)
assert(client:sources("en").sources[1].id == "4")
assert(#client:sources("all").sources == 4)
client = mock([[{"data":{"fetchSourceManga":{"hasNextPage":false,"mangas":[{"id":9,"title":"Book","inLibrary":true,"status":"COMPLETED","chapters":{"totalCount":23}}]}}}]],
    function(request)
        local input = request.variables.input
        assert(input.page == 2 and input.type == "SEARCH" and input.source == "11" and input.query == "Book")
        assert(request.query:find(" status ", 1, true))
    end)
local results = assert(client:sourcePage{source = {id = "11", name = "Source"}, page = 2, mode = "SEARCH", search = "Book"})
assert(results.mangas[1].chapters == 23)
assert(results.mangas[1].status == "COMPLETED")
assert(results.mangas[1].in_library and results.mangas[1].id == "9" and not results.has_next)
assert(mock([[{"data":{"updateManga":{"manga":{"id":9,"inLibrary":true}}}}]]):addManga("9"))
assert(not mock([[{"data":{"updateManga":{"manga":{"id":2,"inLibrary":true}}}}]]):addManga("9"))
assert(not mock("[]"):libraryPage(0, 5))
assert(not mock([[{"data":{"mangas":{"totalCount":0,"nodes":{},"pageInfo":{"hasNextPage":false}}}}]]):libraryPage(0, 5))
local function status_query(request)
    assert(request.query:find(" status ", 1, true) and not request.query:find("fetchChapters", 1, true))
end
local shelf_api = mock([[{"data":{"mangas":{"totalCount":2,"nodes":[{"id":9,"title":"Book","status":"COMPLETED"},
    {"id":10,"title":"Other","trackRecords":{"nodes":[{"remoteId":"120760","tracker":{"name":"AniList"}}]}}],
    "pageInfo":{"hasNextPage":false}}}}]], status_query)
local detail_api = mock([[{"data":{"manga":{"id":9,"title":"Book","status":"ON_HIATUS","initialized":true,
    "trackRecords":{"nodes":[{"remoteId":"42","tracker":{"name":"AniList"}}]}}}}]], status_query)
local detail = assert(detail_api:manga("9"))
assert(detail.status == "ON_HIATUS" and detail.anilist_id == 42)
local tracker_api = mock([[{"data":{"manga":{"id":11,"trackRecords":{"nodes":[
    {"remoteId":"120760","tracker":{"name":"AniList"}}]}}}}]])
local tracked = assert(tracker_api:with_tracker_id({id="11"}))
assert(tracked.anilist_id == 120760)

local root = os.tmpname()
os.remove(root)
local ix = Index.new(config, root)
local other = Index.new({server_url = config.server_url, auth_method = config.auth_method, username = "b"}, root)
assert(other.path ~= ix.path)
-- A pre-0.3 shelf remains readable before the first metadata refresh.
local db = require("lua-ljsqlite3/init").open(ix.path)
db:exec([[CREATE TABLE manga(id TEXT PRIMARY KEY,title TEXT,author TEXT,source TEXT,thumbnail TEXT);
    CREATE TABLE shelf(count INTEGER,synced INTEGER); INSERT INTO shelf VALUES(1,123);
    INSERT INTO manga VALUES('old','Old title','','',''); PRAGMA user_version=1]])
db:close()
local migrated = assert(ix:page(1, 9))
assert(migrated.count == 1 and migrated.synced == 0 and migrated.items[1].chapters == nil)
assert(ix:refresh(function(offset, limit) return shelf_api:libraryPage(offset, limit) end))
local status_page = assert(ix:page(1, 5))
assert(status_page.items[1].status == "COMPLETED" and status_page.items[2].status == "UNKNOWN")
assert(status_page.items[2].anilist_id == 120760)
assert(ix:upsert({id="10",title="Other",author="",source="Source",thumbnail="",chapters=0,unread=0,anilist_id=nil}))
assert(ix:page(1,5).items[2].anilist_id == 120760)
assert(ix:with_db(function(db) return tonumber(db:rowexec("SELECT count(*) FROM directories")) == 0 end))
local function manga(n)
    return {id = tostring(n), title = string.format("Book %05d", n), source = "Source", author = "", thumbnail = "", added = 1700000000+n, chapters = n, unread = 0}
end
local function page(offset, limit)
    local rows, total = {}, 1203
    for i = offset + 1, math.min(total, offset + limit) do rows[#rows + 1] = manga(i) end
    return {rows = rows, total = total, more = offset + #rows < total}
end
assert(ix:refresh(page).count == 1203)
assert(ix:page(1,3,"added").items[1].id=="1203")
assert(ix:page(1,3,"chapters").items[1].id=="1203")
assert(ix:markOpened("17"))
assert(ix:with_db(function(db)
    db:prepare([[CREATE TRIGGER unchanged_shelf BEFORE UPDATE ON manga BEGIN
        SELECT RAISE(ABORT,'unchanged shelf rows must not be rewritten'); END]]):step()
    return true
end))
assert(ix:refresh(page))
assert(ix:with_db(function(db) db:exec("DROP TRIGGER unchanged_shelf"); return true end))
assert(ix:page(1,3,"opened").items[1].id=="17")
assert(ix:page(1,5,"added","bOOk 0001").count==10)
assert(ix:page(2,5,"added","bOOk 0001").items[1].id=="14")
assert(ix:page(1,5,"title","%_").count==0)
local visible = assert(ix:page(2, 9))
assert(visible.items[1].chapters == 10 and visible.items[1].unread == 0)
assert(visible.count == 1203 and #visible.items == 9 and visible.items[1].id == "10")
assert(other:page(1, 9).count == 0)
local function incomplete(second)
    return function(offset)
        if offset == 0 then return {rows = {manga(1)}, total = 2, more = true} end
        -- A reader never sees the interim deletion or inserts.
        assert(ix:page(1, 5).count == 1203)
        return second, "网络中断"
    end
end
assert(not ix:refresh(incomplete(nil)))
assert(not ix:refresh(incomplete({rows = {manga(1)}, total = 2, more = false})))
assert(not ix:refresh(incomplete({rows = {}, total = 1, more = false})))
assert(not ix:refresh(incomplete({rows = {}, total = 2, more = true})))
assert(ix:page(1, 1).count == 1203)
assert(ix:upsert(manga(1204)))
assert(ix:upsert(manga(1204)))
assert(ix:page(1, 1).count == 1204)
assert(ix:refresh(function() return {rows = {}, total = 0, more = false} end).count == 0)
assert(ix:page(2, 5).synced > 0 and ix:page(2, 5).page == 1)
-- Pinning and cached chapters are scoped to the account and survive a shelf rebuild.
assert(ix:setPinned("source-a",true) and ix:pins()["source-a"] and not other:pins()["source-a"])
assert(ix:setPinned("source-b",true) and ix:pins()["source-b"] == 1 and ix:pins()["source-a"] == 2)
assert(ix:moveSource("source-b","up") and ix:pins()["source-b"] == 1)
assert(ix:setPinned("source-a",false) and not ix:pins()["source-a"])
-- Source history stays local to the current server and account.
assert(ix:markSourceOpened("source-a") and ix:markSourceOpened("source-b") and ix:markSourceOpened("source-a"))
local history = assert(Index.new(config, root):sourceHistory())
assert(history.opened["source-a"] > history.opened["source-b"])
assert(not next(other:sourceHistory().opened))

local matching = require("suwayomi_kindle/recommendations")
local recommendation = {id=123,titles={english="Kaiju No.8", native="怪獣８号"},synonyms={"怪兽8号"},authors={"Naoya Matsumoto"}}
local requests = 0
local source_fixture = {sourcePage=function(_, input)
    requests = requests+1
    assert(input.search == "怪兽8号" and input.page == 1)
    return {mangas={
        {id="42",title="怪兽8号 RELAX",author="Naoya Matsumoto"},
        {id="43",title="怪兽 ８ 号",author="Naoya Matsumoto"},
        {id="43",title="怪兽 ８ 号",author="Naoya Matsumoto"},
        {id="44",title="怪兽8号",anilist_id=999},
        {id="45",title="另一译名",anilist_id=123},
        {id="46",title="怪兽8号"},
    }}
end}
local source = {id="zh",name="Chinese source",lang="zh-Hans"}
local source_search = matching.search(source_fixture,source,recommendation)
assert(requests==1 and #source_search.matches==1 and source_search.matches[1].id=="45")
local anilist = require("suwayomi_kindle/anilist")
local original_identify = anilist.identify
local checked = 0
anilist.identify = function(names)
    checked = checked + 1
    assert(#names==2 and names[1]=="怪兽8号" and names[2]=="Kaiju No.8")
    return {[names[1]]=124,[names[2]]=false}
end
source_fixture.sourcePage=function() return {mangas={{id="46",title="怪兽8号"},
    {id="47",title="Kaiju No.8"},{id="48",title="怪兽8号 RELAX"}}} end
assert(#matching.search(source_fixture,source,recommendation).matches==0 and checked==1)
anilist.identify = original_identify

local mixed = {id=123,title="One-Punch Man",country="JP",
    titles={native="ワンパンマン",english="One-Punch Man"},synonyms={"원펀맨", "ONE-PUNCH MAN 一拳超人"}}
local aliases = {id=mixed.id,title=mixed.titles,synonyms=mixed.synonyms}
local verified = assert(anilist.identify({"一拳超人", "One-Punch Man"}, function(_, variables)
    assert(variables.t1=="一拳超人" and variables.t2=="One-Punch Man")
    return {t1={media={aliases}},t2={media={aliases,{id=999,title={english="One-Punch Man"}}}}}
end))
assert(verified["一拳超人"]==123 and verified["One-Punch Man"]==false)
local terms = {}
local lookup = {sourcePage=function(_, input)
    terms[#terms+1] = input.search
    return {mangas={{id="88",anilist_id=123}}}
end}
assert(matching.search(lookup,source,mixed).matches[1] and terms[1]=="一拳超人")
assert(matching.search(lookup,source,mixed,"en,ja,zh").matches[1] and terms[2]=="One-Punch Man")
assert(matching.search(lookup,source,mixed,"ja,en,zh").matches[1] and terms[3]=="ワンパンマン")
local function explore(order)
    return matching.explore(lookup,{source=source,mode="SEARCH",size=4,target=1,recommended_item=mixed,search_languages=order})
end
assert(explore("ja,zh,en").search=="ワンパンマン")
lookup.sourcePage=function(_, input) return {mangas=input.search=="One-Punch Man" and {{id="88"}} or {}} end
assert(explore("zh,en,ja").search=="One-Punch Man")
mixed.synonyms = {"원펀맨"}
assert(explore("zh,en,ja").search=="One-Punch Man")

source_search.verified=true
local other_edition = {id="54",title="Kaiju No.8",anilist_id=123}
recommendation.sources={zh=source_search,en={verified=true,matches={other_edition}}}
local snapshot = {source_order={"zh","en"}, media=1, items={recommendation,
    {id=125,sources={zh={verified=true,matches={{id="45",anilist_id=123}}}}},
}}
local matched = matching.pageResults(snapshot, "42", 1, 4)
assert(#matched==2 and matched[1].match.id=="45" and matched[2].item.id==125 and not matched[2].match)
snapshot.source_order={"en","zh"}
matched = matching.pageResults(snapshot, "42", 1, 4)
assert(#matched==2 and matched[1].match.id=="54" and not matched[2].match)
local Chapters = require("suwayomi_kindle/chapters")
local api = {chapterPage = function(_,_,offset,limit)
    local rows = {}
    for n = offset+1,math.min(205,offset+limit) do
        rows[#rows+1] = {id=n,name="Chapter "..n,isRead=n~=113}
    end
    return {totalCount=205,nodes=rows,pageInfo={hasNextPage=offset+#rows<205}}
end}
assert(not Chapters.page(ix,"9",1,5).cached)
assert(Chapters.refresh(ix,api,"9").count == 205)
assert(Chapters.nextUnread(ix,"9").pos == 113)
assert(Chapters.page(ix,"9",12,10).items[3].id == 113)
assert(Chapters.page(ix,"9",1,10,true).count == 1)
local original = api.chapterPage
api.chapterPage = function(self,id,offset,limit)
    if offset > 0 then return nil,"断开" end
    return original(self,id,offset,limit)
end
assert(not Chapters.refresh(ix,api,"9"))
assert(Chapters.nextUnread(ix,"9").id == 113)
assert(Chapters.setRead(ix,"9",113,true).unread == 0 and Chapters.nextUnread(ix,"9") == false)
assert(Chapters.setRead(ix,"9",113,false).unread == 1)
api.request = function() return {fetchChapterPages={pages={"/p/1","/p/2"},chapter={id=113,manga={id=9}}}} end
local png = require("mime").unb64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l2kAAAAASUVORK5CYII=")
local downloads=require("suwayomi_kindle/downloads")
assert(downloads.enqueue(ix,"9","single",113))
local sample=assert(downloads.claim(ix))
sample.directory=root
local pages_seen={}
api.pageImage = function(_,url)
    local task=assert(require("suwayomi_kindle/tasks").page(ix,"queue",1,1,{filter="active"})).rows[1]
    pages_seen[url]=task.pages_done
    assert(task.pages_total==2)
    return png
end
local archive = assert(Chapters.download(ix,api,sample)).path
assert(Chapters.nextUnread(ix,"9").path == archive)
assert(pages_seen["/p/1"]==0 and pages_seen["/p/2"]==1)
api.pageImage = function() return "<html>" end
assert(not Chapters.download(ix,api,sample))
assert(ix:remove("9"))
assert(Chapters.nextUnread(ix,"9").path == archive)
os.remove(archive)
assert(not Chapters.nextUnread(ix,"9").path)
local lfs = require("libs/libkoreader-lfs")
local dir = archive:match("^(.*)/")
for _=1,3 do lfs.rmdir(dir); dir = dir:match("^(.*)/") end
os.remove(ix.path)
os.remove(other.path)
require("libs/libkoreader-lfs").rmdir(root)

-- A native worker may exit mid-write. Its incomplete output must be safe for the UI.
local Worker = require("suwayomi_kindle/worker")
for _, bytes in ipairs({"", "   ", "{", "null", "true", "{}", '{"data":{}}junk'}) do
    local file = assert(io.tmpfile())
    file:write(bytes)
    local result, err = Worker.readResult(file)
    assert(result == nil and type(err) == "string")
    file:close()
end

-- Exercise actual network resolution and a result larger than a pipe buffer
-- in a fresh worker using a loopback fixture instead of inherited Lua mocks.
local socket = require("socket")
local server = assert(socket.bind("127.0.0.1", 0))
local _, port = server:getsockname()
local scheduled, completed, failure
local ui = {scheduleIn = function(_, _, cb) scheduled = cb end}
local name = string.rep("x", 120000)
assert(Worker.start(ui, {server_url = "http://127.0.0.1:" .. port, auth_method = "none"},
    "sources", {language = "zh"}, function(data, err)
        failure = err
        completed = data and data.sources[1].name == name
    end))
server:settimeout(5)
local peer = assert(server:accept())
peer:settimeout(3)
local length
while true do
    local line = assert(peer:receive("*l"))
    if line == "" then break end
    length = tonumber(line:lower():match("^content%-length:%s*(%d+)")) or length
end
assert(peer:receive(assert(length)))
local body = json.encode({data = {sources = {nodes = {{id = "1", name = name, lang = "zh"}}}}})
assert(peer:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body))
peer:close()
server:close()
local deadline = socket.gettime() + 5
while scheduled and not completed and not failure and socket.gettime() < deadline do
    local cb = scheduled
    scheduled = nil
    cb()
    socket.sleep(0.01)
end
assert(completed, failure or "large worker result did not arrive")
print("catalog API, snapshot, pagination and worker tests passed")
