#!/bin/sh
set -e

### Meebey's HDD Benchmark Script v0.2 ###
# Boot with: mem=1g (else bonnie++ will do cached reads!)
#
# Copyright (C) 2012 Mirco Bauer <meebey@meebey.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# REQUIRED TOOLS
if ! which parted > /dev/null; then echo "no parted!"; exit 1; fi
if ! which smartctl > /dev/null; then echo "no parted!"; exit 1; fi
if ! which blockdev > /dev/null; then echo "no blockdev!"; exit 1; fi
if ! which fio > /dev/null; then echo "no fio!"; exit 1; fi
if ! which mkfs.ext3 > /dev/null; then echo "no mkfs.ext3!"; exit 1; fi
if ! which wget > /dev/null; then echo "no wget!"; exit 1; fi

if [ "$1" = "--help" ]; then
	echo "Usage: $0 [--destroy-my-data] [--tune-kernel] [--verbose] [device-name]"
	exit 0
fi

DO_WRITE=0
if [ "$1" = "--destroy-my-data" ]; then
	DO_WRITE=1
	shift
fi
TUNE_KERNEL=0
if [ "$1" = "--tune-kernel" ]; then
	TUNE_KERNEL=1
	shift
fi
DEBUG=0
if [ "$1" = "-v" -o "$1" = "--verbose" ]; then
	DEBUG=1
	shift
fi
HDD=$1
if [ -z "$HDD" ]; then
	while test -z "$HDD"; do
		echo -n "Enter device name (e.g. sda): "
		read HDD
		if [ ! -z "$HDD" ] && [ ! -b "/dev/$HDD" ]; then
			echo "Invalid device name!"
			HDD=
		fi
	done
else
	if [ ! -b "/dev/$HDD" ]; then
		echo "Invalid device name: /dev/$HDD!"
		exit 1
	fi
fi

# SETUP
HDD_DEV=/dev/$HDD
HDD_P1=${HDD_DEV}1
if [ -z "$HDD" ]; then
	echo "No device name defined!"
	exit 1
fi
if [ -z "$DO_WRITE" ]; then
	# just in case
	DO_WRITE=0
fi
if [ "$DEBUG" = 1 ]; then
	echo DO_WRITE=$DO_WRITE
	echo TUNE_KERNEL=$TUNE_KERNEL
	echo HDD=$HDD
	echo HDD_DEV=$HDD_DEV
	echo HDD_P1=$HDD_P1
fi

COLUMNS=$(tput cols)
if [ -z "$COLUMNS" ]; then
	COLUMNS=80
fi
DEVIDER=$(printf "%${COLUMNS}s" ' ' | sed 's/ /-/g')
echo $DEVIDER

# SYSTEM INFORMATION
smartctl -i $HDD_DEV | egrep "Model|Firmware|Capacity"
echo $DEVIDER
grep name /proc/cpuinfo | uniq
cat /sys/devices/system/cpu/cpu*/topology/core_id | wc -l
cat /sys/devices/system/cpu/cpu*/topology/core_id | sort | uniq | wc -l
uname -a
# limited to 1 GB
grep Memory: /var/log/dmesg
dd if=/dev/zero of=/dev/null bs=32M count=1000
lspci | grep AHCI
egrep -h 'ata[0-9]\.|SATA link up' /var/log/dmesg /var/log/kern.log
blockdev --getra $HDD_DEV

# SECURE ERASE
if grep -q 0 /sys/block/$HDD/queue/rotational; then
	if [ "$DEBUG" = 1 ]; then
		echo "FOUND NON-ROTIONAL DISK (SSD)"
	fi
	if [ $TUNE_KERNEL = 1 ]; then
		if [ "$DEBUG" = 1 ]; then
			echo "TUNING KERNEL..."
		fi
		echo noop > /sys/block/$HDD/queue/scheduler
		if [ -w /sys/block/$HDD/queue/add_random ]; then
			echo 0 > /sys/block/$HDD/queue/add_random
		fi
	fi

	if [ $DO_WRITE = 1 ]; then
		if [ "$DEBUG" = 1 ]; then
			echo "PERFORMING SECURE ERASE OF $HDD_DEV..."
		fi
		if ! which hdparm > /dev/null; then echo "no hdparm!"; exit 1; fi
		hdparm --user-master u --security-set-pass secret $HDD_DEV
		time hdparm --user-master u --security-erase secret $HDD_DEV
	fi
fi
cat /sys/block/$HDD/queue/scheduler
cat /sys/block/$HDD/device/queue_depth
echo $DEVIDER

