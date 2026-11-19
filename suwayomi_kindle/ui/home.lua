-- Boundary: primary application shell.
--
-- Responsibility: compose the shared flat header, top-aligned page body, and
-- bottom tabs. Settings behavior lives in suwayomi_kindle/ui/settings.
-- Owned state: selected tab, settings route, and connection draft.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Config = require("suwayomi_kindle/config")
local FlatButton = require("suwayomi_kindle/ui/flat_button")
local Header = require("suwayomi_kindle/ui/header")
local Icons = require("suwayomi_kindle/ui/icons")
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

local function scale(px)
    return Screen:scaleBySize(px)
end

local function body_text(text, width, options)
    options = options or {}
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace(options.face or "x_smallinfofont", options.size or 15),
        width = width,
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    }
end

function Home:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true
    self.draft = self.settings_store:load()
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

function Home:onCloseWidget()
    self.alive = false
end

function Home:mark_dirty()
    self.dirty = true
    self.verification_result = nil
    self:refresh()
end

function Home:set_tab(tab_id)
    if self.selected_tab == tab_id then
        if tab_id == "settings" and self.settings_route ~= "index" then
            self.settings_route = "index"
            self:refresh()
        end
        return
    end
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
        return self.settings_route == "connection" and "连接与验证" or "设置"
    elseif self.selected_tab == "browse" then
        return "浏览"
    end
    return "书架"
end

function Home:refresh()
    if not self.alive then
        return
    end

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
    if self.selected_tab == "settings" and self.settings_route == "connection" then
        on_back = function()
            self.settings_route = "index"
            self:refresh()
        end
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
        if self.settings_route == "connection" then
            body = self:build_connection_settings(screen.w, body_height)
        else
            body = self:build_settings_index(screen.w, body_height)
        end
    elseif self.selected_tab == "browse" then
        body = self:build_placeholder(
            "browse",
            "浏览",
            "连接服务器后，可在这里浏览漫画源、搜索和查看最新更新。",
            body_height
        )
    else
        body = self:build_library(body_height)
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

function Home:build_action_button(options)
    return FlatButton.new{
        text = options.text,
        width = options.width,
        enabled = options.enabled,
        callback = options.callback,
        show_parent = self,
    }
end

function Home:show_notice(text)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 3,
    })
end

function Home:build_library(body_height)
    local configured = Config.trim(self.draft.server_url) ~= ""
    if configured then
        return self:build_placeholder(
            "library",
            "书架",
            "连接层已经就绪。下一阶段将在这里加载 Suwayomi 书架、封面和继续阅读入口。",
            body_height
        )
    end

    local content_width = math.min(scale(470), Screen:getWidth() - scale(40))
    local content = VerticalGroup:new{
        align = "center",
        Icons.widget("library", scale(54)),
        VerticalSpan:new{ width = scale(16) },
        TextWidget:new{
            text = "连接你的书架",
            face = Font:getFace("smallinfofontbold", 22),
        },
        VerticalSpan:new{ width = scale(8) },
        body_text("配置 Suwayomi Server 后，书架内容会显示在这里。", content_width),
        VerticalSpan:new{ width = scale(18) },
        self:build_action_button{
            text = "前往设置",
            width = scale(180),
            callback = function()
                self:set_tab("settings")
            end,
        },
    }
    return FrameContainer:new{
        width = Screen:getWidth(),
        height = body_height,
        padding = 0,
        bordersize = 0,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = scale(24) },
            content,
        },
    }
end

function Home:build_placeholder(icon, title, description, body_height)
    local content_width = math.min(scale(470), Screen:getWidth() - scale(40))
    local content = VerticalGroup:new{
        align = "center",
        Icons.widget(icon, scale(52)),
        VerticalSpan:new{ width = scale(14) },
        TextWidget:new{
            text = title,
            face = Font:getFace("smallinfofontbold", 22),
        },
        VerticalSpan:new{ width = scale(8) },
        body_text(description, content_width),
    }
    return FrameContainer:new{
        width = Screen:getWidth(),
        height = body_height,
        padding = 0,
        bordersize = 0,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = scale(24) },
            content,
        },
    }
end

for name, method in pairs(Settings.methods) do
    Home[name] = method
end

return Home
