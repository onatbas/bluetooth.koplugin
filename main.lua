--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local EventListener = require("ui/widget/eventlistener")
local Event = require("ui/event")

-- local BTKeyManager = require("BTKeyManager")

local _ = require("gettext")

-- local Bluetooth = EventListener:extend{
local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
    is_bluetooth_on = false,  -- Cache for isBluetoothOn() - do not set directly
    input_device_path = nil,  -- Device path (set dynamically in init)
    current_bank = 1,  -- Current bank (1-based)
    banks = {},  -- Bank configurations
    bank_config_file = "bank_config.txt",  -- Bank configuration file
}

-- Input device paths per device model
Bluetooth.device_input_paths = {
    ["Kobo_goldfinch"] = "/dev/input/event3",  -- Clara 2E
    ["Kobo_io"] = "/dev/input/event4",         -- Libra 2
}
Bluetooth.default_input_path = "/dev/input/event4"  -- Default fallback

-- Bluetooth command configurations per device model
-- Each config contains the commands needed to turn BT on/off
Bluetooth.device_bt_configs = {
    ["Kobo_goldfinch"] = {  -- Clara 2E
        name = "Clara 2E",
        hci_attach = "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20",
        hci_kill = "pkill hciattach",
    },
    ["Kobo_io"] = {  -- Libra 2
        name = "Libra 2",
        hci_attach = "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5",
        hci_kill = "pkill rtk_hciattach",
    },
}
-- Default config (uses Clara 2E style as fallback)
Bluetooth.default_bt_config = {
    name = "Default",
    hci_attach = "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20",
    hci_kill = "pkill hciattach",
}

-- Binary-based detection: map binary names to config profiles
-- Used when device model is unknown but we can detect which binaries exist
Bluetooth.binary_to_config = {
    ["rtk_hciattach"] = {  -- Libra 2 style (Realtek chip)
        name = "Auto-detected (Realtek/Libra 2 style)",
        hci_attach = "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5",
        hci_kill = "pkill rtk_hciattach",
        detection_method = "rtk_hciattach binary found in /sbin",
    },
    ["hciattach"] = {  -- Clara 2E style (standard)
        name = "Auto-detected (Standard/Clara 2E style)",
        hci_attach = "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20",
        hci_kill = "pkill hciattach",
        detection_method = "hciattach binary found in /sbin",
    },
}

-- Default BTAction key mappings for 8BitDo controller
-- These will be written to settings/event_map.lua if auto-correction is used
Bluetooth.default_event_mappings = {
    [19]  = "BTAction1",   -- R
    [23]  = "BTAction2",   -- I
    [25]  = "BTAction3",   -- P/Y
    [32]  = "BTAction4",   -- D/R2
    [38]  = "BTAction5",   -- L/L2
    [45]  = "BTAction6",   -- X
    [46]  = "BTAction7",   -- C/B
    [48]  = "BTAction8",   -- B/UP
    [49]  = "BTAction9",   -- N/A
    [60]  = "BTAction15",  -- F2 (bank switch)
    [61]  = "BTAction16",  -- F3 (bank switch)
    [103] = "BTAction10",  -- Up arrow
    [105] = "BTAction11",  -- Left arrow
    [106] = "BTAction12",  -- Right arrow
    [108] = "BTAction13",  -- Down arrow
    [109] = "BTAction14",  -- Page Down
    [115] = "BTLeft",      -- Additional button
}

-- Config file for storing Bluetooth device settings
Bluetooth.config_file = "bt_config.lua"

-- Button press history (for diagnostics)
Bluetooth.button_press_history = {}
Bluetooth.max_history_size = 10

--[[
Button press history functions
--]]

function Bluetooth:getKeyCodeForEvent(event_name)
    -- Reverse lookup: find which key code maps to this event name
    -- Check Device.input.event_map first (runtime mappings)
    local event_map = Device.input and Device.input.event_map
    if event_map then
        for code, name in pairs(event_map) do
            if name == event_name then
                return code
            end
        end
    end
    -- Fall back to our default mappings
    for code, name in pairs(self.default_event_mappings) do
        if name == event_name then
            return code
        end
    end
    return nil
end

function Bluetooth:logButtonPress(event_name, key_code, action_num, target_event)
    -- If key_code not provided, try to look it up
    if not key_code then
        key_code = self:getKeyCodeForEvent(event_name)
    end
    
    local entry = {
        timestamp = os.date("%H:%M:%S"),
        event_name = event_name,
        key_code = key_code,
        action_num = action_num,
        target_event = target_event,
        bank = self.current_bank,
    }
    
    -- Add to front of history
    table.insert(self.button_press_history, 1, entry)
    
    -- Trim to max size
    while #self.button_press_history > self.max_history_size do
        table.remove(self.button_press_history)
    end
end

function Bluetooth:getButtonPressHistory()
    return self.button_press_history
end

function Bluetooth:clearButtonPressHistory()
    self.button_press_history = {}
end

function Bluetooth:isBluetoothOn()
    -- Actually check if Bluetooth is running by querying hci0 interface
    -- This is more reliable than tracking state manually
    local result = self:executeCommand("hciconfig hci0 2>&1")
    if result and result:match("UP RUNNING") then
        self.is_bluetooth_on = true
        return true
    else
        self.is_bluetooth_on = false
        return false
    end
end

function Bluetooth:readRawInputEvents(timeout_secs)
    -- Read raw input events from the input device using evtest
    -- This uses a timeout to avoid blocking forever
    timeout_secs = timeout_secs or 5
    local events = {}
    
    local cmd = string.format("timeout %ds cat %s 2>/dev/null | od -An -tx1 -w24 | head -20", 
        timeout_secs, self.input_device_path)
    
    local handle = io.popen(cmd)
    if not handle then
        return events
    end
    
    local output = handle:read("*a")
    handle:close()
    
    -- Parse the hex output - Linux input events are 24 bytes each:
    -- struct input_event { time (16 bytes), type (2 bytes), code (2 bytes), value (4 bytes) }
    -- For simplicity, we'll use evtest if available, otherwise parse manually
    
    -- Try evtest approach (more readable output)
    local evtest_cmd = string.format("timeout %ds evtest %s 2>/dev/null | grep -E 'type [0-9]+' | head -10", 
        timeout_secs, self.input_device_path)
    handle = io.popen(evtest_cmd)
    if handle then
        output = handle:read("*a")
        handle:close()
        
        -- Parse evtest output like: "Event: time ..., type 1 (EV_KEY), code 19 (KEY_R), value 1"
        for line in output:gmatch("[^\n]+") do
            local evt_type, code, value = line:match("type (%d+).*code (%d+).*value (%d+)")
            if evt_type and code and value then
                table.insert(events, {
                    type = tonumber(evt_type),
                    code = tonumber(code),
                    value = tonumber(value),
                })
            end
        end
    end
    
    return events
end

--[[
Config management functions
--]]

function Bluetooth:getConfigPath()
    return self.path .. "/" .. self.config_file
end

function Bluetooth:loadConfig()
    local config_path = self:getConfigPath()
    local file = io.open(config_path, "r")
    if not file then
        -- Return default config
        return {
            device_mac = nil,
            device_name = nil,
        }
    end
    
    local content = file:read("*all")
    file:close()
    
    -- Parse the Lua config file
    local ok, config = pcall(function()
        return dofile(config_path)
    end)
    
    if ok and type(config) == "table" then
        return config
    end
    
    return {
        device_mac = nil,
        device_name = nil,
    }
end

function Bluetooth:saveConfig(config)
    local config_path = self:getConfigPath()
    local file = io.open(config_path, "w")
    if not file then
        return false, "Could not open config file for writing"
    end
    
    file:write("-- Bluetooth plugin configuration\n")
    file:write("-- Auto-generated, do not edit manually\n\n")
    file:write("return {\n")
    
    if config.device_mac then
        file:write(string.format("    device_mac = %q,\n", config.device_mac))
    else
        file:write("    device_mac = nil,\n")
    end
    
    if config.device_name then
        file:write(string.format("    device_name = %q,\n", config.device_name))
    else
        file:write("    device_name = nil,\n")
    end
    
    file:write("}\n")
    file:close()
    
    return true
end

function Bluetooth:getSavedDeviceMAC()
    local config = self:loadConfig()
    return config.device_mac, config.device_name
end

function Bluetooth:saveDeviceMAC(mac, name)
    local config = self:loadConfig()
    config.device_mac = mac
    config.device_name = name
    return self:saveConfig(config)
end

--[[
Bluetooth scanning and device management
--]]

