local Button = require("suwayomi_kindle/ui/flat_button")
local Center = require("ui/widget/container/centercontainer")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local Row = require("ui/widget/horizontalgroup")
local UI = require("ui/uimanager")

local Pager = {}
function Pager.height()
    return Screen:scaleBySize(38)
end

local function jump(model)
    local dialog
    local function submit()
        local value = dialog:getInputText():match("^%s*(%d+)%s*$")
        local n = tonumber(value)
        if not n or n < 1 or n > (model.total or 2147483647) then
            UI:show(require("ui/widget/infomessage"):new{text = "请输入有效页码。", timeout = 2})
            return
        end
        UI:close(dialog)
        model.go(n)
    end
    dialog = require("ui/widget/inputdialog"):new{
        title = model.total and ("跳转到页（1–" .. model.total .. "）") or "跳转到页",
        input = "", input_hint = tostring(model.page), input_type = "number", enter_callback = submit,
        buttons = {{{text = "取消", callback = function() UI:close(dialog) end},
            {text = "跳转", is_enter_default = true, callback = submit}}},
    }
    UI:show(dialog)
    dialog:onShowKeyboard()
end

function Pager.build(home, width, model)
    local row = Row:new{}
    local step = math.min(Screen:scaleBySize(50), math.floor(width / 6))
    local function control(text, w, enabled, callback)
        row[#row + 1] = Button.new{text = text, width = w, compact = true, border = 0,
            enabled = enabled and not model.busy, show_parent = home, callback = callback}
    end
    local ahead = not model.total or model.page < model.total
    control("<<", step, model.page > 1, function() model.go(1) end)
    control("<", step, model.page > 1, function() model.go(model.page - 1) end)
    control(model.page .. "/" .. (model.total or "?"), math.min(width - 4 * step, step * 2),
        true, function() jump(model) end)
    control(">", step, ahead, function() model.go(model.page + 1) end)
    control(">>", step, ahead, function() model.go(model.total or "last") end)
    return Center:new{dimen = Geom:new{w = width, h = Pager.height()}, row}
end
return Pager
