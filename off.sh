#!/bin/bash
cd "$(dirname "$0")"

hciconfig hci0 down
pkill hciattach
pkill bluetoothd
rmmod -w /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko
rmmod -w  ./uhid/uhid.ko