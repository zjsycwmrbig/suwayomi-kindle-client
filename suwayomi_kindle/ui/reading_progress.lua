local Screen = require("device").screen
local Font = require("ui/font")
local Text = require("ui/widget/textwidget")
local Row = require("ui/widget/horizontalgroup")
local Gap = require("ui/widget/horizontalspan")
local Bar = require("ui/widget/progresswidget")

local Progress = {}

function Progress.new(total, unread, compact)
    local fraction, percent = require("suwayomi_kindle/progress").measure(total, unread)
    local row=Row:new{}
    if fraction then
        row[#row+1]=Bar:new{width=Screen:scaleBySize(compact and 34 or 52),height=Screen:scaleBySize(6),
            radius=0,margin_v=0,margin_h=0,percentage=fraction}
        row[#row+1]=Gap:new{width=Screen:scaleBySize(5)}
    end
    row[#row+1]=Text:new{text=percent and (percent .. "%") or "—",face=Font:getFace("smallinfofontbold",14)}
    return row
end

return Progress
