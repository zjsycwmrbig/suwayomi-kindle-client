local Languages = require("suwayomi_kindle/languages")
local Sources = {}

local function matches_language(source, selected)
    return selected.all or selected[Languages.base(source.lang)]
end

local function priority(pinned, id)
    return tonumber(pinned[id]) or (pinned[id] and 1 or 0)
end

function Sources.landing(sources, language, history, pinned)
    local selected, latest, order = Languages.set(language), nil, 0
    local top, rank = nil, math.huge
    for _, source in ipairs(sources) do
        if matches_language(source, selected) then
            local weight = priority(pinned or {}, source.id)
            if weight > 0 and weight < rank then top, rank = source, weight end
            local opened = history.opened[source.id] or 0
            if opened > order then latest, order = source, opened end
        end
    end
    return top or latest
end

function Sources.list(sources, language, filter, sort, pinned, opened)
    local selected, rows = Languages.set(language), {}
    for _, source in ipairs(sources) do
        if matches_language(source, selected) and source.name:lower():find(filter or "", 1, true) then
            rows[#rows+1] = source
        end
    end
    table.sort(rows, function(a, b)
        local pa, pb = priority(pinned, a.id), priority(pinned, b.id)
        if (pa > 0) ~= (pb > 0) then return pa > 0 end
        if pa ~= pb then return pa < pb end
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
