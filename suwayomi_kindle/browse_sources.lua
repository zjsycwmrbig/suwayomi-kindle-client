local Languages = require("suwayomi_kindle/languages")
local Sources = {}

local function matches_language(source, selected)
    return selected.all or selected[Languages.base(source.lang)]
end

function Sources.landing(sources, language, history)
    local selected, latest, order = Languages.set(language), nil, 0
    for _, source in ipairs(sources) do
        if matches_language(source, selected) then
            if source.id == history.default_id then return source end
            local opened = history.opened[source.id] or 0
            if opened > order then latest, order = source, opened end
        end
    end
    return latest
end

function Sources.list(sources, language, filter, sort, pinned, opened)
    local selected, rows = Languages.set(language), {}
    for _, source in ipairs(sources) do
        if matches_language(source, selected) and source.name:lower():find(filter or "", 1, true) then
            rows[#rows+1] = source
        end
    end
    table.sort(rows, function(a, b)
        if pinned[a.id] ~= pinned[b.id] then return pinned[a.id] == true end
        if sort == "opened" then
            local x, y = opened[a.id] or 0, opened[b.id] or 0
            if x ~= y then return x > y end
        elseif sort == "language" and a.lang ~= b.lang then return a.lang < b.lang end
        local x, y = a.name:lower(), b.name:lower()
        if x ~= y then return x < y end
        return a.id < b.id
    end)
    return rows
end

return Sources
