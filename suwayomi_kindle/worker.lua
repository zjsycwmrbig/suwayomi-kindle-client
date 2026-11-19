local FFI = require("ffi/util")
local JSON = require("dkjson")
local Connection = require("suwayomi_kindle/connection")
local Index = require("suwayomi_kindle/library_index")
local Chapters = require("suwayomi_kindle/chapters")
local Worker = {}

function Worker.run(config, action, input)
    if action == "verify" then return Connection.test(config) end
    if action == "scan_downloads" then return require("suwayomi_kindle/tasks").scan(Index.new(config),input.directory) end
    local client, err = Connection.open(config)
    if not client then return nil, err end
    if action == "sync_push" then
        return require("suwayomi_kindle/records").push(Index.new(config),client,input.cutoff)
    elseif action == "sync_pull" then
        return require("suwayomi_kindle/records").pull(Index.new(config),client,input.cutoff)
    elseif action == "sources" then
        return client:sources(input.language)
    elseif action == "source_seek" then
        return require("suwayomi_kindle/source_pages").fetch(client, input)
    elseif action == "source_page" then
        return client:sourcePage(input)
    elseif action == "library" then
        return Index.new(config):refresh(function(offset, limit) return client:libraryPage(offset, limit) end)
    elseif action == "add" then
        local added, add_error = client:addManga(input.id)
        if not added then return nil, add_error end
        local saved = Index.new(config):upsert(input)
        return {added = true, warning = not saved and "已加入服务器书架，请重新拉取本地书架。" or nil}
    elseif action == "detail" then
        local item, failure = client:manga(input.id)
        if item then Chapters.saveDescription(Index.new(config),item) end
        return item, failure
    elseif action == "membership" then
        local ok, failure = client:setMembership(input.item.id,input.enabled)
        if not ok then return nil, failure end
        local index = Index.new(config)
        local saved
        if input.enabled then saved = index:upsert(input.item) else saved = index:remove(input.item.id) end
        return {enabled = input.enabled, warning = not saved and "服务器已更新，请刷新本地书架。" or nil}
    elseif action == "chapters" then
        return Chapters.refresh(Index.new(config),client,input.id,input.force)
    elseif action == "chapter_read" then
        local ok, failure = client:setRead(input.id,input.read)
        if not ok then return nil, failure end
        return Chapters.setRead(Index.new(config),input.manga,input.id,input.read)
    elseif action == "download" then
        return Chapters.download(Index.new(config),client,input)
    elseif action == "covers" then
        return require("suwayomi_kindle/covers").fetch(client, input)
    end
    return nil, "未知请求。"
end

function Worker.writeResult(file, config, action, input)
    local ok, data, err = pcall(Worker.run, config, action, input)
    if not ok then data, err = nil, "请求未完成。" end
    file:write(JSON.encode({data = data, error = err}))
    file:flush()
end

function Worker.readResult(file)
    local size = file:seek("end")
    if size and size > 0 and size <= 1024 * 1024 and file:seek("set", 0) then
        local ok, envelope, next_pos = pcall(JSON.decode, file:read("*a"))
        if ok and type(envelope) == "table" and next_pos == size + 1 then
            if type(envelope.data) == "table" then return envelope.data end
            if type(envelope.error) == "string" then return nil, envelope.error end
        end
    end
    return nil, "后台任务未返回完整结果，请重试。"
end

function Worker.start(ui, config, action, input, callback)
    local file = io.tmpfile()
    if not file then callback(nil, "无法创建临时文件。"); return end
    local pid
    if jit.os == "OSX" then
        pid = require("suwayomi_kindle/macos_spawn")(JSON.encode({
            config = config, action = action, input = input,
        }), file)
    else
        pid = FFI.runInSubProcess(function() Worker.writeResult(file, config, action, input) end)
    end
    if not pid then file:close(); callback(nil, "无法启动后台任务。"); return end
    local job = {deadline = os.time() + ((action == "download" or action == "sync_pull" or action == "sync_push" or action == "scan_downloads") and 1200 or (action == "library" or action == "source_seek" or action == "chapters") and 300 or 60)}
    function job:cancel()
        if self.cancelled or self.finished then return end
        self.cancelled = true
        if jit.os == "OSX" then require("ffi").C.kill(pid, 9)
        else FFI.terminateSubProcess(pid) end
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
        job.finished = true
        local data, err
        if not job.cancelled then data, err = Worker.readResult(file) end
        file:close()
        if action == "download" then
            local path = Chapters.downloadPath(Index.new(config),input)
            os.remove(path .. "." .. tonumber(pid) .. ".part")
        end
        if not job.cancelled then callback(data, err) end
    end
    ui:scheduleIn(0.2, poll)
    return job
end

return Worker
