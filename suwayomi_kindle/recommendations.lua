local utf8 = require("ffi/utf8proc")
local Languages = require("suwayomi_kindle/languages")
local Recommendations = {}

local function normalize(text)
    local folded = utf8.lowercase(tostring(text or ""))
    -- Keep words and numbers denoting parts, editions and spin-offs.
    for _, separator in ipairs({"·", "・", "、", "—", "《", "》", "「", "」"}) do
        folded = folded:gsub(separator, "")
    end
    return (folded:gsub("[%s%p]", ""))
end

local function names(item, lang)
    local found, result = {}, {}
    local function add(name)
        if type(name)=="string" and name~="" and not found[name] then
            found[name]=true
            result[#result+1]=name
        end
    end
    if lang=="zh" then
        for _, name in ipairs(item.synonyms) do
            if name:find("[\228-\233][\128-\191][\128-\191]") and not name:find("[\227][\129-\131]") then add(name) end
        end
    end
    if lang=="zh" or lang=="ja" then add(item.titles.native) end
    add(item.titles.english)
    add(item.titles.romaji)
    add(item.titles.native)
    for _, name in ipairs(item.synonyms) do add(name) end
    return result
end

local function rank(candidate, item, bindings, title_keys)
    local bound = bindings[tostring(candidate.id)]
    if bound then return bound==item.id and 3 or nil end
    if not title_keys[normalize(candidate.title)] then return end
    local author = normalize(candidate.author)
    if author=="" or #item.authors==0 then return 1 end
    local names = {[author]=true}
    for name in candidate.author:gmatch("[^,;/&\n]+") do names[normalize(name)]=true end
    for _, name in ipairs(item.authors) do
        local key = normalize(name)
        if key~="" and names[key] then return 2 end
    end
end

function Recommendations.search(client, source, items, bindings)
    local result = {}
    local queries = {}
    for _, item in ipairs(items) do
        local terms = names(item, Languages.base(source.lang))
        local keys, seen, matches, failed = {}, {}, {}, false
        for _, term in ipairs(terms) do keys[normalize(term)] = true end
        for i=1,math.min(2,#terms) do
            local term = terms[i]
            local page = queries[term]
            if page==nil then
                page = client:sourcePage{source=source,mode="SEARCH",page=1,search=term} or false
                queries[term] = page
            end
            if page then
                for _, candidate in ipairs(page.mangas) do
                    local certainty = rank(candidate,item,bindings,keys)
                    if certainty and not seen[candidate.id] and #matches<6 then
                        seen[candidate.id] = true
                        matches[#matches+1] = {id=candidate.id,title=candidate.title,author=candidate.author,
                            source=source.name, source_id=source.id, in_library=candidate.in_library==true,
                            thumbnail=candidate.thumbnail, status=candidate.status, chapters=candidate.chapters, certainty=certainty}
                    end
                end
                if #matches>0 then break end
            else
                failed = true
                break
            end
        end
        result[tostring(item.id)] = {matches=matches, failed=failed}
    end
    return result
end

function Recommendations.matches(item, sources, bindings)
    local rows, seen, checked, failed = {}, {}, 0, 0
    for position, source in ipairs(sources) do
        local result = item.sources and item.sources[source.id]
        if result then
            checked = checked+1
            if result.failed then failed=failed+1 end
            for _, candidate in ipairs(result.matches) do
                local key = candidate.source_id .. ":" .. candidate.id
                local bound = bindings[tostring(candidate.id)]
                if not seen[key] and (not bound or bound==item.id) then
                    seen[key] = true
                    rows[#rows+1] = {item=candidate, rank=bound and 3 or math.min(2,candidate.certainty), position=position}
                end
            end
        end
    end
    table.sort(rows, function(a,b)
        if a.rank~=b.rank then return a.rank>b.rank end
        if a.item.in_library~=b.item.in_library then return a.item.in_library end
        if a.position~=b.position then return a.position<b.position end
        return a.item.id<b.item.id
    end)
    return rows, checked, failed
end

return Recommendations