function Bluetooth:startScan(duration)
    -- Start Bluetooth scanning with auto-timeout (default 30 seconds)
    -- This prevents dangling processes and ensures scan stops automatically
    duration = duration or 30
    
    -- First stop any existing scan
    self:stopScan()
    
    -- Start scan with timeout - will auto-stop after duration seconds
    os.execute(string.format(
        "timeout %ds bluetoothctl scan on > /dev/null 2>&1 &",
        duration
    ))
    return true
end

function Bluetooth:stopScan()
    -- Stop Bluetooth scanning properly
    -- 1. Kill any running bluetoothctl scan process
    os.execute("pkill -f 'bluetoothctl scan' 2>/dev/null")
    
    -- 2. Send scan off command to bluetooth daemon (quick, non-blocking)
    os.execute("echo 'scan off' | bluetoothctl > /dev/null 2>&1 &")
    return true
end

function Bluetooth:executeCommandWithTimeout(cmd, timeout_secs)
    -- Execute a command with a timeout to prevent freezing
    -- Note: On Kobo, 'timeout' may not exist, so we try without it as fallback
    timeout_secs = timeout_secs or 3
    
    -- First try with timeout command
    local full_cmd = string.format("timeout %ds %s 2>&1", timeout_secs, cmd)
    local handle = io.popen(full_cmd)
    if not handle then
        return ""
    end
    local result = handle:read("*a")
    handle:close()
    
    -- If timeout command doesn't exist, it may return error - try direct command
    if result and result:match("timeout:") then
        handle = io.popen(cmd .. " 2>&1")
        if handle then
            result = handle:read("*a")
            handle:close()
        end
    end
    
    return result or ""
end

function Bluetooth:getScannedDevices()
    -- Get list of discovered devices (with timeout to prevent freeze)
    local result = self:executeCommandWithTimeout("bluetoothctl devices", 3)
    local devices = {}
    
    for line in result:gmatch("[^\r\n]+") do
        -- Parse lines like: "Device E4:17:D8:7D:3D:69 8BitDo Micro gamepad"
        local mac, name = line:match("Device%s+([%x:]+)%s+(.+)")
        if mac and name then
            table.insert(devices, {
                mac = mac,
                name = name,
            })
        end
    end
    
    return devices
end

function Bluetooth:getPairedDevices()
    -- Get list of paired devices (with timeout to prevent freeze)
    local result = self:executeCommandWithTimeout("bluetoothctl paired-devices", 3)
    local devices = {}
    
    for line in result:gmatch("[^\r\n]+") do
        -- Parse lines like: "Device E4:17:D8:7D:3D:69 8BitDo Micro gamepad"
        local mac, name = line:match("Device%s+([%x:]+)%s+(.+)")
        if mac and name then
            table.insert(devices, {
                mac = mac,
                name = name,
            })
        end
    end
    
    return devices
end

function Bluetooth:connectToDevice(mac)
    -- Connect to a specific device by MAC address
    local result = self:executeCommand("timeout 5s bluetoothctl connect " .. mac)
    local success = result:match("Connection successful") ~= nil
    return success, result
end

function Bluetooth:connectToSavedDevice()
    -- Connect to the saved device
    local mac, name = self:getSavedDeviceMAC()
    if not mac then
        return false, "No device saved. Please scan and select a device first."
    end
    
    local success, result = self:connectToDevice(mac)
    if success then
        return true, "Connected to " .. (name or mac)
    else
        return false, "Failed to connect to " .. (name or mac) .. "\n\n" .. result
    end
