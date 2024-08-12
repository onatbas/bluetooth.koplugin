# Bluetooth Page Turner Support for Kobo

This plugin allows the user to turn bluetooth on/off and connect a bluetooth device to be connected on kobo devices

## How it works

This plugin adds the menu "Gear > Network > Bluetooth" which includes
* Bluetooth on
* Bluetooth off

On Bluetooth on, the system will turn on wifi (which is required for bluetooth) and bluetooth
and attempts to establish a connection to an input device previously paired on /dev/input/event3

The initial pairing can be done either using nickel's native bluetooth menu, or via SSH/bluetoothctl.

The plugin will also add uhid.ko kernel patch which is a requirement for certain bluetooth devices to be recognized.

## How to install

1. Copy this folder into koreader/plugins
2. Make sure your clicker is already paired with the kobo device.
3. Make sure that your device is mapped to /dev/input/event3 (this is not always guaranteed). If different, edit main.lua of this plugin to match the correct input device. (TODO: Automate)
4. Add hasKeys = yes to the device configuration. (TODO: Automate)
4. Add into "koreader/frontend/device/kobo/device.lua" the device event that your bluetooth device triggers for the buttons on it. See an example here: https://github.com/koreader/koreader/issues/9059#issuecomment-1464958230 . For my device, I needed to add  '[115] = "RPgFwd",' into the event map. (TODO: Automate)
4. Reboot KOReader

The device.lua changes are documented in devica.lua.patch


## Contributions

I have tested this only on a Clara 2E, all contributions are welcome. Here are some reading materials on this topic:
https://www.mobileread.com/forums/showthread.php?p=4444741#post4444741
https://github.com/koreader/koreader/issues/9059


