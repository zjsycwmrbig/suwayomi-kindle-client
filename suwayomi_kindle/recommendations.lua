local AniList = require("suwayomi_kindle/anilist")
local Titles = require("suwayomi_kindle/manga_titles")
local Languages = require("suwayomi_kindle/languages")
local util = require("util")
local Recommendations = {}

local function search_names(item, lang, aliases)
    local names = {}
    if lang == "zh" then
        for _, group in ipairs({aliases or {}, item.synonyms or {}}) do
            for _, name in ipairs(group) do
                if util.hasCJKChar(name) then Titles.add(names, name) end
            end
        end
    elseif lang == "en" then
        Titles.add(names, item.titles.english)
    end
    for _, name in ipairs(Titles.anilist(item.titles, item.synonyms)) do Titles.add(names, name) end
    return names
end

function Recommendations.search(client, source, item)
    local lang = Languages.base(source.lang)
    local searched, identities = {}, {}
    local aliases = item.translations
    local alternate_checks = 0
    local function verify(candidate)
        local key = Titles.key(candidate.title)
        if identities[key] == nil then
            local id, err = AniList.resolve(candidate.title)
            if err then return nil, err end
            identities[key] = id
        end
        return identities[key] == item.id
    end
    local function search(names)
        local queries = 0
        for _, name in ipairs(names) do
            local key = Titles.key(name)
            if not searched[key] then
                searched[key] = true
                queries = queries + 1
                local page, err = client:sourcePage{source=source, mode="SEARCH", page=1,
                    search=name, recommendation=true}
                if not page then return nil, err end
                -- A tracker already supplies the canonical AniList ID on the source response.
                for _, candidate in ipairs(page.mangas) do
                    if candidate.id ~= item.origin and candidate.anilist_id == item.id then return candidate end
                end
                local alternatives = {}
                for _, candidate in ipairs(page.mangas) do
                    if candidate.id ~= item.origin and not candidate.anilist_id then
                        if Titles.contains(names, candidate.title) then
                            local same, check_err = verify(candidate)
                            if check_err then return nil, check_err end
                            if same then return candidate end
                        else
                            alternatives[#alternatives+1] = candidate
                        end
                    end
                end
                -- A source can answer a Japanese query with a different localized title.
                -- Bound extra reverse lookups across the entire source search.
                for _, candidate in ipairs(alternatives) do
                    if alternate_checks >= 2 then break end
                    if identities[Titles.key(candidate.title)] == nil then
                        alternate_checks = alternate_checks + 1
                        local same, check_err = verify(candidate)
                        if check_err then return nil, check_err end
                        if same then return candidate end
                    end
                end
                if queries == 3 then break end
            end
        end
        return false
    end
    local match, err = search(search_names(item, lang, aliases))
    if not match and not err and lang == "zh" and not aliases then
        aliases, err = Titles.translations(item.titles.native or item.titles.english or item.titles.romaji)
        if aliases and #aliases > 0 then match, err = search(search_names(item, lang, aliases)) end
    end
    if err then return nil, err end
    if match then
        match.source_id, match.source, match.anilist_id = source.id, source.name, item.id
    end
    return {matches=match and {match} or {}, translations=aliases}
end

function Recommendations.pageResults(snapshot, manga, page, size)
    local results, seen = {}, {[manga]=true}
    if not snapshot then return results end
    local first = (page - 1) * size + 1
    for i = first, math.min(#snapshot.items, first + size - 1) do
        local item = snapshot.items[i]
        for _, source in ipairs(snapshot.source_order or {}) do
            local cached = item.sources and item.sources[source]
            local match = cached and cached.verified and cached.matches[1]
            if match and match.anilist_id == item.id and not seen[match.id] then
                results[#results+1], seen[match.id] = match, true
                break
            end
        end
    end
    return results
end

return Recommendations