end

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action", {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action", {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action", {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true}) -- New action
    Dispatcher:registerAction("connect_to_device_action", {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true}) -- New action
    Dispatcher:registerAction("full_bluetooth_setup_action", {category="none", event="BTFullBluetoothSetup", title=_("Full Bluetooth Setup"), general=true})
    Dispatcher:registerAction("wifi_up_and_bluetooth_on_action", {category="none", event="BTWifiUpAndBluetoothOn", title=_("WiFi Up & Bluetooth On"), general=true})
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
	self.key_events.BTIncreaseBrightness = { { "BTIncreaseBrightness" }, event = "BTIncreaseBrightness" }
	self.key_events.BTDecreaseBrightness = { { "BTDecreaseBrightness" }, event = "BTDecreaseBrightness" }
	self.key_events.BTIncreaseWarmth = { { "BTIncreaseWarmth" }, event = "BTIncreaseWarmth" }
	self.key_events.BTDecreaseWarmth = { { "BTDecreaseWarmth" }, event = "BTDecreaseWarmth" }
	self.key_events.BTNextBookmark = { { "BTNextBookmark" }, event = "BTNextBookmark" }
	self.key_events.BTPrevBookmark = { { "BTPrevBookmark" }, event = "BTPrevBookmark" }
	self.key_events.BTLastBookmark = { { "BTLastBookmark" }, event = "BTLastBookmark" }
	self.key_events.BTToggleNightMode = { { "BTToggleNightMode" }, event = "BTToggleNightMode" }
	self.key_events.BTToggleStatusBar = { { "BTToggleStatusBar" }, event = "BTToggleStatusBar" }
	
	-- Sleep and shutdown
	self.key_events.BTSleep = { { "BTSleep" }, event = "BTSleep" }
	self.key_events.BTBluetoothOffAndSleep = { { "BTBluetoothOffAndSleep" }, event = "BTBluetoothOffAndSleep" }
	
	-- Bluetooth setup
	self.key_events.BTFullBluetoothSetup = { { "BTFullBluetoothSetup" }, event = "BTFullBluetoothSetup" }
	self.key_events.BTWifiUpAndBluetoothOn = { { "BTWifiUpAndBluetoothOn" }, event = "BTWifiUpAndBluetoothOn" }
	
	-- Screen refresh
	self.key_events.BTRefreshScreen = { { "BTRefreshScreen" }, event = "BTRefreshScreen" }
	
	-- Font settings cycling
	self.key_events.BTCycleFontHinting = { { "BTCycleFontHinting" }, event = "BTCycleFontHinting" }
	self.key_events.BTCycleFontKerning = { { "BTCycleFontKerning" }, event = "BTCycleFontKerning" }
	self.key_events.BTCycleWordSpacing = { { "BTCycleWordSpacing" }, event = "BTCycleWordSpacing" }
	self.key_events.BTCycleWordExpansion = { { "BTCycleWordExpansion" }, event = "BTCycleWordExpansion" }
	
	-- Font weight increase/decrease
	self.key_events.BTIncreaseFontWeight = { { "BTIncreaseFontWeight" }, event = "BTIncreaseFontWeight" }
	self.key_events.BTDecreaseFontWeight = { { "BTDecreaseFontWeight" }, event = "BTDecreaseFontWeight" }
	
	-- Line spacing increase/decrease
	self.key_events.BTIncreaseLineSpacing = { { "BTIncreaseLineSpacing" }, event = "BTIncreaseLineSpacing" }
	self.key_events.BTDecreaseLineSpacing = { { "BTDecreaseLineSpacing" }, event = "BTDecreaseLineSpacing" }
	
	-- Bank navigation
	self.key_events.BTRemoteNextBank = { { "BTRemoteNextBank" }, event = "BTRemoteNextBank" }
	self.key_events.BTRemotePrevBank = { { "BTRemotePrevBank" }, event = "BTRemotePrevBank" }
	
	-- Bank action mapping (BTAction1-20)
	for i = 1, 20 do
		self.key_events["BTAction" .. i] = { { "BTAction" .. i }, event = "BTAction" .. i }
	end
	
end


function Bluetooth:onBTGotoNextChapter()
    UIManager:sendEvent(Event:new("GotoNextChapter"))
end

function Bluetooth:onBTGotoPrevChapter()
    UIManager:sendEvent(Event:new("GotoPrevChapter"))
end

function Bluetooth:onBTDecreaseFontSize()
    UIManager:sendEvent(Event:new("DecreaseFontSize", 2))
end

function Bluetooth:onBTIncreaseFontSize()
    UIManager:sendEvent(Event:new("IncreaseFontSize", 2))
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

function Bluetooth:onBTIncreaseBrightness()
    UIManager:sendEvent(Event:new("IncreaseFlIntensity", 10))
end

function Bluetooth:onBTDecreaseBrightness()
    UIManager:sendEvent(Event:new("DecreaseFlIntensity", 10))
end

function Bluetooth:onBTIncreaseWarmth()
    UIManager:sendEvent(Event:new("IncreaseFlWarmth", 1))
end

function Bluetooth:onBTDecreaseWarmth()
    UIManager:sendEvent(Event:new("IncreaseFlWarmth", -1))
end

function Bluetooth:onBTNextBookmark()
    UIManager:sendEvent(Event:new("GotoNextBookmarkFromPage"))
end

function Bluetooth:onBTPrevBookmark()
    UIManager:sendEvent(Event:new("GotoPreviousBookmarkFromPage"))
end

function Bluetooth:onBTLastBookmark()
    UIManager:sendEvent(Event:new("GoToLatestBookmark"))
end

function Bluetooth:onBTToggleNightMode()
    UIManager:sendEvent(Event:new("ToggleNightMode"))
end

function Bluetooth:onBTToggleStatusBar()
    UIManager:sendEvent(Event:new("ToggleFooterMode"))
end

function Bluetooth:onBTSleep()
    UIManager:suspend()
end

function Bluetooth:onBTRefreshScreen()
    UIManager:setDirty("all", "full")
end

function Bluetooth:onBTBluetoothOffAndSleep()
    -- Turn off Bluetooth first (without popup)
    self:turnOffBluetooth()
    
    -- Wait 1 second, then put device to sleep
    UIManager:scheduleIn(1, function()
        UIManager:suspend()
    end)
end

function Bluetooth:onBTFullBluetoothSetup()
    self:onFullBluetoothSetup()
end

function Bluetooth:onBTWifiUpAndBluetoothOn()
    self:onWifiUpAndBluetoothOn()
end

-- Font settings cycling functions
function Bluetooth:onBTCycleFontHinting()
    self:cycleFontSetting("font_hinting", {0, 1, 2}, {"off", "native", "auto"})
end

function Bluetooth:onBTCycleFontKerning()
    self:cycleFontSetting("font_kerning", {0, 1, 2, 3}, {"off", "fast", "good", "best"})
end

function Bluetooth:onBTCycleWordSpacing()
    self:cycleWordSpacing()
end

function Bluetooth:onBTCycleWordExpansion()
    self:cycleFontSetting("word_expansion", {0, 5, 15}, {"none", "some", "more"})
end

function Bluetooth:onBTIncreaseFontWeight()
    self:adjustFontWeight(0.5)
end

function Bluetooth:onBTDecreaseFontWeight()
    self:adjustFontWeight(-0.5)
end

function Bluetooth:onBTIncreaseLineSpacing()
    self:adjustLineSpacing(5)
end

function Bluetooth:onBTDecreaseLineSpacing()
    self:adjustLineSpacing(-5)
end

-- Bank navigation functions
function Bluetooth:onBTRemoteNextBank()
    self:logButtonPress("BTRemoteNextBank", nil, nil, "nextBank")
    self:nextBank()
end

function Bluetooth:onBTRemotePrevBank()
    self:logButtonPress("BTRemotePrevBank", nil, nil, "prevBank")
    self:prevBank()
end

-- Bank action mapping functions (BTAction1-20)
function Bluetooth:onBTAction1() self:executeBankAction(1) end
function Bluetooth:onBTAction2() self:executeBankAction(2) end
function Bluetooth:onBTAction3() self:executeBankAction(3) end
function Bluetooth:onBTAction4() self:executeBankAction(4) end
function Bluetooth:onBTAction5() self:executeBankAction(5) end
function Bluetooth:onBTAction6() self:executeBankAction(6) end
function Bluetooth:onBTAction7() self:executeBankAction(7) end
function Bluetooth:onBTAction8() self:executeBankAction(8) end
function Bluetooth:onBTAction9() self:executeBankAction(9) end
function Bluetooth:onBTAction10() self:executeBankAction(10) end
function Bluetooth:onBTAction11() self:executeBankAction(11) end
function Bluetooth:onBTAction12() self:executeBankAction(12) end
function Bluetooth:onBTAction13() self:executeBankAction(13) end
function Bluetooth:onBTAction14() self:executeBankAction(14) end
function Bluetooth:onBTAction15() self:executeBankAction(15) end
function Bluetooth:onBTAction16() self:executeBankAction(16) end
function Bluetooth:onBTAction17() self:executeBankAction(17) end
function Bluetooth:onBTAction18() self:executeBankAction(18) end
function Bluetooth:onBTAction19() self:executeBankAction(19) end
function Bluetooth:onBTAction20() self:executeBankAction(20) end

-- BTNone function for empty slots
function Bluetooth:onBTNone()
    -- Do nothing for empty action slots
end

-- Helper function to cycle through font settings
function Bluetooth:cycleFontSetting(setting_name, values, labels)
    -- Get the current reader UI and font module
    local readerui = self.ui
    if not readerui or not readerui.font then
        return
    end
    
    local current_value = readerui.font.configurable[setting_name]
    local current_index = 1
    
    -- Find current index
    for i, value in ipairs(values) do
        if value == current_value then
            current_index = i
            break
        end
    end
    
    -- Cycle to next value
    local next_index = (current_index % #values) + 1
    local next_value = values[next_index]
    
    -- Apply the new setting
    if setting_name == "font_hinting" then
        readerui.font:onSetFontHinting(next_value)
    elseif setting_name == "font_kerning" then
        readerui.font:onSetFontKerning(next_value)
    elseif setting_name == "word_expansion" then
        readerui.font:onSetWordExpansion(next_value)
    end
end

-- Special function for word spacing (handles array values)
function Bluetooth:cycleWordSpacing()
    local readerui = self.ui
    if not readerui or not readerui.font then
        return
    end
    
    local spacing_values = {{75, 50}, {95, 75}, {100, 90}}
    local current_value = readerui.font.configurable.word_spacing
    local current_index = 1
    
    -- Find current index
    for i, value in ipairs(spacing_values) do
        if value[1] == current_value[1] and value[2] == current_value[2] then
            current_index = i
            break
        end
    end
    
    -- Cycle to next value
    local next_index = (current_index % #spacing_values) + 1
    local next_value = spacing_values[next_index]
    
    -- Apply the new setting
    readerui.font:onSetWordSpacing(next_value)
end

-- Helper function to adjust font weight
function Bluetooth:adjustFontWeight(delta)
    local readerui = self.ui
    if not readerui or not readerui.font then
        return
    end
    
    local current_weight = readerui.font.configurable.font_base_weight
    local new_weight = current_weight + delta
    
    -- Clamp the weight to reasonable bounds (-3 to 5.5 as per creoptions.lua)
    new_weight = math.max(-3, math.min(5.5, new_weight))
    
    -- Apply the new weight
    readerui.font:onSetFontBaseWeight(new_weight)
end

-- Helper function to adjust line spacing
function Bluetooth:adjustLineSpacing(delta)
    local readerui = self.ui
    if not readerui or not readerui.font then
        return
    end
    
    local current_spacing = readerui.font.configurable.line_spacing
    local new_spacing = current_spacing + delta
    
    -- Clamp the spacing to reasonable bounds (50 to 200 as per creoptions.lua)
    new_spacing = math.max(50, math.min(200, new_spacing))
    
    -- Apply the new spacing
    readerui.font:onSetLineSpace(new_spacing)
end

-- Bank system functions
function Bluetooth:loadBankConfig()
    local config_path = self.path .. "/" .. self.bank_config_file
    local file = io.open(config_path, "r")
    if not file then
        return
    end
    
    local content = file:read("*all")
    file:close()
    
    self.banks = {}
    local current_bank = nil
    local bank_number = 0
    
    for line in content:gmatch("[^\r\n]+") do
        line = line:gsub("^%s*", ""):gsub("%s*$", "") -- trim whitespace
        if line == "" then goto continue end
        
        if line:match("^Bank%d+$") then
            bank_number = tonumber(line:match("Bank(%d+)"))
            current_bank = {}
            self.banks[bank_number] = current_bank
        elseif line:match("^BTAction%d+:") and current_bank then
            local action_num = tonumber(line:match("BTAction(%d+)"))
            local target_event = line:match("BTAction%d+:(.+)")
            -- Remove anything after comma (comments)
            if target_event then
                target_event = target_event:match("([^,]+)") or target_event
                target_event = target_event:gsub("^%s*", ""):gsub("%s*$", "") -- trim whitespace
            end
            current_bank[action_num] = target_event
        end
        
        ::continue::
    end
    
    -- Load current bank from settings
    self.current_bank = G_reader_settings:readSetting("bluetooth_current_bank") or 1
    if not self.banks[self.current_bank] then
        self.current_bank = 1
    end
end


function Bluetooth:nextBank()
    local max_bank = 0
    for bank_num, _ in pairs(self.banks) do
        max_bank = math.max(max_bank, bank_num)
    end
    
    if max_bank > 0 then
        self.current_bank = (self.current_bank % max_bank) + 1
        G_reader_settings:saveSetting("bluetooth_current_bank", self.current_bank)
    end
end

function Bluetooth:prevBank()
    local max_bank = 0
    for bank_num, _ in pairs(self.banks) do
        max_bank = math.max(max_bank, bank_num)
    end
    
    if max_bank > 0 then
        self.current_bank = self.current_bank - 1
        if self.current_bank < 1 then
            self.current_bank = max_bank
        end
        G_reader_settings:saveSetting("bluetooth_current_bank", self.current_bank)
    end
end

function Bluetooth:executeBankAction(action_num)
    local current_bank_config = self.banks[self.current_bank]
    
    -- Log this button press for diagnostics
    local target_event = current_bank_config and current_bank_config[action_num] or nil
    self:logButtonPress("BTAction" .. action_num, nil, action_num, target_event)
    
    if not current_bank_config then return end
    if not target_event then return end
    
    -- Execute the mapped event
    if self["on" .. target_event] then
        self["on" .. target_event](self)
    end
end


function Bluetooth:init()
    -- Apply any saved auto-corrections first (before other init)
    self:applyStartupFixes()
    
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self:registerKeyEvents()
    self:loadBankConfig()
    
    -- Set input device path based on device model
    self.input_device_path, self.input_path_is_known = self:getInputDevicePath()
end

function Bluetooth:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Full Setup (WiFi + BT + Connect + Refresh)"),
                callback = function()
                    self:onFullBluetoothSetup()
                end,
            },
            {
                text = _("Wifi Up & Bluetooth On"),
                callback = function()
                    self:onWifiUpAndBluetoothOn()
                end,
            },
            {
                text = _("Bluetooth on"),
                callback = function()
                    if not self:isWifiEnabled() then
                        self:popup("Please turn on Wi-Fi to continue.")
                    else
                        self:onBluetoothOn()
                    end
                end,
            },
            {
                text = _("Bluetooth off"),
                callback = function()
                    self:onBluetoothOff()
                end,
            },
            {
                text = _("Device Management"),
                sub_item_table_func = function()
                    return self:getDeviceManagementMenu()
                end,
            },
            {
                text = _("Refresh Device Input"),
                callback = function()
                    self:onRefreshPairing()
                end,
            },
            {
                text = _("Diagnostics"),
                sub_item_table_func = function()
                    return self:getDiagnosticsMenu()
                end,
            },
        },
    }
