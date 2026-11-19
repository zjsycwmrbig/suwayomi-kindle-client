-- Boundary: primary application shell and connection settings screen.
--
-- Responsibility: own the selected bottom tab, editable connection draft, and
-- verification lifecycle for the first UI milestone.
-- Owned state: selected tab, transient draft, and display-only verification status.
-- Dependencies: KOReader widgets/network services and plugin-local facade modules.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Config = require("suwayomi_kindle/config")
local Connection = require("suwayomi_kindle/connection")
local TabBar = require("suwayomi_kindle/ui/tab_bar")

local Home = InputContainer:extend{
    plugin = nil,
    settings_store = nil,
    selected_tab = "library",
    settings_route = "index",
    alive = true,
}

local TAB_ITEMS = {
    { id = "library", label = "书架", icon = "book.opened" },
    { id = "browse", label = "浏览", icon = "appbar.search" },
    { id = "settings", label = "设置", icon = "appbar.settings" },
}

local function text_widget(text, face, width, bold, options)
    options = options or {}
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace(face or "smallinfofont", options.font_size or 16),
        width = width,
        bold = bold,
        bgcolor = options.bgcolor,
    }
end

local function icon_and_text(icon, title, body, width, options)
    options = options or {}
    local function scale(px) return Screen:scaleBySize(px) end
    local icon_size = scale(options.icon_size or 34)
    return HorizontalGroup:new{
        align = "center",
        IconWidget:new{
            icon = icon,
            width = icon_size,
            height = icon_size,
        },
        VerticalSpan:new{ width = scale(14) },
        VerticalGroup:new{
            TextWidget:new{
                text = title,
                face = Font:getFace("smallinfofontbold", options.title_size or 20),
                max_width = width - icon_size - scale(14),
            },
            text_widget(body, "x_smallinfofont", width - icon_size - scale(14), nil, {
                font_size = 16,
                bgcolor = options.text_bgcolor,
            }),
        },
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

function Home:refresh()
    if not self.alive then
        return
    end

    local function scale(px) return Screen:scaleBySize(px) end
    local screen = Screen:getSize()
    local title_bar = TitleBar:new{
        width = screen.w,
        align = "center",
        title = "Suwayomi",
        title_face = Font:getFace("smallinfofontbold", 24),
        with_bottom_line = true,
        close_callback = function()
            self:close()
        end,
        show_parent = self,
    }
    local tab_bar = TabBar:build{
        items = TAB_ITEMS,
        active = self.selected_tab,
        on_select = function(tab_id)
            self:set_tab(tab_id)
        end,
    }
    local title_height = title_bar:getSize().h
    local tab_height = tab_bar:getSize().h
    local body_height = math.max(scale(420), screen.h - title_height - tab_height)

    local body
    if self.selected_tab == "settings" then
        if self.settings_route == "connection" then
            body = self:build_connection_settings(screen.w, body_height)
        else
            body = self:build_settings_index(screen.w, body_height)
        end
    elseif self.selected_tab == "browse" then
        body = self:build_placeholder(
            "appbar.search",
            "浏览",
            "连接服务器后，可在这里浏览漫画源、搜索和查看最新更新。",
            body_height
        )
    else
        body = self:build_library(body_height)
    end

    local main_frame = FrameContainer:new{
        width = screen.w,
        height = screen.h - tab_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            title_bar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = screen.w,
                    h = math.max(1, screen.h - tab_height - title_height),
                },
                body,
            },
        },
    }

    local root = FrameContainer:new{
        width = screen.w,
        height = screen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            main_frame,
            tab_bar,
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
    local function scale(px) return Screen:scaleBySize(px) end
    return Button:new{
        text = options.text,
        width = options.width,
        height = scale(48),
        text_font_face = "smallinfofontbold",
        text_font_size = 18,
        background = options.primary and Blitbuffer.COLOR_LIGHT_GRAY or nil,
        enabled = options.enabled ~= false,
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

function Home:show_server_editor()
    local dialog
    dialog = InputDialog:new{
        title = "服务器地址",
        input = self.draft.server_url,
        input_hint = "http://192.168.1.10:4567",
        description = "填写 Suwayomi Server 首页地址，不要附加 /api/graphql。",
        buttons = {
            {
                {
                    text = "取消",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "保存",
                    is_enter_default = true,
                    callback = function()
                        local normalized, err = Config.normalize_server_url(dialog:getInputText())
                        if not normalized then
                            self:show_notice(err)
                            return
                        end
                        self.draft.server_url = normalized
                        UIManager:close(dialog)
                        self:mark_dirty()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Home:show_credentials_editor()
    local dialog
    dialog = MultiInputDialog:new{
        title = "认证凭据",
        fields = {
            {
                description = "用户名",
                text = self.draft.username or "",
                hint = "Suwayomi 用户名",
            },
            {
                description = "密码",
                text = self.draft.password or "",
                hint = "Suwayomi 密码",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = "取消",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "保存",
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        self.draft.username = Config.trim(fields[1])
                        self.draft.password = tostring(fields[2] or "")
                        UIManager:close(dialog)
                        self:mark_dirty()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Home:show_auth_selector()
    local dialog
    local buttons = {}
    for _, method in ipairs({ "none", "basic_auth", "ui_login" }) do
        local option = Config.AUTH_METHODS[method]
        buttons[#buttons + 1] = {
            {
                text = (self.draft.auth_method == method and "✓ " or "")
                    .. option.label .. "\n" .. option.description,
                callback = function()
                    self.draft.auth_method = method
                    UIManager:close(dialog)
                    self:mark_dirty()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = "取消",
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }
    dialog = ButtonDialog:new{
        title = "认证方式",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Home:status()
    if self.verifying then
        return {
            icon = "info",
            title = "正在验证",
            text = "正在请求 Suwayomi GraphQL API…",
        }
    end
    if self.verification_result then
        if self.verification_result.ok then
            return {
                icon = "check",
                title = "连接正常",
                text = self.verification_result.message or "服务器已通过验证。",
            }
        end
        return {
            icon = "notice-warning",
            title = "验证失败",
            text = self.verification_result.error or "无法连接服务器。",
        }
    end
    if Config.trim(self.draft.server_url) == "" then
        return {
            icon = "info",
            title = "尚未连接",
            text = "添加服务器地址并验证连接。",
        }
    end
    if self.dirty then
        return {
            icon = "edit",
            title = "配置已修改",
            text = "保存并重新验证连接。",
        }
    end
    if self.settings_store:is_verified(self.draft) then
        return {
            icon = "check",
            title = "上次验证成功",
            text = "当前 WiFi 或服务器状态可能已经变化。",
        }
    end
    return {
        icon = "info",
        title = "尚未验证",
        text = "配置已保存，但还没有验证服务器连接。",
    }
end

function Home:build_status(width)
    local status = self:status()
    local function scale(px) return Screen:scaleBySize(px) end
    return FrameContainer:new{
        width = width,
        padding = scale(11),
        bordersize = scale(1),
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        icon_and_text(status.icon, status.title, status.text, width - scale(22), {
            icon_size = 30,
            title_size = 19,
            text_bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        }),
    }
end

function Home:settings_row(label, value, width, callback)
    return Button:new{
        text = label .. "\n" .. value,
        align = "left",
        width = width,
        text_font_face = "smallinfofont",
        text_font_size = 17,
        text_font_bold = false,
        padding_v = Screen:scaleBySize(9),
        padding_h = Screen:scaleBySize(14),
        callback = callback,
        show_parent = self,
    }
end

function Home:connection_summary()
    if Config.trim(self.draft.server_url) == "" then
        return "未设置服务器"
    end
    if self.verification_result and self.verification_result.ok then
        return "已验证 · " .. self.draft.server_url
    end
    if self.dirty then
        return "配置已修改，等待验证"
    end
    if self.settings_store:is_verified(self.draft) then
        return "上次验证成功 · " .. self.draft.server_url
    end
    return "尚未验证 · " .. self.draft.server_url
end

function Home:build_settings_index(screen_width, body_height)
    local function scale(px) return Screen:scaleBySize(px) end
    local width = math.min(scale(520), screen_width - scale(40))
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = scale(10) },
        TextWidget:new{
            text = "设置",
            face = Font:getFace("smallinfofontbold", 24),
            max_width = width,
        },
        VerticalSpan:new{ width = scale(12) },
        self:settings_row(
            "连接与验证",
            self:connection_summary(),
            width,
            function()
                self:open_connection_settings()
            end
        ),
        LineWidget:new{
            dimen = Geom:new{w = width, h = scale(1)},
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }

    return FrameContainer:new{
        width = screen_width,
        height = body_height,
        padding = 0,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{w = screen_width, h = body_height},
            content,
        },
    }
end

function Home:build_connection_settings(screen_width, body_height)
    local function scale(px) return Screen:scaleBySize(px) end
    local width = math.min(scale(520), screen_width - scale(40))
    local auth = Config.AUTH_METHODS[self.draft.auth_method] or Config.AUTH_METHODS.none
    local account_value
    if self.draft.auth_method == "none" then
        account_value = "无需账号"
    elseif Config.trim(self.draft.username) == "" then
        account_value = "未填写"
    elseif self.draft.password == "" then
        account_value = self.draft.username .. " · 未填写密码"
    else
        account_value = self.draft.username .. " · 密码已保存"
    end

    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = scale(7) },
        HorizontalGroup:new{
            align = "center",
            Button:new{
                icon = "chevron.left",
                width = scale(46),
                height = scale(42),
                callback = function()
                    self.settings_route = "index"
                    self:refresh()
                end,
                show_parent = self,
            },
            TextWidget:new{
                text = "连接与验证",
                face = Font:getFace("smallinfofontbold", 24),
                max_width = width - scale(46),
            },
        },
        VerticalSpan:new{ width = scale(4) },
        text_widget("配置 Suwayomi Server 地址和身份。验证会读取受保护的分类接口。", "x_smallinfofont", width, nil, {
            font_size = 16,
        }),
        VerticalSpan:new{ width = scale(10) },
        self:build_status(width),
        VerticalSpan:new{ width = scale(10) },
        self:settings_row(
            "服务器地址",
            Config.trim(self.draft.server_url) ~= "" and self.draft.server_url or "未设置",
            width,
            function()
                self:show_server_editor()
            end
        ),
        LineWidget:new{
            dimen = Geom:new{w = width, h = scale(1)},
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        self:settings_row("认证方式", auth.label .. " · " .. auth.description, width, function()
            self:show_auth_selector()
        end),
        LineWidget:new{
            dimen = Geom:new{w = width, h = scale(1)},
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        self:settings_row("账号与密码", account_value, width, function()
            self:show_credentials_editor()
        end),
        VerticalSpan:new{ width = scale(10) },
        HorizontalGroup:new{
            align = "center",
            self:build_action_button{
                text = "保存设置",
                width = math.floor((width - scale(10)) / 2),
                callback = function()
                    self:save_draft()
                end,
            },
            HorizontalSpan:new{ width = scale(10) },
            self:build_action_button{
                text = self.verifying and "验证中…" or "验证连接",
                width = math.floor((width - scale(10)) / 2),
                primary = true,
                enabled = not self.verifying,
                callback = function()
                    self:verify_connection()
                end,
            },
        },
        VerticalSpan:new{ width = scale(6) },
        text_widget(
            "凭据保存在本机 KOReader 设置中。HTTP 会明文传输密码，请优先使用 HTTPS。",
            "x_smallinfofont",
            width,
            nil,
            {font_size = 15}
        ),
        VerticalSpan:new{ width = scale(8) },
    }

    if content:getSize().h > body_height then
        local content_height = content:getSize().h
        self:show_notice("设置页内容超出当前屏幕，请缩小系统字号后重试。")
        return FrameContainer:new{
            width = screen_width,
            height = body_height,
            padding = 0,
            bordersize = 0,
            CenterContainer:new{
                dimen = Geom:new{w = screen_width, h = body_height},
                VerticalGroup:new{
                    align = "center",
                    VerticalSpan:new{ width = math.max(0, math.floor((body_height - content_height) / 2)) },
                    content,
                },
            },
        }
    end

    return FrameContainer:new{
        width = screen_width,
        height = body_height,
        padding = 0,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{w = screen_width, h = body_height},
            content,
        },
    }
end

function Home:build_library(body_height)
    local configured = Config.trim(self.draft.server_url) ~= ""
    if configured then
        return self:build_placeholder(
            "book.opened",
            "书架",
            "连接层已经就绪。下一阶段将在这里加载 Suwayomi 书架、封面和继续阅读入口。",
            body_height
        )
    end

    local function scale(px) return Screen:scaleBySize(px) end
    local width = math.min(scale(470), Screen:getWidth() - scale(40))
    return FrameContainer:new{
        width = Screen:getWidth(),
        height = body_height,
        padding = 0,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{w = Screen:getWidth(), h = body_height},
            VerticalGroup:new{
                align = "center",
                IconWidget:new{
                    icon = "book.opened",
                    width = scale(64),
                    height = scale(64),
                },
                VerticalSpan:new{ width = scale(16) },
                TextWidget:new{
                    text = "连接你的书架",
                    face = Font:getFace("smallinfofontbold", 23),
                },
                VerticalSpan:new{ width = scale(8) },
                text_widget("配置 Suwayomi Server 后，书架内容会显示在这里。", "x_smallinfofont", width),
                VerticalSpan:new{ width = scale(18) },
                self:build_action_button{
                    text = "前往设置",
                    width = scale(180),
                    primary = true,
                    callback = function()
                        self:set_tab("settings")
                    end,
                },
            },
        },
    }
end

function Home:build_placeholder(icon, title, description, body_height)
    local function scale(px) return Screen:scaleBySize(px) end
    local width = math.min(scale(470), Screen:getWidth() - scale(40))
    return FrameContainer:new{
        width = Screen:getWidth(),
        height = body_height,
        padding = 0,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{w = Screen:getWidth(), h = body_height},
            VerticalGroup:new{
                align = "center",
                IconWidget:new{
                    icon = icon,
                    width = scale(58),
                    height = scale(58),
                },
                VerticalSpan:new{ width = scale(14) },
                TextWidget:new{
                    text = title,
                    face = Font:getFace("smallinfofontbold", 23),
                },
                VerticalSpan:new{ width = scale(8) },
                text_widget(description, "x_smallinfofont", width),
            },
        },
    }
end

function Home:save_draft(options)
    options = options or {}
    local normalized, err = Config.normalize(self.draft)
    if not normalized then
        if not options.quiet then
            self:show_notice(err)
        end
        return nil, err
    end
    normalized = self.settings_store:save(normalized)
    if not normalized then
        if not options.quiet then
            self:show_notice("设置保存失败。")
        end
        return nil, "设置保存失败。"
    end
    self.draft = self.settings_store:load()
    self.dirty = false
    if not options.defer_refresh then
        self:refresh()
    end
    return normalized
end

function Home:verify_connection()
    if self.verifying then
        return
    end
    local saved = self:save_draft{quiet = true, defer_refresh = true}
    if not saved then
        local _, err = Config.normalize(self.draft)
        self:show_notice(err or "请先完成连接设置。")
        return
    end

    self.verifying = true
    self.verification_result = nil
    self:refresh()

    local settings_copy = {}
    for key, value in pairs(saved) do
        settings_copy[key] = value
    end

    NetworkMgr:runWhenConnected(function()
        if not self.alive then
            return
        end
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local info = InfoMessage:new{
                text = "正在验证连接…\n轻触可取消",
            }
            UIManager:show(info)
            UIManager:forceRePaint()

            local completed, result = Trapper:dismissableRunInSubprocess(function()
                return Connection.test(settings_copy)
            end, info)

            if not self.alive then
                return
            end
            UIManager:close(info)
            self.verifying = false
            if not completed then
                self.verification_result = {
                    ok = false,
                    error = "验证已取消。",
                }
            elseif type(result) ~= "table" then
                self.verification_result = {
                    ok = false,
                    error = "验证过程没有返回有效结果。",
                }
            else
                self.verification_result = result
                if result.ok then
                    self.settings_store:mark_verified(settings_copy)
                end
            end
            self:refresh()
        end)
    end)
end

return Home
