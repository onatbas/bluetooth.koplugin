#!/bin/bash
cd "$(dirname "$0")"

../../enable-wifi.sh
insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko
insmod ./uhid/uhid.ko
/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20
dbus-send --system --dest=org.bluez --print-reply  /  org.freedesktop.DBus.ObjectManager.GetManagedObjects
hciconfig hci0 up
