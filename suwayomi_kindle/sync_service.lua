local UI = require("ui/uimanager")
local Records = require("suwayomi_kindle/records")
local Worker = require("suwayomi_kindle/worker")
local Service = {}
local sessions = {}

function Service.session(index,home)
    local key=index.path
    local state=sessions[key] or {}
    sessions[key]=state
    if home then state.home=home end
    return state
end

function Service.detach(index,home)
    local state=index and sessions[index.path]
    if state and state.home==home then state.home=nil end
end

local function refresh(state,index)
    local home=state.home
    if home and home.alive and home.index and home.index.path==index.path and home.settings_route=="sync"
        and home.selected_tab=="settings" then home:refresh() end
end

function Service.run(index,config,action,cutoff,all_chapters)
    local state=Service.session(index)
    if state.busy then return end
    if state.timer then UI:unschedule(state.timer); state.timer=nil end
    local label=action=="push" and "上传" or (all_chapters and "全库拉取" or "拉取")
    state.busy=label
    Records.log(index,"开始" .. label)
    refresh(state,index)
    Worker.start(UI,config,"sync_" .. action,{cutoff=cutoff,all_chapters=all_chapters},function(result,err)
        state.busy=nil
        Records.log(index,result and result.message or label .. "失败 · " .. (err or "后台任务中断。"))
        if action=="pull" and result then
            local settings=require("suwayomi_kindle/settings_store"):new():load("download")
            require("suwayomi_kindle/queue").reconcile(index,config,settings)
        end
        refresh(state,index)
        if state.changed then
            state.changed=nil
            Service.schedule(index,config)
        end
    end)
end

function Service.schedule(index,config)
    local state=Service.session(index)
    if state.busy then state.changed=true; return end
    if state.timer then return end
    state.timer=function()
        state.timer=nil
        local status=Records.status(index)
        if status and status.count>0 then Service.run(index,config,"push",status.cutoff) end
    end
    UI:scheduleIn(20,state.timer)
end

return Service
