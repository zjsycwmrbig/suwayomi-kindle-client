-- Boundary: primary application shell.
--
-- Responsibility: compose the shared flat header, top-aligned page body, and
-- bottom tabs. Settings behavior lives in suwayomi_kindle/ui/settings.
-- Owned state: selected tab, settings route, and connection draft.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Config = require("suwayomi_kindle/config")
local Pager = require("suwayomi_kindle/ui/pager")
local Drawer = require("suwayomi_kindle/ui/drawer")
local Header = require("suwayomi_kindle/ui/header")
local Settings = require("suwayomi_kindle/ui/settings")
local TabBar = require("suwayomi_kindle/ui/tab_bar")

local Screen = Device.screen

local Home = InputContainer:extend{
    plugin = nil,
    settings_store = nil,
    selected_tab = "library",
    settings_route = "index",
    alive = true,
}

local TAB_ITEMS = {
    { id = "library", label = "书架", icon = "library" },
    { id = "browse", label = "探索", icon = "browse" },
    { id = "tasks", label = "下载任务", icon = "download" },
    { id = "settings", label = "设置", icon = "settings" },
}

function Home:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true
    self.settings = {}
    for _, section in ipairs({"connection", "download", "library", "browse", "theme", "general"}) do
        self.settings[section] = self.settings_store:load(section)
    end
    self.previous_night_mode = Screen.night_mode == true
    self:apply_night_mode(self.settings.theme.mode == "night")
    self.draft = self.settings_store:load("connection")
    self:reset_catalog()
    if self.reader_origin then
        local row=self.reader_origin
        self.settings.connection,self.index=row.config,row.index
        self.detail={id=row.manga,title=row.title,in_library=true}
        self.directory={page=1,anchor=row.pos,target=row.id}
    end
    self.dirty = false
    self.verifying = false
    if Config.trim(self.draft.server_url) == "" then
        self.selected_tab = "settings"
    end
    if self.settings.connection.server_url ~= "" then
        local queue = require("suwayomi_kindle/queue")
        queue.start(queue.attach(self:local_index(),self.settings.connection,self.settings.download,self))
        require("suwayomi_kindle/sync_service").schedule(self.index,self.settings.connection)
    end
    self:refresh()
end

function Home:apply_night_mode(enabled)
    if (Screen.night_mode == true) ~= enabled then
        Screen:toggleNightMode()
        UIManager:ToggleNightMode(enabled)
        UIManager:setDirty("all", "full")
    end
end

function Home:close()
    UIManager:close(self)
end

function Home:request_exit()
    if not self.settings.general.confirm_exit then self:close(); return end
    if self.exit_dialog and UIManager:isWidgetShown(self.exit_dialog) then return end
    self:finish_field()
    self.exit_dialog = require("ui/widget/confirmbox"):new{
        text = "退出 Suwayomi Kindle？",
        ok_text = "退出",
        cancel_text = "取消",
        ok_callback = function() self:close() end,
    }
    UIManager:show(self.exit_dialog)
end

function Home:handleEvent(event)
    if event.handler == "onCloseWidget" then
        self:release_input_form()
    end
    return InputContainer.handleEvent(self, event)
end

function Home:onCloseWidget()
    if self.task_progress_timer then UIManager:unschedule(self.task_progress_timer); self.task_progress_timer=nil end
    require("suwayomi_kindle/queue").detach(self.index,self)
    require("suwayomi_kindle/sync_service").detach(self.index,self)
    self:close_drawer()
    if self.verification_job then self.verification_job:cancel(); self.verification_job = nil end
    self:cancel_catalog()
    self:apply_night_mode(self.previous_night_mode)
    self.alive = false
end

function Home:set_tab(tab_id)
    self:close_drawer()
    if self.selected_tab == tab_id then
        if tab_id == "settings" and self.settings_route ~= "index" then
            self.settings_route = "index"
            self:refresh()
        end
        return
    end
    self:cancel_catalog()
    self.detail, self.directory,self.reader_origin = nil, nil,nil
    self.catalog_message = nil
    self.selected_tab = tab_id
    if tab_id == "browse" then self.browse.auto_open = true end
    if tab_id=="tasks" and self.settings.connection.server_url~="" then
        local queue=require("suwayomi_kindle/queue")
        queue.start(queue.attach(self:local_index(),self.settings.connection,self.settings.download,self))
    end
    if tab_id == "settings" then
        self.settings_route = "index"
    end
    self:refresh()
end

function Home:open_drawer()
    local actions = self:catalog_actions()
    if self.drawer or not actions then return end
    self:finish_field()
    self.drawer = Drawer:new{owner = self, actions = actions}
    UIManager:show(self.drawer, "ui", self.drawer.dimen, 0, self.drawer.dimen.y)
end

function Home:close_drawer()
    if self.drawer then self.drawer:dismiss() end
end

function Home:open_connection_settings()
    self.settings_route = "connection"
    self:refresh()
end