end

function Bluetooth:getDeviceManagementMenu()
    local menu = {}
    
    -- Check actual Bluetooth state (syncs is_bluetooth_on with reality)
    local bt_on = self:isBluetoothOn()
    
    -- Show Bluetooth status at top
    table.insert(menu, {
        text = bt_on and _("🔵 Bluetooth is ON") or _("⚫ Bluetooth is OFF"),
        enabled = false,
    })
    
    -- Show current saved device
    local saved_mac, saved_name = self:getSavedDeviceMAC()
    local saved_text = saved_name and saved_mac 
        and string.format("%s (%s)", saved_name, saved_mac)
        or _("No device configured")
    
    table.insert(menu, {
        text = _("Current device: ") .. saved_text,
        keep_menu_open = true,
        callback = function()
            if saved_mac then
                self:popup(_("Saved Bluetooth device:\n\n") ..
                    _("Name: ") .. (saved_name or "Unknown") .. "\n" ..
                    _("MAC: ") .. saved_mac, 5)
            else
                self:popup(_("No Bluetooth device configured yet.\n\nUse 'Scan for devices' to find and select a device."), 5)
            end
        end,
    })
    
    -- Connect to saved device
    table.insert(menu, {
        text = _("Connect to saved device"),
        enabled_func = function() return self.is_bluetooth_on and saved_mac ~= nil end,
        callback = function()
            local success, result = self:connectToSavedDevice()
            if success then
                self:popup(_("✓ ") .. result, 3)
            else
                self:popup(_("✗ ") .. result, 5)
            end
        end,
    })
    
    -- Separator
    table.insert(menu, {
        text = "───────────────",
        enabled = false,
    })
    
    -- Start scan
    table.insert(menu, {
        text = _("Start scanning (30s)"),
        enabled_func = function() return self.is_bluetooth_on end,
        callback = function()
            self:startScan(30)
            self:popup(_("Bluetooth scanning started.\n\nScan will automatically stop after 30 seconds.\n\nDevices will appear in 'Select from scanned devices'."), 4)
        end,
    })
    
    -- Stop scan
    table.insert(menu, {
        text = _("Stop scanning"),
        enabled_func = function() return self.is_bluetooth_on end,
        callback = function()
            self:stopScan()
            self:popup(_("Bluetooth scanning stopped."), 2)
        end,
    })
    
    -- Select from scanned devices
    table.insert(menu, {
        text = _("Select from scanned devices"),
        enabled_func = function() return self.is_bluetooth_on end,
        sub_item_table_func = function()
            return self:getScannedDevicesMenu()
        end,
    })
    
    -- Select from paired devices  
    table.insert(menu, {
        text = _("Select from paired devices"),
        enabled_func = function() return self.is_bluetooth_on end,
        sub_item_table_func = function()
            return self:getPairedDevicesMenu()
        end,
    })
    
    return menu
end

function Bluetooth:getScannedDevicesMenu()
    local devices = self:getScannedDevices()
    local menu = {}
    
    if #devices == 0 then
        table.insert(menu, {
            text = _("No devices found. Start scanning first."),
            enabled = false,
        })
        -- Debug option to see raw output
        table.insert(menu, {
            text = _("(Debug: Show raw output)"),
            callback = function()
                -- Try direct command without timeout wrapper
                local handle = io.popen("bluetoothctl devices 2>&1")
                local raw = ""
                if handle then
                    raw = handle:read("*a") or ""
                    handle:close()
                end
                self:popup(_("Raw bluetoothctl output:\n\n") .. (raw == "" and "(empty)" or raw), 10)
            end,
        })
    else
        for _, device in ipairs(devices) do
            table.insert(menu, {
                text = string.format("%s (%s)", device.name, device.mac),
                callback = function()
                    self:onSelectDevice(device.mac, device.name)
                end,
            })
        end
    end
    
    return menu
end

function Bluetooth:getPairedDevicesMenu()
    local devices = self:getPairedDevices()
    local menu = {}
    
    if #devices == 0 then
        table.insert(menu, {
            text = _("No paired devices found."),
            enabled = false,
        })
    else
        for _, device in ipairs(devices) do
            table.insert(menu, {
                text = string.format("%s (%s)", device.name, device.mac),
                callback = function()
                    self:onSelectDevice(device.mac, device.name)
                end,
            })
        end
    end
    
    return menu
end

function Bluetooth:onSelectDevice(mac, name)
    -- Save the selected device
    local success = self:saveDeviceMAC(mac, name)
    if success then
        self:popup(_("✓ Device saved!\n\n") ..
            _("Name: ") .. name .. "\n" ..
            _("MAC: ") .. mac .. "\n\n" ..
            _("Use 'Connect to saved device' to connect."), 5)
    else
        self:popup(_("✗ Failed to save device configuration."), 5)
    end
end

-- Supported device models (codename -> friendly name)
Bluetooth.supported_devices = {
    ["Kobo_io"] = "Kobo Libra 2",
    ["Kobo_goldfinch"] = "Kobo Clara 2E",
}

function Bluetooth:getDeviceInfo()
    -- Gather device information for diagnostics
    local info = {
        model = Device.model or "unknown",
        isKobo = Device:isKobo() and true or false,
        isEmulator = Device:isEmulator() and true or false,
        isSDL = Device:isSDL() and true or false,
    }
    return info
end

function Bluetooth:checkDeviceType()
    local info = self:getDeviceInfo()
    
    -- Check if device is a Kobo
    if not info.isKobo then
        return false, nil, info
    end
    
    -- Check if it's a supported model
    local friendly_name = self.supported_devices[info.model]
    
    if friendly_name then
        return true, friendly_name, info
    else
        return false, nil, info
    end
end

function Bluetooth:getActualKoreaderPath()
    -- Get the actual KOReader installation path using DataStorage
    return DataStorage:getFullDataDir()
end

