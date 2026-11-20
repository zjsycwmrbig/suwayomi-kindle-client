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

-- Source entries carry a canonical ID only when the server has an AniList track record.
function Recommendations.search(client, source, item)
    local names = search_names(item, Languages.base(source.lang))
    local aliases = {}
    for _, name in ipairs(names) do aliases[normalize(name)] = true end
    for i = 1, math.min(2, #names) do
        local page, err = client:sourcePage{source=source, mode="SEARCH", page=1,
            search=names[i], recommendation=true}
        if not page then return nil, err end
        local best, best_rank
        for _, candidate in ipairs(page.mangas) do
            local tracked = candidate.anilist_id
            local matches = tracked == item.id or (not tracked and aliases[normalize(candidate.title)])
            if matches and candidate.id ~= item.origin then
                local rank = (tracked and 2 or 0) + (candidate.in_library and 1 or 0)
                if not best_rank or rank > best_rank then
                    best, best_rank = candidate, rank
                end
            end
        end
        if best then
            best.source_id, best.source = source.id, source.name
            return {matches={best}}
        end
    end
    return {matches={}}
end

-- Legacy snapshots may have several source editions inside one AniList recommendation.
function Recommendations.results(snapshot, manga_id)
    local results, seen_media, seen_entries = {}, {}, {[tostring(manga_id)]=true}
    for _, item in ipairs(snapshot.items) do
        local sources = snapshot.source_order
        if not sources then
            sources = {}
            for id in pairs(item.sources or {}) do sources[#sources+1] = id end
            table.sort(sources)
        end
        if item.id ~= snapshot.media and not seen_media[item.id] then
            for _, id in ipairs(sources) do
                local cached = item.sources and item.sources[id]
                for _, candidate in ipairs(cached and cached.matches or {}) do
                    local key = tostring(candidate.id)
                    if not seen_entries[key] and (not candidate.anilist_id or candidate.anilist_id == item.id) then
                        results[#results+1] = candidate
                        seen_entries[key], seen_media[item.id] = true, true
                        break
                    end
                end
                if seen_media[item.id] then break end
            end
        end
    end
    return results
end

return Recommendations
