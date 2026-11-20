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

local traditional_pairs = {
    {"為","为"},{"與","与"},{"這","这"},{"來","来"},{"個","个"},{"們","们"},{"會","会"},{"時","时"},
    {"說","说"},{"後","后"},{"裡","里"},{"發","发"},{"國","国"},{"學","学"},{"體","体"},{"臺","台"},
    {"萬","万"},{"啓","启"},{"啟","启"},{"喫","吃"},{"衆","众"},{"眾","众"},{"鏈","链"},{"鋸","锯"},
    {"電","电"},{"進","进"},{"擊","击"},{"巨","巨"},{"術","术"},{"戰","战"},{"獸","兽"},{"讀","读"},
    {"者","者"},{"視","视"},{"角","角"},{"鋼","钢"},{"鍊","炼"},{"術","术"},{"師","师"},{"龍","龙"},
    {"劍","剑"},{"擊","击"},{"魔","魔"},{"導","导"},{"夢","梦"},{"戲","戏"},{"愛","爱"},{"情","情"},
}
local traditional = {}
for _, pair in ipairs(traditional_pairs) do traditional[pair[1]] = true end

function Titles.isTraditional(name)
    for char in (name or ""):gmatch(char_pattern) do
        if traditional[char] then return true end
    end
    return false
end

return Titles
