local Button = require("ui/widget/button")
local Center = require("ui/widget/container/centercontainer")
local Screen = require("device").screen
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Frame = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local Column = require("ui/widget/verticalgroup")
local Left = require("ui/widget/container/leftcontainer")
local Space = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local Text = require("ui/widget/textwidget")
local InputText = require("ui/widget/inputtext")
local UI = require("ui/uimanager")
local Font = require("ui/font")
local FlatButton = require("suwayomi_kindle/ui/flat_button")

local Pager = {}
function Pager.height()
    return Screen:scaleBySize(38)
end

local JumpDialog = InputContainer:extend{
    modal = true,
    stop_events_propagation = true,
    is_always_active = true,
}

local function number(value)
    local digits = tostring(value or ""):match("^%s*(%d+)%s*$")
    return tonumber(digits)
end

function JumpDialog:init()
    local scale = function(n) return Screen:scaleBySize(n) end
    local inset, border = scale(18), scale(1)
    local inner = math.min(Screen:getWidth() - 2*scale(20), scale(320)) - 2*(inset + border)
    local label_width, padding = scale(62), scale(6)
    local input_width = inner - label_width - 2*(padding + border)
    local label_face = Font:getFace("smallinfofontbold", 16)
    local function field(maximum)
        return InputText:new{parent=self, focused=false, width=input_width,
            hint=maximum and ("1 – " .. maximum) or "输入序号",
            padding=padding, margin=0, bordersize=border, scroll=true,
            input_type="number", face=Font:getFace("smallinfofont",16), enter_callback=function()
                self:submit()
            end}
    end
    self.page_input, self.item_input = field(self.model.total), field(self.model.item_count)
    local function input_row(name, input)
        return Row:new{align="center",
            Left:new{dimen=Geom:new{w=label_width, h=input:getSize().h},
                Text:new{text=name, face=label_face}},
            input,
        }
    end
    self.submit_button = FlatButton.new{text="跳转", width=inner, filled=true, show_parent=self,
        callback=function() self:submit() end}
    self.frame = Frame:new{padding=inset, bordersize=border, background=Blitbuffer.COLOR_WHITE,
        Column:new{align="left",
            input_row("页码",self.page_input),
            Space:new{width=scale(10)},
            input_row("项码",self.item_input),
            Space:new{width=scale(16)},
            self.submit_button,
        }}
    self.frame:getSize()
    self[1] = Center:new{dimen=Screen:getSize():copy(),
        ignore_if_over="height", self.frame}
    self.ges_events = {
        TapOutside = {GestureRange:new{ges="tap",range=Screen:getSize()}},
    }
    if Device:hasKeys() then
        self.key_events = {CloseDialog={{Device.input.group.Back}}}
    end
end

function JumpDialog:onShowKeyboard()
    if self.focused then return end
    self:onSwitchFocus(self.page_input)
end

function JumpDialog:getFocusableWidgetXY()
    -- InputText asks for a D-pad layout even when touch manages focus.
end

function JumpDialog:onKeyboardHeightChanged()
    local field = self.focused
    self[1].dimen.h = Screen:getHeight() - (field and field:isKeyboardVisible() and field:getKeyboardDimen().h or 0)
end

function JumpDialog:onSwitchFocus(field)
    if self.focused and self.focused ~= field then
        self.focused:onCloseKeyboard()
        self.focused:unfocus()
    end
    self.focused = field
    field:focus()
    if not ((Device:hasKeyboard() or Device:hasScreenKB())
        and G_reader_settings:nilOrFalse("virtual_keyboard_enabled")) then
        field:onShowKeyboard()
    end
    self:onKeyboardHeightChanged()
    UI:setDirty(self,"ui")
    return true
end

function JumpDialog:onTapOutside(_, gesture)
    if gesture.pos:notIntersectWith(self.frame.dimen) then
        if self.focused and self.focused:isKeyboardVisible() then
            self.focused:onCloseKeyboard()
            self:onKeyboardHeightChanged()
            UI:setDirty(self,"ui")
        else
            self:onCloseDialog()
        end
    end
    return true
end

function JumpDialog:onCloseDialog()
    if self.focused then self.focused:onCloseKeyboard() end
    UI:close(self)
    return true
end

function JumpDialog:show_error(text)
    UI:show(require("ui/widget/infomessage"):new{text=text,timeout=2})
end

function JumpDialog:submit()
    local item_text, page_text = self.item_input:getText(), self.page_input:getText()
    if item_text == "" and page_text == "" then
        self:show_error("请输入页码或项码。")
        return
    end
    local model = self.model
    if item_text ~= "" then
        local item = number(item_text)
        if not item or item < 1 or (model.item_count and item > model.item_count) then
            self:show_error("请输入有效项码" .. (model.item_count and ("（1–"..model.item_count.."）") or "") .. "。")
            return
        end
        if not model.go_item and not model.page_size then
            self:show_error("当前页面不支持项码跳转。")
            return
        end
        self:onCloseDialog()
        if model.go_item then model.go_item(item)
        else model.go(math.ceil(item/model.page_size)) end
        return
    end
    local page = number(page_text)
    if not page or page < 1 or (model.total and page > model.total) then
        self:show_error("请输入有效页码" .. (model.total and ("（1–"..model.total.."）") or "") .. "。")
        return
    end
    self:onCloseDialog()
    model.go(page)
end

local function jump(model)
    local dialog = JumpDialog:new{model=model}
    UI:show(dialog)
    dialog:onShowKeyboard()
end

function Pager.build(home, width, model)
    local row = Row:new{}
    local button_width = math.min(Screen:scaleBySize(50), math.floor(width/7))
    local function control(icon, text, enabled, callback)
        local button = Button:new{icon = icon, text = text, bordersize = 0, padding = 0,
            width = icon and button_width or nil, height = Pager.height(),
            padding_h = text and Screen:scaleBySize(12) or 0,
            margin = 0, icon_width = Screen:scaleBySize(22), icon_height = Screen:scaleBySize(22),
            text_font_bold = false, text_font_size = 17, show_parent = home, callback = callback}
        button:enableDisable(enabled and not model.busy)
        row[#row+1] = button
    end
    local ahead = not model.total or model.page < model.total
    control("chevron.first", nil, model.page > 1, function() model.go(1) end)
    control("chevron.left", nil, model.page > 1, function() model.go(model.page-1) end)
    control(nil, model.page .. "/" .. (model.total or "?"), model.page > 0, function() jump(model) end)
    control("chevron.right", nil, ahead, function() model.go(model.page+1) end)
    control("chevron.last", nil, ahead, function() model.go(model.total or "last") end)
    return Center:new{dimen = Geom:new{w = width, h = Pager.height()}, row}
end
return Pager
