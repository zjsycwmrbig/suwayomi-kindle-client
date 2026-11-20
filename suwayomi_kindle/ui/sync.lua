local UI = require("ui/uimanager")
local Screen = require("device").screen
local Text = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Column = require("ui/widget/verticalgroup")
local Space = require("ui/widget/verticalspan")
local Row = require("suwayomi_kindle/ui/setting_row")
local Records = require("suwayomi_kindle/records")
local Service = require("suwayomi_kindle/sync_service")
local Sync = {}


function Sync:start_sync(action,status,all_chapters)
    local index = self:local_index()
    if Service.session(index,self).busy then return end
    local function start() Service.run(index,self.settings.connection,action,status.cutoff,all_chapters) end
    if action=="pull" and (all_chapters or status.count>0) then
        local prompt = all_chapters and "逐部拉取整个书架的章节目录和进度，书架较大时可能需要较长时间。" or ""
        if status.count>0 then prompt=prompt .. "存在 " .. status.count .. " 条待上传记录，成功刷新的目录将采用服务器进度。" end
        UI:show(require("ui/widget/confirmbox"):new{text=prompt .. "继续？",ok_callback=start})
    else start() end
end

function Sync:build_sync(screen_width,height)
    local width=screen_width-Screen:scaleBySize(48)
    local col=Column:new{align="left",Space:new{width=Screen:scaleBySize(10)}}
    local function note(text)
        col[#col+1]=Text:new{width=width,text=text,face=Font:getFace("smallinfofont",16)}
        col[#col+1]=Space:new{width=Screen:scaleBySize(7)}
    end
    if self.settings.connection.server_url=="" then note("先在连接设置中填写服务器地址。")
    else
        local index=self:local_index()
        local limit=math.max(1,math.floor((height-Screen:scaleBySize(270))/Screen:scaleBySize(52)))
        local status,err=Records.status(index,self.log_page,limit)
        if not status then note(err)
        else
            self.log_page=status.page
            self.pagination={page=status.page,total=status.pages,go=function(n) self.log_page=n; self:refresh() end}
            local busy=Service.session(index,self).busy
            col[#col+1]=Row:new{width=width,label="同步本地记录",value="上传已读状态和页码 · 待上传 " .. status.count .. " 项",
                callback=function() self:start_sync("push",status) end}
            col[#col+1]=Row:new{width=width,label="从服务器同步",value="刷新书架，更新已打开、已缓存或有本地任务的漫画目录",
                callback=function() self:start_sync("pull",status) end}
            col[#col+1]=Row:new{width=width,label="同步全部章节",value="逐部更新整个书架的目录和阅读进度",
                callback=function() self:start_sync("pull",status,true) end}
            note(busy and ("同步日志 · 正在" .. busy) or "同步日志")
            if #status.logs==0 then note("尚无同步记录") end
            for _,line in ipairs(status.logs) do note(line) end
        end
    end
    return self:settings_page_frame(screen_width,height,width,col)
end

return Sync