# STOCK
if [ $DO_WRITE = 1 ]; then
	fio --filename=$HDD_DEV --direct=1 --rw=write --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1
	sleep 10
	fio --filename=$HDD_DEV --direct=1 --rw=randwrite --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1 --ioengine=libaio --iodepth=32
	sleep 10
fi
fio --readonly --filename=$HDD_DEV --direct=1 --rw=read --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1
fio --readonly --filename=$HDD_DEV --direct=1 --rw=randread --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1 --ioengine=libaio --iodepth=32

if [ ! -x /tmp/seeker_baryluk_amd64 ]; then
	cd /tmp; wget -q http://debian.gsd-software.net/benchmark/seeker_baryluk_amd64; chmod +x seeker_baryluk_amd64
fi
for threads in 01 02 04 08 16 32; do echo -n "Threads: $threads "; /tmp/seeker_baryluk_amd64 $HDD_DEV $threads | grep Results; sleep 1; done
#rm /tmp/seeker_baryluk_amd64

echo 3 > /proc/sys/vm/drop_caches
dd if=$HDD_DEV of=/dev/null bs=1M count=16000
if [ $DO_WRITE = 1 ]; then
	dd if=/dev/zero of=$HDD_DEV bs=1M count=16000
	sleep 10

	if ! which bonnie++ > /dev/null; then echo "no bonnie++!"; exit 1; fi

	blockdev --rereadpt $HDD_DEV && sleep 3
	parted $HDD_DEV mklabel msdos
	parted $HDD_DEV mkpart p 2048s 64g; sleep 3
	blockdev --rereadpt $HDD_DEV && sleep 3
	mkfs.ext3 $HDD_P1
	mount -o noatime $HDD_P1 /mnt
	echo 3 > /proc/sys/vm/drop_caches
	bonnie++ -f -n 128:4096:4096 -r 24000 -d /mnt -u root
	umount /mnt
fi
echo $DEVIDER

if [ $DO_WRITE = 1 ]; then
	# WRITE ONCE
	fio --filename=$HDD_DEV --direct=1 --rw=write --bs=1M --numjobs=1 --group_reporting --name=file1
	sleep 10

	fio --filename=$HDD_DEV --direct=1 --rw=write --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1
	sleep 10
	fio --filename=$HDD_DEV --direct=1 --rw=randwrite --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1 --ioengine=libaio --iodepth=32
	sleep 10
fi
fio --readonly --filename=$HDD_DEV --direct=1 --rw=read --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1
fio --readonly --filename=$HDD_DEV --direct=1 --rw=randread --bs=4k --runtime=60 --numjobs=1 --group_reporting --name=file1 --ioengine=libaio --iodepth=32

if [ ! -x /tmp/seeker_baryluk_amd64 ]; then
	cd /tmp; wget -q http://debian.gsd-software.net/benchmark/seeker_baryluk_amd64; chmod +x seeker_baryluk_amd64
fi
for threads in 01 02 04 08 16 32; do echo -n "Threads: $threads "; /tmp/seeker_baryluk_amd64 $HDD_DEV $threads | grep Results; sleep 1; done
rm /tmp/seeker_baryluk_amd64

echo 3 > /proc/sys/vm/drop_caches
dd if=$HDD_DEV of=/dev/null bs=1M count=16000
if [ $DO_WRITE = 1 ]; then
	dd if=/dev/zero of=$HDD_DEV bs=1M count=16000
	sleep 10
	
	blockdev --rereadpt $HDD_DEV && sleep 3
	parted $HDD_DEV mklabel msdos
	parted $HDD_DEV mkpart p 2048s 64g; sleep 3
	blockdev --rereadpt $HDD_DEV && sleep 3
	mkfs.ext3 $HDD_P1
	mount -o noatime $HDD_P1 /mnt
	echo 3 > /proc/sys/vm/drop_caches
	bonnie++ -f -n 128:4096:4096 -r 24000 -d /mnt -u root
	umount /mnt
fi
echo $DEVIDER

# SECURE ERASE
if grep -q 0 /sys/block/$HDD/queue/rotational; then
	if [ "$DEBUG" = 1 ]; then
		echo "FOUND NON-ROTIONAL DISK (SSD)"
	fi
	if [ $DO_WRITE = 1 ]; then
		if [ "$DEBUG" = 1 ]; then
			echo "PERFORMING SECURE ERASE OF $HDD_DEV..."
		fi
		hdparm --user-master u --security-set-pass secret $HDD_DEV
		time hdparm --user-master u --security-erase secret $HDD_DEV
		echo $DEVIDER
	fi
fi