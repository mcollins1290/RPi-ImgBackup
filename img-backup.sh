#!/bin/bash
set -B

####################### VARIABLES #######################
PARTITION_TABLE_FILE="/dev/mmcblk0"
BOOT_PARTITION_FILE="/dev/mmcblk0p1"
ROOT_PARTITION_FILE="/dev/mmcblk0p2"
TMP_DIRECTORY=/tmp/RPi-ImgBackup # No need to include / on the end
BACKUP_DIRECTORY=/media/raid1/Backups/imgs/$HOSTNAME # No need to include / on the end
IMAGE_FILENAME=$HOSTNAME"_"$(date +%Y-%m-%d_%H-%M-%S)".img"
ZIP_FILENAME=$IMAGE_FILENAME".zip"
DEST_ROOT_BUFFER=40 # as a %
DEST_ROOT_SET_MAX_MOUNT_COUNT=True # True or False
DEST_ROOT_MAX_MOUNT_COUNT_VALUE=1
ZIP_IMG_FILE=False
DBG_STEP_TIMINGS=False
#########################################################

# Check to see if script is being run as root
if [ $(id -u) -ne 0 ]; then
	printf "ERROR: Image Backup Script must be run as root. Try '$0'\n"
	exit 1
fi

# Check if required apps are installed
apps=( "awk" "column" "cp" "df" "du" "fdisk" "grep" "losetup" "lsblk" "mount" "umount" "mkfs.ext4" "mkfs.vfat" "parted" "rsync" "sed" "sync" "tail" "truncate" "zip" "tune2fs" )
for i in "${apps[@]}"
do
	if ! [ -x "$(command -v $i)" ]; then
		echo "ERROR: $i could not be found."
	exit 1
fi
done
#

# Check source PARTITION TABLE, BOOT and ROOT partitions exist
if [ ! -e $PARTITION_TABLE_FILE ]; then
	echo "ERROR: Partition table '$PARTITION_TABLE_FILE' does not exist!"
	exit 1
fi
if [ ! -e $BOOT_PARTITION_FILE ]; then
        echo "ERROR: BOOT Partition '$BOOT_PARTITION_FILE' does not exist!"
	exit 1
fi
if [ ! -e $ROOT_PARTITION_FILE ]; then
        echo "ERROR: ROOT Partition '$ROOT_PARTITION_FILE' does not exist!"
	exit 1
fi
#

# Check whether TMP directory exists and if not, create it
if [ ! -d $TMP_DIRECTORY ]; then
        mkdir -p $TMP_DIRECTORY
        if [ ! -d $TMP_DIRECTORY ]; then
                echo "ERROR: Unable to create Temp Directory - [$TMP_DIRECTORY]"
                exit 1
        fi
fi
#

# Check whether Backup directory exists
if [ ! -d $BACKUP_DIRECTORY ]; then
	echo "ERROR: Backup Directory [$BACKUP_DIRECTORY] does not exist."
	exit 1
fi
#

# Obtain Disk Identifer and Partition labels for BOOT & ROOT
SOURCE_PTUUID=$(fdisk -l $PARTITION_TABLE_FILE | sed -n 's/Disk identifier: 0x\([^ ]*\)/\1/p')
SOURCE_BOOT_LABEL=$(lsblk -dn $BOOT_PARTITION_FILE -o LABEL)
SOURCE_ROOT_LABEL=$(lsblk -dn $ROOT_PARTITION_FILE -o LABEL)

echo "      Source Disk Identifer: $SOURCE_PTUUID"
echo "Source BOOT Partition Label: $SOURCE_BOOT_LABEL"
echo "Source ROOT Partition Label: $SOURCE_ROOT_LABEL"
echo ""
#

# Obtain number of Sectors used by BOOT partition (and subtract 1 for fdisk usage later)
SOURCE_BOOT_SECTORS=$(($(fdisk -l | grep ^$BOOT_PARTITION_FILE |  awk -F" "  '{ print $4 }')-1))

