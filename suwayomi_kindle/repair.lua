local json = require("dkjson")
local Flash = require("suwayomi_kindle/deepseek")
local Sources = require("suwayomi_kindle/browse_sources")
local Titles = require("suwayomi_kindle/manga_titles")
local Log = require("suwayomi_kindle/repair_log")
local Repair = {}

-- Cache discovery for adjacent failed chapters, never a permanent chapter substitution.
local function discover(index,client,source,target,aliases)
    local cache_key = target.manga .. "/" .. source.id
    local cached = index:with_db(function(db)
        return db:prepare("SELECT data FROM repair_cache WHERE id=? AND expires>?"):bind(cache_key,os.time()):step()
    end)
    if cached then return json.decode(cached[1]) end
    local page,err = client:sourcePage{source=source,mode="SEARCH",page=1,search=target.title,recommendation=true}
    if not page then return nil,err end
    if #page.mangas==0 then
        for _,alias in ipairs(aliases()) do
            page,err=client:sourcePage{source=source,mode="SEARCH",page=1,search=alias,recommendation=true}
            if not page then return nil,err end
            if #page.mangas>0 then break end
        end
    end
    local works, partial = {},nil
    for i=1,math.min(3,#page.mangas) do
        local m = page.mangas[i]
        if m.id~=target.manga and not (m.anilist_id and target.anilist_id and m.anilist_id~=target.anilist_id) then
            local work = {manga=m.id,title=m.title,author=m.author,source=source.name,chapters={}}
            local offset,complete = 0,false
            repeat
                local part,why = client:chapterPage(m.id,offset,100,true)
                if part and part.totalCount==0 and offset==0 then
                    local fetched
                    fetched,why=client:request("mutation($id:Int!){fetchChapters(input:{mangaId:$id}){__typename}}",{id=tonumber(m.id)})
                    if fetched then part,why=client:chapterPage(m.id,0,100,true) else part=nil end
                end
                if not part then partial=why or "候选目录读取失败。"; break end
                for _,c in ipairs(part.nodes) do
                    work.chapters[#work.chapters+1]={id=c.id,name=c.name,number=c.chapterNumber}
                end
                complete=not part.pageInfo.hasNextPage
                offset=offset+#part.nodes
                if not complete and #part.nodes==0 then partial="候选目录分页异常。"; break end
            until complete or offset>=5000
            if #work.chapters>0 then works[#works+1]=work end
        end
    end
    if not partial then
        local encoded=json.encode(works)
        if #encoded<=512*1024 then
            index:with_db(function(db)
                db:exec("BEGIN IMMEDIATE")
                db:prepare("INSERT OR REPLACE INTO repair_cache VALUES(?,?,?)"):bind(cache_key,os.time()+1800,encoded):step()
                db:exec("DELETE FROM repair_cache WHERE id IN (SELECT id FROM repair_cache ORDER BY expires DESC LIMIT -1 OFFSET 24); COMMIT")
                return true
            end)
        end
    end
    return works,partial
end

local function number(c)
    local n=tonumber(c.number)
    if n and n>=0 then return n end
    return tonumber(c.name:match("(%d+%.?%d*)%s*话") or c.name:match("(%d+%.?%d*)%s*話")
        or c.name:match("^%s*(%d+%.?%d*)"))
end

function Repair.select(index,client,job,exclude)
    local eligible,db_error=index:with_db(function(db)
        local row=db:prepare([[SELECT 1 FROM manga m JOIN chapter c ON c.manga=m.id
            WHERE m.id=? AND c.id=?]]):bind(job.manga,job.id):step()
        return row~=nil
    end)
    if not eligible then return nil,db_error or "原章节已离开本地书架。" end
    local data,err=client:request([[query($id:Int!){chapter(id:$id){name chapterNumber manga{
        id title author inLibrary source{id} trackRecords{nodes{remoteId tracker{name}}}
    }}}]],{id=job.id})
    if not data then return nil,err end
    local chapter=data.chapter
    local m=chapter and chapter.manga
    if not m or not m.inLibrary or tostring(m.id)~=job.manga or not m.source then return nil,"原章节已离开书架。" end
    local target={manga=job.manga,title=m.title,author=m.author,name=chapter.name,number=chapter.chapterNumber,
        path=job.manga.."/"..job.id..".cbz"}
    for _,t in ipairs(m.trackRecords and m.trackRecords.nodes or {}) do
        if t.tracker and t.tracker.name:lower()=="anilist" then target.anilist_id=tonumber(t.remoteId) end
    end
    local alias_list
    local function aliases()
        if alias_list then return alias_list end
        alias_list={}
        if target.anilist_id then
            local item=require("suwayomi_kindle/anilist").titlesById(target.anilist_id)
            if item then
                local settings=require("suwayomi_kindle/settings_store"):new():load("recommendation")
                local names=require("suwayomi_kindle/recommendations").searchNames(item,settings.search_languages)
                for _,name in ipairs(names) do
                    if Titles.key(name)~=Titles.key(target.title) then Titles.add(alias_list,name) end
                    if #alias_list==2 then break end
                end
            end
        end
        return alias_list
    end
    local all,why=client:sources("all")
    if not all then return nil,why end
    local store=require("suwayomi_kindle/settings_store"):new()
    local browse=store:load("browse")
    local pins,pin_error=index:pins()
    if not pins then return nil,pin_error end
    local history,history_error=index:sourceHistory()
    if not history then return nil,history_error end
    local ordered=Sources.list(all.sources,browse.language,nil,browse.sort,pins,history.opened)
    local limit=math.min(10,math.max(1,store:load("download").repair_sources))
    local saved=index:with_db(function(db)
        return db:prepare([[SELECT remote_manga,remote_id,remote_name,remote_title FROM repair_match
            WHERE manga=? AND id=? AND original_name=?]]):bind(job.manga,job.id,target.name):step()
    end)
    local candidates,remote={},{}
    local used,last_error=0,nil
    for _,s in ipairs(ordered) do
        if s.id~=m.source.id then
            used=used+1
            local works,source_error=discover(index,client,s,target,aliases)
            local before = #candidates
            last_error=source_error or last_error
            for _,work in ipairs(works or {}) do
                for pos,c in ipairs(work.chapters) do
                    local a,b=number(target),number(c)
                    local skipped=exclude and work.manga==exclude.manga and c.id==exclude.id
                    if not skipped and ((a and a==b) or (not (a and b and a~=b) and Titles.key(c.name)==Titles.key(target.name))) then
                        local i=#candidates+1
                        candidates[i]={candidate_id="c"..i,title=work.title,author=work.author,source=s.name,
                            chapter=c.name,number=c.number,
                            previous=work.chapters[pos-1] and work.chapters[pos-1].name,
                            following=work.chapters[pos+1] and work.chapters[pos+1].name}
                        remote[i]={manga=work.manga,id=c.id,name=c.name,title=work.title,original_name=target.name}
                        if saved and saved[1]==work.manga and tonumber(saved[2])==c.id and saved[3]==c.name and saved[4]==work.title then
                            remote[i].reused=true
                        end
                        if i>=8 then break end
                    end
                end
                if #candidates>=8 then break end
            end
            local summary = string.format("%s · 找到 %d 个候选章节", s.name, #candidates-before)
            Log.add(index,job,source_error and (summary.." · "..source_error) or summary)
            if used>=limit or #candidates>=8 then break end
        end
    end
    if #candidates==0 then return nil,last_error and ("候选源查询失败："..last_error) or "备用源中没有匹配章节。" end
    local available,choices={},{}
    local last_failure
    for i,match in ipairs(remote) do
        local pages,reason=require("suwayomi_kindle/chapters").pages(client,match.manga,match.id)
        if pages then
            match.pages=pages
            if match.reused then
                Log.add(index,job,"复用上次匹配 · "..candidates[i].source.." · "..match.name)
                return match
            end
            available[#available+1]=match
            choices[#choices+1]=candidates[i]
        else
            last_failure=reason
        end
    end
    if #available==0 then return nil,"备用章节均无法取页："..(last_failure or "没有可下载的漫画页。") end
    local selected,reason=Flash.choose(target,choices)
    if selected then
        Log.add(index,job,"Flash 选择 · "..choices[selected].source.." · "..choices[selected].chapter)
    end
    return available[selected],reason
end

return Repair
