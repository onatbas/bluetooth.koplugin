--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local EventListener = require("ui/widget/eventlistener")

local _ = require("gettext")

local Bluetooth = EventListener:extend{
    name = "Bluetooth",
    is_doc_only = false,
    is_running = false,  -- Internal variable to track if the task is running
    task_interval = 4000, -- Interval in milliseconds (4 seconds)
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action", {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action", {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action", {category="none", event="RefreshPairing", title=_("Refresh Pairing"), general=true}) -- New action
end

function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end


function Bluetooth:startRepeatingTask()
    -- Ensure the task is only started once
    if self.is_running then return end

    self.is_running = true

    local function onTimeout()
        if self.is_running then
            local status, err = pcall(function()

                Device.input.open("/dev/input/event3")
            end)
            UIManager:setTimeout(self.task_interval, onTimeout)
        end
    end

    UIManager:setTimeout(self.task_interval, onTimeout)
end


function Bluetooth:stopRepeatingTask()
    self.is_running = false
end



function Bluetooth:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Bluetooth on"),
                callback = function()
                    NetworkMgr:turnOnWifi(function()
				self:onBluetoothOn()
				end)
                end,
            },
            {
                text = _("Bluetooth off"),
                callback = function()     
                    self:onBluetoothOff()
                end,
            },
	    {
		text = _("Refresh Pairing"), -- New menu item
		callback = function()
			self:onRefreshPairing()
		end,
	    },
        },
    }
end

function Bluetooth:getScriptPath(script)
    return script
end

function Bluetooth:executeScript(script)
    local command = "/bin/sh /mnt/onboard/.koreader/plugins/bluetooth.koplugin/" .. script
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()
    return result
end

function Bluetooth:onBluetoothOn()
    local script = self:getScriptPath("on.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Result: ") .. result,
    }
    UIManager:show(popup)
    self:startRepeatingTask()
end

function Bluetooth:onBluetoothOff()
    local script = self:getScriptPath("off.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Result: ") .. result,
    }
    UIManager:show(popup)
    self:stopRepeatingTask()

end

function Bluetooth:onRefreshPairing()
    local status, err = pcall(function()
        Device.input.close("/dev/input/event3") -- Close the input
        Device.input.open("/dev/input/event3")  -- Reopen the input
    end)
    if not status then
        local errorMsg = InfoMessage:new{ text = _("Error: ") .. err }
        UIManager:show(errorMsg)
    end
end

return Bluetooth