local utf8 = require("ffi/utf8proc")
local charcode = require("ffi/util").utf8charcode
local char_pattern = require("util").UTF8_CHAR_PATTERN
local post = require("suwayomi_kindle/catalog_http")
local Titles = {}

function Titles.key(name)
    if type(name) ~= "string" then return "" end
    return (utf8.lowercase(name):gsub("[%s%p]", ""):gsub("【", ""):gsub("】", ""):gsub("・", ""))
end

function Titles.contains(names, name)
    local key = Titles.key(name)
    if key == "" then return false end
    for _, value in ipairs(names) do
        if Titles.key(value) == key then return true end
    end
    return false
end

function Titles.add(names, name)
    if Titles.key(name) ~= "" and not Titles.contains(names, name) then names[#names+1] = name end
end

function Titles.anilist(titles, synonyms)
    local names = {}
    titles = titles or {}
    Titles.add(names, titles.native)
    Titles.add(names, titles.english)
    Titles.add(names, titles.romaji)
    for _, name in ipairs(synonyms or {}) do Titles.add(names, name) end
    return names
end

function Titles.isChineseAlias(name)
    if type(name) ~= "string" then return false end
    local has_han = false
    for char in name:gmatch(char_pattern) do
        local code = charcode(char)
        if (code >= 0x3040 and code <= 0x30FF) or (code >= 0x31F0 and code <= 0x31FF)
            or (code >= 0xFF66 and code <= 0xFF9F) or (code >= 0x1100 and code <= 0x11FF)
            or (code >= 0x3130 and code <= 0x318F) or (code >= 0xAC00 and code <= 0xD7FF) then
            return false
        end
        has_han = has_han or (code >= 0x3400 and code <= 0x9FFF)
            or (code >= 0xF900 and code <= 0xFAFF) or (code >= 0x20000 and code <= 0x323AF)
    end
    return has_han
end

-- A book's translated title can be in name_cn or the infobox. Search rank alone
-- would turn titles such as ONE PIECE into a volume, spin-off or adaptation.
function Titles.translations(title)
    local rows, err = post("api.bgm.tv", "/v0/search/subjects?limit=8",
        {keyword=title, filter={type={1}}}, "Bangumi")
    if not rows then return nil, err end
    local result, localized, original = {}, {}, nil
    for _, book in ipairs(rows) do
        local names = {}
        Titles.add(names, book.name)
        Titles.add(names, book.name_cn)
        for _, field in ipairs(book.infobox or {}) do
            if field.key == "别名" or field.key == "中文名" then
                if type(field.value) == "table" then
                    for _, value in ipairs(field.value) do
                        Titles.add(names, type(value) == "table" and value.v or value)
                    end
                else
                    Titles.add(names, field.value)
                end
            end
        end
        if Titles.contains(names, title) then
            local key = Titles.key(book.name)
            if original and original ~= key then return {} end
            original = key
            Titles.add(localized, book.name_cn)
            for _, name in ipairs(names) do Titles.add(result, name) end
        end
    end
    for _, name in ipairs(result) do Titles.add(localized, name) end
    return localized
end

return Titles