function Bluetooth:findHighestEventPath()
    -- Find the highest eventX in /dev/input/
    local input_dir = "/dev/input"
    local highest_num = -1
    local highest_path = nil
    
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, dir_obj = pcall(lfs.dir, input_dir)
    if not ok then
        return nil
    end
    
    for entry in iter, dir_obj do
        local event_num = entry:match("^event(%d+)$")
        if event_num then
            local num = tonumber(event_num)
            if num and num > highest_num then
                highest_num = num
                highest_path = input_dir .. "/" .. entry
            end
        end
    end
    
    return highest_path
end

function Bluetooth:getInputDevicePath()
    -- Determine the correct input device path based on device model
    local model = Device.model
    local path = self.device_input_paths[model]
    if path then
        return path, true  -- known path
    end
    
    -- Try to find the highest event number as best guess
    local guessed_path = self:findHighestEventPath()
    if guessed_path then
        return guessed_path, false  -- guessed path
    end
    
    return self.default_input_path, false  -- fallback
end

function Bluetooth:detectBluetoothBinaries()
    -- Check which Bluetooth binaries exist in /sbin
    local lfs = require("libs/libkoreader-lfs")
    local binaries_found = {}
    
    -- Check for rtk_hciattach (Realtek chip, used by Libra 2)
    local rtk_attr = lfs.attributes("/sbin/rtk_hciattach")
    if rtk_attr then
        table.insert(binaries_found, "rtk_hciattach")
    end
    
    -- Check for hciattach (standard, used by Clara 2E)
    local hci_attr = lfs.attributes("/sbin/hciattach")
    if hci_attr then
        table.insert(binaries_found, "hciattach")
    end
    
    return binaries_found
end

function Bluetooth:getBluetoothConfig()
    -- Get device-specific Bluetooth configuration
    -- Priority: 1) Known device model, 2) Binary detection, 3) Default
    local model = Device.model
    
    -- First try: known device model
    local config = self.device_bt_configs[model]
    if config then
        return config, "known_device", model
    end
    
    -- Second try: detect by checking which binaries exist in /sbin
    local binaries = self:detectBluetoothBinaries()
    
    -- Prefer rtk_hciattach if found (Libra 2 style)
    for _, binary in ipairs(binaries) do
        if binary == "rtk_hciattach" then
            local detected_config = self.binary_to_config["rtk_hciattach"]
            return detected_config, "binary_detected", "rtk_hciattach"
        end
    end
    
    -- Fall back to hciattach if found (Clara 2E style)
    for _, binary in ipairs(binaries) do
        if binary == "hciattach" then
            local detected_config = self.binary_to_config["hciattach"]
            return detected_config, "binary_detected", "hciattach"
        end
    end
    
    -- Last resort: default config
    return self.default_bt_config, "default", nil
end

