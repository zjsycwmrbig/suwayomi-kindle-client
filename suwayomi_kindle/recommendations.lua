local AniList = require("suwayomi_kindle/anilist")
local Titles = require("suwayomi_kindle/manga_titles")
local Languages = require("suwayomi_kindle/languages")
local Recommendations = {}

local function search_names(item, order)
    local titles = item.titles or {}
    local groups, mixed = {zh={}, en={}, ja={}}, {}
    if item.country == "CN" or item.country == "TW" or item.country == "HK" then
        Titles.add(groups.zh, titles.native)
    end
    Titles.add(groups.en, titles.english)
    if item.country == "JP" or not item.country then Titles.add(groups.ja, titles.native) end
    for _, name in ipairs(item.synonyms or {}) do
        local han, kana, hangul, latin = Titles.scripts(name)
        if kana then
            Titles.add(groups.ja, name)
        elseif han and not hangul and Titles.key(name) ~= Titles.key(titles.native) then
            if latin then
                Titles.add(mixed, Titles.hanPart(name))
                Titles.add(mixed, name)
            else
                Titles.add(groups.zh, name)
            end
        end
    end
    for _, name in ipairs(mixed) do Titles.add(groups.zh, name) end
    if #groups.zh == 0 and not titles.native and not titles.english then
        local han, kana, hangul = Titles.scripts(item.title)
        if han and not kana and not hangul then Titles.add(groups.zh, item.title) end
    end
    if item.country == "JP" or not item.country then Titles.add(groups.ja, titles.romaji) end

    local names, known = {}, Titles.anilist(titles, item.synonyms)
    Titles.add(known, item.title)
    for _, lang in ipairs(Languages.titleOrder(order)) do
        local group = groups[lang]
        for i, name in ipairs(group) do
            Titles.add(known, name)
            if i <= (lang == "zh" and 3 or 2) then Titles.add(names, name) end
        end
    end
    if #names == 0 then
        Titles.add(names, titles.native)
        Titles.add(names, titles.romaji)
        Titles.add(names, item.title)
    end
    return names, known
end

function Recommendations.preferredTitle(item, order)
    local names = search_names(item, order)
    return names[1] or item.title
end

function Recommendations.explore(client, input)
    local fetch = require("suwayomi_kindle/source_pages").fetch
    local names = search_names(input.recommended_item, input.search_languages)
    local first_empty
    for _, name in ipairs(names) do
        input.search = name
        local page, err = fetch(client, input)
        if not page then
            if not first_empty then return nil, err end
            break
        end
        page.search = input.search
        if #page.results.mangas > 0 then return page end
        first_empty = first_empty or page
        input.counts = {}
    end
    if first_empty then return first_empty end
    return nil, "没有可搜索的书名。"
end

function Recommendations.search(client, source, item, order)
    local names, known = search_names(item, order)
    local checked, verification_error = {}, nil
    local function result(candidate)
        candidate.source_id, candidate.source, candidate.anilist_id = source.id, source.name, item.id
        return {matches={candidate}}
    end
    for _, name in ipairs(names) do
        local page, err = client:sourcePage{source=source, mode="SEARCH", page=1,
            search=name, recommendation=true}
        if not page then return nil, err end
        local candidates, titles = {}, {}
        for _, candidate in ipairs(page.mangas) do
            if candidate.id ~= item.origin then
                if candidate.anilist_id == item.id then return result(candidate) end
                local key = Titles.key(candidate.title)
                if not candidate.anilist_id and not checked[key] and #titles < 6
                    and Titles.contains(known, candidate.title) then
                    checked[key] = true
                    titles[#titles+1], candidates[#candidates+1] = candidate.title, candidate
                end
            end
        end
        if #titles > 0 and not verification_error then
            local identities, failure = AniList.identify(titles)
            if identities then
                for _, candidate in ipairs(candidates) do
                    if identities[candidate.title] == item.id then return result(candidate) end
                end
            else
                verification_error = failure
            end
        end
    end
    if verification_error then return nil, verification_error end
    return {matches={}}
end

function Recommendations.pageResults(snapshot, manga, page, size)
    local results, seen = {}, {[manga]=true}
    if not snapshot then return results end
    local first = (page - 1) * size + 1
    for i = first, math.min(#snapshot.items, first + size - 1) do
        local item = snapshot.items[i]
        local slot = {item=item}
        results[#results+1] = slot
        for _, source in ipairs(snapshot.source_order or {}) do
            local cached = item.sources and item.sources[source]
            local match = cached and cached.verified and cached.matches[1]
            if match and match.anilist_id == item.id and not seen[match.id] then
                slot.match, seen[match.id] = match, true
                break
            end
        end
    end
    return results
end

return Recommendations
