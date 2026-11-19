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
local Left = require("ui/widget/container/leftcontainer")
local Languages = require("suwayomi_kindle/languages")
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
    local browse_lang = Languages.summary(browse.language)
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

-- Fixed-width value controls keep labels aligned on small screens.
local function setting_line(width, text, control)
    local h = scale(48)
    return Row:new{Left:new{dimen = Geom:new{w = width - control:getSize().w, h = h}, label(text)}, control}
end

local function small(home, text, w, fn, selected)
    return Button.new{text = text, compact = true, width = w, filled = selected, enabled = fn ~= nil,
        show_parent = home, callback = fn}
end

local function view_line(home, section, width)
    local modes = Row:new{}
    for _, option in ipairs({{"list", "列表"}, {"grid", "书架"}}) do
        modes[#modes+1] = small(home, option[2], math.min(scale(62), math.floor(width / 4)), function()
            save_section(home, section, {view_mode = option[1]})
        end, home.settings[section].view_mode == option[1])
    end
    return setting_line(width, "显示方式", modes)
end

local policies = {{"never","不删除"}, {"0","直接删除"}, {"1","留 1 章"}, {"3","留 3 章"},
    {"5","留 5 章"}, {"10","留 10 章"}}

local function stepper(home, width, title, options, value, change)
    local index = 1
    for i, opt in ipairs(options) do if opt[1] == value then index = i end end
    local w = math.min(scale(82), math.floor(width/4))
    local value_widget = require("ui/widget/container/centercontainer"):new{
        dimen = Geom:new{w = w, h = scale(30)},
        Text:new{text = options[index][2], face = Font:getFace("smallinfofont", 15), max_width = w},
    }
    return setting_line(width, title, Row:new{
        small(home, "<", scale(32), index > 1 and function() change(options[index-1][1]) end or nil),
        value_widget,
        small(home, ">", scale(32), index < #options and function() change(options[index+1][1]) end or nil),
    })
end

function methods:build_download_settings(screen_width, body_height)
    local cfg = self.settings.download
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(10),
        SettingRow:new{label = "下载位置", value = cfg.directory == "" and "KOReader 书库" or cfg.directory,
            width = width, callback = function() self:choose_download_directory() end},
        rule(width),
        stepper(self, width, "并行下载", {{1,"1"},{2,"2"},{3,"3"}}, cfg.max_parallel,
            function(v) save_section(self, "download", {max_parallel = v}) end),
        rule(width),
        stepper(self, width, "已读后保留", policies, cfg.retention,
            function(v) save_section(self, "download", {retention = v}) end),
        rule(width),
    }
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:build_library_settings(screen_width, body_height)
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(10), view_line(self, "library", width), rule(width)}
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:build_browse_settings(screen_width, body_height)
    local width = math.min(screen_width - scale(48), scale(520))
    local column = Column:new{align = "left", spacing(10),
        SettingRow:new{label = "源语言", value = Languages.summary(self.settings.browse.language), width = width,
            callback = function()
                self.settings_route, self.language_page = "languages", 1
                if not self.all_sources and self.settings.connection.server_url ~= "" then self:fetch_sources()
                else self:refresh() end
            end},
        rule(width), view_line(self, "browse", width), rule(width)}
    return self:settings_page_frame(screen_width, body_height, width, column)
end

