-- Settings navigation, inline connection form, and verification feedback.
local BB = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Frame = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local Column = require("ui/widget/verticalgroup")
local Space = require("ui/widget/verticalspan")
local Gap = require("ui/widget/horizontalspan")
local Scroll = require("ui/widget/container/scrollablecontainer")
local Worker = require("suwayomi_kindle/worker")
local CheckButton = require("ui/widget/checkbutton")
local InputText = require("ui/widget/inputtext")
local Text = require("ui/widget/textwidget")
local Paragraph = require("ui/widget/textboxwidget")
local Line = require("ui/widget/linewidget")
local UI = require("ui/uimanager")

local Config = require("suwayomi_kindle/config")
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
    local download = self.settings.download
    local library = self.settings.library
    local browse = self.settings.browse
    local browse_lang = ({all = "全部语言", en = "英文", zh = "中文"})[browse.language] or "中文"
    return Frame:new{
        width = screen_width, height = body_height, bordersize = 0, padding = 0,
        padding_left = inset, padding_right = screen_width - width - inset,
        Column:new{
            spacing(12),
            SettingRow:new{
                label = "连接", value = status, width = width,
                callback = function() self.settings_route = "connection"; self:refresh() end,
            },
            rule(width),
            SettingRow:new{
                label = "下载",
                value = (download.max_parallel or 1) .. " 并行 · "
                    .. (download.retention == "never" and "不删除" or download.retention == "0" and "直接删除" or "保留 " .. download.retention .. " 章"),
                width = width,
                callback = function() self.settings_route = "download"; self:refresh() end,
            },
            rule(width),
            SettingRow:new{
                label = "书架",
                value = library.view_mode == "grid" and "书架视图" or "列表视图",
                width = width,
                callback = function() self.settings_route = "library"; self:refresh() end,
            },
            rule(width),
            SettingRow:new{
                label = "浏览",
                value = browse_lang .. " · " .. (browse.view_mode == "grid" and "书架视图" or "列表视图"),
                width = width,
                callback = function() self.settings_route = "browse"; self:refresh() end,
            },
            rule(width),
        },
    }
end

local function save_section(home, section, patch)
    local saved, err = home.settings_store:update(section, patch)
    if not saved then
        UI:show(require("ui/widget/infomessage"):new{text = err})
        home:refresh()
        return false
    end
    if section == "browse" and saved.language ~= home.settings.browse.language then home:reset_browse() end
    home.settings[section] = saved
    home:refresh()
    return true
end

