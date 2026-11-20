local Device = require("device")
local Geom = require("ui/geometry")
local Gesture = require("ui/gesturerange")
local Input = require("ui/widget/container/inputcontainer")
local Center = require("ui/widget/container/centercontainer")
local Frame = require("ui/widget/container/framecontainer")
local Column = require("ui/widget/verticalgroup")
local Image = require("ui/widget/imagewidget")
local Text = require("ui/widget/textwidget")
local Font = require("ui/font")
local Icons = require("suwayomi_kindle/ui/icons")

local Tile = Input:extend{}
function Tile:init()
    local screen = Device.screen
    local poster_h = self.poster_height or screen:scaleBySize(114)
    local poster_w = math.min(self.width - 4, math.floor(poster_h * 0.71))
    local cover = self.path and Image:new{original_in_nightmode = true, file = self.path, width = poster_w, height = poster_h}
        or Icons.widget("library", screen:scaleBySize(36))
    local body = Column:new{align = "center",
        Frame:new{padding = 0, bordersize = 1,
            Center:new{dimen = Geom:new{w = poster_w, h = poster_h}, cover}},
        Text:new{text = self.title, face = Font:getFace("smallinfofont", 16), max_width = self.width - 4},
    }
    if self.subtitle then body[#body+1] = Text:new{text = self.subtitle, face = Font:getFace("x_smallinfofont", 13), max_width = self.width - 4} end
    self.dimen = Geom:new{w = self.width, h = body:getSize().h + screen:scaleBySize(6)}
    self[1] = Center:new{dimen = self.dimen, body}
    self.ges_events = {TapManga = {Gesture:new{ges = "tap", range = self.dimen}}}
    if self.hold_callback then
        self.ges_events.HoldManga = {Gesture:new{ges="hold",range=self.dimen}}
    end
end
function Tile:onTapManga()
    self.callback()
    return true
end
function Tile:onHoldManga()
    self.hold_callback()
    return true
end

return Tile
