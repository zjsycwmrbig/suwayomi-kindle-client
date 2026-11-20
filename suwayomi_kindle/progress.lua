local Progress = {}

function Progress.measure(total, unread)
    if not total or total <= 0 or not unread or unread < 0 or unread > total then return end
    local fraction = (total - unread) / total
    -- Reserve 100% for a fully read series, even for very long manga.
    return fraction, unread == 0 and 100 or math.min(99, math.floor(fraction * 100 + 0.5))
end

function Progress.badge(total, unread)
    local _, percent = Progress.measure(total, unread)
    if not percent then return total == 0 and "暂无章节" or "进度未知" end
    if unread == 0 then return "已读" end
    if unread == total then return "未读" end
    return string.format("%d/%d · %d%%", total - unread, total, percent), percent .. "%"
end

return Progress
