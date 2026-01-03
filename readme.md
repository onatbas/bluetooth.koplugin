# Bluetooth Page Turner for Kobo

Use a Bluetooth controller (like 8BitDo Micro) to turn pages and control KOReader on your Kobo.

## Supported Devices

| Device | Chipset | Status |
|--------|---------|--------|
| Kobo Clara 2E | i.MX6 | ✅ Fully tested |
| Kobo Libra 2 | i.MX6 | ✅ Fully tested |
| Other i.MX6 Kobos | i.MX6 | ⚠️ May work (auto-detection) |
| Kobo Clara BW | MTK | ⚠️ Experimental |
| Kobo Clara Colour | MTK | ⚠️ Experimental |
| Kobo Libra Colour | MTK | ✅ Community Tested |
| Kobo Elipsa 2E | MTK | ⚠️ Experimental |

## MTK Device Support (Experimental)

Support for MediaTek-based Kobo devices (Clara BW/Colour, Libra Colour, Elipsa 2E) is **experimental**, tests are conducted by community members; [Libra Colour](https://www.mobileread.com/forums/showpost.php?p=4557375&postcount=83) .

### How It Works

MTK devices use a completely different Bluetooth stack than older i.MX6 devices:
- **i.MX6 devices**: Use `bluetoothctl` and `hciattach`
- **MTK devices**: Use D-Bus service `com.kobo.mtk.bluedroid`

The plugin auto-detects your device type and uses the appropriate method.

### MTK-Specific Features

- Bluetooth on/off via D-Bus (no kernel modules to load)
- Device scanning and pairing via D-Bus
- Smart input device detection using `uhid` pattern in `/sys/class/input/`
- Device name matching between D-Bus and kernel input devices

### Known Issues (MTK)

**Kernel Panic on Nickel Return**: Due to non-idempotent MediaTek kernel drivers, returning to Nickel after using Bluetooth in KOReader may cause a kernel panic and device reboot. This is a known hardware/driver issue that cannot be fixed by the plugin.

**Workaround**: Reboot your device before returning to Nickel if you've used Bluetooth.

### Credits

MTK Bluetooth support made possible by the excellent investigation and documentation by **OGKevin** and the kobo.koplugin project. Their thorough research into the MediaTek D-Bus interface (`com.kobo.mtk.bluedroid`) saved countless hours of reverse engineering.

---

## Installation

### Step 1: Copy the Plugin

1. Download this folder
2. Rename to `bluetooth.koplugin`
3. Copy to `plugins/` on your Kobo koreader
4. Restart KOReader

### Step 2: Run Diagnostics & Auto-Fix

In KOReader, go to **☰ → Network → Bluetooth → Diagnostics**

Click any item marked with ✗ and choose **"Correct Automatically"**:
- **hasKeys flag** - Required for button input to work
- **Event map** - Default button mappings for 8BitDo controllers

### Step 3: Turn On Bluetooth & Pair Your Controller

1. Go to **Bluetooth → Bluetooth On**
2. Put your controller in pairing mode
3. Go to **Bluetooth → Device Management**
4. Click **"Start scanning (30s)"**
5. Click **"Select from scanned devices"** → choose your controller
6. Your controller is now saved!

### Step 4: Connect

Whenever you want to use your controller:
1. **Bluetooth → Bluetooth On**
2. **Device Management → Connect to saved device**

That's it! 🎉

### Step 5 (Optional): Customize Button Mappings

The plugin comes pre-configured for **8BitDo Micro** in keyboard mode. If you're using a different controller or want to customize:

**Option A: Use the Event Map Editor**

Go to **Bluetooth → Event Map Editor** to:
- View current mappings (key code → event)
- Add new button mappings
- Change or delete existing mappings

To find your button's key code:
1. Go to **Diagnostics → Monitor raw input (5 sec)**
2. Press buttons on your controller
3. Note the key codes shown
4. Add them in Event Map Editor

**Option B: Edit bank_config.txt**

The bank system lets the same buttons do different things. Edit `bank_config.txt` in the plugin folder:

```
Bank1
BTAction1:BTLeft, A button - previous page
BTAction2:BTRight, B button - next page
BTAction3:BTToggleBookmark, Y button

Bank2
BTAction1:BTIncreaseBrightness, A button
BTAction2:BTDecreaseBrightness, B button
```

Switch banks using buttons mapped to `BTRemoteNextBank` / `BTRemotePrevBank`.

---

## Features

### Auto-Configuration
Everything is automatic:
- ✅ Installation path detection
- ✅ Device-specific Bluetooth commands (Clara 2E vs Libra 2)
- ✅ Input device path (event3/event4)
- ✅ Button mappings
- ✅ hasKeys override

### Device Management
Scan, select, and save Bluetooth devices directly from the UI. No more editing scripts!

### Event Map Editor
**Bluetooth → Event Map Editor**

View and edit button-to-event mappings:
- See all current mappings (key code → event)
- Add new mappings
- Delete or change existing mappings
- Changes take effect immediately

### Diagnostics
**Bluetooth → Diagnostics**

Live status of your configuration:
- 🔵 Bluetooth status (ON/OFF)
- ✓/✗ indicators for each configuration item
- Click for details and auto-fix options
- Debug tools for troubleshooting

### Bank System
Map the same physical buttons to different actions by switching banks.

Edit `bank_config.txt` to customize:
```
Bank1
BTAction1:BTLeft, A button
BTAction2:BTRight, B button
BTAction3:BTToggleBookmark, Y button

Bank2
BTAction1:BTIncreaseBrightness, A button
BTAction2:BTDecreaseBrightness, B button
BTAction3:BTToggleNightMode, Y button
```
The bank system lets you use the same buttons for different functions by switching between "banks" of button mappings. Perfect for controllers with limited buttons - sacrifice one button for bank switching and gain access to unlimited functionality.


Switch banks using BTRemoteNextBank/BTRemotePrevBank.

Bank system is intended for controllers with fewer buttons than intended number of functions. By sacrificing one or two buttons to cycle through banks, the user can now have access to virtually infinite number of banks and functionality.
---

## Troubleshooting

### Buttons Not Working?

1. **Check Diagnostics** - All items should show ✓
2. **Check Event Map** - Your button codes should be mapped
3. **Use Raw Input Monitor** - Diagnostics → Monitor raw input (5 sec)
   - Press buttons to see their key codes
   - Add unmapped codes via Event Map Editor

### Controller Not Connecting?

1. Make sure Bluetooth is ON (check Diagnostics)
2. Ensure controller is paired via Nickel first
3. Use Device Management → Select from paired devices

### "No devices found" When Scanning?

1. Make sure Bluetooth is ON
2. Put controller in pairing mode
3. Wait for scan to complete (30 seconds)

---

## Available BT Events

### Page Navigation
- `BTLeft` / `BTRight` - Previous/next page (orientation-aware)
- `BTGotoPrevChapter` / `BTGotoNextChapter` - Chapter navigation

### Bookmarks
- `BTToggleBookmark` - Add/remove bookmark
- `BTPrevBookmark` / `BTNextBookmark` - Navigate bookmarks
- `BTLastBookmark` - Jump to most recent bookmark

### Display
- `BTIncreaseBrightness` / `BTDecreaseBrightness`
- `BTIncreaseWarmth` / `BTDecreaseWarmth`
- `BTToggleNightMode`
- `BTToggleStatusBar`
- `BTIterateRotation` - Rotate screen 90°
- `BTRefreshScreen`

### Font
- `BTIncreaseFontSize` / `BTDecreaseFontSize`
- `BTIncreaseFontWeight` / `BTDecreaseFontWeight`
- `BTIncreaseLineSpacing` / `BTDecreaseLineSpacing`

### System
- `BTBluetoothOff` - Turn off Bluetooth
- `BTBluetoothOffAndSleep` - Turn off and sleep
- `BTSleep` - Put device to sleep

### Bank Navigation
- `BTRemoteNextBank` / `BTRemotePrevBank` - Switch button banks

### Bank Actions
- `BTAction1` through `BTAction20` - Configurable via bank_config.txt

---

## Credits

- Tested on Clara 2E and Libra 2
- Libra 2 support thanks to MobileRead user **enji**
- MTK device support thanks to **OGKevin** (kobo.koplugin project) for the comprehensive Bluetooth investigation and D-Bus documentation
- MTK device testing thanks to MobileRead user **WaveEquation**
- 8BitDo Micro controller recommended

## Links

- [MobileRead Discussion](https://www.mobileread.com/forums/showthread.php?p=4444741)
- [KOReader Bluetooth Issue](https://github.com/koreader/koreader/issues/9059)
- [kobo.koreader Bluetooth Investigation](https://ogkevin.github.io/kobo.koplugin/dev/investigations/bluetooth/00-overview.html)

## License

This software is provided under the [MIT License](LICENSE). See [DISCLAIMER](DISCLAIMER) for important information.

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK**

This software interacts with low-level system components and hardware drivers. The authors and contributors are not liable for any damages, including but not limited to hardware damage, data loss, system instability, or loss of device functionality.

By using this software, you acknowledge that you understand the risks and are solely responsible for any consequences. Please read the [LICENSE](LICENSE) and [DISCLAIMER](DISCLAIMER) files for complete terms.
