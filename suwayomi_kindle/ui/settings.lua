-- Boundary: settings index and connection-detail screen behavior.
--
-- Responsibility: own the editable connection draft and verification lifecycle,
-- while rendering only flat, top-aligned Kindle-friendly content.
-- Owned state: delegated to the Home widget.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Config = require("suwayomi_kindle/config")
local Connection = require("suwayomi_kindle/connection")
local FlatButton = require("suwayomi_kindle/ui/flat_button")
local Icons = require("suwayomi_kindle/ui/icons")
local SettingRow = require("suwayomi_kindle/ui/setting_row")

local Screen = Device.screen
local Settings = {methods = {}}

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

local function separator(width)
    return LineWidget:new{
        dimen = Geom:new{
            w = width,
            h = scale(1),
        },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

local function top_frame(screen_width, body_height, content)
    return FrameContainer:new{
        width = screen_width,
        height = body_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = scale(10) },
            content,
        },
    }
end

function Settings.methods:connection_summary()
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

function Settings.methods:status()
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
            icon = "warning",
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
            icon = "info",
            title = "配置已修改",
            text = "保存并重新验证连接。",
        }
    end
    if self.settings_store:is_verified(self.draft) then
        return {
            icon = "check",
            title = "上次验证成功",
            text = "当前网络或服务器状态可能已经变化。",
        }
    end
    return {
        icon = "info",
        title = "尚未验证",
        text = "配置已保存，但还没有验证服务器连接。",
    }
end

function Settings.methods:build_status(width)
    local status = self:status()
    local icon_size = scale(28)
    local text_width = width - icon_size - scale(14)
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            Icons.widget(status.icon, icon_size),
            HorizontalSpan:new{ width = scale(14) },
            VerticalGroup:new{
                TextWidget:new{
                    text = status.title,
                    face = Font:getFace("smallinfofontbold", 18),
                    max_width = text_width,
                },
                VerticalSpan:new{ width = scale(3) },
                body_text(status.text, text_width),
            },
        },
        VerticalSpan:new{ width = scale(10) },
        separator(width),
    }
end

function Settings.methods:build_settings_index(screen_width, body_height)
    local width = screen_width - scale(36)
    local content = VerticalGroup:new{
        align = "center",
        SettingRow:new{
            label = "连接与验证",
            value = self:connection_summary(),
            width = width,
            callback = function()
                self:open_connection_settings()
            end,
        },
        separator(width),
    }
    return top_frame(screen_width, body_height, content)
end

function Settings.methods:show_server_editor()
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
    dialog.dialog_frame.radius = 0
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings.methods:show_credentials_editor()
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
    dialog.dialog_frame.radius = 0
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings.methods:show_auth_selector()
    local menu
    local item_table = {}
    for _, method in ipairs({"none", "basic_auth", "ui_login"}) do
        local option = Config.AUTH_METHODS[method]
        item_table[#item_table + 1] = {
            text = option.label .. " · " .. option.description,
            radio = true,
            checked_func = function()
                return self.draft.auth_method == method
            end,
            callback = function()
                self.draft.auth_method = method
                if menu then
                    menu:closeMenu()
                end
                self:mark_dirty()
            end,
        }
    end
    menu = TouchMenu:new{
        title = "认证方式",
        width = Screen:getWidth(),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function Settings.methods:build_connection_settings(screen_width, body_height)
    local width = screen_width - scale(36)
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
    local button_width = math.floor((width - scale(10)) / 2)

    local content = VerticalGroup:new{
        align = "center",
        self:build_status(width),
        SettingRow:new{
            label = "服务器地址",
            value = Config.trim(self.draft.server_url) ~= "" and self.draft.server_url or "未设置",
            width = width,
            callback = function()
                self:show_server_editor()
            end,
        },
        separator(width),
        SettingRow:new{
            label = "认证方式",
            value = auth.label .. " · " .. auth.description,
            width = width,
            callback = function()
                self:show_auth_selector()
            end,
        },
        separator(width),
        SettingRow:new{
            label = "账号与密码",
            value = account_value,
            width = width,
            callback = function()
                self:show_credentials_editor()
            end,
        },
        separator(width),
        VerticalSpan:new{ width = scale(14) },
        HorizontalGroup:new{
            align = "center",
            FlatButton.new{
                text = "保存设置",
                width = button_width,
                callback = function()
                    self:save_draft()
                end,
                show_parent = self,
            },
            HorizontalSpan:new{ width = scale(10) },
            FlatButton.new{
                text = self.verifying and "验证中…" or "验证连接",
                width = button_width,
                enabled = not self.verifying,
                callback = function()
                    self:verify_connection()
                end,
                show_parent = self,
            },
        },
        VerticalSpan:new{ width = scale(10) },
        body_text(
            "凭据保存在本机 KOReader 设置中。HTTP 会明文传输密码，请优先使用 HTTPS。",
            width,
            {size = 14}
        ),
    }
    return top_frame(screen_width, body_height, content)
end

function Settings.methods:save_draft(options)
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

function Settings.methods:verify_connection()
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

return Settings
