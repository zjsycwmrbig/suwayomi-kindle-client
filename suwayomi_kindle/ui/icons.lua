-- Boundary: plugin-owned transparent SVG icon paths and widgets.
--
-- Responsibility: keep every plugin icon alpha-preserving and independent of
-- KOReader's white-flattened default icon cache.

local IconWidget = require("ui/widget/iconwidget")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = assert(module_path:match("^(.*)/suwayomi_kindle/ui/icons%.lua$"))

local Icons = {
    directory = plugin_root .. "/resources/icons",
}

function Icons.path(name)
    return Icons.directory .. "/" .. name .. ".svg"
end

function Icons.widget(name, size)
    return IconWidget:new{
        file = Icons.path(name),
        width = size,
        height = size,
        alpha = true,
    }
end

return Icons
