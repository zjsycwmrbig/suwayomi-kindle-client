local AniList = require("suwayomi_kindle/anilist")
local Titles = require("suwayomi_kindle/manga_titles")
local Languages = require("suwayomi_kindle/languages")
local Recommendations = {}

function Recommendations.searchLanguage(preference, source)
    if preference == "zh" or preference == "en" or preference == "ja" then return preference end
    return Languages.base(source.lang)
end

local function chinese_names(item, translations)
    local names = {}
    for _, group in ipairs({translations or {}, item.synonyms or {}}) do
        for _, name in ipairs(group) do
            if Titles.isChineseAlias(name) and Titles.key(name) ~= Titles.key((item.titles or {}).native) then
                Titles.add(names, name)
            end
        end
    end
    return names
end

local function search_names(item, lang, translations)
    local names = {}
    local titles = item.titles or {}
    if lang == "zh" then
        names = chinese_names(item, translations)
    elseif lang == "en" then
        Titles.add(names, titles.english)
        Titles.add(names, titles.romaji)
    elseif lang == "ja" then
        Titles.add(names, titles.native)
    end
    for _, name in ipairs(Titles.anilist(titles, item.synonyms)) do Titles.add(names, name) end
    Titles.add(names, item.title)
    return names
end

local function localized_names(item, source, preference)
    local lang = Recommendations.searchLanguage(preference, source)
    local translations = item.translations
    local incomplete = false
    if lang == "zh" and not translations and #chinese_names(item) == 0 then
        local inputs = Titles.anilist(item.titles)
        Titles.add(inputs, item.title)
        local aliases = {}
        for i = 1, math.min(2, #inputs) do
            local found = Titles.translations(inputs[i])
            if found then
                for _, alias in ipairs(found) do Titles.add(aliases, alias) end
                if #chinese_names(item, aliases) > 0 then break end
            else
                incomplete = true
                break
            end
        end
        if not incomplete or #aliases > 0 then translations = aliases end
    end
    return search_names(item, lang, translations), translations, incomplete
end

function Recommendations.explore(client, input)
    local fetch = require("suwayomi_kindle/source_pages").fetch
    local names = localized_names(input.recommended_item, input.source, input.search_language)
    local first_empty
    for i = 1, math.min(3, #names) do
        input.search = names[i]
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

function Recommendations.search(client, source, item, preference)
    local identities = {}
    local alternate_checks = 0
    local names, aliases, incomplete = localized_names(item, source, preference)
    local function verify(candidate)
        local key = Titles.key(candidate.title)
        if identities[key] == nil then
            local id, err, missing_aliases = AniList.resolve(candidate.title)
            incomplete = incomplete or missing_aliases
            if err then return nil, err end
            identities[key] = id
        end
        return identities[key] == item.id
    end
    local function search()
        for i = 1, math.min(3, #names) do
            local page, err = client:sourcePage{source=source, mode="SEARCH", page=1,
                search=names[i], recommendation=true}
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
        end
        return false
    end
    local match, err = search()
    if err then return nil, err end
    if match then
        match.source_id, match.source, match.anilist_id = source.id, source.name, item.id
    end
    return {matches=match and {match} or {}, translations=aliases, failed=not match and incomplete or nil}
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
