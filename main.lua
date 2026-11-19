-- Boundary: KOReader plugin lifecycle and entry points.
--
-- Responsibility: register the plugin action and open the shared application
-- root without owning screen or connection state.
-- Owned state: the root widget and persistent settings facade.
-- Dependencies: KOReader runtime modules and suwayomi_kindle/* modules.

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SettingsStore = require("suwayomi_kindle/settings_store")

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

function SuwayomiKindle:onNetworkConnected()
    local config=self.settings_store:load("connection")
    if config.server_url=="" then return end
    local index=require("suwayomi_kindle/library_index").new(config)
    require("suwayomi_kindle/sync_service").schedule(index,config)
    index:with_db(function(db)
        db:exec([[UPDATE queue SET state='queued' WHERE state='failed' AND
            (error LIKE '%连接%' OR error LIKE '%超时%')]])
        return true
    end)
    local queue=require("suwayomi_kindle/queue")
    queue.start(queue.attach(index,config,self.settings_store:load("download")),true)
end

function SuwayomiKindle:openHome()
    if self.home and self.home.alive then
        UIManager:close(self.home)
    end
    self.home = require("suwayomi_kindle/ui/home"):new{
        plugin = self,
        settings_store = self.settings_store,
    }
    UIManager:show(self.home)
end

function SuwayomiKindle:onSuwayomiKindleAction()
    self:openHome()
    return true
end

for name,method in pairs(require("suwayomi_kindle/reader")) do SuwayomiKindle[name]=method end

return SuwayomiKindle