function Home:page_title()
    if self.selected_tab == "settings" then
        return self.settings_route == "connection" and "连接"
            or self.settings_route == "languages" and "源语言"
            or self.settings_route == "download" and "下载"
            or self.settings_route == "library" and "书架"
            or self.settings_route == "sync" and "同步"
            or self.settings_route == "theme" and "主题"
            or self.settings_route == "general" and "通用"
            or self.settings_route == "browse" and "探索"
            or "设置"
    elseif self.selected_tab == "tasks" then
        return self.task_folder and (self.task_folder.title or ("漫画 " .. self.task_folder.manga)) or "下载任务"
    elseif self.directory then
        return self.directory.unread_only and "未读章节" or "全部章节"
    elseif self.detail then
        return "漫画详情"
    elseif self.selected_tab == "browse" then
        return self.browse.source and self.browse.source.name or "探索"
    end
    return "书架"
end

function Home:refresh()
    if not self.alive then
        return
    end

    self:capture_inputs()
    self:release_input_form()
    if self.cropping_widget then self.cropping_widget:reset(); self.cropping_widget = nil end
    local screen = Screen:getSize()
    local tab_bar = TabBar:build{
        items = TAB_ITEMS,
        active = self.selected_tab,
        on_select = function(tab_id)
            self:set_tab(tab_id)
        end,
    }
    local tab_height = tab_bar:getSize().h
    local main_height = screen.h - tab_height
    local on_back
    if self.selected_tab == "settings" and self.settings_route ~= "index" then
        on_back = function()
            self.settings_route = self.settings_route == "languages" and "browse" or "index"
            self:refresh()
        end
    elseif self.selected_tab=="tasks" and self.task_folder then
        on_back=function() self:leave_task_folder() end
    elseif self.selected_tab ~= "settings" and (self.detail or (self.selected_tab == "browse" and self.browse.source)) then
        on_back = function() self:catalog_back() end
    end
    local actions = self:catalog_actions()
    -- A completed request can replace a cancel action while the drawer is open.
    if self.drawer then
        local previous = self.drawer.actions
        if not actions or #actions ~= #previous then
            self:close_drawer()
        else
            for i, action in ipairs(actions) do
                if action[1] ~= previous[i][1] then self:close_drawer(); break end
            end
        end
    end
    local header = Header:build{
        width = screen.w,
        title = self.directory and "" or self:page_title(),
        on_back = on_back,
        on_menu = actions and function() self:open_drawer() end,
        on_close = function()
            self:request_exit()
        end,
    }
    self.drawer_top = header:getSize().h
    self.drawer_height = main_height - self.drawer_top
    local paginated = self.selected_tab == "settings" and (self.settings_route == "languages" or self.settings_route == "sync")
        or self.selected_tab ~= "settings" and (not self.detail or self.directory) and self.settings.connection.server_url ~= ""
    self.pagination = nil
    local footer = self.detail and not self.directory and self:detail_footer(screen.w)
    local body_height = main_height - header:getSize().h
        - (footer and footer:getSize().h or 0) - (paginated and Pager.height() or 0)
    local body
    if self.selected_tab == "settings" then
        if self.settings_route == "index" then
            body = self:build_settings_index(screen.w, body_height)
        elseif self.settings_route == "connection" then
            body = self:build_connection_settings(screen.w, body_height)
        elseif self.settings_route == "download" then
            body = self:build_download_settings(screen.w, body_height)
        elseif self.settings_route == "library" then
            body = self:build_library_settings(screen.w, body_height)
        elseif self.settings_route == "languages" then
            body = self:build_language_picker(screen.w, body_height)
        elseif self.settings_route == "sync" then
            body = self:build_sync(screen.w, body_height)
        elseif self.settings_route == "theme" then
            body = self:build_theme_settings(screen.w, body_height)
        elseif self.settings_route == "general" then
            body = self:build_general_settings(screen.w, body_height)
        elseif self.settings_route == "browse" then
            body = self:build_browse_settings(screen.w, body_height)
        end
    elseif self.selected_tab == "tasks" then
        body = self:build_tasks(screen.w,body_height)
    else
        body = self:build_catalog(screen.w, body_height)
    end

    local navigation = VerticalGroup:new{align = "center"}
    if footer then navigation[#navigation+1] = footer end
    if paginated then
        navigation[#navigation+1] = Pager.build(self, screen.w, self.pagination or {page = 0, total = 0, busy = true})
    end
    navigation[#navigation+1] = tab_bar

    local main_frame = FrameContainer:new{
        width = screen.w,
        height = main_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align = "left", header, body},
    }
    local root = FrameContainer:new{
        width = screen.w,
        height = screen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = screen,
            main_frame,
            BottomContainer:new{
                dimen = screen,
                navigation,
            },
        },
    }

    local old = self[1]
    self[1] = root
    if old then
        old:free(true)
    end
    UIManager:setDirty(self, "ui")
end

for name, method in pairs(require("suwayomi_kindle/ui/catalog")) do
    Home[name] = method
end

for name, method in pairs(require("suwayomi_kindle/ui/manga")) do Home[name] = method end

for name, method in pairs(require("suwayomi_kindle/ui/sync")) do Home[name] = method end

for name, method in pairs(require("suwayomi_kindle/ui/tasks")) do Home[name] = method end

for name, method in pairs(Settings.methods) do
    Home[name] = method
end

return Home
