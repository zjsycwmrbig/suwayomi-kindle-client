-- Boundary: KOReader plugin lifecycle and entry points.
--
-- Responsibility: register the plugin action and open the shared application
-- root without owning screen or connection state.
-- Owned state: the root widget and persistent settings facade.
-- Dependencies: KOReader runtime modules and suwayomi_kindle/* modules.

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Home = require("suwayomi_kindle/ui/home")
local SettingsStore = require("suwayomi_kindle/settings")

local SuwayomiKindle = WidgetContainer:extend{
    name = "suwayomi_kindle_client",
    is_doc_only = false,
}

function SuwayomiKindle:onDispatcherRegisterActions()
    Dispatcher:registerAction("suwayomi_kindle_action", {
        category = "none",
        event = "SuwayomiKindleAction",
        title = "Suwayomi Kindle",
        filemanager = true,
    })
end

function SuwayomiKindle:init()
    self.settings_store = SettingsStore:new{}
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function SuwayomiKindle:addToMainMenu(menu_items)
    menu_items.suwayomi_kindle_client = {
        text = "Suwayomi Kindle",
        sorting_hint = "more_tools",
        callback = function()
            self:openHome()
        end,
    }
end

function SuwayomiKindle:openHome()
    if self.home and self.home.alive then
        UIManager:close(self.home)
    end
    self.home = Home:new{
        plugin = self,
        settings_store = self.settings_store,
    }
    UIManager:show(self.home)
end

function SuwayomiKindle:onSuwayomiKindleAction()
    self:openHome()
    return true
end

return SuwayomiKindle
