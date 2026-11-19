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
client = mock([[{"data":{"fetchSourceManga":{"hasNextPage":false,"mangas":[{"id":9,"title":"Book","inLibrary":true}]}}}]],
    function(request)
        local input = request.variables.input
        assert(input.page == 2 and input.type == "SEARCH" and input.source == "11" and input.query == "Book")
    end)
local results = assert(client:sourcePage{source = {id = "11", name = "Source"}, page = 2, mode = "SEARCH", search = "Book"})
assert(results.mangas[1].in_library and results.mangas[1].id == "9" and not results.has_next)
assert(mock([[{"data":{"updateManga":{"manga":{"id":9,"inLibrary":true}}}}]]):addManga("9"))
assert(not mock([[{"data":{"updateManga":{"manga":{"id":2,"inLibrary":true}}}}]]):addManga("9"))
assert(not mock("[]"):libraryPage(0, 5))
assert(not mock([[{"data":{"mangas":{"totalCount":0,"nodes":{},"pageInfo":{"hasNextPage":false}}}}]]):libraryPage(0, 5))

local root = os.tmpname()
os.remove(root)
local ix = Index.new(config, root)
local other = Index.new({server_url = config.server_url, auth_method = config.auth_method, username = "b"}, root)
assert(other.path ~= ix.path)
local function manga(n)
    return {id = tostring(n), title = string.format("Book %05d", n), source = "Source", author = "", thumbnail = ""}
end
local function page(offset, limit)
    local rows, total = {}, 1203
    for i = offset + 1, math.min(total, offset + limit) do rows[#rows + 1] = manga(i) end
    return {rows = rows, total = total, more = offset + #rows < total}
end
assert(ix:refresh(page).count == 1203)
local visible = assert(ix:page(2, 9))
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
os.remove(ix.path)
os.remove(other.path)
require("libs/libkoreader-lfs").rmdir(root)

-- Exercise the real fork/result transport with more than a pipe buffer.
local Worker = require("suwayomi_kindle/worker")
local socket = require("socket")
local original = Worker.run
Worker.run = function() return {text = string.rep("x", 250000)} end
local scheduled, completed
local ui = {scheduleIn = function(_, _, cb) scheduled = cb end}
Worker.start(ui, config, "source_page", {}, function(data, err)
    assert(data, err)
    completed = #data.text == 250000
end)
local deadline = socket.gettime() + 4
while scheduled and not completed and socket.gettime() < deadline do
    local cb = scheduled
    scheduled = nil
    cb()
    socket.sleep(0.01)
end
Worker.run = original
assert(completed, "large worker result did not arrive")
print("catalog API, snapshot, pagination and worker tests passed")
