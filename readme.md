
# Bluetooth Page Turner Support for Kobo

This plugin allows the user to turn Bluetooth on/off and connect a Bluetooth device to be connected on Kobo devices.

## How it Works

This plugin adds the menu "Gear > Network > Bluetooth" which includes:
* Bluetooth On
* Bluetooth Off

On Bluetooth On, the system will turn on WiFi (which is required for Bluetooth) and Bluetooth, then attempt to establish a connection to an input device previously paired on `/dev/input/event3`.

The initial pairing can be done either using Nickel's native Bluetooth menu, or via SSH/bluetoothctl.

The plugin will also add the `uhid.ko` kernel patch, which is a requirement for certain Bluetooth devices to be recognized.

## New Actions

### Refresh Device Input
**Description:** This command allows the device to start listening to input from connected devices again if the connection was lost and then automatically re-established. This is useful in situations where the Kobo device loses connection but reconnects automatically, and input events aren't being recognized.

### Connect to Device
**Description:** Sometimes Kobo devices do not automatically initiate the connection to an available Bluetooth device (e.g., 8bitdo micro). This command sends a connection request from the Kobo to the Bluetooth device. It requires the `connect.sh` script to be configured with your device’s MAC address, which can be obtained using the `bluetoothctl info` command.

## New Passive Features

With the current version of the code, there should be no reason to restart KOReader.

### Gesture Integration
All commands can now be triggered using taps and gestures. This enhances the user experience by allowing easy access to commands through customizable gestures. *Recommendation:* Bind the reconnect and relisten events to swipe gestures or similar actions for quick access.

### Automatic Listening
Once a device establishes a connection, it will now be automatically listened to without the need to reboot the device. This eliminates the previous requirement of restarting KOReader after enabling Bluetooth.

## Dedicated Bluetooth Events
The following new Bluetooth events have been implemented, allowing for additional functionality within KOReader:

- **BTGotoNextChapter:** Navigate to the next chapter.
- **BTGotoPrevChapter:** Navigate to the previous chapter.
- **BTDecreaseFontSize:** Reduce the font size by 1.
- **BTIncreaseFontSize:** Increase the font size by 1.
- **BTToggleBookmark:** Toggle bookmarks on and off.
- **BTIterateRotation:** Rotate the screen orientation 90 degrees.
- **BTBluetoothOff:** Turn off Bluetooth.
- **BTRight:** Go to the next page.
- **BTLeft:** Go to the previous page.
- **BTPrevBookmark:** Navigate to the previous bookmark in the document.
- **BTNextBookmark:** Navigate to the next bookmark in the document.
- **BTLastBookmark:** Jump to the last bookmark by timestamp.
- **BTToggleStatusBar:** Toggle the display of the status bar.
- **BTIncreaseBrightness:** Increase the frontlight brightness by 10 units.
- **BTDecreaseBrightness:** Decrease the frontlight brightness by 10 units.
- **BTToggleNightMode:** Toggle between dark mode (night mode) and light mode.
- **BTIncreaseWarmth:** Increase the warmth of the frontlight by 2 units.
- **BTDecreaseWarmth:** Decrease the warmth of the frontlight by 2 units.

*BTRight and BTLeft are recommended for page turning instead of the default actions, as these custom events will work with all screen orientations.*

## How to Install

1. Copy this folder into `koreader/plugins`.
2. Make sure your clicker is already paired with the Kobo device.
3. Make sure that your device is mapped to `/dev/input/event3` (this is not always guaranteed). If different, edit `main.lua` of this plugin to match the correct input device. (TODO: Automate)
4. Add `hasKeys = yes` to the device configuration. (TODO: Automate)
5. Add into `koreader/frontend/device/kobo/device.lua` a mapping of buttons to actions. This mapping is to be a button code (decimal number) to event name, events that you want your Bluetooth device to do. See an example below. My recommendation is to use the dedicated custom events, as most events mentioned before this update don't take orientation into account. (TODO: Automate)
6. Reboot KOReader if you haven't done so since installing the plugin.
7. (Optional) Greate Tap & Gesture shortcuts to various events.

## Example device.lua Configuration

Below is an example of how you can map Bluetooth device events in your `device.lua` file:

```lua
event_map = {
    -- Your existing mappings...
    
   [46]  = "BTGotoNextChapter",  -- C for Next Chapter                           
    [45]  = "BTGotoPrevChapter",  -- X for Previous Chapter                       
    [32]  = "BTDecreaseFontSize", -- D for Decrease Font Size                     
    [23]  = "BTIncreaseFontSize", -- I for Increase Font Size
    [48]  = "BTToggleBookmark",   -- B for Toggle Bookmark   
    [25]  = "BTLeft",             -- P for Previous Page                
    [49]  = "BTRight",            -- N for Next Page         
    [19]  = "BTIterateRotation",  -- R for Rotate 90 Degrees 
    [109] = "BTBluetoothOff",     -- Page Down for Bluetooth Off
                                                                
    [105] = "BTPrevBookmark",    -- Left arrow key for Previous Bookmark
    [106] = "BTNextBookmark",    -- Right arrow key for Next Bookmark   
    [108] = "BTLastBookmark",    -- Down arrow key for Last Bookmark (by timestamp)
    [103] = "BTToggleStatusBar", -- Up arrow key for Toggle Status Bar             
    [60]  = "BTIncreaseBrightness",   -- F2 for Increase Brightness                
    [59]  = "BTDecreaseBrightness",   -- F1 for Decrease Brightness                
    [38]  = "BTToggleNightMode",     -- L for Toggle Night Mode (Dark/Light Mode)  

--    [49]  = "BTIncreaseWarmth",       -- N for Increase Warmth                   
--    [48]  = "BTDecreaseWarmth",       -- C for Decrease Warmth                   
}
```


## Configuring connect.sh
To use the Connect to Device function, you need to modify the `connect.sh` script and add your device's MAC address. You can retrieve the MAC address using `bluetoothctl info`. Once configured, the script will be able to send connection requests from the Kobo device to your Bluetooth device.

## Device Specific Modifications

### Clara 2E
By default, all instructions are given for Clara 2E. No further modifications are needed apart from those documented in this description.

### Libra 2
MobileRead user **enji** provided instructions to adapt this plugin to Libra 2 by using `rtk_hciattach` instead of `hciattach`. *Thanks enji!* There are also previous cases of seeing `event4` being used instead of `event3`. In this case, please replace all instances of `event3` with `event4` in the scripts.

Replace `hciattach` with `rtk_hciattach` instructions:
- In *bluetooth.koplugin/on.sh*, change `hciattach -p ttymxc1 any 1500000 flow -t 20` to `/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5`.
- In *bluetooth.koplugin/off.sh*, change `pkill hciattach` to `pkill rtk_hciattach`.

## Contributions

I have tested this only on a Clara 2E, but all contributions are welcome. Here are some reading materials on this topic:

- https://www.mobileread.com/forums/showthread.php?p=4444741#post4444741
- https://github.com/koreader/koreader/issues/9059
- MobileRead user **enji**'s comment on Libra 2: https://www.mobileread.com/forums/showpost.php?p=4447639&postcount=16

