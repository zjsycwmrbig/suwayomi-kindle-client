local Device = require("device")
local Geom = require("ui/geometry")
local Gesture = require("ui/gesturerange")
local Input = require("ui/widget/container/inputcontainer")
local Center = require("ui/widget/container/centercontainer")
local Icons = require("suwayomi_kindle/ui/icons")
local UI = require("ui/uimanager")

local Control = Input:extend{}

function Control:init()
    self.dimen = Geom:new{w=Device.screen:scaleBySize(42),h=self.height or Device.screen:scaleBySize(72)}
    self[1] = Center:new{dimen=self.dimen,Icons.widget(self.icon,Device.screen:scaleBySize(20))}
    self.ges_events={
        TapControl={Gesture:new{ges="tap",range=self.dimen}},
        HoldControl={Gesture:new{ges="hold",range=self.dimen}},
    }
end

function Control:getSize()
    return self.dimen
end

function Control:onTapControl()
    if self.enabled and self.callback then self.callback() end
    return true
end

function Control:onHoldControl()
    UI:show(require("ui/widget/infomessage"):new{text=self.label,timeout=2})
    return true
end

return Control
