#!/bin/bash

# Check if bluetoothd is running
if pgrep bluetoothd > /dev/null
then
    echo "bluetoothd is running. Turning off Bluetooth and killing bluetoothd."
    bluetoothctl power off
    pkill bluetoothd
else
    echo "bluetoothd is not running. No action taken."
fi
