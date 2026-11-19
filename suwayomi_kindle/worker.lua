local FFI = require("ffi/util")
local JSON = require("dkjson")
local Connection = require("suwayomi_kindle/connection")
local Index = require("suwayomi_kindle/library_index")
local Worker = {}

function Worker.run(config, action, input)
    local client, err = Connection.open(config)
    if not client then return nil, err end
    if action == "sources" then
        return client:sources(input.language)
    elseif action == "source_page" then
        return client:sourcePage(input)
    elseif action == "library" then
        return Index.new(config):refresh(function(offset, limit) return client:libraryPage(offset, limit) end)
    elseif action == "add" then
        local added, add_error = client:addManga(input.id)
        if not added then return nil, add_error end
        local saved = Index.new(config):upsert(input)
        return {added = true, warning = not saved and "已加入服务器书架，请重新拉取本地书架。" or nil}
    elseif action == "covers" then
        return require("suwayomi_kindle/covers").fetch(client, input)
    end
    return nil, "未知请求。"
end

-- A shared anonymous temporary file avoids blocking the child on a full pipe.
function Worker.start(ui, config, action, input, callback)
    local file = io.tmpfile()
    if not file then callback(nil, "无法创建临时文件。"); return end
    local pid = FFI.runInSubProcess(function()
        local ok, data, err = pcall(Worker.run, config, action, input)
        if not ok then data, err = nil, "请求未完成。" end
        file:write(JSON.encode({data = data, error = err}))
        file:flush()
    end)
    if not pid then file:close(); callback(nil, "无法启动后台任务。"); return end
    local job = {deadline = os.time() + (action == "library" and 300 or 60)}
    function job:cancel()
        if self.cancelled then return end
        self.cancelled = true
        FFI.terminateSubProcess(pid)
    end
    local function poll()
        if not FFI.isSubProcessDone(pid) then
            if not job.cancelled and os.time() >= job.deadline then
                job:cancel()
                callback(nil, "请求超时，请重试。")
            end
            ui:scheduleIn(0.2, poll)
            return
        end
        local result
        if not job.cancelled and file:seek("end") <= 1024 * 1024 then
            file:seek("set", 0)
            result = JSON.decode(file:read("*a"))
        end
        file:close()
        if not job.cancelled then
            if result then callback(result.data, result.error)
            else callback(nil, "后台任务未返回完整结果。") end
        end
    end
    ui:scheduleIn(0.2, poll)
    return job
end

return Worker
