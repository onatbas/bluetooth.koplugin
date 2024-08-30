--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")

local _ = require("gettext")

local Bluetooth = WidgetContainer:extend{
    name = "Bluetooth",
    is_doc_only = false,
    is_running = false,  -- Internal variable to track if the task is running
    task_interval = 4000, -- Interval in milliseconds (4 seconds)
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action", {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action", {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
end

function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Bluetooth:getBasePath()
    -- Get the full path of this script file and extract the directory
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return script_path:match("(.*/)")
end

function Bluetooth:startRepeatingTask()
    -- Ensure the task is only started once
    if self.is_running then return end

    self.is_running = true

    local function onTimeout()
        if self.is_running then
            self:checkBluetoothStatus()
            UIManager:setTimeout(self.task_interval, onTimeout)
        end
    end

    UIManager:setTimeout(self.task_interval, onTimeout)
end

function Bluetooth:stopRepeatingTask()
    self.is_running = false
end

function Bluetooth:checkBluetoothStatus()
    local script = self:getScriptPath("status.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Bluetooth Status: ") .. result,
    }
    UIManager:show(popup)
end

function Bluetooth:onBluetoothOn()
    local script = self:getScriptPath("on.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Result: ") .. result,
    }
    UIManager:show(popup)

    -- Start the repeating task when Bluetooth is turned on
    self:startRepeatingTask()
end

function Bluetooth:onBluetoothOff()
    local script = self:getScriptPath("off.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Result: ") .. result,
    }
    UIManager:show(popup)

    -- Stop the repeating task when Bluetooth is turned off
    self:stopRepeatingTask()
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
                        local status, err = pcall(function()
                           require("device").input.open("/dev/input/event3")
                        end)
                    end)
                end,
            },
            {
                text = _("Bluetooth off"),
                callback = function()
                    self:onBluetoothOff()
                end,
            },
        },
    }
end


function Bluetooth:executeScript(script)
    local command = "/bin/sh " .. self:getBasePath() .. script
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()
    return result
end

return Bluetooth
