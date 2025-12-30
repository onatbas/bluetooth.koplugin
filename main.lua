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
    _watching = false,
    _watch_path = nil,
    _watch_inode = nil,
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
    ["Kobo_goldfinch"] = {  -- Clara 2E (i.MX6)
        name = "Clara 2E",
        driver_path = "/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko",
        hci_attach = "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20",
        hci_kill = "pkill hciattach",
    },
    ["Kobo_io"] = {  -- Libra 2 (i.MX6)
        name = "Libra 2",
        driver_path = "/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko",
        hci_attach = "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5",
        hci_kill = "pkill rtk_hciattach",
    },
}
-- Default driver path (i.MX6 style)
Bluetooth.default_driver_path = "/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko"

-- Default config (uses Clara 2E style as fallback)
Bluetooth.default_bt_config = {
    name = "Default",
    driver_path = nil,  -- Will be auto-detected
    hci_attach = "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20",
    hci_kill = "pkill hciattach",
}

-- Binary-based detection: map binary names to config profiles
-- Used when device model is unknown but we can detect which binaries exist
Bluetooth.binary_to_config = {
    ["rtk_hciattach"] = {  -- Libra 2 style (Realtek chip)
        name = "Auto-detected (Realtek/Libra 2 style)",
        driver_path = nil,  -- Will be auto-detected
        hci_attach = "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5",
        hci_kill = "pkill rtk_hciattach",
        detection_method = "rtk_hciattach binary found in /sbin",
    },
    ["hciattach"] = {  -- Clara 2E style (standard)
        name = "Auto-detected (Standard/Clara 2E style)",
        driver_path = nil,  -- Will be auto-detected
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

-- Live capture mode (for discovering unknown key codes)
Bluetooth.live_capture_active = false
Bluetooth.live_capture_events = {}

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

function Bluetooth:startLiveCapture(duration)
    -- Start capturing ALL key events that KOReader receives
    duration = duration or 15
    
    self.live_capture_active = true
    self.live_capture_events = {}
    
    -- Store original onKeyPress if we're overriding
    if not self._original_key_handler then
        self._original_key_handler = Device.input.handleKeyBoardEv
    end
    
    local plugin = self
    
    -- Hook into the keyboard event handler
    Device.input.handleKeyBoardEv = function(self_input, ev)
        if plugin.live_capture_active then
            -- Capture this event
            table.insert(plugin.live_capture_events, {
                timestamp = os.date("%H:%M:%S"),
                code = ev.code,
                value = ev.value,  -- 1=press, 0=release, 2=repeat
                code_name = plugin:getKeyCodeName(ev.code),
            })
        end
        -- Call original handler
        if plugin._original_key_handler then
            return plugin._original_key_handler(self_input, ev)
        end
    end
    
    -- Auto-stop after duration
    UIManager:scheduleIn(duration, function()
        plugin:stopLiveCapture()
    end)
end

function Bluetooth:stopLiveCapture()
    self.live_capture_active = false
    
    -- Restore original handler
    if self._original_key_handler then
        Device.input.handleKeyBoardEv = self._original_key_handler
        self._original_key_handler = nil
    end
    
    -- Display results
    local events = self.live_capture_events
    
    if #events == 0 then
        self:popup(_("No key events captured.\n\n") ..
            _("Either no buttons were pressed, or the events aren't coming through as keyboard events."), 7)
        return
    end
    
    -- Analyze captured events
    local unique_codes = {}
    local press_events = {}
    
    for i, evt in ipairs(events) do
        if evt.value == 1 then  -- Key press
            unique_codes[evt.code] = evt.code_name or true
            table.insert(press_events, evt)
        end
    end
    
    local lines = {}
    
    -- Summary
    table.insert(lines, "=== KEY CODES DETECTED ===")
    table.insert(lines, "")
    
    -- Sort codes numerically
    local sorted_codes = {}
    for code, _ in pairs(unique_codes) do
        table.insert(sorted_codes, code)
    end
    table.sort(sorted_codes)
    
    for i, code in ipairs(sorted_codes) do
        local name = unique_codes[code]
        if type(name) == "string" then
            table.insert(lines, string.format("  Code %d = %s", code, name))
        else
            table.insert(lines, string.format("  Code %d", code))
        end
    end
    
    table.insert(lines, "")
    table.insert(lines, "=== ALL PRESS EVENTS ===")
    for i, evt in ipairs(press_events) do
        if i > 20 then
            table.insert(lines, "  ... and " .. (#press_events - 20) .. " more")
            break
        end
        local name_str = evt.code_name and (" (" .. evt.code_name .. ")") or ""
        table.insert(lines, string.format("  [%s] Code %d%s", evt.timestamp, evt.code, name_str))
    end
    
    table.insert(lines, "")
    table.insert(lines, _("Total events: ") .. #events)
    table.insert(lines, _("Unique key codes: ") .. #sorted_codes)
    
    self:popup(table.concat(lines, "\n"), 25)
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

-- Common Linux input event key codes for reference
Bluetooth.key_code_names = {
    -- Standard keys
    [1] = "ESC", [2] = "1", [3] = "2", [4] = "3", [5] = "4",
    [6] = "5", [7] = "6", [8] = "7", [9] = "8", [10] = "9",
    [11] = "0", [14] = "BACKSPACE", [15] = "TAB", [28] = "ENTER",
    [29] = "LEFTCTRL", [42] = "LEFTSHIFT", [54] = "RIGHTSHIFT",
    [56] = "LEFTALT", [57] = "SPACE", [97] = "RIGHTCTRL", [100] = "RIGHTALT",
    
    -- Arrow keys
    [103] = "UP", [105] = "LEFT", [106] = "RIGHT", [108] = "DOWN",
    
    -- Page navigation (common for page turners)
    [104] = "PAGEUP", [109] = "PAGEDOWN", [102] = "HOME", [107] = "END",
    
    -- Function keys
    [59] = "F1", [60] = "F2", [61] = "F3", [62] = "F4", [63] = "F5",
    [64] = "F6", [65] = "F7", [66] = "F8", [67] = "F9", [68] = "F10",
    [87] = "F11", [88] = "F12",
    
    -- Media keys (common on Bluetooth controllers)
    [113] = "MUTE", [114] = "VOLUMEDOWN", [115] = "VOLUMEUP",
    [116] = "POWER", [119] = "PAUSE", [128] = "STOP",
    [139] = "MENU", [142] = "SLEEP", [143] = "WAKEUP",
    [152] = "SCREENLOCK", [158] = "BACK", [159] = "FORWARD",
    [163] = "NEXTSONG", [164] = "PLAYPAUSE", [165] = "PREVIOUSSONG",
    [166] = "STOPCD", [167] = "RECORD", [168] = "REWIND", [169] = "PHONE",
    [171] = "CONFIG", [172] = "HOMEPAGE", [173] = "REFRESH",
    [176] = "EDIT", [177] = "SCROLLUP", [178] = "SCROLLDOWN",
    [200] = "PLAYCD", [201] = "PAUSECD", [207] = "FASTFORWARD",
    [208] = "BASSBOOST", [209] = "PRINT", [210] = "HP",
    [211] = "CAMERA", [212] = "SOUND", [213] = "QUESTION",
    [217] = "SEARCH", [224] = "BRIGHTNESSDOWN", [225] = "BRIGHTNESSUP",
    
    -- Bluetooth remote / gamepad buttons (BTN_* codes start at 0x100 = 256)
    [256] = "BTN_0", [257] = "BTN_1", [258] = "BTN_2", [259] = "BTN_3",
    [260] = "BTN_4", [261] = "BTN_5", [262] = "BTN_6", [263] = "BTN_7",
    [264] = "BTN_8", [265] = "BTN_9",
    
    -- Mouse buttons
    [272] = "BTN_LEFT", [273] = "BTN_RIGHT", [274] = "BTN_MIDDLE",
    [275] = "BTN_SIDE", [276] = "BTN_EXTRA",
    
    -- Gamepad
    [304] = "BTN_SOUTH/A", [305] = "BTN_EAST/B", [306] = "BTN_C",
    [307] = "BTN_NORTH/X", [308] = "BTN_WEST/Y", [309] = "BTN_Z",
    [310] = "BTN_TL", [311] = "BTN_TR", [312] = "BTN_TL2", [313] = "BTN_TR2",
    [314] = "BTN_SELECT", [315] = "BTN_START", [316] = "BTN_MODE",
    [317] = "BTN_THUMBL", [318] = "BTN_THUMBR",
    
    -- Consumer keys (additional)
    [353] = "KEY_SELECT", [354] = "KEY_GOTO", [357] = "KEY_INFO",
    [358] = "KEY_PROGRAM", [362] = "KEY_CHANNEL", [366] = "KEY_PLAYER",
    [370] = "KEY_SUBTITLE", [372] = "KEY_VCR", [373] = "KEY_VCR2",
    [374] = "KEY_SAT", [381] = "KEY_RED", [382] = "KEY_GREEN",
    [383] = "KEY_YELLOW", [384] = "KEY_BLUE", [385] = "KEY_CHANNELUP",
    [386] = "KEY_CHANNELDOWN", [388] = "KEY_LIST", [392] = "KEY_MEMO",
    [398] = "KEY_DVD", [399] = "KEY_AUDIO", [400] = "KEY_VIDEO",
    [407] = "KEY_NEXT", [412] = "KEY_PREVIOUS", [416] = "KEY_ZOOMIN",
    [417] = "KEY_ZOOMOUT",
}

-- Event type names
Bluetooth.event_type_names = {
    [0] = "EV_SYN",
    [1] = "EV_KEY",
    [2] = "EV_REL",
    [3] = "EV_ABS",
    [4] = "EV_MSC",
    [5] = "EV_SW",
    [17] = "EV_LED",
    [18] = "EV_SND",
    [20] = "EV_REP",
    [21] = "EV_FF",
}

function Bluetooth:getKeyCodeName(code)
    return self.key_code_names[code] or nil
end

function Bluetooth:getEventTypeName(evt_type)
    return self.event_type_names[evt_type] or ("TYPE_" .. evt_type)
end

function Bluetooth:readRawInputEvents(timeout_secs, include_all)
    -- Read raw input events from the input device using evtest
    -- timeout_secs: how long to listen
    -- include_all: if true, include sync events and all types; if false, only key events
    timeout_secs = timeout_secs or 5
    include_all = include_all or false
    local events = {}
    
    -- Use evtest for comprehensive output - capture more events
    local evtest_cmd = string.format("timeout %ds evtest %s 2>/dev/null | grep -E '^Event:' | head -50", 
        timeout_secs, self.input_device_path)
    
    local handle = io.popen(evtest_cmd)
    if handle then
        local output = handle:read("*a")
        handle:close()
        
        -- Parse evtest output like: "Event: time 1234.567890, type 1 (EV_KEY), code 19 (KEY_R), value 1"
        for line in output:gmatch("[^\n]+") do
            local evt_type, type_name, code, code_name, value = 
                line:match("type (%d+) %(([^)]+)%), code (%d+) %(([^)]+)%), value (%d+)")
            
            if not evt_type then
                -- Try simpler pattern without names
                evt_type, code, value = line:match("type (%d+).*code (%d+).*value (%d+)")
            end
            
            if evt_type and code and value then
                local t = tonumber(evt_type)
                local c = tonumber(code)
                local v = tonumber(value)
                
                -- Skip sync events unless include_all is set
                if include_all or t ~= 0 then
                    table.insert(events, {
                        type = t,
                        type_name = type_name or self:getEventTypeName(t),
                        code = c,
                        code_name = code_name or self:getKeyCodeName(c),
                        value = v,
                        raw_line = line,
                    })
                end
            end
        end
    end
    
    -- If evtest didn't work, try direct binary read as fallback
    if #events == 0 then
        local cmd = string.format("timeout %ds cat %s 2>/dev/null | od -An -td1 -w24 | head -30", 
            timeout_secs, self.input_device_path)
        
        handle = io.popen(cmd)
        if handle then
            local output = handle:read("*a")
            handle:close()
            
            -- Very basic parsing - each line is 24 bytes of an input_event struct
            -- Bytes 16-17: type (little endian), 18-19: code (little endian), 20-23: value
            for line in output:gmatch("[^\n]+") do
                local bytes = {}
                for b in line:gmatch("%-?%d+") do
                    table.insert(bytes, tonumber(b))
                end
                if #bytes >= 20 then
                    local t = bytes[17] + (bytes[18] or 0) * 256
                    local c = bytes[19] + (bytes[20] or 0) * 256
                    local v = bytes[21] or 0
                    
                    if include_all or t ~= 0 then
                        table.insert(events, {
                            type = t,
                            type_name = self:getEventTypeName(t),
                            code = c,
                            code_name = self:getKeyCodeName(c),
                            value = v,
                        })
                    end
                end
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
    Dispatcher:registerAction("refresh_pairing_action", {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true})
    Dispatcher:registerAction("toggle_input_watching_action", {category="none", event="ToggleInputWatching", title=_("Toggle Input Watching"), general=true})
    Dispatcher:registerAction("connect_to_device_action", {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true})
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
    
    -- Set input device path (with detection method tracking)
    self.input_device_path, self.input_path_is_known, self.input_path_method, self.input_path_extra = self:getInputDevicePath()
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
                text = _("Event Map Editor"),
                sub_item_table_func = function()
                    return self:getEventMapEditorMenu()
                end,
            },
            {
                text = _("Refresh Device Input"),
                callback = function()
                    self:onRefreshPairing()
                end,
            },
            {
                text_func = function()
                    return self._watching and _("Stop Watching Input") or _("Watch Input Device")
                end,
                callback = function()
                    self:toggleInputWatching()
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

-- Available BT events for mapping (non-BTAction events first, then BTActions)
Bluetooth.available_bt_events = {
    -- Direct BT events (non-bank, immediate actions)
    "BTLeft",
    "BTRight",
    "BTGotoNextChapter",
    "BTGotoPrevChapter",
    "BTIncreaseFontSize",
    "BTDecreaseFontSize",
    "BTToggleBookmark",
    "BTIterateRotation",
    "BTIncreaseBrightness",
    "BTDecreaseBrightness",
    "BTIncreaseWarmth",
    "BTDecreaseWarmth",
    "BTNextBookmark",
    "BTPrevBookmark",
    "BTLastBookmark",
    "BTToggleNightMode",
    "BTToggleStatusBar",
    "BTRefreshScreen",
    "BTSleep",
    "BTBluetoothOff",
    "BTBluetoothOffAndSleep",
    "BTRemoteNextBank",
    "BTRemotePrevBank",
    -- BTActions (bank-configurable, at the end)
    "BTAction1",
    "BTAction2",
    "BTAction3",
    "BTAction4",
    "BTAction5",
    "BTAction6",
    "BTAction7",
    "BTAction8",
    "BTAction9",
    "BTAction10",
    "BTAction11",
    "BTAction12",
    "BTAction13",
    "BTAction14",
    "BTAction15",
    "BTAction16",
    "BTAction17",
    "BTAction18",
    "BTAction19",
    "BTAction20",
}

function Bluetooth:getCurrentEventMap()
    -- Get the current event map from Device.input or load from file
    local mappings = {}
    
    -- First try to read from the settings file
    local path = self:getCustomEventMapPath()
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        -- Parse the Lua table
        local fn = loadstring(content)
        if fn then
            local ok, result = pcall(fn)
            if ok and type(result) == "table" then
                mappings = result
            end
        end
    end
    
    -- If no file, use Device.input.event_map for BT entries
    if next(mappings) == nil then
        local event_map = Device.input and Device.input.event_map
        if event_map then
            for code, name in pairs(event_map) do
                if type(name) == "string" and name:match("^BT") then
                    mappings[code] = name
                end
            end
        end
    end
    
    return mappings
end

function Bluetooth:saveEventMap(mappings)
    local path = self:getCustomEventMapPath()
    local file = io.open(path, "w")
    if not file then
        return false, "Could not open file for writing: " .. path
    end
    
    file:write("-- Custom event map for Bluetooth plugin\n")
    file:write("-- Auto-generated by Event Map Editor\n")
    file:write("-- Maps key codes to BT events\n\n")
    file:write("return {\n")
    
    -- Sort by key code
    local keys = {}
    for k, _ in pairs(mappings) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    for _, key in ipairs(keys) do
        local value = mappings[key]
        file:write(string.format("    [%d] = \"%s\",\n", key, value))
    end
    
    file:write("}\n")
    file:close()
    
    -- Also inject into current session
    local event_map = Device.input and Device.input.event_map
    if event_map then
        -- Clear old BT mappings first
        for code, name in pairs(event_map) do
            if type(name) == "string" and name:match("^BT") then
                event_map[code] = nil
            end
        end
        -- Add new mappings
        for code, name in pairs(mappings) do
            event_map[code] = name
        end
    end
    
    return true, path
end

function Bluetooth:getEventMapEditorMenu()
    local menu = {}
    local mappings = self:getCurrentEventMap()
    
    -- Header
    table.insert(menu, {
        text = _("─── Current Mappings ───"),
        enabled = false,
    })
    
    -- Sort mappings by key code
    local sorted_codes = {}
    for code, _ in pairs(mappings) do
        table.insert(sorted_codes, code)
    end
    table.sort(sorted_codes)
    
    if #sorted_codes == 0 then
        table.insert(menu, {
            text = _("(No BT mappings defined)"),
            enabled = false,
        })
    else
        for _, code in ipairs(sorted_codes) do
            local event_name = mappings[code]
            table.insert(menu, {
                text = string.format("[%d] → %s", code, event_name),
                callback = function()
                    self:showMappingOptions(code, event_name, mappings)
                end,
            })
        end
    end
    
    -- Separator
    table.insert(menu, {
        text = _("─── Actions ───"),
        enabled = false,
    })
    
    -- Add new mapping
    table.insert(menu, {
        text = _("➕ Add new mapping"),
        callback = function()
            self:showAddMappingDialog(mappings)
        end,
    })
    
    -- Guided Simple Setup
    table.insert(menu, {
        text = _("🧙 Guided Simple Setup"),
        callback = function()
            self:startGuidedSetup()
        end,
    })
    
    -- Reload from file
    table.insert(menu, {
        text = _("🔄 Reload from file"),
        callback = function()
            self:popup(_("Event map reloaded."), 2)
        end,
    })
    
    return menu
end

-- Guided Simple Setup wizard state
Bluetooth.guided_setup = {
    active = false,
    mappings = {},
    step = 0,
}

-- User-friendly action names for guided setup
Bluetooth.friendly_action_names = {
    ["BTRight"] = "Next Page",
    ["BTLeft"] = "Previous Page",
    ["BTGotoNextChapter"] = "Next Chapter",
    ["BTGotoPrevChapter"] = "Previous Chapter",
    ["BTIncreaseFontSize"] = "Increase Font Size",
    ["BTDecreaseFontSize"] = "Decrease Font Size",
    ["BTToggleBookmark"] = "Toggle Bookmark",
    ["BTIterateRotation"] = "Rotate Screen",
    ["BTIncreaseBrightness"] = "Increase Brightness",
    ["BTDecreaseBrightness"] = "Decrease Brightness",
    ["BTIncreaseWarmth"] = "Increase Warmth",
    ["BTDecreaseWarmth"] = "Decrease Warmth",
    ["BTNextBookmark"] = "Next Bookmark",
    ["BTPrevBookmark"] = "Previous Bookmark",
    ["BTLastBookmark"] = "Last Bookmark",
    ["BTToggleNightMode"] = "Toggle Night Mode",
    ["BTToggleStatusBar"] = "Toggle Status Bar",
    ["BTRefreshScreen"] = "Refresh Screen",
    ["BTSleep"] = "Sleep Device",
    ["BTRemoteNextBank"] = "Next Bank (Advanced)",
    ["BTRemotePrevBank"] = "Previous Bank (Advanced)",
}

-- Common actions shown first in guided setup
Bluetooth.common_actions = {
    "BTRight",           -- Next Page
    "BTLeft",            -- Previous Page
    "BTGotoNextChapter",
    "BTGotoPrevChapter",
    "BTToggleBookmark",
    "BTIncreaseFontSize",
    "BTDecreaseFontSize",
    "BTIncreaseBrightness",
    "BTDecreaseBrightness",
}

function Bluetooth:startGuidedSetup()
    -- Check if Bluetooth is on
    if not self:isBluetoothOn() then
        UIManager:show(ConfirmBox:new{
            text = _("Bluetooth is not enabled.\n\nWould you like to turn it on first?"),
            ok_text = _("Turn On Bluetooth"),
            ok_callback = function()
                self:onBluetoothOn()
                -- Schedule to continue after BT is on
                UIManager:scheduleIn(3, function()
                    if self:isBluetoothOn() then
                        self:continueGuidedSetup()
                    else
                        self:popup(_("Failed to turn on Bluetooth. Please try manually."), 5)
                    end
                end)
            end,
            cancel_text = _("Cancel"),
        })
        return
    end
    
    self:continueGuidedSetup()
end

function Bluetooth:continueGuidedSetup()
    -- Initialize guided setup state
    self.guided_setup = {
        active = true,
        mappings = {},
        step = 0,
    }
    
    -- Reset dialog state flags
    self._guided_asking_more = false
    self._guided_selection_made = false
    
    -- Ensure input device is open (try to open, ignore errors if already open)
    local status, err = pcall(function()
        if self.input_device_path and self.input_device_path ~= "" then
            -- Just try to open - Device.input handles duplicates gracefully
            Device.input:open(self.input_device_path)
        end
    end)
    
    -- Don't fail if open had issues - the device might already be open
    -- We'll find out when we try to capture input
    
    -- Start the first button capture
    self:guidedCaptureNextButton()
end

function Bluetooth:guidedCaptureNextButton()
    self.guided_setup.step = self.guided_setup.step + 1
    local step = self.guided_setup.step
    
    local msg = string.format(_("BUTTON %d\n\n"), step) ..
        _("Press a button on your Bluetooth controller.\n\n") ..
        _("Listening for 10 seconds...")
    
    self:popup(msg, 2)
    
    -- Start capture after popup
    UIManager:scheduleIn(0.5, function()
        self:guidedStartCapture(step)
    end)
end

function Bluetooth:guidedStartCapture(step)
    -- Use the same mechanism as startLiveCapture but stop on first key press
    local plugin = self
    local timeout_secs = 10
    
    -- Mark as waiting for capture
    self.guided_capture_waiting = true
    self.guided_capture_step = step
    
    -- Store original handler if not already stored
    if not self._guided_original_handler then
        self._guided_original_handler = Device.input.handleKeyBoardEv
    end
    
    -- Hook into the keyboard event handler (same pattern as startLiveCapture)
    Device.input.handleKeyBoardEv = function(self_input, ev)
        if plugin.guided_capture_waiting and ev.value == 1 then  -- Key press only
            plugin.guided_capture_waiting = false
            local detected_code = ev.code
            local current_step = plugin.guided_capture_step
            
            -- Restore original handler immediately
            if plugin._guided_original_handler then
                Device.input.handleKeyBoardEv = plugin._guided_original_handler
                plugin._guided_original_handler = nil
            end
            
            -- Schedule action selection (deferred to avoid event issues)
            UIManager:scheduleIn(0.1, function()
                plugin:guidedShowActionSelection(current_step, detected_code)
            end)
        end
        
        -- Always call original handler to keep system working
        if plugin._guided_original_handler then
            return plugin._guided_original_handler(self_input, ev)
        end
    end
    
    -- Set timeout
    UIManager:scheduleIn(timeout_secs, function()
        if plugin.guided_capture_waiting then
            plugin.guided_capture_waiting = false
            
            -- Restore original handler
            if plugin._guided_original_handler then
                Device.input.handleKeyBoardEv = plugin._guided_original_handler
                plugin._guided_original_handler = nil
            end
            
            -- Ask if they want to try again or finish
            UIManager:show(ConfirmBox:new{
                text = _("No button press detected.\n\nDo you want to try again?"),
                ok_text = _("Try Again"),
                ok_callback = function()
                    plugin.guided_setup.step = plugin.guided_setup.step - 1
                    plugin:guidedCaptureNextButton()
                end,
                cancel_text = _("Finish Setup"),
                cancel_callback = function()
                    plugin:guidedFinishSetup()
                end,
            })
        end
    end)
end

function Bluetooth:guidedShowActionSelection(step, key_code)
    local key_name = self:getKeyCodeName(key_code) or "Unknown"
    
    -- Reset dialog state flags for clean state
    self._guided_asking_more = false
    
    local menu_items = {}
    
    -- Add common actions first
    table.insert(menu_items, {
        text = _("─── Common Actions ───"),
        enabled = false,
    })
    
    for idx, event_name in ipairs(self.common_actions) do
        local friendly = self.friendly_action_names[event_name] or event_name:gsub("^BT", "")
        table.insert(menu_items, {
            text = friendly,
            callback = function()
                self._guided_selection_made = true
                UIManager:close(self._guided_action_menu)
                self:guidedAssignAction(step, key_code, event_name)
            end,
        })
    end
    
    -- Add separator and all other actions
    table.insert(menu_items, {
        text = _("─── All Actions ───"),
        enabled = false,
    })
    
    for idx, event_name in ipairs(self.available_bt_events) do
        -- Skip if already in common actions
        local is_common = false
        for j, common in ipairs(self.common_actions) do
            if common == event_name then
                is_common = true
                break
            end
        end
        
        if not is_common then
            local friendly = self.friendly_action_names[event_name] or event_name:gsub("^BT", "")
            table.insert(menu_items, {
                text = friendly,
                callback = function()
                    self._guided_selection_made = true
                    UIManager:close(self._guided_action_menu)
                    self:guidedAssignAction(step, key_code, event_name)
                end,
            })
        end
    end
    
    -- Add skip option
    table.insert(menu_items, {
        text = _("─── ───"),
        enabled = false,
    })
    table.insert(menu_items, {
        text = _("Skip this button"),
        callback = function()
            self._guided_selection_made = true
            UIManager:close(self._guided_action_menu)
            self:guidedAskMoreButtons()
        end,
    })
    
    local Menu = require("ui/widget/menu")
    local Screen = Device.screen
    self._guided_selection_made = false  -- Reset flag
    self._guided_action_menu = Menu:new{
        title = string.format(_("Button detected: Code %d (%s)\n\nWhat should this button do?"), key_code, key_name),
        item_table = menu_items,
        width = Screen:getWidth() - 100,
        height = Screen:getHeight() - 100,
        single_line = true,
        items_per_page = 12,
        close_callback = function()
            -- If closed without making a selection, finish the setup
            if not self._guided_selection_made then
                UIManager:scheduleIn(0.1, function()
                    if self.guided_setup.active then
                        self:guidedFinishSetup()
                    end
                end)
            end
        end,
    }
    UIManager:show(self._guided_action_menu)
end

function Bluetooth:guidedAssignAction(step, key_code, event_name)
    -- Save the mapping
    self.guided_setup.mappings[key_code] = event_name
    
    -- Go directly to asking about more buttons (no intermediate popup)
    -- The summary at the end will show all mappings
    self:guidedAskMoreButtons()
end

function Bluetooth:guidedAskMoreButtons()
    if not self.guided_setup.active then
        return
    end
    
    -- Prevent duplicate dialogs
    if self._guided_asking_more then
        return
    end
    self._guided_asking_more = true
    
    local mapped_count = 0
    for k, v in pairs(self.guided_setup.mappings) do
        mapped_count = mapped_count + 1
    end
    
    self._guided_more_dialog = ConfirmBox:new{
        text = string.format(_("You have mapped %d button(s) so far.\n\nDo you have more buttons to configure?"), mapped_count),
        ok_text = _("Yes, add more"),
        ok_callback = function()
            self._guided_asking_more = false
            self:guidedCaptureNextButton()
        end,
        cancel_text = _("No, finish setup"),
        cancel_callback = function()
            self._guided_asking_more = false
            self:guidedFinishSetup()
        end,
    }
    UIManager:show(self._guided_more_dialog)
end

function Bluetooth:guidedFinishSetup()
    self.guided_setup.active = false
    self._guided_asking_more = false
    self._guided_selection_made = false
    
    -- Restore handler if still hooked
    if self._guided_original_handler then
        Device.input.handleKeyBoardEv = self._guided_original_handler
        self._guided_original_handler = nil
    end
    
    local mapped_count = 0
    for k, v in pairs(self.guided_setup.mappings) do
        mapped_count = mapped_count + 1
    end
    
    if mapped_count == 0 then
        self:popup(_("Setup cancelled. No buttons were mapped."), 3)
        return
    end
    
    -- Show summary and confirm save
    local summary_lines = {_("Summary of button mappings:\n")}
    
    for code, event_name in pairs(self.guided_setup.mappings) do
        local key_name = self:getKeyCodeName(code) or "Code " .. code
        local friendly = self.friendly_action_names[event_name] or event_name:gsub("^BT", "")
        table.insert(summary_lines, string.format("  %s → %s", key_name, friendly))
    end
    
    table.insert(summary_lines, "")
    table.insert(summary_lines, _("Save these mappings?"))
    
    UIManager:show(ConfirmBox:new{
        text = table.concat(summary_lines, "\n"),
        ok_text = _("Save"),
        ok_callback = function()
            -- Merge with existing mappings
            local existing = self:getCurrentEventMap()
            for code, event_name in pairs(self.guided_setup.mappings) do
                existing[code] = event_name
            end
            
            -- Save to file
            local success, path = self:writeCustomEventMap(existing)
            if success then
                self:popup(_("Mappings saved successfully!\n\nYour controller is now configured."), 5)
            else
                self:popup(_("Failed to save mappings."), 5)
            end
        end,
        cancel_text = _("Discard"),
        cancel_callback = function()
            self:popup(_("Mappings discarded."), 2)
        end,
    })
end

function Bluetooth:showMappingOptions(code, event_name, mappings)
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    
    local button_dialog
    button_dialog = ButtonDialog:new{
        title = string.format(_("Mapping: [%d] → %s"), code, event_name),
        buttons = {
            {
                {
                    text = _("Change Event"),
                    callback = function()
                        UIManager:close(button_dialog)
                        self:showEventSelector(code, mappings)
                    end,
                },
            },
            {
                {
                    text = _("Delete Mapping"),
                    callback = function()
                        UIManager:close(button_dialog)
                        mappings[code] = nil
                        local ok, result = self:saveEventMap(mappings)
                        if ok then
                            self:popup(string.format(_("Mapping [%d] deleted."), code), 2)
                        else
                            self:popup(_("Error: ") .. result, 5)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(button_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(button_dialog)
end

function Bluetooth:showAddMappingDialog(mappings)
    local InputDialog = require("ui/widget/inputdialog")
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Add New Mapping"),
        description = _("Enter the key code (use Diagnostics → Monitor raw input to find codes)"),
        input_hint = _("e.g., 115"),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local code = tonumber(input_dialog:getInputText())
                        UIManager:close(input_dialog)
                        if code then
                            if mappings[code] then
                                self:popup(string.format(_("Code %d is already mapped to %s.\n\nEdit it from the list instead."), code, mappings[code]), 5)
                            else
                                self:showEventSelector(code, mappings)
                            end
                        else
                            self:popup(_("Invalid key code. Please enter a number."), 3)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Bluetooth:showEventSelector(code, mappings)
    local ButtonDialog = require("ui/widget/buttondialog")
    
    -- Build button rows (3 buttons per row for better display)
    local button_rows = {}
    local current_row = {}
    
    for i, event_name in ipairs(self.available_bt_events) do
        table.insert(current_row, {
            text = event_name:gsub("^BT", ""),  -- Remove BT prefix for shorter display
            callback = function()
                UIManager:close(self._event_selector_dialog)
                mappings[code] = event_name
                local ok, result = self:saveEventMap(mappings)
                if ok then
                    self:popup(string.format(_("Mapped [%d] → %s"), code, event_name), 2)
                else
                    self:popup(_("Error: ") .. result, 5)
                end
            end,
        })
        
        -- 2 buttons per row
        if #current_row >= 2 then
            table.insert(button_rows, current_row)
            current_row = {}
        end
    end
    
    -- Add remaining buttons
    if #current_row > 0 then
        table.insert(button_rows, current_row)
    end
    
    -- Add cancel button
    table.insert(button_rows, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._event_selector_dialog)
            end,
        },
    })
    
    self._event_selector_dialog = ButtonDialog:new{
        title = string.format(_("Select event for key code %d"), code),
        buttons = button_rows,
    }
    UIManager:show(self._event_selector_dialog)
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

function Bluetooth:findInputDeviceByBluetoothName()
    -- Try to find input device by matching against saved Bluetooth device name
    -- Returns: path, device_name if found; nil, nil otherwise
    
    local saved_mac, saved_name = self:getSavedDeviceMAC()
    if not saved_name then
        return nil, nil, "No saved Bluetooth device"
    end
    
    -- Get all input devices
    local devices = self:listAllInputDevices()
    if #devices == 0 then
        return nil, nil, "No input devices found"
    end
    
    -- Try exact match first (case-insensitive)
    local saved_lower = saved_name:lower()
    for _, dev in ipairs(devices) do
        if dev.name then
            local dev_lower = dev.name:lower()
            if dev_lower == saved_lower then
                return dev.path, dev.name, "exact_match"
            end
        end
    end
    
    -- Try partial match (saved name contains or is contained in device name)
    for _, dev in ipairs(devices) do
        if dev.name then
            local dev_lower = dev.name:lower()
            -- Check if one contains the other
            if dev_lower:find(saved_lower, 1, true) or saved_lower:find(dev_lower, 1, true) then
                return dev.path, dev.name, "partial_match"
            end
        end
    end
    
    return nil, nil, "No matching device found"
end

function Bluetooth:getInputDevicePath()
    -- Determine the correct input device path
    -- Priority: 1) Match by Bluetooth device name, 2) Known device model, 3) Highest event, 4) Default
    
    -- First try: match by saved Bluetooth device name
    local matched_path, matched_name, match_type = self:findInputDeviceByBluetoothName()
    if matched_path then
        return matched_path, true, "bt_name_match", matched_name
    end
    
    -- Second try: known device model
    local model = Device.model
    local path = self.device_input_paths[model]
    if path then
        return path, true, "device_model", model  -- known path
    end
    
    -- Third try: find the highest event number as best guess
    local guessed_path = self:findHighestEventPath()
    if guessed_path then
        return guessed_path, false, "highest_event", nil  -- guessed path
    end
    
    return self.default_input_path, false, "default", nil  -- fallback
end

function Bluetooth:updateInputDevicePath()
    -- Re-detect the input device path (called when refreshing)
    local path, is_known, method, extra = self:getInputDevicePath()
    self.input_device_path = path
    self.input_path_is_known = is_known
    self.input_path_method = method
    self.input_path_extra = extra
    return path, is_known, method, extra
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

function Bluetooth:detectBluetoothDriverPath()
    -- Try to find the Bluetooth power driver
    -- Different Kobo devices have it in different locations
    
    local possible_paths = {
        -- i.MX6 devices (Clara 2E, Libra 2, etc.)
        "/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko",
        -- MediaTek devices (Clara BW, Clara Colour, Libra Colour)
        "/drivers/mt8113t-ntx/wifi/sdio_bt_pwr.ko",
        -- Other possible locations
        "/drivers/*/wifi/sdio_bt_pwr.ko",
    }
    
    -- First, try exact paths
    for i, path in ipairs(possible_paths) do
        if not path:find("%*") then
            local attr = lfs.attributes(path)
            if attr then
                return path
            end
        end
    end
    
    -- Try to find it dynamically in /drivers
    local handle = io.popen("find /drivers -name 'sdio_bt_pwr.ko' 2>/dev/null | head -1")
    if handle then
        local result = handle:read("*a")
        handle:close()
        result = result and result:gsub("%s+$", "") or ""
        if result ~= "" then
            return result
        end
    end
    
    -- Fallback to default
    return self.default_driver_path
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
    
    -- Check 4: Input device path (re-check dynamically)
    local current_path, path_is_known, path_method, path_extra = self:getInputDevicePath()
    local model = Device.model or "unknown"
    local path_icon
    if path_method == "bt_name_match" then
        path_icon = "✓ "  -- Best: matched by BT device name
    elseif path_method == "device_model" then
        path_icon = "✓ "  -- Good: known device model
    else
        path_icon = "⚠ "  -- Warning: guessing
    end
    
    table.insert(diagnostics, {
        text = path_icon .. _("Input device path"),
        callback = function()
            -- Re-check dynamically when clicked
            local p, known, method, extra = self:getInputDevicePath()
            local msg
            
            if method == "bt_name_match" then
                msg = _("✓ Input device matched by Bluetooth name!\n\n") ..
                    _("This is the most reliable detection method.\n\n") ..
                    _("Bluetooth device: ") .. (extra or "?") .. "\n" ..
                    _("Input path: ") .. p .. "\n\n" ..
                    _("The input device name matches your saved Bluetooth device.")
            elseif method == "device_model" then
                msg = _("✓ Input device path is configured for your device model.\n\n") ..
                    _("Model: ") .. (extra or model) .. "\n" ..
                    _("Path: ") .. p
            elseif method == "highest_event" then
                msg = _("⚠ Input device path is a best guess!\n\n") ..
                    _("Model: ") .. model .. "\n" ..
                    _("Path: ") .. p .. _(" (highest event found)\n\n") ..
                    _("Your device model is not in the known device list, and no Bluetooth name match was found.\n\n") ..
                    _("The system detected the highest /dev/input/eventX as a best guess. This usually works but is not guaranteed.\n\n") ..
                    _("Tip: Save a Bluetooth device in Device Management, and the plugin will try to match it by name next time.")
            else
                msg = _("⚠ Using default input device path!\n\n") ..
                    _("Path: ") .. p .. "\n\n" ..
                    _("Could not detect the correct input device. Using fallback.")
            end
            
            self:popup(msg, 10)
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
                local msg = _("✓ Event map has BT event entries.\n\n") ..
                    _("Found ") .. #found .. _(" BT mappings:\n") ..
                    table.concat(found, ", ")
                
                -- Show ButtonDialog with OK and Delete options
                local ButtonDialog = require("ui/widget/buttondialog")
                local button_dialog
                button_dialog = ButtonDialog:new{
                    title = msg,
                    buttons = {
                        {
                            {
                                text = _("OK"),
                                callback = function()
                                    UIManager:close(button_dialog)
                                end,
                            },
                        },
                        {
                            {
                                text = _("Delete Mappings"),
                                callback = function()
                                    UIManager:close(button_dialog)
                                    -- Confirm deletion
                                    UIManager:show(ConfirmBox:new{
                                        text = _("Delete all BT event mappings?\n\nThis will remove the custom event_map.lua file and clear runtime mappings."),
                                        ok_text = _("Delete"),
                                        ok_callback = function()
                                            self:deleteEventMappings()
                                            self:popup(_("Mappings deleted. You can now set up new ones."), 3)
                                        end,
                                        cancel_text = _("Cancel"),
                                    })
                                end,
                            },
                        },
                    },
                }
                UIManager:show(button_dialog)
            else
                local msg = _("✗ Event map has no BT event entries!\n\n") ..
                    _("Bluetooth button presses won't be recognized without BT event mappings.\n\n") ..
                    _("Choose how to set up your button mappings:")
                
                -- Show ButtonDialog with multiple options
                local ButtonDialog = require("ui/widget/buttondialog")
                local button_dialog
                button_dialog = ButtonDialog:new{
                    title = msg,
                    buttons = {
                        {
                            {
                                text = _("Simple Guided Setup"),
                                callback = function()
                                    UIManager:close(button_dialog)
                                    self:startGuidedSetup()
                                end,
                            },
                        },
                        {
                            {
                                text = _("Advanced Default"),
                                callback = function()
                                    UIManager:close(button_dialog)
                                    local success, result = self:autoCorrectEventMap()
                                    if success then
                                        self:popup(_("✓ ") .. result, 7)
                                    else
                                        self:popup(_("✗ Auto-correction failed:\n") .. result, 7)
                                    end
                                end,
                            },
                        },
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(button_dialog)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(button_dialog)
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
        text = "📡 " .. _("Event discovery (10 sec)"),
        callback = function()
            self:popup(_("Listening for ALL events from:\n") .. self.input_device_path .. 
                _("\n\nPress buttons on your Bluetooth controller now!\n\n") ..
                _("This will capture any key codes your device sends."), 2)
            
            -- Schedule the actual read after popup closes
            UIManager:scheduleIn(0.5, function()
                -- Get ALL events including all types
                local raw_events = self:readRawInputEvents(10, true)
                
                if #raw_events == 0 then
                    self:popup(_("No input events detected in 10 seconds.\n\n") ..
                        _("Troubleshooting:\n") ..
                        _("1. Is Bluetooth turned on?\n") ..
                        _("2. Is your controller connected?\n") ..
                        _("3. Is evtest installed?\n") ..
                        _("4. Input path: ") .. self.input_device_path .. "\n\n" ..
                        _("Try running manually:\n") ..
                        "evtest " .. self.input_device_path, 12)
                else
                    -- Group events by type for clearer display
                    local key_events = {}
                    local other_events = {}
                    local unique_codes = {}
                    
                    for _, evt in ipairs(raw_events) do
                        if evt.type == 1 then -- EV_KEY
                            table.insert(key_events, evt)
                            -- Track unique key codes
                            if evt.value == 1 then -- Key press (not release)
                                unique_codes[evt.code] = evt.code_name or true
                            end
                        elseif evt.type ~= 0 then -- Not sync
                            table.insert(other_events, evt)
                        end
                    end
                    
                    local lines = {}
                    
                    -- Summary of unique key codes detected
                    if next(unique_codes) then
                        table.insert(lines, "=== KEY CODES DETECTED ===")
                        for code, name in pairs(unique_codes) do
                            if type(name) == "string" then
                                table.insert(lines, string.format("  Code %d = %s", code, name))
                            else
                                table.insert(lines, string.format("  Code %d (unknown)", code))
                            end
                        end
                        table.insert(lines, "")
                    end
                    
                    -- Detailed key events
                    if #key_events > 0 then
                        table.insert(lines, "=== KEY EVENTS ===")
                        for _, evt in ipairs(key_events) do
                            local action = evt.value == 1 and "PRESS" or (evt.value == 0 and "RELEASE" or "REPEAT")
                            local name_str = evt.code_name and (" (" .. evt.code_name .. ")") or ""
                            table.insert(lines, string.format("  [%s] Code %d%s", action, evt.code, name_str))
                        end
                        table.insert(lines, "")
                    end
                    
                    -- Other events (mouse, gamepad axes, etc)
                    if #other_events > 0 then
                        table.insert(lines, "=== OTHER EVENTS ===")
                        for i, evt in ipairs(other_events) do
                            if i > 10 then
                                table.insert(lines, "  ... and " .. (#other_events - 10) .. " more")
                                break
                            end
                            table.insert(lines, string.format("  Type %d (%s), Code %d, Value %d",
                                evt.type, evt.type_name or "?", evt.code, evt.value))
                        end
                    end
                    
                    if #lines == 0 then
                        table.insert(lines, "Only sync events detected (no key presses)")
                    end
                    
                    -- Add hint if only MSC events detected
                    if #key_events == 0 and #other_events > 0 then
                        table.insert(lines, "")
                        table.insert(lines, "NOTE: Only scan codes detected, no key events.")
                        table.insert(lines, "Try 'List all input devices' to find the")
                        table.insert(lines, "correct device with actual key events.")
                    end
                    
                    self:popup(_("Events captured from input device:\n\n") .. table.concat(lines, "\n"), 20)
                end
            end)
        end,
    })
    
    -- List all input devices
    table.insert(diagnostics, {
        text = "📋 " .. _("List all input devices"),
        callback = function()
            local gettext = _  -- Save reference before loop
            local devices = self:listAllInputDevices()
            if #devices == 0 then
                self:popup(gettext("No input devices found in /dev/input/"), 5)
            else
                local lines = {gettext("Available input devices:\n")}
                for idx, dev in ipairs(devices) do
                    local line = dev.path
                    if dev.name then
                        line = line .. "\n  " .. dev.name
                    end
                    if dev.handlers then
                        line = line .. "\n  Handlers: " .. dev.handlers
                    end
                    table.insert(lines, line)
                end
                table.insert(lines, "")
                table.insert(lines, gettext("Current: ") .. self.input_device_path)
                table.insert(lines, "")
                table.insert(lines, gettext("Use 'Test specific device' to try a different one."))
                self:popup(table.concat(lines, "\n"), 20)
            end
        end,
    })
    
    -- Test a specific input device
    table.insert(diagnostics, {
        text = "🔧 " .. _("Test specific device"),
        sub_item_table_func = function()
            return self:getInputDeviceTestMenu()
        end,
    })
    
    -- Live capture - hooks into KOReader's input system directly
    table.insert(diagnostics, {
        text = "🎯 " .. _("Live capture (15 sec)"),
        callback = function()
            if self.live_capture_active then
                self:popup(_("Live capture already running!"), 2)
                return
            end
            
            self:popup(_("LIVE CAPTURE MODE\n\n") ..
                _("Capturing ALL key events that KOReader receives for 15 seconds.\n\n") ..
                _("Press buttons on your controller NOW!\n\n") ..
                _("Results will appear when capture ends."), 3)
            
            UIManager:scheduleIn(0.5, function()
                self:startLiveCapture(15)
            end)
        end,
    })
    
    return diagnostics
end

function Bluetooth:listAllInputDevices()
    -- List all available input devices with their names
    local devices = {}
    
    -- Get list of event devices
    local handle = io.popen("ls /dev/input/event* 2>/dev/null | sort -V")
    if handle then
        local output = handle:read("*a")
        handle:close()
        
        for path in output:gmatch("/dev/input/event%d+") do
            local dev = { path = path }
            
            -- Try to get device name from /proc/bus/input/devices
            local event_num = path:match("event(%d+)")
            if event_num then
                local proc_handle = io.popen("cat /proc/bus/input/devices 2>/dev/null")
                if proc_handle then
                    local proc_output = proc_handle:read("*a")
                    proc_handle:close()
                    
                    -- Parse the devices file - look for the handler that matches our event
                    local current_name = nil
                    local current_handlers = nil
                    for line in proc_output:gmatch("[^\n]+") do
                        local name = line:match('^N: Name="(.-)"')
                        if name then
                            current_name = name
                        end
                        local handlers = line:match("^H: Handlers=(.*)")
                        if handlers then
                            current_handlers = handlers
                            if handlers:match("event" .. event_num .. "[^%d]") or 
                               handlers:match("event" .. event_num .. "$") then
                                dev.name = current_name
                                dev.handlers = current_handlers:gsub("%s+", " ")
                            end
                        end
                    end
                end
            end
            
            table.insert(devices, dev)
        end
    end
    
    return devices
end

function Bluetooth:getInputDeviceTestMenu()
    local menu = {}
    local devices = self:listAllInputDevices()
    local gettext = _  -- Save gettext function reference before loops
    
    for idx, dev in ipairs(devices) do
        local display = dev.path
        if dev.name then
            display = display .. " (" .. dev.name:sub(1, 25) .. ")"
        end
        
        table.insert(menu, {
            text = display,
            callback = function()
                -- Temporarily test this device
                local original_path = self.input_device_path
                self.input_device_path = dev.path
                
                self:popup(gettext("Testing: ") .. dev.path .. 
                    gettext("\n\nPress buttons on your controller for 10 seconds..."), 2)
                
                UIManager:scheduleIn(0.5, function()
                    local raw_events = self:readRawInputEvents(10, true)
                    
                    -- Restore original path
                    self.input_device_path = original_path
                    
                    if #raw_events == 0 then
                        self:popup(gettext("No events from: ") .. dev.path .. 
                            gettext("\n\nThis device doesn't appear to be your controller."), 5)
                    else
                        -- Check if we got actual key events
                        local key_count = 0
                        local msc_count = 0
                        local unique_keys = {}
                        
                        for j, evt in ipairs(raw_events) do
                            if evt.type == 1 then
                                key_count = key_count + 1
                                if evt.value == 1 then
                                    unique_keys[evt.code] = evt.code_name or true
                                end
                            elseif evt.type == 4 then
                                msc_count = msc_count + 1
                            end
                        end
                        
                        local lines = {}
                        table.insert(lines, gettext("Device: ") .. dev.path)
                        if dev.name then
                            table.insert(lines, gettext("Name: ") .. dev.name)
                        end
                        table.insert(lines, "")
                        
                        if key_count > 0 then
                            table.insert(lines, "*** KEY EVENTS FOUND! ***")
                            table.insert(lines, "")
                            table.insert(lines, gettext("Key events: ") .. key_count)
                            table.insert(lines, gettext("Key codes detected:"))
                            for code, name in pairs(unique_keys) do
                                if type(name) == "string" then
                                    table.insert(lines, string.format("  %d = %s", code, name))
                                else
                                    table.insert(lines, string.format("  %d", code))
                                end
                            end
                            table.insert(lines, "")
                            table.insert(lines, gettext("This looks like the right device!"))
                            table.insert(lines, gettext("Update input_device_path in the plugin"))
                            table.insert(lines, gettext("to use: ") .. dev.path)
                        else
                            table.insert(lines, gettext("Only scan codes (MSC): ") .. msc_count)
                            table.insert(lines, gettext("No key events - not the right device."))
                        end
                        
                        self:popup(table.concat(lines, "\n"), 15)
                    end
                end)
            end,
        })
    end
    
    if #menu == 0 then
        table.insert(menu, {
            text = _("No input devices found"),
            enabled = false,
        })
    end
    
    return menu
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

function Bluetooth:writeCustomEventMap(mappings)
    -- Write event mappings to settings/event_map.lua
    -- If mappings is provided, use that; otherwise use default_event_mappings
    local mappings_to_write = mappings or self.default_event_mappings
    
    local path = self:getCustomEventMapPath()
    local file = io.open(path, "w")
    if not file then
        return false, "Could not open file for writing: " .. path
    end
    
    -- Write the Lua table
    file:write("-- Custom event map for Bluetooth plugin\n")
    file:write("-- Auto-generated by bluetooth.koplugin\n")
    file:write("-- This file is loaded by KOReader on startup\n\n")
    file:write("return {\n")
    
    -- Sort keys for consistent output
    local keys = {}
    for k, _ in pairs(mappings_to_write) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    for _, key in ipairs(keys) do
        local value = mappings_to_write[key]
        file:write(string.format("    [%d] = \"%s\",\n", key, value))
    end
    
    file:write("}\n")
    file:close()
    
    -- Also inject into current session
    local event_map = Device.input and Device.input.event_map
    if event_map then
        for code, name in pairs(mappings_to_write) do
            event_map[code] = name
        end
    end
    
    return true, path
end

function Bluetooth:deleteEventMappings()
    -- Delete custom event_map.lua file and clear runtime BT mappings
    local path = self:getCustomEventMapPath()
    
    -- Delete the file
    os.remove(path)
    
    -- Clear BT mappings from runtime event_map
    local event_map = Device.input and Device.input.event_map
    if event_map then
        -- Remove all BT* entries
        local to_remove = {}
        for code, name in pairs(event_map) do
            if type(name) == "string" and name:match("^BT") then
                table.insert(to_remove, code)
            end
        end
        for _, code in ipairs(to_remove) do
            event_map[code] = nil
        end
    end
    
    return true
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
-- This file is a marker that hasKeys override is enabled
-- The actual override happens in the Bluetooth plugin at runtime
-- (Patches run too early, before Device is initialized)
return true
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
        return false, "Runtime fix applied, but marker file creation failed:\n" .. write_result .. "\n\nThe fix will work this session but may need to be re-applied after restart."
    end
    
    return true, "hasKeys is now enabled!\n\nMarker file created at:\n" .. write_result .. "\n\nThe override will be applied automatically on each startup."
end

function Bluetooth:applyStartupFixes()
    -- Apply any saved auto-corrections on startup
    -- The patch file is just a marker - we apply the actual override here
    -- because KOReader patches run before Device is initialized
    
    -- If the marker file exists and hasKeys is false, apply the override
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
    
    -- Determine driver path (from config or auto-detect)
    local driver_path = bt_config.driver_path or self:detectBluetoothDriverPath()
    
    -- Step 1: Load Bluetooth power module
    if driver_path then
        local driver_result = self:executeCommand("insmod " .. driver_path)
        if driver_result and driver_result:match("No such file") then
            table.insert(results, "Driver not found: " .. driver_path)
        else
            table.insert(results, driver_result)
        end
    else
        table.insert(results, "Warning: No Bluetooth driver path found")
    end
    
    -- Step 2: Load UHID module (from plugin directory)
    table.insert(results, self:executeCommand("insmod " .. plugin_path .. "/uhid/uhid.ko"))
    
    -- Step 3: Attach HCI (device-specific command)
    table.insert(results, self:executeCommand(bt_config.hci_attach))
    
    -- Step 4: Initialize D-Bus/BlueZ (silently - we don't need the verbose output)
    os.execute("dbus-send --system --dest=org.bluez / org.freedesktop.DBus.ObjectManager.GetManagedObjects > /dev/null 2>&1")
    
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
        -- Truncate long results to avoid huge popups
        local short_result = result or ""
        if #short_result > 500 then
            short_result = short_result:sub(1, 500) .. "\n...(truncated)"
        end
        -- Provide helpful troubleshooting info
        local msg = _("Bluetooth may not have started correctly.\n\n")
        msg = msg .. _("Check Diagnostics for more info.\n\n")
        if detection_type == "default" then
            msg = msg .. _("Note: Using default config. Your device may need different drivers.\n\n")
        end
        if short_result ~= "" then
            msg = msg .. _("Details:\n") .. short_result
        end
        self:popup(msg, 10)
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
    
    -- Determine driver path (from config or auto-detect)
    local driver_path = bt_config.driver_path or self:detectBluetoothDriverPath()
    
    -- Step 1: Bring down HCI interface
    self:executeCommand("hciconfig hci0 down")
    
    -- Step 2: Kill HCI attach process (device-specific)
    self:executeCommand(bt_config.hci_kill)
    
    -- Step 3: Kill bluetoothd
    self:executeCommand("pkill bluetoothd")
    
    -- Step 4: Unload Bluetooth power module
    if driver_path then
        -- For rmmod, we just need the module name, not the full path
        self:executeCommand("rmmod sdio_bt_pwr")
    end
    
    -- Step 5: Unload UHID module
    self:executeCommand("rmmod uhid")
    -- Note: is_bluetooth_on cache will be updated on next isBluetoothOn() call
end

function Bluetooth:onRefreshPairing()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end

    -- Dynamically update input device path (try to match by BT device name first)
    local path, is_known, method, extra = self:updateInputDevicePath()

    local status, err = pcall(function()
        -- Ensure the device path is valid
        if not path or path == "" then
            error("Invalid device path")
        end

        Device.input:close(path) -- Close the input using the high-level parameter
        Device.input:open(path)  -- Reopen the input using the high-level parameter
        
        -- Build informative message
        local msg = _("Input device opened: ") .. path
        if method == "bt_name_match" then
            msg = msg .. "\n" .. _("(Matched by Bluetooth device name: ") .. (extra or "?") .. ")"
        elseif method == "device_model" then
            msg = msg .. "\n" .. _("(Known path for ") .. (extra or Device.model) .. ")"
        elseif method == "highest_event" then
            msg = msg .. "\n" .. _("(Best guess: highest event number)")
        else
            msg = msg .. "\n" .. _("(Default fallback)")
        end
        
        self:popup(msg, 4)
    end)

    if not status then
        self:popup(_("Error: ") .. err)
    end
end

function Bluetooth:toggleInputWatching()
    if self._watching then
        -- Stop watching
        self._watching = false
        UIManager:unschedule(self._poll)
        self:popup(_("Stopped watching."), 2)
        return
    end
    
    -- Start watching: refresh device every second (silently)
    self._watching = true
    
    self._poll = function()
        if not self._watching then return end
        if self:isBluetoothOn() then
            local path = self:updateInputDevicePath()
            if path and path ~= "" then
                pcall(function() Device.input:close(path) end)
                pcall(function() Device.input:open(path) end)
            end
        end
        UIManager:scheduleIn(1, self._poll)
    end
    
    UIManager:scheduleIn(1, self._poll)
    self:popup(_("Watching enabled."), 2)
end

function Bluetooth:onToggleInputWatching()
    self:toggleInputWatching()
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
