local repo=assert(debug.getinfo(1,"S").source:match("^@(.*)/tests/tasks.lua$"))
package.path=repo .. "/?.lua;" .. package.path
local Index=require("suwayomi_kindle/library_index")
local Chapters=require("suwayomi_kindle/chapters")
local Tasks=require("suwayomi_kindle/tasks")
local Downloads=require("suwayomi_kindle/downloads")
local lfs=require("libs/libkoreader-lfs")
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
local last=assert(Downloads.claim(ix))
assert(last.id==17)
assert(Downloads.finish(ix,last,"forced failure"))
local failed=assert(Tasks.page(ix,"queue",1,5,{filter="failed"}))
assert(failed.count==1 and failed.rows[1].key=="queue:7:17")
local retried=assert(Tasks.retry(ix,{[failed.rows[1].key]=failed.rows[1]}))
assert(retried.count==1)
assert(Tasks.page(ix,"queue",1,5,{filter="failed"}).count==0)
assert(Tasks.page(ix,"queue",1,5,{filter="queued"}).count==1)
assert(Tasks.setPaused(ix,true))
assert(Tasks.page(ix,"queue",1,5,{filter="queued"}).count==0)
assert(Tasks.page(ix,"queue",1,5,{filter="paused"}).count==1)
assert(Tasks.setPaused(ix,false))

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
local folders=assert(Tasks.page(ix,"files",1,10))
assert(folders.count==2)
local expanded=assert(Tasks.expandFiles(ix,folders.rows))
assert(#expanded==3)
local files=assert(Tasks.page(ix,"files",1,10,{manga="7"}))
assert(files.count==2)
local selected
for _,item in ipairs(files.rows) do
    if item.manga=="7" and item.id==50 then selected=item end
end
assert(selected)
local deleted=assert(Tasks.deleteFiles(ix,{[selected.key]=selected},root))
assert(deleted.count==1 and lfs.attributes(path("7",50),"mode")==nil)
assert(Tasks.page(ix,"files",1,10).count==2)
local guarded
for _,item in ipairs(Tasks.page(ix,"files",1,10,{manga="7"}).rows) do
    if item.manga=="7" and item.id==99 then guarded=item end
end
local kept=assert(Tasks.deleteFiles(ix,{[guarded.key]=guarded},root,guarded.path))
assert(kept.kept==1 and lfs.attributes(guarded.path,"mode")=="file")
local all=assert(Tasks.expandFiles(ix,Tasks.page(ix,"files",1,10).rows))
assert(#all==2)
local bulk=assert(Tasks.deleteFiles(ix,all,root,guarded.path))
assert(bulk.count==1 and bulk.kept==1 and bulk.failed==0)
assert(lfs.attributes(root.."/extra/x.CBZ","mode")=="file")
assert(not Tasks.scan(ix,tmp.."/missing"))
assert(Tasks.page(ix,"orphan",1,5).count==3)
require("ffi/util").purgeDir(tmp)
print("Task filters, retry, guarded deletion, inventory and orphan scan passed")