# Obtain Mount points for BOOT and ROOT
SOURCE_BOOT_MOUNTPOINT=$(lsblk -dn $BOOT_PARTITION_FILE -o MOUNTPOINT)
SOURCE_ROOT_MOUNTPOINT=$(lsblk -dn $ROOT_PARTITION_FILE -o MOUNTPOINT)

# Obtain total size of BOOT & used size of ROOT Partitions
SOURCE_BOOT_TOTAL_SIZE=$(df --block-size=1010k --output=size $SOURCE_BOOT_MOUNTPOINT | tail -n +2 | column -t)
SOURCE_ROOT_USED_SIZE=$(du --block-size=1010k --summarize --exclude={boot,dev,proc,sys,tmp,run,mnt,media,lost+found,var/swap,var/tmp} $SOURCE_ROOT_MOUNTPOINT | awk '{print $1}')

# Determine size of BOOT & ROOT Partitions on Destination Image
DEST_BOOT_SIZE=$SOURCE_BOOT_TOTAL_SIZE
DEST_ROOT_SIZE=$(((($SOURCE_ROOT_USED_SIZE / 100 )*$DEST_ROOT_BUFFER) + $SOURCE_ROOT_USED_SIZE)) # Add % as a buffer

# Add Destination BOOT & ROOT sizes together to determine total size needed for image
DEST_IMAGE_SIZE=$(($DEST_BOOT_SIZE + $DEST_ROOT_SIZE))

# Output Image Backup Started message
s_timestamp=$(date +'%s')
dt=$(date -d @$s_timestamp '+%m/%d/%Y %H:%M:%S');
printf "IMAGE BACKUP PROCESS STARTED ON $dt\n"
#

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Stage 1: Create initial RAW image
echo "Stage 1: Create initial RAW Image file"
IMAGE_FILE=$BACKUP_DIRECTORY/$IMAGE_FILENAME
truncate -s $DEST_IMAGE_SIZE"M" $IMAGE_FILE >& /dev/null
if [ ! -f $IMAGE_FILE ]; then
	echo "ERROR: Failed to create RAW Image file - [$IMAGE_FILE]."
	exit 1
fi
#

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Finished message
	stepfinish_timestamp=$(date +'%s')
	dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP FINISHED ON $dt\n"
	dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

	h=$(( dur / 3600 ))
	m=$(( ( dur / 60 ) % 60 ))
	s=$(( dur % 60 ))

	printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	#
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Stage 2: Create and format Partitions in RAW image
echo "Stage 2: Create and format Partitions in RAW Image file"
# Create Partition Table
parted $IMAGE_FILE mklabel msdos
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to create Partition table in RAW Image file. Exit Code: $?"
	exit 1
fi
# Set RAW Image PTUUID to Source PTUUID
(
echo x #Extra functionality
echo i #Change Disk Identifier Option
echo 0x$SOURCE_PTUUID #Specify new PTUUID
echo r #Return to Main Menu Option
echo w #Write changes
) | fdisk $IMAGE_FILE > /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to change RAW Image file Disk Identifer to: 0x"$SOURCE_PTUUID"."
	exit 1
fi
# Create BOOT Partition
(
echo n #New Partition
echo p #Primary
echo 1 #Partition #1
echo   #First sector (Accept default)
echo +"$SOURCE_BOOT_SECTORS" #No. of Sectors from BOOT Partition on Source
echo t #Change Partition Type Option
echo c #Change Partition Type to 'W95 FAT32 (LBA)'
echo w #Write changes
) | fdisk $IMAGE_FILE > /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to create "$DEST_BOOT_SIZE"MB BOOT Partition in RAW Image file."
	exit 1
fi
# Create ROOT Partition
(
echo n #New Partition
echo p #Primary
echo 2 #Partition #2
echo   #First sector (Accept default)
echo   #Last sector (Accept default)
echo w #Write changes
) | fdisk $IMAGE_FILE > /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to create "$DEST_ROOT_SIZE"MB ROOT Partition in RAW Image file."
	exit 1
