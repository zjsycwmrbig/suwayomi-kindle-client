-- Boundary: flat rectangular button factory for Kindle-friendly actions.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")

local Screen = Device.screen
local FlatButton = {}

function FlatButton.new(options)
    local function scale(px) return Screen:scaleBySize(px) end
    return Button:new{
        text = options.text,
        width = options.width,
        height = scale(48),
        text_font_face = "smallinfofontbold",
        text_font_size = 18,
        padding = 0,
        margin = 0,
        bordersize = scale(1),
        radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        enabled = options.enabled ~= false,
        callback = options.callback,
        show_parent = options.show_parent,
    }
end

return FlatButton
