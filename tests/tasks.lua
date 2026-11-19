local repo=assert(debug.getinfo(1,"S").source:match("^@(.*)/tests/tasks.lua$"))
package.path=repo .. "/?.lua;" .. package.path
local Index=require("suwayomi_kindle/library_index")
local Chapters=require("suwayomi_kindle/chapters")
local Tasks=require("suwayomi_kindle/tasks")
local Downloads=require("suwayomi_kindle/downloads")
local tmp=os.tmpname()
os.remove(tmp)
local ix=Index.new({server_url="http://example.test",auth_method="none"},tmp)
local function track(manga,id,path)
    require("util").makePath(path:match("^(.*)/"))
    local file=assert(io.open(path,"wb")); file:write("fixture"); file:close()
    if manga then assert(ix:with_db(function(db)
        db:prepare("INSERT INTO files VALUES(?,?,?)"):bind(manga,id,path):step()
        return true
    end)) end
end
local function directory(id)
    assert(Chapters.refresh(ix,{chapterPage=function()
        return {totalCount=2,pageInfo={hasNextPage=false},nodes={{id=50,name="One",isRead=false},{id=17,name="Two",isRead=false}}}
    end},id))
end
directory("7")
assert(ix:upsert({id="7",title="Shelf",author="",source="",thumbnail="",chapters=2,unread=2}))
Downloads.enqueue(ix,"7","all")
local active=assert(Downloads.claim(ix))
assert(Tasks.setPaused(ix,true))
assert(not Downloads.claim(ix) and Tasks.page(ix,"queue",1,5).paused)
assert(Chapters.page(ix,"7",1,5).items[1].state=="paused")
-- A stale completion must not touch the reissued attempt.
assert(Tasks.setPaused(ix,false,{manga="7",id=50}))
local retry=assert(Downloads.claim(ix))
assert(retry.id==50 and retry.ticket~=active.ticket)
assert(Downloads.finish(ix,active,"late failure"))
assert(Chapters.page(ix,"7",1,5).items[1].state=="active" and not Downloads.claim(ix))
assert(Downloads.finish(ix,retry,nil))
assert(Tasks.setPaused(ix,false))
assert(Downloads.claim(ix).id==17)

local root=tmp.."/books"
local function path(manga,id)
    return Chapters.downloadPath(ix,{directory=root,manga=manga,id=id})
end
track("7",50,path("7",50))       -- reachable
track("8",3,path("8",3))         -- removed manga
track("7",99,path("7",99))       -- removed chapter
track(nil,nil,root.."/extra/x.CBZ") -- never indexed
track(nil,nil,root.."/extra/x.sdr/ignore.cbz")
track(nil,nil,root.."/extra/bad.cbz.part")
local result=assert(Tasks.scan(ix,root))
assert(result.count==3)
local first=Tasks.page(ix,"orphan",1,2)
assert(first.pages==2 and #first.rows==2 and first.scanned)
local reasons={}
for page=1,2 do
    for _,item in ipairs(Tasks.page(ix,"orphan",page,2).rows) do reasons[item.reason]=true end
end
assert(reasons["漫画不在书架"] and reasons["章节不在目录"] and reasons["本地文件未登记"])
assert(not Tasks.scan(ix,tmp.."/missing"))
assert(Tasks.page(ix,"orphan",1,5).count==3)
require("ffi/util").purgeDir(tmp)
print("Task pause, attempt ownership, inventory and orphan scan passed")
