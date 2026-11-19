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
    { id = "browse", label = "浏览", icon = "browse" },
    { id = "settings", label = "设置", icon = "settings" },
}

function Home:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true
    self.settings = {}
    for _, section in ipairs({"connection", "download", "library", "browse"}) do
        self.settings[section] = self.settings_store:load(section)
    end
    self.draft = self.settings_store:load("connection")
    self:reset_catalog()
    self.dirty = false
    self.verifying = false
    if Config.trim(self.draft.server_url) == "" then
        self.selected_tab = "settings"
    end
    self:refresh()
end

function Home:close()
    UIManager:close(self)
end

function Home:handleEvent(event)
    if event.handler == "onCloseWidget" then
        self:release_connection_form()
    end
    return InputContainer.handleEvent(self, event)
end

function Home:onCloseWidget()
    self:cancel_catalog()
    self.alive = false
end

function Home:set_tab(tab_id)
    if self.selected_tab == tab_id then
        if tab_id == "settings" and self.settings_route ~= "index" then
            self.settings_route = "index"
            self:refresh()
        end
        return
    end
    self:cancel_catalog()
    self.detail = nil
    self.catalog_message = nil
    self.selected_tab = tab_id
    if tab_id == "settings" then
        self.settings_route = "index"
    end
    self:refresh()
end

function Home:open_connection_settings()
    self.settings_route = "connection"
    self:refresh()
end

function Home:page_title()
    if self.selected_tab == "settings" then
        return self.settings_route == "connection" and "连接"
            or self.settings_route == "download" and "下载"
            or self.settings_route == "library" and "书架"
            or self.settings_route == "browse" and "浏览"
            or "设置"
    elseif self.detail then
        return self.detail.title
    elseif self.selected_tab == "browse" then
        return self.browse.source and self.browse.source.name or "浏览"
    end
    return "书架"
end

function Home:refresh()
    if not self.alive then
        return
    end

    self:read_connection_fields()
    self:release_connection_form()
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
            self.settings_route = "index"
            self:refresh()
        end
    elseif self.selected_tab ~= "settings" and (self.detail or (self.selected_tab == "browse" and self.browse.source)) then
        on_back = function() self:catalog_back() end
    end
    local header = Header:build{
        width = screen.w,
        title = self:page_title(),
        on_back = on_back,
        on_close = function()
            self:close()
        end,
    }
    local body_height = main_height - header:getSize().h
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
        elseif self.settings_route == "browse" then
            body = self:build_browse_settings(screen.w, body_height)
        end
    else
        body = self:build_catalog(screen.w, body_height)
    end

    local main_frame = FrameContainer:new{
        width = screen.w,
        height = main_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            header,
            body,
        },
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
                tab_bar,
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

for name, method in pairs(Settings.methods) do
    Home[name] = method
end

return Home
