#!/bin/bash

# An set of disks to ignore from partitioning and formatting
BLACKLIST="/dev/sdz"

usage() {
    echo "Usage: $(basename $0) <new disk>"
}

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "${BLACKLIST}"|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=${UUID}\t${MOUNTPOINT}\text4\tdefaults,nofail\t1 2"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

add_cifs_to_fstab() {
    SHARE=${1}
    MOUNTPOINT=${2}
    grep "${SHARE}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${SHARE} to fstab again (it's already there!)"
    else
        LINE="${SHARE}\t${MOUNTPOINT}\tcifs\t_netdev,vers=3.0,username=rhelfileshare01,password=6ZW+IS3Ezuv77dvghsoVnV2V9UOu8uJQPQ9G3dqcokkskpolveYGpnFQCZfUoQKZBFxvpv746b6U9SaIl3ocAQ==,dir_mode=0777,file_mode=0777,uid=500,gid=500\t0 0"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

is_partitioned() {
# Checks if there is a valid partition table on the
# specified disk
    OUTPUT=$(sfdisk -l ${1} 2>&1)
    grep "No partitions found" "${OUTPUT}" >/dev/null 2>&1
    return "${?}"       
}

has_filesystem() {
    DEVICE=${1}
    OUTPUT=$(file -L -s ${DEVICE})
    grep filesystem <<< "${OUTPUT}" > /dev/null 2>&1
    return ${?}
}

do_partition() {
# This function creates one (1) primary partition on the
# disk, using all available space
    DISK=${1}
    echo "n
p
1


w"| fdisk "${DISK}" > /dev/null 2>&1

#
# Use the bash-specific $PIPESTATUS to ensure we get the correct exit code
# from fdisk and not from echo
if [ ${PIPESTATUS[1]} -ne 0 ];
then
    echo "An error occurred partitioning ${DISK}" >&2
    echo "I cannot continue" >&2
    exit 2
fi
}

##########  START HERE ##########

if [ -z "${1}" ];
then
    DISKS=($(scan_for_new_disks))
else
    DISKS=("${@}")
fi
echo "Disks are ${DISKS[@]}"
DISK=${DISKS[0]}
echo "Working on ${DISK}"

is_partitioned ${DISK}
if [ ${?} -ne 0 ];
then
    echo "${DISK} is not partitioned, partitioning"
    do_partition ${DISK}
fi
PARTITION=$(fdisk -l ${DISK}|grep -A 1 Device|tail -n 1|awk '{print $1}')
has_filesystem ${PARTITION}
if [ ${?} -ne 0 ];
then
    echo "Creating filesystem on ${PARTITION}."
    #echo "Press Ctrl-C if you don't want to destroy all data on ${PARTITION}"
    #sleep 5
    mkfs -t ext4 ${PARTITION}
fi
MOUNTPOINT=/cft
echo "Mount point is ${MOUNTPOINT}"
[ -d "${MOUNTPOINT}" ] || mkdir "${MOUNTPOINT}"
read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
add_to_fstab "${UUID}" "${MOUNTPOINT}"
echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
mount "${MOUNTPOINT}"
chmod go+w "${MOUNTPOINT}"

AZUREFILES=/axway
echo "Azure Fileshare path is ${AZUREFILES}"
[ -d "${AZUREFILES}" ] || mkdir "${AZUREFILES}"
SHARE=//rhelfileshare01.file.core.windows.net/axway
add_cifs_to_fstab "${SHARE}" "${AZUREFILES}"
echo "Mounting Azure share ${SHARE} on ${AZUREFILES}"
mount "${AZUREFILES}"
chmod go+w "${AZUREFILES}"
