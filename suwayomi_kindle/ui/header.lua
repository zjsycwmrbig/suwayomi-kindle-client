-- Boundary: flat page header shared by every plugin screen.
--
-- Responsibility: render a centered title with optional transparent SVG back
-- and close controls. No shadow, radius, or tonal background is used.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local Icons = require("suwayomi_kindle/ui/icons")

local Screen = Device.screen
local Header = {}

local HeaderButton = InputContainer:extend{
    icon_name = nil,
    callback = nil,
}

function HeaderButton:init()
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        Icons.widget(self.icon_name, Screen:scaleBySize(24)),
    }
    self.ges_events = {
        TapHeaderButton = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function HeaderButton:getSize()
    return self.dimen
end

function HeaderButton:onTapHeaderButton()
    if self.callback then
        self.callback()
    end
    return true
end

function Header:build(options)
    local function scale(px) return Screen:scaleBySize(px) end
    local width = options.width or Screen:getWidth()
    local height = scale(54)
    local button_width = scale(54)
    local side_width = button_width * (options.on_back and options.on_menu and 2 or 1)
    local title_width = width - 2 * side_width
    local title = TextWidget:new{
        text = options.title or "",
        face = Font:getFace("smallinfofontbold", 22),
        max_width = title_width - scale(20),
    }

    local left = HorizontalGroup:new{}
    local right = HorizontalGroup:new{}
    local function icon(group, name, callback)
        group[#group+1] = HeaderButton:new{icon_name = name, callback = callback,
            dimen = Geom:new{w = button_width, h = height}}
    end
    if options.on_back then icon(left, "chevron_left", options.on_back) end
    if options.on_menu then icon(left, "menu", options.on_menu) end
    if #left == 0 then left[1] = HorizontalSpan:new{width = side_width} end
    if side_width > button_width then right[1] = HorizontalSpan:new{width = side_width - button_width} end
    icon(right, "close", options.on_close)

    local row = HorizontalGroup:new{
        left,
        CenterContainer:new{
            dimen = Geom:new{w = title_width, h = height},
            title,
        },
        right,
    }

    return FrameContainer:new{
        width = width,
        height = height + scale(1),
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            row,
            LineWidget:new{
                dimen = Geom:new{
                    w = width,
                    h = scale(1),
                },
                background = Blitbuffer.COLOR_GRAY,
            },
        },
    }
end

return Header
