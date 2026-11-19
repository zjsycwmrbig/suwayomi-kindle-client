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
local Scroll = require("ui/widget/container/scrollablecontainer")
local SettingRow = require("suwayomi_kindle/ui/setting_row")

local Drawer = Input:extend{modal = true, stop_events_propagation = true}

function Drawer:init()
    local screen = Device.screen
    local bounds = screen:getSize()
    local width = math.min(screen:scaleBySize(290), math.floor(bounds.w * 0.60))
    self.dimen = Geom:new{x=0,y=self.owner.drawer_top,w=width,h=self.owner.drawer_height}
    self:show_items(self.actions)
    self.ges_events.DrawerTap = {GestureRange:new{ges = "tap", range = bounds}}
    self.ges_events.DrawerSwipe = {GestureRange:new{ges = "swipe", range = bounds}}
    if Device:hasKeys() then self.key_events.CloseDrawer = {{Device.input.group.Back}} end
end

function Drawer:show_items(items, nested)
    local border = Device.screen:scaleBySize(1)
    local inner = self.dimen.w - 2*border
    local content = Column:new{align="left"}
    local function entry(label,icon,callback)
        content[#content+1] = SettingRow:new{width=inner-Scroll:getScrollbarWidth(),single_line=true,label=label,
            leading=icon and Icons.widget(icon,Device.screen:scaleBySize(20)),callback=callback}
        content[#content+1] = Line:new{dimen=Geom:new{w=inner-Scroll:getScrollbarWidth(),h=border},background=BB.COLOR_LIGHT_GRAY}
    end
    self.nested = nested
    if nested then entry("上一级","chevron_left",function() self:show_items(self.actions) end) end
    local ordered={}
    for _,submenu in ipairs({false,true}) do
        for _,action in ipairs(items) do
            if (action.children ~= nil) == submenu then ordered[#ordered+1]=action end
        end
    end
    for _,action in ipairs(ordered) do
        entry(action[1],action.children and "chevron_right" or action.icon,function()
            if action.children then self:show_items(action.children(),true)
            else self:dismiss(); action[2]() end
        end)
    end
    local old=self[1]
    self[1]=Frame:new{width=self.dimen.w,height=self.dimen.h,padding=0,bordersize=border,background=BB.COLOR_WHITE,
        Scroll:new{dimen=Geom:new{w=inner,h=self.dimen.h-2*border},show_parent=self,content}}
    if old then old:free(true); UI:setDirty(self,"ui",self.dimen) end
end

function Drawer:dismiss()
    if self.owner.drawer == self then UI:close(self, "ui", self.dimen) end
    return true
end

function Drawer:onCloseDialog()
    if self.nested then self:show_items(self.actions); return true end
    return self:dismiss()
end
Drawer.onCloseDrawer = Drawer.onCloseDialog
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
