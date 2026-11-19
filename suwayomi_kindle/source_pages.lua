-- A provider supplies hasNextPage but no total. Keep only page lengths and
-- a single provider page. Each device page renders at most one screen.
local Pages = {}

function Pages.screens(count, size)
    return math.max(1, math.ceil(count / size))
end

function Pages.before(counts, remote, size)
    local offset = 0
    for i = 1, remote - 1 do offset = offset + Pages.screens(counts[i], size) end
    return offset
end

function Pages.fetch(client, input)
    local counts, size = input.counts or {}, input.size
    local target = input.target == "last" and math.huge or input.target
    local page, offset = 1, 0
    while counts[page] do
        local n = Pages.screens(counts[page], size)
        if offset + n >= target or (input.ended and page == #counts) then break end
        offset, page = offset + n, page + 1
    end
    local previous
    while true do
        local data, err = client:sourcePage{source = input.source, mode = input.mode, page = page, search = input.search}
        if not data then return nil, err end
        local count = #data.mangas
        local n = Pages.screens(count, size)
        local signature = count > 0 and (data.mangas[1].id .. "/" .. data.mangas[count].id .. "/" .. count)
        if data.has_next and (count == 0 or signature == previous) then return nil, "漫画源重复返回同一页，请稍后刷新。" end
        previous = signature
        local ended = input.ended or false
        if counts[page] and counts[page] ~= count then
            for j = #counts, page + 1, -1 do counts[j] = nil end
            ended = false
        end
        counts[page] = count
        if not data.has_next then
            for j = #counts, page + 1, -1 do counts[j] = nil end
            ended = true
        elseif page == #counts then ended = false end
        if target <= offset + n or not data.has_next then
            return {results = data, remote = page, slice = math.min(n, target - offset),
                counts = counts, ended = ended}
        end
        page, offset = page + 1, offset + n
    end
end
return Pages
