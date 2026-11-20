local Button = require("ui/widget/button")
local Center = require("ui/widget/container/centercontainer")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local UI = require("ui/uimanager")

local Pager = {}
function Pager.height()
    return Screen:scaleBySize(38)
end

local function jump_input(model, by_item)
    local dialog
    local maximum = by_item and model.item_count or not by_item and model.total
    local label = by_item and "项目序号" or "页码"
    local function submit()
        local value = dialog:getInputText():match("^%s*(%d+)%s*$")
        local n = tonumber(value)
        if not n or n < 1 or n > (maximum or 2147483647) then
            UI:show(require("ui/widget/infomessage"):new{text = "请输入有效" .. label .. "。", timeout = 2})
            return
        end
        UI:close(dialog)
        if not by_item then model.go(n)
        elseif model.go_item then model.go_item(n)
        else model.go(math.ceil(n / model.page_size)) end
    end
    dialog = require("ui/widget/inputdialog"):new{
        title = "输入" .. label .. (maximum and ("（1–" .. maximum .. "）") or ""),
        input = "", input_hint = by_item and "" or tostring(model.page), input_type = "number", enter_callback = submit,
        buttons = {{{text = "取消", callback = function() UI:close(dialog) end},
            {text = "跳转", is_enter_default = true, callback = submit}}},
    }
    UI:show(dialog)
    dialog:onShowKeyboard()
end

local function jump(model)
    if not model.go_item and (not model.page_size or not model.item_count or model.item_count == 0) then
        return jump_input(model, false)
    end
    local dialog
    local function action(label, by_item)
        return {text=label, callback=function()
            UI:close(dialog)
            jump_input(model, by_item)
        end}
    end
    dialog = require("ui/widget/buttondialog"):new{title="跳转",buttons={
        {action("按页码", false), action("按项目序号", true)},
    }}
    UI:show(dialog)
end

function Pager.build(home, width, model)
    local row = Row:new{}
    local function control(icon, text, enabled, callback)
        local button = Button:new{icon = icon, text = text, bordersize = 0, padding = Screen:scaleBySize(4),
            margin = 0, icon_width = Screen:scaleBySize(22), icon_height = Screen:scaleBySize(22),
            text_font_bold = false, text_font_size = 17, show_parent = home, callback = callback}
        button:enableDisable(enabled and not model.busy)
        row[#row+1] = button
    end
    local function gap()
        row[#row+1] = require("ui/widget/horizontalspan"):new{width = math.min(Screen:scaleBySize(30), math.floor(width/20))}
    end
    local ahead = not model.total or model.page < model.total
    control("chevron.first", nil, model.page > 1, function() model.go(1) end)
    gap()
    control("chevron.left", nil, model.page > 1, function() model.go(model.page-1) end)
    gap()
    control(nil, model.page .. "/" .. (model.total or "?"), model.page > 0, function() jump(model) end)
    gap()
    control("chevron.right", nil, ahead, function() model.go(model.page+1) end)
    gap()
    control("chevron.last", nil, ahead, function() model.go(model.total or "last") end)
    return Center:new{dimen = Geom:new{w = width, h = Pager.height()}, row}
end
return Pager
