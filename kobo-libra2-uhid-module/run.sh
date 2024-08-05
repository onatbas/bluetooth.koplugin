#!/bin/sh

insmod /mnt/onboard/.adds/kobo-libra2-uhid-module/uhid.ko
lsmod | grep "uhid"