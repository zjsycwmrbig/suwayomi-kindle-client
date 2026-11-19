-- Settings navigation, inline connection form, and verification feedback.
local BB = require("ffi/blitbuffer")
local FFI = require("ffi/util")
local Device = require("device")
local Font = require("ui/font")
local Frame = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local Column = require("ui/widget/verticalgroup")
local Space = require("ui/widget/verticalspan")
local Gap = require("ui/widget/horizontalspan")
local Scroll = require("ui/widget/container/scrollablecontainer")
local InputText = require("ui/widget/inputtext")
local Text = require("ui/widget/textwidget")
local Paragraph = require("ui/widget/textboxwidget")
local Line = require("ui/widget/linewidget")
local UI = require("ui/uimanager")
local JSON = require("json")
local clock = require("socket").gettime

local Config = require("suwayomi_kindle/config")
local Connection = require("suwayomi_kindle/connection")
local Button = require("suwayomi_kindle/ui/flat_button")
local SettingRow = require("suwayomi_kindle/ui/setting_row")

local Screen = Device.screen
local methods = {}

local function scale(n)
    return Screen:scaleBySize(n)
end

local function spacing(n)
    return Space:new{width = scale(n)}
end

local function label(text)
    return Text:new{text = text, face = Font:getFace("smallinfofontbold", 17)}
end

local function rule(width)
    return Line:new{dimen = Geom:new{w = width, h = scale(1)}, background = BB.COLOR_LIGHT_GRAY}
end

function methods:build_settings_index(screen_width, body_height)
    local width = screen_width - scale(48)
    local inset = math.floor((screen_width - width) / 2)
    local status = "尚未验证"
    if Config.trim(self.draft.server_url) == "" then
        status = "未设置服务器"
    elseif self.verifying then
        status = "正在验证"
    elseif self.verification_result and not self.verification_result.ok then
        status = "验证失败"
    elseif not self.dirty and self.settings_store:is_verified(self.draft) then
        status = "上次验证成功"
    end
    return Frame:new{
        width = screen_width, height = body_height, bordersize = 0, padding = 0,
        padding_left = inset, padding_right = screen_width - width - inset,
        Column:new{
            spacing(12),
            SettingRow:new{
                label = "连接与验证", value = status, width = width,
                callback = function() self:open_connection_settings() end,
            },
            rule(width),
        },
    }
end

-- InputText sends focus events to its owning top-level widget.
function methods:onSwitchFocus(field)
    local form = self.connection_form
    if not form or self.verifying then return end
    if form.focused and form.focused ~= field then
        form.focused:onCloseKeyboard()
        form.focused:unfocus()
    end
    form.focused = field
    self.is_always_active = true
    field:focus()
    if not ((Device:hasKeyboard() or Device:hasScreenKB())
        and G_reader_settings:nilOrFalse("virtual_keyboard_enabled")) then
        field:onShowKeyboard()
        self:onKeyboardHeightChanged()
    end
    UI:setDirty(self, "ui")
end

function methods:getFocusableWidgetXY()
    -- The form handles touch focus directly.
end

function methods:onKeyboardHeightChanged()
    local form = self.connection_form
    if not form or not form.focused or not form.focused:isKeyboardVisible() then return end
    local viewport, field = form.viewport, form.focused
    local keyboard = field:getKeyboardDimen()
    if not keyboard or not keyboard.h then return end
    local offset = viewport:getScrolledOffset()
    local top = (field.dimen.y or 0) - (viewport.dimen.y or 0) + offset.y
    local visible = math.max(scale(48), math.min(form.height,
        Screen:getHeight() - (viewport.dimen.y or 0) - keyboard.h))
    viewport:reset()
    viewport.dimen.h = visible
    viewport:initState()
    if viewport._is_scrollable then
        local target = math.max(0, top + field.dimen.h + scale(8) - visible)
        viewport:_scrollBy(0, target)
    end
    UI:setDirty(self, "ui")
end

