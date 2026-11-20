local utf8 = require("ffi/utf8proc")
local charcode = require("ffi/util").utf8charcode
local char_pattern = require("util").UTF8_CHAR_PATTERN
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

function Titles.scripts(name)
    local han, kana, hangul, latin = false, false, false, false
    if type(name) ~= "string" then return han, kana, hangul, latin end
    for char in name:gmatch(char_pattern) do
        local code = charcode(char)
        kana = kana or (code >= 0x3041 and code <= 0x30FF and code ~= 0x30FB)
            or (code >= 0x31F0 and code <= 0x31FF) or (code >= 0xFF66 and code <= 0xFF9F)
        hangul = hangul or (code >= 0x1100 and code <= 0x11FF)
            or (code >= 0x3130 and code <= 0x318F) or (code >= 0xAC00 and code <= 0xD7FF)
        latin = latin or char:match("^[A-Za-z]$") ~= nil
            or (code >= 0xFF21 and code <= 0xFF3A) or (code >= 0xFF41 and code <= 0xFF5A)
        han = han or (code >= 0x3400 and code <= 0x9FFF)
            or (code >= 0xF900 and code <= 0xFAFF) or (code >= 0x20000 and code <= 0x323AF)
    end
    return han, kana, hangul, latin
end

-- Retain the section between the first and last Han characters when an alias
-- also has a Latin prefix or suffix, e.g. "ONE PIECE～航海王～".
function Titles.hanPart(name)
    local first, last
    for offset, char in name:gmatch("()(" .. char_pattern .. ")") do
        if Titles.scripts(char) then
            first, last = first or offset, offset + #char - 1
        end
    end
    if first then return name:sub(first, last) end
end

return Titles
