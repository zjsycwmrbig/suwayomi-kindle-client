-- Boundary: bottom navigation visual component.
--
-- Responsibility: render three icon-and-label tabs with stable dimensions.
-- Owned state: none; selection remains in the parent screen.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen
local TabBar = {}
local Icons = require("suwayomi_kindle/ui/icons")

local TabButton = InputContainer:extend{
    tab_id = nil,
    label = nil,
    icon = nil,
    selected = false,
    callback = nil,
}

function TabButton:init()
    local function scale(px) return Screen:scaleBySize(px) end
    self.icon_widget = Icons.widget(self.icon, scale(25))
    self.label_widget = TextWidget:new{
        text = self.label,
        face = Font:getFace(self.selected and "smallinfofontbold" or "smallinfofont", 16),
        max_width = self.dimen.w,
    }
    self.frame = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            LineWidget:new{
                dimen = Geom:new{
                    w = self.dimen.w,
                    h = scale(2),
                },
                background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.dimen.w,
                    h = self.dimen.h - scale(2),
                },
                VerticalGroup:new{
                    align = "center",
                    self.icon_widget,
                    VerticalSpan:new{ width = scale(5) },
                    self.label_widget,
                },
            },
        },
    }
    self[1] = self.frame
    self.ges_events = {
        TapSelectTab = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function TabButton:getSize()
    return self.dimen
end

function TabButton:onTapSelectTab()
    if self.callback then
        self.callback(self.tab_id)
    end
    return true
end

function TabBar:build(options)
    local screen = Screen:getSize()
    local function scale(px) return Screen:scaleBySize(px) end
    local button_width = math.floor(screen.w / 3)
    local button_height = scale(74)
    local buttons = HorizontalGroup:new{}

    for _, item in ipairs(options.items) do
        buttons[#buttons + 1] = TabButton:new{
            tab_id = item.id,
            label = item.label,
            icon = item.icon,
            selected = options.active == item.id,
            callback = options.on_select,
            dimen = Geom:new{
                w = button_width,
                h = button_height,
            },
        }
    end

    return FrameContainer:new{
        width = screen.w,
        height = button_height + scale(1),
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            LineWidget:new{
                dimen = Geom:new{
                    w = screen.w,
                    h = scale(1),
                },
                background = Blitbuffer.COLOR_GRAY,
            },
            buttons,
        },
    }
end

return TabBar
