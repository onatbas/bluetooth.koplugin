#!/bin/bash
cd "$(dirname "$0")"

# Check if bluetoothd is running
if pgrep bluetoothd > /dev/null
then
    echo "bluetoothd is running."

    echo "Turning off Bluetooth and killing bluetoothd."
#    bluetoothctl power off
    pkill bluetoothd

    echo "Remove uhid.ko.."
    sh ./removeuhid.sh

    echo "Killing hciattach.."
    pkill hciattach

    echo "Success.."

else
    echo "bluetoothd is not running. No action taken."
fi
