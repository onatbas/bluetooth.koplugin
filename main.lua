--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local EventListener = require("ui/widget/eventlistener")
local Event = require("ui/event")  -- Add this line

-- local BTKeyManager = require("BTKeyManager")

local _ = require("gettext")

-- local Bluetooth = EventListener:extend{
local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
    is_doc_only = false,
    is_running = false,  -- Internal variable to track if the task is running
    task_interval = 4000, -- Interval in milliseconds (4 seconds)
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action", {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action", {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action", {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true}) -- New action
    Dispatcher:registerAction("connect_to_device_action", {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true}) -- New action
end

function Bluetooth:registerKeyEvents()
    self.key_events.BTGotoNextChapter = { { "BTGotoNextChapter" }, event = "BTGotoNextChapter" }
    self.key_events.BTGotoPrevChapter = { { "BTGotoPrevChapter" }, event = "BTGotoPrevChapter" }
    self.key_events.BTDecreaseFontSize = { { "BTDecreaseFontSize" }, event = "BTDecreaseFontSize" }
    self.key_events.BTIncreaseFontSize = { { "BTIncreaseFontSize" }, event = "BTIncreaseFontSize" }
    self.key_events.BTToggleBookmark = { { "BTToggleBookmark" }, event = "BTToggleBookmark" }
    self.key_events.BTIterateRotation = { { "BTIterateRotation" }, event = "BTIterateRotation" }
    self.key_events.BTBluetoothOff = { { "BTBluetoothOff" }, event = "BTBluetoothOff" }
    self.key_events.BTRight = { { "BTRight" }, event = "BTRight" }
    self.key_events.BTLeft = { { "BTLeft" }, event = "BTLeft" }
end


function Bluetooth:onBTGotoNextChapter()
    UIManager:sendEvent(Event:new("GotoNextChapter"))
end

function Bluetooth:onBTGotoPrevChapter()
    UIManager:sendEvent(Event:new("GotoPrevChapter"))
end

function Bluetooth:onBTDecreaseFontSize()
    UIManager:sendEvent(Event:new("DecreaseFontSize", 1))
end

function Bluetooth:onBTIncreaseFontSize()
    UIManager:sendEvent(Event:new("IncreaseFontSize", 1))
end

function Bluetooth:onBTToggleBookmark()
    UIManager:sendEvent(Event:new("ToggleBookmark"))
end

function Bluetooth:onBTIterateRotation()
    UIManager:sendEvent(Event:new("IterateRotation"))
end

function Bluetooth:onBTBluetoothOff()
    UIManager:sendEvent(Event:new("BluetoothOff"))
end

function Bluetooth:onBTRight()
    UIManager:sendEvent(Event:new("GotoViewRel", 1))
end

function Bluetooth:onBTLeft()
    UIManager:sendEvent(Event:new("GotoViewRel", -1))
end

function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self:registerKeyEvents()
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
                text = _("Reconnect to Device"),
                callback = function()     
                    self:onConnectToDevice()
                end,
            },
	    {
		text = _("Refresh Device Input"), -- New menu item
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



function Bluetooth:onConnectToDevice()
    local script = self:getScriptPath("connect.sh")
    local result = self:executeScript(script)
    local popup = InfoMessage:new{
        text = _("Result: ") .. result,
    }
    UIManager:show(popup)
    self:startRepeatingTask()
end

function Bluetooth:debugPopup(msg)

    local popup = InfoMessage:new{                                                                                                                            
        text = _("DEBUG: ") .. msg,
    }                                                                                                                                                         
    UIManager:show(popup)  

end


return Bluetooth