function methods:build_language_picker(screen_width, height)
    local width = math.min(screen_width - scale(48), scale(520))
    local value = self.settings.browse.language
    local set = Languages.set(value)
    local options = Languages.options(value, self.all_sources)
    local row_h = scale(40)
    local size = math.max(1, math.floor((height-scale(16))/row_h))
    local pages = math.ceil((#options+1)/size)
    local page = math.min(pages, self.language_page or 1)
    self.pagination = {page = page, total = pages, go = function(n) self.language_page = n; self:refresh() end}
    local column = Column:new{align = "left", spacing(8)}
    for i = (page-1)*size+1, math.min(page*size, #options+1) do
        local code = i == 1 and "all" or options[i-1]
        local checked = set.all or set[code]
        local text = (checked and "☑  " or "☐  ") .. (code == "all" and "全部语言" or Languages.label(code))
        -- The full row is tappable; the text stays left-aligned.
        column[#column+1] = SettingRow:new{label = text, single_line = true, width = width, callback = function()
            save_section(self, "browse", {language = Languages.toggle(value, code, options)})
        end}
    end
    return self:settings_page_frame(screen_width, height, width, column)
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
    local form = self.input_form
    if not form or field.readonly then return end
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
    local form = self.input_form
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
    local form = self.input_form
    if not form or not form.focused then return end
    local field = form.focused
    form.focused = nil
    self.is_always_active = false
    field:onCloseKeyboard()
    field:unfocus()
    form.viewport:reset()
    form.viewport.dimen.h = form.height
    if form.redraw_on_blur then
        form.redraw_on_blur = nil
        UI:nextTick(function()
            if self.alive and self.input_form == form then self:refresh() end
        end)
    end
    UI:setDirty(self, "ui")
end

function methods:onCloseDialog()
    if self.input_form and self.input_form.focused then
        self:finish_field()
    elseif self.drawer then
        self:close_drawer()
    elseif self.selected_tab ~= "settings" and (self.detail or (self.selected_tab == "browse" and self.browse.source)) then
        self:catalog_back()
    elseif self.selected_tab == "settings" and self.settings_route ~= "index" then
        self.settings_route = self.settings_route == "languages" and "browse" or "index"
        self:refresh()
    else
        self:close()
    end
end

function methods:release_input_form()
    local form = self.input_form
    if not form then return end
    self:finish_field()
    form.viewport:reset()
    self.input_form = nil
    self.cropping_widget = nil
end

function methods:bind_keyboard_close(input)
    -- Back can close KOReader's keyboard directly, without going through Home.
    if input.keyboard and input.keyboard.onCloseWidget then
        local on_close = input.keyboard.onCloseWidget
        input.keyboard.onCloseWidget = function(keyboard)
            local result = on_close(keyboard)
            UI:nextTick(function()
                local form = self.input_form
                if form and form.focused == input and not input:isKeyboardVisible() then
                    self:finish_field()
                end
            end)
            return result
        end
    end
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
    home:bind_keyboard_close(input)
    home.input_form.fields[key] = input
    if key == "password" then
        local toggle
        toggle = small(home, "显示", scale(54), not home.verifying and function()
            local reveal = input.text_type == "password"
            input.text_type = reveal and "text" or "password"
            input:setText(input:getText(), true)
            toggle:setText(reveal and "隐藏" or "显示", scale(54))
            UI:setDirty(home, "ui")
        end or nil)
        column[#column+1] = setting_line(width, title, toggle)
    else
        column[#column+1] = label(title)
    end
    column[#column+1] = spacing(4)
    column[#column+1] = input
end

function methods:capture_inputs()
    local form = self.input_form
    if not form then return end
    if form.capture then form.capture(); return end
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
    self.input_form = form
    add_field(self, column, width, "server_url", "服务器地址", "http://192.168.1.10:4567")
    column[#column + 1] = spacing(16)
    column[#column+1] = stepper(self, width, "认证方式", {
        {"none", "无认证"}, {"basic_auth", "Basic Auth"}, {"ui_login", "账号登录"},
    }, self.draft.auth_method, function(mode)
        if self.verifying then return end
        self:capture_inputs()
        self.draft.auth_method, self.dirty = mode, true
        self.connection_status, self.verification_result = nil, nil
        self:refresh()
    end)
    if self.draft.auth_method ~= "none" then
        column[#column + 1] = spacing(16)
        add_field(self, column, width, "username", "用户名", "")
        column[#column + 1] = spacing(12)
        add_field(self, column, width, "password", "密码", "")
    end

    column[#column + 1] = spacing(20)
    column[#column + 1] = rule(width)
    column[#column + 1] = spacing(14)
    local secondary = math.min(scale(104), math.floor((width-scale(8))/2))
    column[#column + 1] = Row:new{
        Button.new{
            text = "保存设置", compact = true, width = secondary, enabled = not self.verifying,
            show_parent = self, callback = function() self:save_draft() end,
        },
        Gap:new{width = scale(10)},
        Button.new{
            text = self.verifying and "验证中…" or "保存并验证",
            compact = true, width = secondary, filled = true, enabled = not self.verifying,
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
    self:capture_inputs()
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
    self:release_input_form()
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