fi
# Mount RAW Image as a loop device
LOOP_DEV=$(losetup -fP --show $IMAGE_FILE)
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to create Loop device using RAW Image file."
	exit 1
fi
# Format BOOT Partition
mkfs.vfat -F 32 -n "$SOURCE_BOOT_LABEL" -s 4 "$LOOP_DEV"p1 >& /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to format the BOOT Partition in the RAW Image file."
	exit 1
fi
# Format ROOT Partition
mkfs.ext4 -b 4096 -L "$SOURCE_ROOT_LABEL" -q  "$LOOP_DEV"p2 >& /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to format the ROOT Partition in the RAW Image file."
	exit 1
fi
# Set Max Mount Count on ROOT Partition
if [ "$DEST_ROOT_SET_MAX_MOUNT_COUNT" = True ] ; then
	echo "Stage 2a: Set ROOT Max Mount Count to $DEST_ROOT_MAX_MOUNT_COUNT_VALUE."
	tune2fs -c "$DEST_ROOT_MAX_MOUNT_COUNT_VALUE" "$LOOP_DEV"p2 >& /dev/null

	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to set ROOT Max Mount Count."
		exit 1
	fi
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Finished message
	stepfinish_timestamp=$(date +'%s')
	dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP FINISHED ON $dt\n"
	dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

	h=$(( dur / 3600 ))
	m=$(( ( dur / 60 ) % 60 ))
	s=$(( dur % 60 ))

	printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	#
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Stage 3a & 3b: Copy Source files to Partitions in RAW image
# Estlabish BOOT and ROOT Directory in Work Directory and mount them
DEST_BOOT_DIR="$TMP_DIRECTORY/boot"
DEST_ROOT_DIR="$TMP_DIRECTORY/"

# Mount ROOT Directory
mount "$LOOP_DEV"p2 $DEST_ROOT_DIR >& /dev/null
if [ $? -ne 0 ]; then
        echo "ERROR: Failed to mount ROOT Directory in Image file."
        exit 1
fi

# Create BOOT Directory
mkdir $DEST_BOOT_DIR >& /dev/null
if [ ! -d $DEST_BOOT_DIR ]; then
        echo "ERROR: Failed to create BOOT Directory in Image file - [$DEST_BOOT_DIR]."
        exit 1
fi

# Mount BOOT Directory
mount "$LOOP_DEV"p1 $DEST_BOOT_DIR >& /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to mount BOOT Directory in Image file."
	exit 1
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Finished message
	stepfinish_timestamp=$(date +'%s')
	dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP FINISHED ON $dt\n"
	dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

	h=$(( dur / 3600 ))
	m=$(( ( dur / 60 ) % 60 ))
	s=$(( dur % 60 ))

	printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	#
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Populate BOOT Partition from Source
echo "Stage 3a: Copy Source BOOT files to BOOT Partition in RAW Image file"
cp --recursive $SOURCE_BOOT_MOUNTPOINT/. $DEST_BOOT_DIR >& /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to copy Source BOOT files to BOOT Partition in RAW Image file."
	exit 1
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Finished message
	stepfinish_timestamp=$(date +'%s')
	dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP FINISHED ON $dt\n"
	dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

	h=$(( dur / 3600 ))
	m=$(( ( dur / 60 ) % 60 ))
	s=$(( dur % 60 ))

	printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	#
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Populate ROOT Partition from Source
echo "Stage 3b: Copy Source ROOT files to ROOT Partition in RAW Image file"
rsync -aAX --exclude={"/boot/*","/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/var/swap","/var/tmp/*"} $SOURCE_ROOT_MOUNTPOINT $DEST_ROOT_DIR >& /dev/null
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to copy Source ROOT files to ROOT Partition in RAW Image file."
	exit 1
fi

#Run 'sync' to synchronize cached data to permanent storage
sync

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Finished message
	stepfinish_timestamp=$(date +'%s')
	dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP FINISHED ON $dt\n"
	dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

	h=$(( dur / 3600 ))
	m=$(( ( dur / 60 ) % 60 ))
	s=$(( dur % 60 ))

	printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	#