local function choice_button(home, options, selected, on_select, width)
    local row = Row:new{}
    local gap, count = scale(6), #options
    local button_width = math.floor((width - gap * (count - 1)) / count)
    for i, option in ipairs(options) do
        if i > 1 then row[#row + 1] = Gap:new{width = gap} end
        row[#row + 1] = Button.new{
            text = option.label,
            width = button_width,
            filled = selected == option.value,
            show_parent = home,
            callback = function() on_select(option.value) end,
        }
    end
    return row
end

function methods:build_download_settings(screen_width, body_height)
    local cfg = self.settings.download
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(18)}
    column[#column + 1] = SettingRow:new{
        label = "下载位置", value = cfg.directory == "" and "KOReader 书库" or cfg.directory,
        width = width, callback = function() self:choose_download_directory() end,
    }
    column[#column + 1] = rule(width)
    column[#column + 1] = spacing(12)
    column[#column + 1] = label("最大并行下载数")
    column[#column + 1] = choice_button(self, {
        {label = "1", value = 1}, {label = "2", value = 2}, {label = "3", value = 3},
    }, cfg.max_parallel, function(value)
        save_section(self, "download", {max_parallel = value})
    end, width)
    column[#column + 1] = spacing(14)
    column[#column + 1] = label("标记已读后")
    local function retention(options)
        column[#column + 1] = spacing(6)
        column[#column + 1] = choice_button(self, options, cfg.retention, function(value)
            save_section(self, "download", {retention = value})
        end, width)
    end
    retention({{label = "不删除", value = "never"}, {label = "直接删除", value = "0"}})
    retention({{label = "留 1 章", value = "1"}, {label = "留 3 章", value = "3"},
        {label = "留 5 章", value = "5"}, {label = "留 10 章", value = "10"}})
    column[#column + 1] = rule(width)
    column[#column + 1] = Paragraph:new{
        text = "下载队列接入后，此策略将用于清理已读章节。",
        width = width, face = Font:getFace("x_smallinfofont", 14),
    }
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:build_library_settings(screen_width, body_height)
    local cfg = self.settings.library
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(18)}
    column[#column + 1] = label("漫画显示方式")
    column[#column + 1] = choice_button(self, {
        {label = "列表", value = "list"}, {label = "书架", value = "grid"},
    }, cfg.view_mode, function(value)
        save_section(self, "library", {view_mode = value})
    end, width)
    column[#column + 1] = rule(width)
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:build_browse_settings(screen_width, body_height)
    local cfg = self.settings.browse
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(18)}
    column[#column + 1] = label("源语言")
    column[#column + 1] = choice_button(self, {
        {label = "中文", value = "zh"},
        {label = "英文", value = "en"},
        {label = "全部", value = "all"},
    }, cfg.language, function(value)
        save_section(self, "browse", {language = value})
    end, width)
    column[#column + 1] = rule(width)
    column[#column + 1] = label("漫画显示方式")
    column[#column + 1] = choice_button(self, {
        {label = "列表", value = "list"}, {label = "书架", value = "grid"},
    }, cfg.view_mode, function(value)
        save_section(self, "browse", {view_mode = value})
    end, width)
    column[#column + 1] = rule(width)
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:settings_page_frame(screen_width, body_height, width, content)
    local inset = math.floor((screen_width - width) / 2)
    local view = Scroll:new{dimen = Geom:new{w = width + Scroll:getScrollbarWidth(), h = body_height},
        show_parent = self, content}
    self.cropping_widget = view
    return Frame:new{
        width = screen_width, height = body_height, bordersize = 0, padding = 0,
        padding_left = inset,
        view,
    }
end

function methods:choose_download_directory()
    local PathChooser = require("ui/widget/pathchooser")
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        title = "长按文件夹选择下载位置",
        path = require("libs/libkoreader-lfs").attributes(self.settings.download.directory, "mode") == "directory"
            and self.settings.download.directory or require("apps/filemanager/filemanagerutil").getHomeFolder(),
        onConfirm = function(path)
            save_section(self, "download", {directory = path})
        end,
    }
    UI:show(chooser)
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
    elseif self.selected_tab ~= "settings" and (self.detail or (self.selected_tab == "browse" and self.browse.source)) then
        self:catalog_back()
    elseif self.selected_tab == "settings" and self.settings_route ~= "index" then
        self.settings_route = "index"
        self:refresh()
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
    if key == "password" then
        local toggle
        toggle = CheckButton:new{
            text = "显示密码", width = width, parent = home, enabled = not home.verifying,
            callback = function()
                input.text_type = toggle.checked and "text" or "password"
                input:setText(input:getText(), true)
                UI:setDirty(home, "ui")
            end,
        }
        column[#column + 1] = toggle
    end
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
    local saved, save_error = self.settings_store:update("connection", config)
    if not saved then
        self.connection_status = save_error or "设置保存失败。"
        self:refresh()
        return
    end
    self:release_connection_form()
    self:set_saved_connection(saved)
    self.draft = self.settings_store:load("connection")
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
        if result.ok then
            local verified = self.settings_store:mark_verified(config)
            if verified then
                self.draft.last_verified_credential_hash = verified.last_verified_credential_hash
            else
                self.connection_status = "连接成功，验证记录保存失败。"
            end
        end
        self:refresh()
    end

    self.verification_job = Worker.start(UI, config, "verify", {}, function(result, err)
        self.verification_job = nil
        complete(result or {ok = false, error = err})
    end)
end

return {methods = methods}
