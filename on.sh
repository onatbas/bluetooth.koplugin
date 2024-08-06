#!/bin/bash

# Check if bluetoothd is running
if ! pgrep bluetoothd > /dev/null
then
    echo "bluetoothd is not running. Starting bluetoothd and turning on Bluetooth."
    /libexec/bluetooth/bluetoothd  > /dev/null 2>&1 &
    timeout 2s bluetoothctl power on
else
    echo "bluetoothd is already running. No action taken."
fi

