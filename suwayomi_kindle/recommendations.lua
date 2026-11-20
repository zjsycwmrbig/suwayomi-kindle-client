local utf8 = require("ffi/utf8proc")
local Languages = require("suwayomi_kindle/languages")
local Recommendations = {}

local function normalize(value)
    return (utf8.lowercase(tostring(value or "")):gsub("[%s%p]", ""))
end

local function search_names(item, lang)
    local result, seen = {}, {}
    local function add(value)
        local key=type(value)=="string" and normalize(value) or ""
        if key~="" and not seen[key] then
            seen[key]=true
            result[#result+1]=value
        end
    end
    if lang=="zh" or lang=="ja" then add(item.titles.native) end
    add(item.titles.english)
    add(item.titles.romaji)
    add(item.titles.native)
    for _,value in ipairs(item.synonyms or {}) do add(value) end
    return result
end

function Recommendations.search(client, source, items)
    local result, cache = {}, {}
    for _,item in ipairs(items) do
        local names, keys, matches, seen, failed = search_names(item,Languages.base(source.lang)),{}, {}, {}, false
        for _,name in ipairs(names) do keys[normalize(name)]=true end
        for i=1,math.min(2,#names) do
            local term=names[i]
            local page=cache[term]
            if page==nil then
                page=client:sourcePage{source=source,mode="SEARCH",page=1,search=term} or false
                cache[term]=page
            end
            if not page then failed=true; break end
            for _,candidate in ipairs(page.mangas) do
                if keys[normalize(candidate.title)] and not seen[candidate.id] and #matches<6 then
                    seen[candidate.id]=true
                    matches[#matches+1]={id=candidate.id,title=candidate.title,author=candidate.author,
                        source=source.name,source_id=source.id,in_library=candidate.in_library==true,
                        thumbnail=candidate.thumbnail,status=candidate.status,chapters=candidate.chapters}
                end
            end
            if #matches>0 then break end
        end
        result[tostring(item.id)]={matches=matches,failed=failed}
    end
    return result
end

function Recommendations.matches(item,sources)
    local rows,seen,checked,failed={}, {},0,0
    for position,source in ipairs(sources) do
        local result=item.sources and item.sources[source.id]
        if result then
            checked=checked+1
            if result.failed then failed=failed+1 end
            for _,candidate in ipairs(result.matches) do
                local key=candidate.source_id..":"..candidate.id
                if not seen[key] then
                    seen[key]=true
                    rows[#rows+1]={item=candidate,position=position}
                end
            end
        end
    end
    table.sort(rows,function(a,b)
        if a.item.in_library~=b.item.in_library then return a.item.in_library end
        if a.position~=b.position then return a.position<b.position end
        return a.item.id<b.item.id
    end)
    return rows,checked,failed
end

return Recommendations