function Bluetooth:getDiagnosticsMenu()
    local diagnostics = {}
    
    -- Check Bluetooth status first (actual system check)
    local bt_on = self:isBluetoothOn()
    local bt_icon = bt_on and "🔵 " or "⚫ "
    
    table.insert(diagnostics, {
        text = bt_icon .. (bt_on and _("Bluetooth is ON") or _("Bluetooth is OFF")),
        callback = function()
            -- Re-check when clicked
            local is_on = self:isBluetoothOn()
            local hci_output = self:executeCommand("hciconfig hci0 2>&1")
            self:popup((is_on and _("✓ Bluetooth is currently ON\n\n") or _("✗ Bluetooth is currently OFF\n\n")) ..
                _("HCI interface status:\n") .. (hci_output or "(no output)"), 10)
        end,
    })
    
    -- Separator
    table.insert(diagnostics, {
        text = "─── " .. _("Configuration Checks") .. " ───",
        enabled = false,
    })
    
    -- Info 1: Installation path (auto-detected, always correct)
    local actual_path = self:getActualKoreaderPath()
    
    table.insert(diagnostics, {
        text = "ℹ " .. _("KOReader installation path"),
        callback = function()
            self:popup(_("KOReader installation path (auto-detected):\n\n") .. (actual_path or "unknown") .. "\n\n" .. _("This path is used for WiFi scripts."), 5)
        end,
    })
    
    -- Check 2: Device type
    local device_ok, friendly_name, device_info = self:checkDeviceType()
    local device_icon = device_ok and "✓ " or "✗ "
    
    table.insert(diagnostics, {
        text = device_icon .. _("Device type"),
        callback = function()
            -- Build device info string for display
            local info_str = _("Detected device info:\n") ..
                _("  Model: ") .. device_info.model .. "\n" ..
                _("  isKobo: ") .. tostring(device_info.isKobo) .. "\n" ..
                _("  isEmulator: ") .. tostring(device_info.isEmulator) .. "\n" ..
                _("  isSDL: ") .. tostring(device_info.isSDL)
            
            if device_ok then
                self:popup(_("✓ Supported device detected:\n") .. friendly_name .. "\n(" .. device_info.model .. ")\n\n" .. info_str, 7)
            else
                local msg
                if not device_info.isKobo then
                    msg = _("✗ This is not a Kobo device!\n\n") ..
                        info_str .. "\n\n" ..
                        _("This plugin only supports Kobo devices.\n\n") ..
                        _("Supported devices:\n") ..
                        _("• Kobo Libra 2\n") ..
                        _("• Kobo Clara 2E")
                else
                    msg = _("✗ Unsupported Kobo model!\n\n") ..
                        info_str .. "\n\n" ..
                        _("Supported devices:\n") ..
                        _("• Kobo Libra 2 (Kobo_io)\n") ..
                        _("• Kobo Clara 2E (Kobo_goldfinch)\n\n") ..
                        _("Corrective action:\n") ..
                        _("This plugin may still work if your device has compatible Bluetooth hardware. Check the 'Bluetooth commands' diagnostic to see if binaries were auto-detected.")
                end
                self:popup(msg, 10)
            end
        end,
    })
    
    -- Check 3: hasKeys flag
    local has_keys = Device:hasKeys() and true or false
    local keys_icon = has_keys and "✓ " or "✗ "
    
    table.insert(diagnostics, {
        text = keys_icon .. _("hasKeys flag"),
        callback = function()
            -- Re-check in case it changed
            local current_has_keys = Device:hasKeys() and true or false
            
            if current_has_keys then
                self:popup(_("✓ hasKeys is enabled.\n\nYour device is configured to accept key input from external devices."), 5)
            else
                local msg = _("✗ hasKeys is NOT enabled!\n\n") ..
                    _("This is required for Bluetooth input devices to work.\n\n") ..
                    _("This can be corrected automatically. The fix will be applied immediately and remembered for future sessions.")
                
                UIManager:show(ConfirmBox:new{
                    text = msg,
                    ok_text = _("Correct Automatically"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local success, result = self:autoCorrectHasKeys()
                        if success then
                            self:popup(_("✓ ") .. result, 5)
                        else
                            self:popup(_("✗ Auto-correction failed:\n") .. result, 7)
                        end
                    end,
                })
            end
        end,
    })
    
    -- Check 4: Input device path
    local model = Device.model or "unknown"
    local current_path = self.input_device_path
    local path_is_known = self.input_path_is_known
    local path_icon = path_is_known and "✓ " or "⚠ "
    
    table.insert(diagnostics, {
        text = path_icon .. _("Input device path"),
        callback = function()
            if path_is_known then
                self:popup(_("✓ Input device path is configured for your device.\n\n") ..
                    _("Model: ") .. model .. "\n" ..
                    _("Path: ") .. current_path, 5)
            else
                local msg = _("⚠ Input device path is auto-detected!\n\n") ..
                    _("Model: ") .. model .. "\n" ..
                    _("Path: ") .. current_path .. _(" (highest event found)\n\n") ..
                    _("Your device model is not in the known device list. ") ..
                    _("The system detected the highest /dev/input/eventX as a best guess.\n\n") ..
                    _("If Bluetooth input doesn't work, try editing the plugin to add your device to device_input_paths with the correct event path.")
                self:popup(msg, 10)
            end
        end,
    })
    
    -- Check 5: Bluetooth configuration
    local bt_config, bt_detection_type, bt_detection_info = self:getBluetoothConfig()
    local bt_icon
    if bt_detection_type == "known_device" then
        bt_icon = "✓ "
    elseif bt_detection_type == "binary_detected" then
        bt_icon = "ℹ "  -- Info: auto-detected but should work
    else
        bt_icon = "⚠ "  -- Warning: using defaults
    end
    
    table.insert(diagnostics, {
        text = bt_icon .. _("Bluetooth commands"),
        callback = function()
            local model = Device.model or "unknown"
            local binaries = self:detectBluetoothBinaries()
            local binaries_str = #binaries > 0 and table.concat(binaries, ", ") or "none found"
            
            if bt_detection_type == "known_device" then
                self:popup(_("✓ Bluetooth commands configured for your device.\n\n") ..
                    _("Device: ") .. bt_config.name .. "\n" ..
                    _("Model: ") .. model .. "\n\n" ..
                    _("HCI attach: ") .. bt_config.hci_attach .. "\n\n" ..
                    _("HCI kill: ") .. bt_config.hci_kill .. "\n\n" ..
                    _("Binaries in /sbin: ") .. binaries_str, 10)
            elseif bt_detection_type == "binary_detected" then
                self:popup(_("ℹ Bluetooth commands auto-detected!\n\n") ..
                    _("Detection: ") .. (bt_config.detection_method or bt_detection_info) .. "\n" ..
                    _("Config: ") .. bt_config.name .. "\n" ..
                    _("Model: ") .. model .. "\n\n" ..
                    _("HCI attach: ") .. bt_config.hci_attach .. "\n\n" ..
                    _("HCI kill: ") .. bt_config.hci_kill .. "\n\n" ..
                    _("Binaries in /sbin: ") .. binaries_str .. "\n\n" ..
                    _("Your device model is unknown, but the plugin detected which Bluetooth binaries exist and will use the appropriate commands."), 12)
            else
                local msg = _("⚠ Using default Bluetooth commands!\n\n") ..
                    _("Model: ") .. model .. "\n" ..
                    _("Config: ") .. bt_config.name .. _(" (fallback)\n\n") ..
                    _("HCI attach: ") .. bt_config.hci_attach .. "\n\n" ..
                    _("Binaries in /sbin: ") .. binaries_str .. "\n\n" ..
                    _("No known Bluetooth binaries found in /sbin. Using default commands (Clara 2E style).\n\n") ..
                    _("If Bluetooth doesn't work, you may need to add your device to device_bt_configs in the plugin.")
                self:popup(msg, 12)
            end
        end,
    })
    
    -- Check 6: Event map entries (any BT* events)
    local event_map_ok, bt_events_found, event_map_error = self:checkEventMapEntries()
    local event_map_icon = event_map_ok and "✓ " or "✗ "
    
    table.insert(diagnostics, {
        text = event_map_icon .. _("Event map (BT events)"),
        callback = function()
            -- Re-check in case it changed
            local ok, found, err = self:checkEventMapEntries()
            
            if err then
                self:popup(_("✗ Error checking event map:\n\n") .. err, 5)
            elseif ok then
                self:popup(_("✓ Event map has BT event entries.\n\n") ..
                    _("Found ") .. #found .. _(" BT mappings:\n") ..
                    table.concat(found, ", "), 7)
            else
                local msg = _("✗ Event map has no BT event entries!\n\n") ..
                    _("Bluetooth button presses won't be recognized without BT event mappings.\n\n") ..
                    _("This can be corrected automatically by creating a custom event_map.lua file with default BTAction mappings.")
                
                -- Show ConfirmBox with auto-correct option
                UIManager:show(ConfirmBox:new{
                    text = msg,
                    ok_text = _("Correct Automatically"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local success, result = self:autoCorrectEventMap()
                        if success then
                            self:popup(_("✓ ") .. result, 7)
                        else
                            self:popup(_("✗ Auto-correction failed:\n") .. result, 7)
                        end
                    end,
                })
            end
        end,
    })
    
    -- Check 7: Bank configuration (BTAction indirections)
    local bank_config_ok, bank_count, total_mappings = self:checkBankConfig()
    local bank_icon = bank_config_ok and "✓ " or "⚠ "
    
    table.insert(diagnostics, {
        text = bank_icon .. _("Bank configuration"),
        callback = function()
            local ok, num_banks, num_mappings, details = self:checkBankConfigDetails()
            if ok then
                local msg = _("✓ Bank configuration loaded.\n\n") ..
                    _("Banks defined: ") .. num_banks .. "\n" ..
                    _("Total mappings: ") .. num_mappings .. "\n" ..
                    _("Current bank: ") .. self.current_bank .. "\n\n" ..
                    details
                self:popup(msg, 15)
            else
                self:popup(_("⚠ Bank configuration issue!\n\n") .. details, 10)
            end
        end,
    })
    
    -- Check 8: Saved Bluetooth device
    local saved_mac, saved_name = self:getSavedDeviceMAC()
    local device_saved = saved_mac ~= nil
    local saved_icon = device_saved and "✓ " or "✗ "
    
    table.insert(diagnostics, {
        text = saved_icon .. _("Saved Bluetooth device"),
        callback = function()
            local mac, name = self:getSavedDeviceMAC()
            if mac then
                self:popup(_("✓ Bluetooth device is configured.\n\n") ..
                    _("Name: ") .. (name or "Unknown") .. "\n" ..
                    _("MAC: ") .. mac, 5)
            else
                self:popup(_("✗ No Bluetooth device configured!\n\n") ..
                    _("Go to Bluetooth > Device Management to scan for and select a device."), 5)
            end
        end,
    })
    
    -- Separator before debug tools
    table.insert(diagnostics, {
        text = "─── " .. _("Debug Tools") .. " ───",
        enabled = false,
    })
    
    -- Button press history viewer
    local history_count = #self.button_press_history
    table.insert(diagnostics, {
        text = "🔍 " .. _("Button press history") .. " (" .. history_count .. ")",
        callback = function()
            local history = self:getButtonPressHistory()
            if #history == 0 then
                self:popup(_("No button presses recorded yet.\n\n") ..
                    _("Press some buttons on your Bluetooth controller and check back here."), 5)
            else
                local lines = {}
                for i, entry in ipairs(history) do
                    local code_str = entry.key_code and string.format("code %d", entry.key_code) or "code ?"
                    local line = string.format("%d. [%s] %s (%s)", 
                        i, entry.timestamp, entry.event_name, code_str)
                    if entry.target_event then
                        line = line .. "\n   → " .. entry.target_event .. " [Bank " .. (entry.bank or "?") .. "]"
                    else
                        line = line .. "\n   → (no mapping)"
                    end
                    table.insert(lines, line)
                end
                self:popup(_("Last ") .. #history .. _(" button presses:\n\n") .. table.concat(lines, "\n"), 20)
            end
        end,
    })
    
    -- Clear button press history
    table.insert(diagnostics, {
        text = "🗑 " .. _("Clear button history"),
        callback = function()
            self:clearButtonPressHistory()
            self:popup(_("Button press history cleared."), 2)
        end,
    })
    
    -- Raw input device monitor (reads actual key codes from device)
    table.insert(diagnostics, {
        text = "📡 " .. _("Monitor raw input (5 sec)"),
        callback = function()
            self:popup(_("Reading raw input from:\n") .. self.input_device_path .. _("\n\nPress buttons on your controller now..."), 2)
            
            -- Schedule the actual read after popup closes
            UIManager:scheduleIn(0.5, function()
                local raw_events = self:readRawInputEvents(5)
                if #raw_events == 0 then
                    self:popup(_("No input events detected in 5 seconds.\n\n") ..
                        _("Make sure:\n") ..
                        _("• Bluetooth is on\n") ..
                        _("• Controller is connected\n") ..
                        _("• Input device path is correct: ") .. self.input_device_path, 7)
                else
                    local lines = {}
                    for _, evt in ipairs(raw_events) do
                        table.insert(lines, string.format("Code: %d, Value: %d, Type: %d", 
                            evt.code, evt.value, evt.type))
                    end
                    self:popup(_("Raw input events captured:\n\n") .. table.concat(lines, "\n"), 10)
                end
            end)
        end,
    })
    
    return diagnostics
end

function Bluetooth:checkBankConfig()
    -- Quick check: do we have banks loaded with mappings?
    if not self.banks or next(self.banks) == nil then
        return false, 0, 0
    end
    
    local bank_count = 0
    local total_mappings = 0
    
    for bank_num, bank in pairs(self.banks) do
        bank_count = bank_count + 1
        for action_num, target in pairs(bank) do
            total_mappings = total_mappings + 1
        end
    end
    
    return bank_count > 0 and total_mappings > 0, bank_count, total_mappings
end

function Bluetooth:checkBankConfigDetails()
    -- Detailed check with per-bank breakdown
    local config_path = self.path .. "/" .. self.bank_config_file
    
    -- Check if file exists
    local file = io.open(config_path, "r")
    if not file then
        return false, 0, 0, _("bank_config.txt not found at:\n") .. config_path
    end
    file:close()
    
    if not self.banks or next(self.banks) == nil then
        return false, 0, 0, _("No banks loaded. Check bank_config.txt format.")
    end
    
    local bank_count = 0
    local total_mappings = 0
    local details_lines = {}
    
    -- Get sorted bank numbers
    local bank_nums = {}
    for bank_num, _ in pairs(self.banks) do
        table.insert(bank_nums, bank_num)
    end
    table.sort(bank_nums)
    
    for _, bank_num in ipairs(bank_nums) do
        local bank = self.banks[bank_num]
        bank_count = bank_count + 1
        local mapping_count = 0
        local action_nums = {}
        
        for action_num, target in pairs(bank) do
            mapping_count = mapping_count + 1
            total_mappings = total_mappings + 1
            table.insert(action_nums, action_num)
        end
        table.sort(action_nums)
        
        -- Build action list string
        local actions_str = ""
        for _, num in ipairs(action_nums) do
            if actions_str ~= "" then actions_str = actions_str .. "," end
            actions_str = actions_str .. num
        end
        
        local bank_marker = bank_num == self.current_bank and " ← current" or ""
        table.insert(details_lines, string.format("Bank %d: %d mappings (BTAction %s)%s", 
            bank_num, mapping_count, actions_str, bank_marker))
    end
    
    -- Check for unmapped BTActions in event_map
    local event_map = Device.input and Device.input.event_map
    local unmapped_actions = {}
    if event_map then
        for code, event_name in pairs(event_map) do
            if type(event_name) == "string" and event_name:match("^BTAction(%d+)$") then
                local action_num = tonumber(event_name:match("BTAction(%d+)"))
                -- Check if this action is defined in current bank
                local current_bank_config = self.banks[self.current_bank]
                if current_bank_config and not current_bank_config[action_num] then
                    table.insert(unmapped_actions, string.format("%s (code %d)", event_name, code))
                end
            end
        end
    end
    
    if #unmapped_actions > 0 then
        table.insert(details_lines, "")
        table.insert(details_lines, _("⚠ BTActions in event_map but NOT in current bank:"))
        for _, action in ipairs(unmapped_actions) do
            table.insert(details_lines, "  • " .. action)
        end
    end
    
    return true, bank_count, total_mappings, table.concat(details_lines, "\n")
end

function Bluetooth:checkEventMapEntries()
    -- Check if Device.input.event_map contains any BT* entries (BTAction, BTRemote, etc.)
    local found = {}
    
    local event_map = Device.input and Device.input.event_map
    if not event_map then
        -- No event_map available
        return false, {}, "event_map not accessible"
    end
    
    -- Scan event_map for all BT* entries (any event starting with "BT")
    for key, value in pairs(event_map) do
        if type(value) == "string" and value:match("^BT") then
            table.insert(found, value)
        end
    end
    
    -- Sort found for display
    table.sort(found)
    
    -- OK if we have at least one BT entry
    local ok = #found > 0
    return ok, found, nil
end

function Bluetooth:getCustomEventMapPath()
    return DataStorage:getSettingsDir() .. "/event_map.lua"
end

function Bluetooth:writeCustomEventMap()
    -- Write the default BTAction mappings to settings/event_map.lua
    local path = self:getCustomEventMapPath()
    local file = io.open(path, "w")
    if not file then
        return false, "Could not open file for writing: " .. path
    end
    
    -- Write the Lua table
    file:write("-- Custom event map for Bluetooth plugin (8BitDo controller)\n")
    file:write("-- Auto-generated by bluetooth.koplugin\n")
    file:write("-- This file is loaded by KOReader on startup\n\n")
    file:write("return {\n")
    
    -- Sort keys for consistent output
    local keys = {}
    for k, _ in pairs(self.default_event_mappings) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    for _, key in ipairs(keys) do
        local value = self.default_event_mappings[key]
        file:write(string.format("    [%d] = \"%s\",\n", key, value))
    end
    
    file:write("}\n")
    file:close()
    
    return true, path
end

function Bluetooth:injectEventMappings()
    -- Inject BTAction mappings into Device.input.event_map at runtime
    local event_map = Device.input and Device.input.event_map
    if not event_map then
        return false, "event_map not accessible"
    end
    
    local count = 0
    for key, value in pairs(self.default_event_mappings) do
        event_map[key] = value
        count = count + 1
    end
    
    return true, count
end

function Bluetooth:autoCorrectEventMap()
    -- Step 1: Write the custom event_map.lua file (persists across restarts)
    local write_ok, write_result = self:writeCustomEventMap()
    if not write_ok then
        return false, write_result
    end
    
    -- Step 2: Inject mappings into current session (immediate effect)
    local inject_ok, inject_result = self:injectEventMappings()
    if not inject_ok then
        return true, "File written to " .. write_result .. " but runtime injection failed: " .. inject_result .. "\n\nPlease restart KOReader for changes to take effect."
    end
    
    return true, "Event mappings configured!\n\nFile: " .. write_result .. "\nMappings injected: " .. inject_result .. "\n\nBluetooth buttons should work immediately."
end

function Bluetooth:enableHasKeys()
    -- Override Device.hasKeys to return true
    Device.hasKeys = function() return true end
    return true
end

function Bluetooth:getHasKeysPatchPath()
    return DataStorage:getDataDir() .. "/patches/1-bluetooth-haskeys.lua"
end

function Bluetooth:writeHasKeysPatch()
    -- Create the patches directory if it doesn't exist
    local patches_dir = DataStorage:getDataDir() .. "/patches"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(patches_dir, "mode") ~= "directory" then
        lfs.mkdir(patches_dir)
    end
    
    -- Write the patch file
    local patch_path = self:getHasKeysPatchPath()
    local file = io.open(patch_path, "w")
    if not file then
        return false, "Could not create patch file: " .. patch_path
    end
    
    file:write([[-- Auto-generated by bluetooth.koplugin
-- This patch enables hasKeys for Bluetooth controller support
-- It runs early during boot, before Device is initialized

local Device = require("device")

-- Store original hasKeys function
local orig_hasKeys = Device.hasKeys

-- Override to always return true (for Bluetooth controller support)
Device.hasKeys = function() return true end
]])
    file:close()
    
    return true, patch_path
end

function Bluetooth:hasKeysPatchExists()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(self:getHasKeysPatchPath(), "mode") == "file"
end

function Bluetooth:autoCorrectHasKeys()
    -- Step 1: Enable hasKeys at runtime (immediate effect for this session)
    self:enableHasKeys()
    
    -- Step 2: Create user patch for early boot (persists across restarts)
    local write_ok, write_result = self:writeHasKeysPatch()
    if not write_ok then
        return false, "Runtime fix applied, but patch file creation failed:\n" .. write_result .. "\n\nRestart may be needed."
    end
    
    return true, "hasKeys is now enabled!\n\nPatch file created:\n" .. write_result .. "\n\nThis will apply early on boot, before Device initialization."
end

function Bluetooth:applyStartupFixes()
    -- Apply any saved auto-corrections on startup
    -- Note: The user patch runs even earlier (before Device init),
    -- but this provides a fallback for the current session
    
    -- Check if the patch exists but hasn't taken effect yet (first run after creating patch)
    if self:hasKeysPatchExists() and not Device:hasKeys() then
        self:enableHasKeys()
    end
end

function Bluetooth:getScriptPath(script)
    return script
end

function Bluetooth:executeScript(script)
    local command = "/bin/sh " .. self.path .. "/" .. script
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()
    return result
end

function Bluetooth:executeCommand(cmd)
    local handle = io.popen(cmd .. " 2>&1")
    local result = handle:read("*a")
    handle:close()
    return result
end

function Bluetooth:turnOnBluetoothCommands()
    -- Get device-specific Bluetooth config
    local bt_config, _ = self:getBluetoothConfig()
    local plugin_path = self.path
    local results = {}
    
    -- Step 1: Load Bluetooth power module
    table.insert(results, self:executeCommand("insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko"))
    
    -- Step 2: Load UHID module (from plugin directory)
    table.insert(results, self:executeCommand("insmod " .. plugin_path .. "/uhid/uhid.ko"))
    
    -- Step 3: Attach HCI (device-specific command)
    table.insert(results, self:executeCommand(bt_config.hci_attach))
    
    -- Step 4: Initialize D-Bus/BlueZ
    table.insert(results, self:executeCommand("dbus-send --system --dest=org.bluez --print-reply / org.freedesktop.DBus.ObjectManager.GetManagedObjects"))
    
    -- Step 5: Bring up HCI interface
    table.insert(results, self:executeCommand("hciconfig hci0 up"))
    
    return table.concat(results, "\n")
end

function Bluetooth:onBluetoothOn()
    local bt_config, detection_type, detection_info = self:getBluetoothConfig()
    local result = self:turnOnBluetoothCommands()

    -- Check if hci0 is up as success indicator (also updates cache)
    if self:isBluetoothOn() then
        local config_note = ""
        if detection_type == "binary_detected" then
            config_note = _("\n(Auto-detected: ") .. (detection_info or "unknown") .. ")"
        elseif detection_type == "default" then
            config_note = _("\n(Using default config)")
        end
        self:popup(_("Bluetooth turned on.") .. config_note)
    else
        self:popup(_("Bluetooth may not have started correctly.\n\nDetails:\n") .. result)
    end
end

function Bluetooth:onBluetoothOff()
    self:turnOffBluetooth()
    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:turnOffBluetooth()
    -- Get device-specific Bluetooth config
    local bt_config, _ = self:getBluetoothConfig()
    local plugin_path = self.path
    
    -- Step 1: Bring down HCI interface
    self:executeCommand("hciconfig hci0 down")
    
    -- Step 2: Kill HCI attach process (device-specific)
    self:executeCommand(bt_config.hci_kill)
    
    -- Step 3: Kill bluetoothd
    self:executeCommand("pkill bluetoothd")
    
    -- Step 4: Unload Bluetooth power module
    self:executeCommand("rmmod -w /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko")
    
    -- Step 5: Unload UHID module
    self:executeCommand("rmmod -w " .. plugin_path .. "/uhid/uhid.ko")
    -- Note: is_bluetooth_on cache will be updated on next isBluetoothOn() call
end

function Bluetooth:onRefreshPairing()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end

    local status, err = pcall(function()
        -- Ensure the device path is valid
        if not self.input_device_path or self.input_device_path == "" then
            error("Invalid device path")
        end

        Device.input:close(self.input_device_path) -- Close the input using the high-level parameter
        Device.input:open(self.input_device_path)  -- Reopen the input using the high-level parameter
        self:popup(_("Bluetooth device at ") .. self.input_device_path .. " is now open.")
    end)

    if not status then
        self:popup(_("Error: ") .. err)
    end
end

function Bluetooth:onConnectToDevice()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end

    -- Use saved device MAC address from config
    local success, result = self:connectToSavedDevice()
    
    if success then
        self:popup(_("✓ ") .. result)
    else
        self:popup(_("✗ ") .. result)
    end
end


function Bluetooth:debugPopup(msg)
    self:popup(_("DEBUG: ") .. msg)
end

function Bluetooth:popup(text, timeout)
    timeout = timeout or 2  -- Default 2 seconds
    local popup = InfoMessage:new{
        text = text,
    }
    UIManager:show(popup)
    -- Auto-dismiss after timeout
    UIManager:scheduleIn(timeout, function()
        UIManager:close(popup)
    end)
end

function Bluetooth:isWifiEnabled()
    local handle = io.popen("iwconfig")
    local result = handle:read("*a")
    handle:close()

    -- Check if Wi-Fi is enabled by looking for 'ESSID'
    return result:match("ESSID") ~= nil
end

function Bluetooth:enableWifi()
    -- Use dynamically detected KOReader path
    local koreader_path = self:getActualKoreaderPath()
    local enable_wifi_script = koreader_path .. "/enable-wifi.sh"
    
    -- Check if script exists
    local file = io.open(enable_wifi_script, "r")
    if not file then
        return false, "Could not find enable-wifi.sh at " .. enable_wifi_script
    end
    file:close()
    
    -- Execute the script from its directory
    local command = string.format("sh -c 'cd %s && ./enable-wifi.sh'", koreader_path)
    
    local result = os.execute(command)
    if result == 0 then
        return true, "WiFi enabled successfully"
    else
        return false, "Failed to enable WiFi (exit code: " .. tostring(result) .. ")"
    end
end

function Bluetooth:disableWifi()
    -- Use dynamically detected KOReader path
    local koreader_path = self:getActualKoreaderPath()
    local disable_wifi_script = koreader_path .. "/disable-wifi.sh"
    
    -- Check if script exists
    local file = io.open(disable_wifi_script, "r")
    if not file then
        return false, "Could not find disable-wifi.sh at " .. disable_wifi_script
    end
    file:close()
    
    -- Execute the script from its directory
    local command = string.format("sh -c 'cd %s && ./disable-wifi.sh'", koreader_path)
    
    local result = os.execute(command)
    if result == 0 then
        return true, "WiFi disabled successfully"
    else
        return false, "Failed to disable WiFi (exit code: " .. tostring(result) .. ")"
    end
end

function Bluetooth:onWifiUpAndBluetoothOn()
    -- First enable WiFi
    local success, message = self:enableWifi()
    if not success then
        self:popup(_("Failed to enable WiFi: ") .. message)
        return
    end
    
    -- Wait a moment for WiFi to initialize
    UIManager:scheduleIn(1, function()
        -- Now turn on Bluetooth
        self:onBluetoothOn()
    end)
    
    self:popup(_("WiFi enabled. Turning on Bluetooth..."))
end

function Bluetooth:onFullBluetoothSetup()
    -- Check if we have a saved device
    local saved_mac, saved_name = self:getSavedDeviceMAC()
    if not saved_mac then
        self:popup(_("No Bluetooth device configured!\n\nPlease go to Device Management and select a device first."), 5)
        return
    end
    
    -- Step 1: Enable WiFi
    self:popup(_("Step 1: Enabling WiFi..."), 4)
    local success, message = self:enableWifi()
    if not success then
        self:popup(_("Failed to enable WiFi: ") .. message, 4)
        return
    end
    
    -- Wait a bit, then show completion and move to next step
    UIManager:scheduleIn(1, function()
        self:popup(_("✓ WiFi enabled"), 2)
        
        -- Step 2: Enable Bluetooth
        UIManager:scheduleIn(1, function()
            self:popup(_("Step 2: Turning on Bluetooth..."), 4)
            local result = self:turnOnBluetoothCommands()
            
            -- Check if hci0 is up as success indicator (also updates cache)
            if not self:isBluetoothOn() then
                self:popup(_("Bluetooth error: ") .. result, 4)
                return
            end
            
            -- Wait a bit, then show completion and move to next step
            UIManager:scheduleIn(1, function()
                self:popup(_("✓ Bluetooth enabled"), 2)
                
                -- Step 3: Connect to device
                UIManager:scheduleIn(1, function()
                    self:popup(_("Step 3: Connecting to ") .. (saved_name or saved_mac) .. "...", 4)
                    local connect_success, connect_result = self:connectToSavedDevice()
                    
                    if not connect_success then
                        self:popup(_("Connection failed: ") .. connect_result, 4)
                        -- Continue anyway to try refreshing input
                    end
                    
                    -- Wait a bit, then show completion and move to next step
                    UIManager:scheduleIn(1, function()
                        self:popup(connect_success and _("✓ Device connected") or _("⚠ Connection may have failed"), 2)
                        
                        -- Step 4: Refresh device input
                        UIManager:scheduleIn(1, function()
                            self:popup(_("Step 4: Refreshing device input..."), 4)
                            local status, err = pcall(function()
                                if not self.input_device_path or self.input_device_path == "" then
                                    error("Invalid device path")
                                end
                                Device.input:close(self.input_device_path)
                                Device.input:open(self.input_device_path)
                            end)
                            
                            if status then
                                UIManager:scheduleIn(1, function()
                                    self:popup(_("✓ Device input refreshed"), 2)
                                    
                                    -- Step 5: Disable WiFi
                                    UIManager:scheduleIn(1, function()
                                        self:popup(_("Step 5: Disabling WiFi..."), 4)
                                        local wifi_success, wifi_message = self:disableWifi()
                                        
                                        if wifi_success then
                                            UIManager:scheduleIn(1, function()
                                                self:popup(_("✓ All done! Bluetooth ready, WiFi disabled."), 4)
                                            end)
                                        else
                                            self:popup(_("WiFi disable warning: ") .. wifi_message, 4)
                                            -- Still show success since Bluetooth is working
                                            UIManager:scheduleIn(1, function()
                                                self:popup(_("✓ Bluetooth ready (WiFi may still be on)"), 4)
                                            end)
                                        end
                                    end)
                                end)
                            else
                                self:popup(_("Error refreshing input: ") .. err, 4)
                            end
                        end)
                    end)
                end)
            end)
        end)
    end)
end


return Bluetooth