fi

if [ "$DBG_STEP_TIMINGS" = True ] ; then
	# Output Step Started message
	stepstart_timestamp=$(date +'%s')
	dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
	printf "STEP STARTED ON $dt\n"
	#
fi

# Stage 4: Unmount BOOT & ROOT Directories and delete LOOP device
echo "Stage 4: Cleanup following creation of .IMG file"
# Unmount BOOT Directory
umount $DEST_BOOT_DIR
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to unmount temporary BOOT Directory."
	exit 1
fi
# Unmount ROOT Directory
umount $DEST_ROOT_DIR
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to unmount temporary ROOT Directory."
	exit 1
fi
# Delete loop device
losetup -d $LOOP_DEV
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to delete Loop device using RAW Image file."
	exit 1
fi
#

if [ "$DBG_STEP_TIMINGS" = True ] ; then
        # Output Step Finished message
        stepfinish_timestamp=$(date +'%s')
        dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
        printf "STEP FINISHED ON $dt\n"
        dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

        h=$(( dur / 3600 ))
        m=$(( ( dur / 60 ) % 60 ))
        s=$(( dur % 60 ))

        printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
        #
fi

if [ "$ZIP_IMG_FILE" = True ] ; then
        if [ "$DBG_STEP_TIMINGS" = True ] ; then
                # Output Step Started message
                stepstart_timestamp=$(date +'%s')
                dt=$(date -d @$stepstart_timestamp '+%m/%d/%Y %H:%M:%S');
                printf "STEP STARTED ON $dt\n"
                #
        fi

        # Stage 5: Create ZIP of .IMG file
        echo "Stage 5: Create ZIP of .IMG file"

        # Create ZIP file of RAW Image file
        zip -j $BACKUP_DIRECTORY/$ZIP_FILENAME $IMAGE_FILE >& /dev/null
        if [ $? -ne 0 ]; then
	        echo "ERROR: Failed to create ZIP file of RAW Image file."
	        exit 1
        fi

        BACKUP_FILENAME=$ZIP_FILENAME

        if [ "$DBG_STEP_TIMINGS" = True ] ; then
	        # Output Step Finished message
                stepfinish_timestamp=$(date +'%s')
                dt=$(date -d @$stepfinish_timestamp '+%m/%d/%Y %H:%M:%S');
                printf "STEP FINISHED ON $dt\n"
                dur="$(($stepfinish_timestamp-$stepstart_timestamp))"

                h=$(( dur / 3600 ))
                m=$(( ( dur / 60 ) % 60 ))
                s=$(( dur % 60 ))

                printf "Step Duration: %02d:%02d:%02d\n\n" $h $m $s
	        #
        fi
else
        BACKUP_FILENAME=$IMAGE_FILENAME
fi

# Output Image Backup Finished message
f_timestamp=$(date +'%s')
dt=$(date -d @$f_timestamp '+%m/%d/%Y %H:%M:%S');
printf "IMAGE BACKUP PROCESS FINISHED ON $dt\n"
dur="$(($f_timestamp-$s_timestamp))"

h=$(( dur / 3600 ))
m=$(( ( dur / 60 ) % 60 ))
s=$(( dur % 60 ))

printf "Duration: %02d:%02d:%02d\n\n" $h $m $s
# Output Backup details
BACKUP_DETAILS=$(ls -sh $BACKUP_DIRECTORY/$BACKUP_FILENAME)
printf "Backup Details: $BACKUP_DETAILS\n\n"
# Delete Prior Backups in Backup Directory (if any exist)
BACKUPS_TO_DELETE=$(find $BACKUP_DIRECTORY/ -type 'f' | grep -v "$BACKUP_FILENAME")

if [ -n "$BACKUPS_TO_DELETE" ]; then
	printf "Deleted the following previous backups:\n$BACKUPS_TO_DELETE\n\n"
	rm -f $BACKUPS_TO_DELETE
else
	printf "There are no previous backups to delete.\n\n"
fi
#

echo "Process completed successfully."
exit 0
