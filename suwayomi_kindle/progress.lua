local Progress = {}

function Progress.measure(total, unread)
    if not total or total <= 0 or not unread or unread < 0 or unread > total then return end
    local fraction = (total - unread) / total
    -- Reserve 100% for a fully read series, even for very long manga.
    return fraction, unread == 0 and 100 or math.min(99, math.floor(fraction * 100 + 0.5))
end

return Progress
