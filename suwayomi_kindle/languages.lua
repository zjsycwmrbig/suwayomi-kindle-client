local Languages = {}
local names = {zh="中文", en="英语", ja="日语", ko="韩语", fr="法语", de="德语", es="西班牙语",
    pt="葡萄牙语", ru="俄语", it="意大利语", ar="阿拉伯语", id="印尼语", vi="越南语",
    th="泰语", tr="土耳其语", pl="波兰语", uk="乌克兰语", multi="多语言", other="其他"}
local preferred = {"zh", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it",
    "ar", "id", "vi", "th", "tr", "pl", "uk", "multi", "other"}

function Languages.base(code)
    return (code or ""):lower():match("^[^_%-]+") or "other"
end

function Languages.set(value)
    local set = {}
    for code in (value or ""):gmatch("[^,]+") do set[code] = true end
    return set
end

function Languages.options(value, sources)
    local options, seen, extra = {}, {}, {}
    for _, code in ipairs(preferred) do options[#options+1], seen[code] = code, true end
    local function append(code)
        if code ~= "all" and not seen[code] then extra[#extra+1], seen[code] = code, true end
    end
    for code in pairs(Languages.set(value)) do append(code) end
    for _, source in ipairs(sources or {}) do append(Languages.base(source.lang)) end
    table.sort(extra)
    for _, code in ipairs(extra) do options[#options+1] = code end
    return options
end

function Languages.label(code) return names[code] or code end

function Languages.summary(value)
    if value == "all" then return "全部语言" end
    local labels = {}
    for code in value:gmatch("[^,]+") do labels[#labels+1] = Languages.label(code) end
    if #labels == 0 then return "未选择" end
    if #labels > 3 then return table.concat(labels, "、", 1, 2) .. "等 " .. #labels .. " 种" end
    return table.concat(labels, "、")
end

function Languages.toggle(value, code, options)
    if code == "all" then return value == "all" and "" or "all" end
    local selected = Languages.set(value)
    if value == "all" then for _, opt in ipairs(options) do selected[opt] = true end end
    selected[code] = not selected[code]
    local result = {}
    for _, opt in ipairs(options) do if selected[opt] then result[#result+1] = opt end end
    return table.concat(result, ",")
end
return Languages
