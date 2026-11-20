local Titles = require("suwayomi_kindle/manga_titles")
local post = require("suwayomi_kindle/catalog_http")
local AniList = {}
local fields = [[id format title{english native romaji} synonyms]]

local function request(query, variables)
    return post("graphql.anilist.co", "", {query=query, variables=variables}, "AniList")
end

-- Search each distinct alias in one GraphQL round trip. Accept only an unambiguous exact name.
local function lookup(names, transport)
    local definitions, queries, variables = {}, {}, {}
    for i = 1, math.min(6, #names) do
        local key = "t" .. i
        definitions[i] = "$" .. key .. ":String!"
        queries[i] = key .. ":Page(perPage:5){media(type:MANGA,format_in:[MANGA,ONE_SHOT],isAdult:false,search:$"
            .. key .. "){" .. fields .. "}}"
        variables[key] = names[i]
    end
    if #queries == 0 then return false end
    local query = "query(" .. table.concat(definitions, ",") .. "){" .. table.concat(queries, " ") .. "}"
    local data, err = (transport or request)(query, variables)
    if not data then return nil, err end
    for i = 1, #queries do
        local page = data["t" .. i]
        if not page or type(page.media) ~= "table" then return nil, "AniList 作品响应不完整。" end
        local id
        for _, row in ipairs(page.media) do
            if Titles.contains(Titles.anilist(row.title, row.synonyms), names[i]) then
                if id and id ~= row.id then id = false; break end
                id = row.id
            end
        end
        if id then return id end
    end
    return false
end

function AniList.resolve(title, transport)
    local id, err = lookup({title}, transport)
    if id or err then return id, err end
    local aliases = Titles.translations(title)
    if not aliases then return false, nil, true end
    local names = {}
    for _, alias in ipairs(aliases) do
        if Titles.key(alias) ~= Titles.key(title) then names[#names+1] = alias end
    end
    return lookup(names, transport)
end

local function media(row)
    if type(row)~="table" or not tonumber(row.id) or type(row.title)~="table" then return end
    return {id=row.id, format=row.format, titles=row.title, synonyms=row.synonyms or {},
        title=row.title.english or row.title.romaji or row.title.native}
end

function AniList.recommend(id, title, limit, transport)
    if not id then
        local resolved, err, missing_aliases = AniList.resolve(title, transport)
        if err then return nil, err end
        if missing_aliases then return nil, "AniList 未能确认原作，别名服务暂不可用。请稍后重试。" end
        if not resolved then return {items={}, limit=limit, fetched_at=os.time(), version=2} end
        id = resolved
    end
    local query = [[query($id:Int!,$limit:Int!){Media(id:$id,type:MANGA){
        recommendations(page:1,perPage:$limit,sort:RATING_DESC){
        nodes{mediaRecommendation{type isAdult ]] .. fields .. [[}}}}}]]
    local data, err = (transport or request)(query, {id=id,limit=limit})
    if not data then return nil, err end
    local origin = data.Media
    local nodes = origin and origin.recommendations and origin.recommendations.nodes
    if type(nodes) ~= "table" then return nil, "AniList 未返回推荐列表。" end
    local items, seen = {}, {[id]=true}
    for _, node in ipairs(nodes) do
        local row = node.mediaRecommendation
        local item = media(row)
        if item and item.title and row.type=="MANGA" and not row.isAdult
            and (item.format=="MANGA" or item.format=="ONE_SHOT") and not seen[item.id] then
            seen[item.id] = true
            items[#items+1] = item
        end
    end
    return {items=items, media=id, limit=limit, fetched_at=os.time(), version=2}
end

return AniList
