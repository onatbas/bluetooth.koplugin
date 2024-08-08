#!/bin/bash
cd "$(dirname "$0")"

#echo "This is disabled, use nickelmenu to run bluetooth on."
# exit 0


# Check if bluetoothd is running
if ! pgrep bluetoothd > /dev/null
then
    echo "bluetoothd is not running."

#    echo "Killing getty and bluealsa"
#    pkill bluealsa &
#    pkill getty &
#    sleep 1

#    echo "bluealsastuff"
#    sh bluealsastuff.sh  > /dev/null 2>&1 &

    echo "Adding uhid.ko.."
    sh ./adduhid.sh

    echo "hci services.."
    sh ./runhci.sh  > /dev/null 2>&1 &
    sleep 1

    echo "Starting bluetoothd.."
    /libexec/bluetooth/bluetoothd  > /dev/null 2>&1 &

    echo "Sleep 1"
    sleep 1
    bluetoothctl power on


    echo "HCI0 up..."
    hciconfig hci0 up  > /dev/null 2>&1 &

    echo "Success.."
else
    echo "bluetoothd is already running. No action taken."
fi

exit 0

