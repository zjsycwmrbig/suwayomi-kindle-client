local labels = {
    ONGOING = "连载中",
    COMPLETED = "已完结",
    LICENSED = "已授权",
    PUBLISHING_FINISHED = "出版完毕",
    CANCELLED = "已取消",
    ON_HIATUS = "休刊中",
}

local MangaStatus = {}

function MangaStatus.label(status)
    return labels[status] or "状态未知"
end

return MangaStatus
