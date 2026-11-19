-- Run in KOReader's runtime. All records and CBZs in this test are temporary.
local root=assert(debug.getinfo(1,"S").source:match("^@(.*)/tests/reading.lua$"))
package.path=root .. "/?.lua;" .. package.path
local Index=require("suwayomi_kindle/library_index")
local Chapters=require("suwayomi_kindle/chapters")
local Records=require("suwayomi_kindle/records")
local Downloads=require("suwayomi_kindle/downloads")
local temp=os.tmpname()
os.remove(temp)
local index=Index.new({server_url="http://fixture.test",auth_method="none"},temp)
local m="7"
local api={}
function api:chapterPage()
    local nodes={}
    for i=1,8 do nodes[i]={id=i,name="第"..i.."话",isRead=false,lastPageRead=0} end
    return {totalCount=#nodes,nodes=nodes,pageInfo={hasNextPage=false}}
end
function api:libraryPage()
    return {rows={{id=m,title="测试漫画",author="",source="",thumbnail="",unread=8,chapters=8}},total=1,more=false}
end
assert(Chapters.refresh(index,api,m).count==8)
local function status() return assert(Records.status(index)) end
local function mark(id,range,read,page)
    return assert(Records.mark(index,m,{id=id,pos=id},range,read,page))
end
assert(mark(4,"before",true).changes==3 and Chapters.nextUnread(index,m).id==4)
assert(mark(7,"single",true).changes==1)
assert(mark(4,"after",false).changes==1 and status().count==4)
assert(mark(2,"single",nil,4).changes==1 and status().count==4)
assert(Chapters.refresh(index,api,m).unread==5) -- ordinary refresh preserves local changes
local old=status().cutoff
function api:chapterOwners() return {[1]=m,[2]=m,[3]=m,[7]="different"} end
function api:updateRecord(id,read,page)
    if id==1 then return nil,"连接超时" end
    return true
end
assert(not Records.push(index,api,old) and status().count==4)
assert(status().logs[1]:find("连接超时"))
local sent={}
function api:updateRecord(id,read,page)
    sent[id]={read=read,page=page}
    if id==2 then mark(2,"single",false,5) end -- newer edits survive the ACK for this upload
    return true
end
assert(Records.push(index,api,old).message:find("失败 1"))
assert(sent[2].read and sent[2].page==4 and not sent[7] and status().count==2)
local cutoff=status().cutoff
mark(4,"single",true,9)
local original=api.chapterPage
api.chapterPage=function() return nil,"接口超时" end
assert(not Records.pull(index,api,cutoff))
assert(status().count==3)
api.chapterPage=original
assert(Records.pull(index,api,cutoff))
assert(status().count==1 and Chapters.nextUnread(index,m).id==1)
local rec=index:with_db(function(db)
    local v=db:prepare("SELECT is_read,last_page FROM chapter WHERE id=4"):step()
    return {tonumber(v[1]),tonumber(v[2])}
end)
assert(rec[1]==1 and rec[2]==9)
assert(Downloads.configure(index,m,"ahead",3))
assert(Downloads.enqueue(index,m,"auto").count==3)
assert(Downloads.configure(index,m,"ahead",1))
assert(Downloads.enqueue(index,m,"auto").count==1)
local job=assert(Downloads.claim(index))
assert(job.id==1 and not Downloads.claim(index))
assert(Downloads.finish(index,job,"连接超时"))
assert(Downloads.enqueue(index,m,"auto"))
assert(not Downloads.claim(index))
assert(Downloads.enqueue(index,m,"single",1))
job=assert(Downloads.claim(index))
assert(job.id==1 and Downloads.finish(index,job,nil))
local paths={}
for id=1,4 do
    local p=Chapters.downloadPath(index,{manga=m,id=id,directory=temp})
    require("util").makePath(p:match("^(.*)/"))
    local f=assert(io.open(p,"wb")); assert(f:write("fixture")); f:close()
    assert(index:with_db(function(db)
        db:prepare("INSERT INTO files VALUES(?,?,?)"):bind(m,id,p):step()
        return true
    end))
    paths[id]=p
end
assert(Downloads.enqueue(index,m,"all").count==4)
assert(Downloads.configure(index,m,"retention","never"))
mark(4,"before",true)
assert(Downloads.clean(index,m,"0",false).count==0)
assert(Downloads.configure(index,m,"retention","1"))
assert(Downloads.clean(index,m,"never",false,paths[1]).count==2)
assert(Downloads.clean(index,m,"never",true,paths[1]).count==1)
assert(Downloads.clean(index,m,"never",true).count==1)
for _,path in ipairs(paths) do assert(not require("libs/libkoreader-lfs").attributes(path)) end
require("ffi/util").purgeDir(temp)
print("Offline records, sync conflicts, partial failure, queue windows and local cleanup passed")
