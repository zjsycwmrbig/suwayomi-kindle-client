-- Run with a temporary KO_HOME and the emulator's LuaJIT. No live downloads or credentials.
local root=assert(debug.getinfo(1,"S").source:match("^@(.*)/tests/repair.lua$"))
package.path=root.."/?.lua;"..package.path
local Downloads=require("suwayomi_kindle/downloads")
local Chapters=require("suwayomi_kindle/chapters")
local Tasks=require("suwayomi_kindle/tasks")
local Flash=require("suwayomi_kindle/deepseek")
local Repair=require("suwayomi_kindle/repair")
local temp=os.tmpname()
os.remove(temp)
local index=require("suwayomi_kindle/library_index").new({server_url="http://fixture.test",auth_method="none"},temp)
local server={online=false}
function server:chapterPage(id)
    local item=id=="7" and {id=76,name="第76话",isRead=false}
        or {id=3401,name="第076话",chapterNumber=76,isRead=false}
    return {totalCount=1,nodes={item},pageInfo={hasNextPage=false}}
end
function server:sources()
    return {sources={{id="orig",lang="zh",name="A"},{id="backup",lang="zh",name="B"}}}
end
function server:sourcePage(input)
    assert(input.source.id=="backup" and input.mode=="SEARCH")
    return {mangas={{id="33",title="测试书",author="测试作者"}}}
end
function server:request(query,vars)
    if query:find("fetchChapterPages",1,true) then
        local orig=vars.id==76
        assert(orig or vars.id==3401)
        return {fetchChapterPages={chapter={id=vars.id,manga={id=orig and 7 or 33}},
            pages=(not orig or self.online) and {"/page/1"} or {}}}
    end
    return {chapter={name="第76话",chapterNumber=76,manga={id=7,title="测试书",inLibrary=true,source={id="orig"}}}}
end
function server:pageImage() return "\137PNG\r\n\26\nfixture" end
assert(index:upsert{id="7",title="测试书",author="",source="A",chapters=1,unread=1})
assert(Chapters.refresh(index,server,"7"))
local function claim()
    assert(Downloads.enqueue(index,"7","single",76))
    return assert(Downloads.claim(index,temp))
end
local repair_batch=assert(Downloads.enqueueRepairs(index,{{manga="7",id=76},{manga="7",id=99}}))
assert(repair_batch.count==1)
local repair_row=assert(Tasks.page(index,"queue",1,10).rows[1])
assert(repair_row.id==76 and repair_row.repair=="ready" and repair_row.state=="queued")
assert(index:with_db(function(db) db:exec("DELETE FROM queue"); return true end))
local job=claim()
local _,err,kind=Chapters.download(index,server,job)
assert(kind=="source")
local cfg={retries=1}
assert(Downloads.sourceFailure(index,job,cfg,err).action=="retry")
assert(not Downloads.claim(index,temp))
assert(index:with_db(function(db) db:exec("UPDATE queue SET retry_at=0"); return true end))
job=assert(Downloads.claim(index,temp))
assert(Downloads.sourceFailure(index,job,cfg,err).action=="ask")
assert(not Downloads.confirmRepair(index,{manga="7",id=76,ticket=-1},true))
assert(Downloads.confirmRepair(index,job,true))
job=assert(Downloads.claim(index,temp))
assert(job.repair)
local chosen,configured=Flash.choose,Flash.configured
local calls=0
Flash.configured=function() return true end
Flash.choose=function(target,candidates)
    assert(target.path=="7/76.cbz" and #candidates==1 and candidates[1].chapter=="第076话")
    calls=calls+1
    return 1
end
local remote=assert(Repair.select(index,server,job))
job.match,job.remote_id,job.remote_manga=remote,remote.id,remote.manga
local path=assert(Chapters.download(index,server,job)).path
assert(path:match("/7/76%.cbz$") and Chapters.locate(index,"7",76).path==path)
assert(not Chapters.locate(index,"33",3401))
assert(Tasks.deleteFiles(index,{{manga="7",id=76,path=path}},temp).count==1)
server.online=true
job=claim()
assert(not job.repair and not job.remote_id)
assert(Chapters.download(index,server,job).path==path and calls==1)
assert(Repair.select(index,server,job).reused and calls==1)
local Log=require("suwayomi_kindle/repair_log")
local entries=assert(Log.recent(index))
assert(entries[1]:find("复用上次匹配 · B · 第076话",1,true))
assert(table.concat(entries):find("Flash 选择 · B · 第076话",1,true))
for i=1,101 do assert(Log.add(index,job,"记录 "..i)) end
entries=assert(Log.recent(index))
assert(#entries==100 and entries[1]:match("记录 101$") and entries[100]:match("记录 2$"))
assert(entries[1]:find("测试书 · 第76话",1,true))
Flash.choose,Flash.configured=chosen,configured
assert(Tasks.deleteFiles(index,{{manga="7",id=76,path=path}},temp).count==1)
for _,mode in ipairs({"auto","all"}) do
    assert(Downloads.configure(index,"7","ahead",1))
    for _,enabled in ipairs({false,true}) do
        assert(Downloads.enqueue(index,"7",mode))
        local next_job=assert(Downloads.claim(index,temp))
        local decision=Downloads.sourceFailure(index,next_job,{
            retries=0,repair_auto=mode=="auto" and enabled,repair_batch=mode=="all" and enabled},"无页")
        assert(decision.action==(enabled and "repair" or "failed"))
        assert(index:with_db(function(db) db:exec("DELETE FROM queue"); return true end))
    end
end
require("ffi/util").purgeDir(temp)
print("Repair retries, consent, alternate-file ownership, deletion and fresh original-source downloads passed")
