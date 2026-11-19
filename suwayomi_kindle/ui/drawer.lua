-- A separate modal window leaves the catalog viewport and its scroll state in place.
local BB = require("ffi/blitbuffer")
local Device = require("device")
local Frame = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Input = require("ui/widget/container/inputcontainer")
local Line = require("ui/widget/linewidget")
local Column = require("ui/widget/verticalgroup")
local UI = require("ui/uimanager")
local Icons = require("suwayomi_kindle/ui/icons")
local Header = require("suwayomi_kindle/ui/header")
local SettingRow = require("suwayomi_kindle/ui/setting_row")

local Drawer = Input:extend{modal = true, stop_events_propagation = true}

function Drawer:init()
    local screen = Device.screen
    local bounds = screen:getSize()
    local width = math.min(screen:scaleBySize(290), math.floor(bounds.w * 0.60))
    local border = screen:scaleBySize(1)
    local inner = width - 2 * border
    self.dimen = Geom:new{w = width, h = bounds.h}
    local content = Column:new{align = "left",
        Header:build{width = inner, title = self.owner:page_title(), on_close = function() self:dismiss() end},
    }
    for _, action in ipairs(self.actions) do
        content[#content+1] = SettingRow:new{width = inner, single_line = true, label = action[1],
            leading = action.icon and Icons.widget(action.icon, screen:scaleBySize(20)),
            callback = function()
                self:dismiss()
                action[2]()
            end}
        content[#content+1] = Line:new{dimen = Geom:new{w = inner, h = border}, background = BB.COLOR_LIGHT_GRAY}
    end
    self[1] = Frame:new{width = width, height = bounds.h, padding = 0, bordersize = border,
        background = BB.COLOR_WHITE, content}
    self.ges_events.DrawerTap = {GestureRange:new{ges = "tap", range = bounds}}
    self.ges_events.DrawerSwipe = {GestureRange:new{ges = "swipe", range = bounds}}
    if Device:hasKeys() then self.key_events.CloseDrawer = {{Device.input.group.Back}} end
end

function Drawer:dismiss()
    if self.owner.drawer == self then UI:close(self, "ui", self.dimen) end
    return true
end

Drawer.onCloseDrawer = Drawer.dismiss
Drawer.onCloseDialog = Drawer.dismiss
Drawer.onSetDimensions = Drawer.dismiss

function Drawer:onCloseWidget()
    if self.owner.drawer == self then self.owner.drawer = nil end
end

function Drawer:onDrawerTap(_, gesture)
    if gesture.pos:notIntersectWith(self.dimen) then self:dismiss() end
    return true
end

function Drawer:onDrawerSwipe(_, gesture)
    if gesture.direction == "west" then self:dismiss() end
    return true
end

return Drawer
