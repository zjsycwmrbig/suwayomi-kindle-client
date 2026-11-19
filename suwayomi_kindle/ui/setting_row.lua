-- Boundary: flat navigation/configuration row.
--
-- Responsibility: show a label, one-line value, and transparent SVG chevron.
-- The row itself owns only tap handling and fixed layout dimensions.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Icons = require("suwayomi_kindle/ui/icons")

local Screen = Device.screen

local SettingRow = InputContainer:extend{
    label = "",
    value = "",
    width = nil,
    callback = nil,
    chevron = "chevron_right",
}

function SettingRow:init()
    local function scale(px) return Screen:scaleBySize(px) end
    local height = scale(self.single_line and 40 or 66)
    local horizontal_padding = scale(18)
    local chevron_size = scale(20)
    local leading_width = self.leading and scale(52) or 0
    local left_width = self.width - leading_width - 2 * horizontal_padding
        - ((self.single_line or self.hide_chevron) and 0 or chevron_size + scale(12))
    local label = TextWidget:new{
        text = self.label,
        face = Font:getFace("smallinfofontbold", 18),
        max_width = left_width,
    }
    local content = label
    if not self.single_line then
        content = VerticalGroup:new{align = "left", label, VerticalSpan:new{width = scale(4)},
            TextWidget:new{text = self.value or "", face = Font:getFace("x_smallinfofont", 15),
                max_width = left_width, fgcolor = Blitbuffer.COLOR_DARK_GRAY},
        }
    end
    local left = LeftContainer:new{dimen = Geom:new{w = left_width, h = height}, content}
    self.dimen = Geom:new{
        w = self.width,
        h = height,
    }
    local row = HorizontalGroup:new{}
    if self.leading then
        row[#row + 1] = CenterContainer:new{dimen = Geom:new{w = leading_width, h = height}, self.leading}
    end
    row[#row + 1] = left
    if not self.single_line and not self.hide_chevron then
        row[#row + 1] = CenterContainer:new{dimen = Geom:new{w = chevron_size + scale(12), h = height},
            Icons.widget(self.chevron, chevron_size)}
    end
    self[1] = FrameContainer:new{
        width = self.width,
        height = height,
        padding_left = horizontal_padding,
        padding_right = horizontal_padding,
        padding_top = 0,
        padding_bottom = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
    self.ges_events = {
        TapSettingRow = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function SettingRow:getSize()
    return self.dimen
end

function SettingRow:onTapSettingRow()
    if self.callback then
        self.callback()
    end
    return true
end

return SettingRow
