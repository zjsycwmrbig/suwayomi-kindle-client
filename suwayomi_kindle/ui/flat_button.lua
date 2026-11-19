-- Boundary: flat rectangular button factory for Kindle-friendly actions.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")

local Screen = Device.screen
local FlatButton = {}

function FlatButton.new(options)
    local function scale(px) return Screen:scaleBySize(px) end
    local button = Button:new{
        text = options.text,
        width = options.width,
        height = scale(options.compact and 30 or 38),
        text_font_face = "smallinfofontbold",
        text_font_size = options.compact and 15 or 18,
        padding = 0,
        margin = 0,
        bordersize = options.border or scale(options.compact and 1 or 2),
        radius = 0,
        avoid_text_truncation = false,
        enabled = options.enabled ~= false,
        callback = options.callback,
        show_parent = options.show_parent,
    }
    if options.filled and button.enabled then
        button.frame.background = Blitbuffer.COLOR_BLACK
        button.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end
    return button
end

return FlatButton