function methods:finish_field()
    local form = self.connection_form
    if not form or not form.focused then return end
    local field = form.focused
    form.focused = nil
    self.is_always_active = false
    field:onCloseKeyboard()
    field:unfocus()
    form.viewport:reset()
    form.viewport.dimen.h = form.height
    UI:setDirty(self, "ui")
end

function methods:onCloseDialog()
    if self.connection_form and self.connection_form.focused then
        self:finish_field()
    else
        self:close()
    end
end

function methods:release_connection_form()
    local form = self.connection_form
    if not form then return end
    self:finish_field()
    form.viewport:reset()
    self.connection_form = nil
    self.cropping_widget = nil
end

local function add_field(home, column, width, key, title, hint)
    local padding, border = scale(9), scale(1)
    local input = InputText:new{
        parent = home, focused = false, readonly = home.verifying,
        text = home.draft[key] or "", hint = hint,
        text_type = key == "password" and "password" or nil,
        show_password_toggle = false,
        width = width - 2 * (padding + border), height = scale(31), scroll = true,
        face = Font:getFace("smallinfofont", 18), margin = 0,
        padding = padding, bordersize = border,
        disable_clipboard_snippet_edit = key == "password",
        enter_callback = function()
            if home.alive then home:finish_field() end
        end,
    }
    -- Back can close KOReader's keyboard directly, without going through Home.
    if input.keyboard and input.keyboard.onCloseWidget then
        local on_close = input.keyboard.onCloseWidget
        input.keyboard.onCloseWidget = function(keyboard)
            local result = on_close(keyboard)
            UI:nextTick(function()
                local form = home.connection_form
                if form and form.focused == input and not input:isKeyboardVisible() then
                    home:finish_field()
                end
            end)
            return result
        end
    end
    home.connection_form.fields[key] = input
    column[#column + 1] = label(title)
    column[#column + 1] = spacing(6)
    column[#column + 1] = input
end

function methods:read_connection_fields()
    local form = self.connection_form
    if not form then return end
    for key, field in pairs(form.fields) do
        local value = (field:getText():gsub("[\r\n]", ""))
        if value ~= self.draft[key] then
            self.draft[key] = value
            self.dirty = true
            self.verification_result = nil
            self.connection_status = nil
        end
    end
end

function methods:build_connection_settings(screen_width, body_height)
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(20)}
    local form = {fields = {}, height = math.max(scale(48), body_height)}
    self.connection_form = form
    add_field(self, column, width, "server_url", "服务器地址", "http://192.168.1.10:4567")
    column[#column + 1] = spacing(16)
    column[#column + 1] = label("认证方式")
    column[#column + 1] = spacing(6)

    local modes = Row:new{}
    local gap = scale(6)
    local segment_width = math.floor((width - 2 * gap) / 3)
    for i, mode in ipairs({"none", "basic_auth", "ui_login"}) do
        if i > 1 then modes[#modes + 1] = Gap:new{width = gap} end
        modes[#modes + 1] = Button.new{
            text = Config.auth_label(mode), width = segment_width,
            filled = mode == self.draft.auth_method, enabled = not self.verifying,
            show_parent = self,
            callback = function()
                if self.draft.auth_method == mode then return end
                self:read_connection_fields()
                self.draft.auth_method = mode
                self.dirty = true
                self.connection_status, self.verification_result = nil, nil
                self:refresh()
            end,
        }
    end
    column[#column + 1] = modes
    if self.draft.auth_method ~= "none" then
        column[#column + 1] = spacing(16)
        add_field(self, column, width, "username", "用户名", "")
        column[#column + 1] = spacing(12)
        add_field(self, column, width, "password", "密码", "")
    end

    column[#column + 1] = spacing(20)
    column[#column + 1] = rule(width)
    column[#column + 1] = spacing(14)
    local secondary = math.floor((width - scale(10)) * 0.42)
    column[#column + 1] = Row:new{
        Button.new{
            text = "保存设置", width = secondary, enabled = not self.verifying,
            show_parent = self, callback = function() self:save_draft() end,
        },
        Gap:new{width = scale(10)},
        Button.new{
            text = self.verifying and "验证中…" or "保存并验证",
            width = width - secondary - scale(10), filled = true, enabled = not self.verifying,
            show_parent = self, callback = function() self:verify_connection() end,
        },
    }
    local status = self.connection_status
    if not status and not self.dirty and self.settings_store:is_verified(self.draft) then
        status = "上次验证成功"
    end
    if status then
        column[#column + 1] = spacing(12)
        column[#column + 1] = Paragraph:new{
            text = status, width = width, face = Font:getFace("smallinfofont", 16),
        }
    end
    if self.draft.auth_method ~= "none" and Config.trim(self.draft.server_url):match("^http://") then
        column[#column + 1] = spacing(8)
        column[#column + 1] = Paragraph:new{
            text = "HTTP 连接未加密。", width = width, face = Font:getFace("x_smallinfofont", 14),
        }
    end
    column[#column + 1] = spacing(16)

    -- Reserve room for a scrollbar without shifting field edges when it appears.
    local viewport_width = width + Scroll:getScrollbarWidth()
    local inset = math.floor((screen_width - width) / 2)
    form.viewport = Scroll:new{
        dimen = Geom:new{w = viewport_width, h = form.height},
        show_parent = self, swipe_full_view = false, column,
    }
    self.cropping_widget = form.viewport
    return Frame:new{
        width = screen_width, height = body_height, bordersize = 0, padding = 0,
        padding_left = inset, padding_right = screen_width - inset - viewport_width,
        form.viewport,
    }
end

function methods:save_draft(for_verification)
    if self.verifying then return end
    self:read_connection_fields()
    self:finish_field()
    local config, err = Config.normalize(self.draft)
    if not config or config.server_url == "" then
        self.connection_status = err or "请填写服务器地址。"
        self:refresh()
        return
    end
    local saved, save_error = self.settings_store:save(config)
    if not saved then
        self.connection_status = save_error or "设置保存失败。"
        self:refresh()
        return
    end
    self:release_connection_form()
    self.draft = self.settings_store:load()
    self.dirty = false
    if not for_verification then
        self.connection_status = "设置已保存。"
        self:refresh()
    end
    return saved
end

function methods:verify_connection()
    local config = self:save_draft(true)
    if not config then return end
    self.verifying = true
    self.verification_result = nil
    self.connection_status = "正在验证连接…"
    self:refresh()

    local function complete(result)
        if not self.alive then return end
        self.verifying = false
        self.verification_result = result
        self.connection_status = result.ok and "连接验证成功。" or (result.error or "无法完成连接验证。")
        if result.ok then self.settings_store:mark_verified(config) end
        self:refresh()
    end

    local pid, fd = FFI.runInSubProcess(function(_, write_fd)
        local ok, result = pcall(Connection.test, config)
        local valid = ok and type(result) == "table"
        -- Only send a small status record, so the child can exit before we read.
        FFI.writeToFD(write_fd, JSON.encode({
            ok = valid and result.ok == true,
            error = valid and result.error or "无法完成连接验证。",
        }), true)
    end, true)
    if not pid then
        complete({ok = false, error = "无法启动连接验证。"})
        return
    end
    local deadline = clock() + 35
    local stopped
    local function poll()
        if not FFI.isSubProcessDone(pid) then
            if not stopped and (not self.alive or clock() >= deadline) then
                stopped = true
                FFI.terminateSubProcess(pid)
            end
            UI:scheduleIn(0.25, poll)
            return
        end
        local ok, result = pcall(JSON.decode, FFI.readAllFromFD(fd))
        if not stopped and ok and type(result) == "table" then
            complete(result)
        else
            complete({ok = false, error = stopped and "连接超时。" or "无法完成连接验证。"})
        end
    end
    UI:scheduleIn(0.25, poll)
end

return {methods = methods}
