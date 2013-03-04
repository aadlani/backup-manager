#!/bin/bash

# Check the command dependency
CMDS="date rsync find gpg tar"
for i in $CMDS
do
  command -v $i >/dev/null && continue || { echo "$i command not found."; exit 1; }
done


################################################################################
# Step #0: Data repository models
################################################################################

# Variable to configure
USER="aadlani"
EMAIL="anouar@adlani.com"
BACKUP_HOME="/Users/$USER/backups"
BACKUP_SOURCE_DIR="/Users/$USER/Documents"

# Dates
NOW=$(date +%Y%m%d%H%M)               #YYYYMMDDHHMM
YESTERDAY=$(date -v -1d +%Y%m%d)      #YYYYMMDD
PREVIOUSMONTH=$(date -v -1m +%Y%m)    #YYYYMM
TODAY=${NOW:0:8}                      #YYYYMMDD
THISMONTH=${TODAY:0:6}                #YYYYMM
THISYEAR=${TODAY:0:4}                 #YYYY

# Backup Configuration
LOGFILE="$BACKUP_HOME/backups.log"
CURRENT_LINK="$BACKUP_HOME/current"
SNAPSHOT_DIR="$BACKUP_HOME/snapshots"
ARCHIVES_DIR="$BACKUP_HOME/archives"
DAILY_ARCHIVES_DIR="$ARCHIVES_DIR/daily"
WEEKLY_ARCHIVES_DIR="$ARCHIVES_DIR/weekly"
MONTHLY_ARCHIVES_DIR="$ARCHIVES_DIR/monthly"

start_time=`date +%s`

# Init the folder structure
mkdir -p $SNAPSHOT_DIR  $DAILY_ARCHIVES_DIR $WEEKLY_ARCHIVES_DIR $MONTHLY_ARCHIVES_DIR &> /dev/null
touch $LOGFILE
printf "[%12d] Backup started\n" $NOW >> $LOGFILE

################################################################################
# Step #1: Retreive files to create snapshots with RSYNC.
################################################################################

rsync -azH --link-dest=$CURRENT_LINK  $BACKUP_SOURCE_DIR $SNAPSHOT_DIR/$NOW \
  && ln -snf $(ls -1d $SNAPSHOT_DIR/* | tail -n1) $CURRENT_LINK \
  && printf "\t- Copy from %s to %s successfull \n" $BACKUP_SOURCE_DIR $SNAPSHOT_DIR/$NOW >> $LOGFILE

################################################################################
# Step #2: Group and Compress the previous snaphots per days
################################################################################

# Go Through all the snapshots to find those eligible for backup
find $SNAPSHOT_DIR -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | \
  while read fileName
  do
    snapshotGroup=${fileName:0:8}   # YYYYMMDD
    # Archive and delete only if the snapshots are older than yesterday
    if [[ $snapshotGroup -le $YESTERDAY ]]
    then
      tar -czf $DAILY_ARCHIVES_DIR/$snapshotGroup.tar.gz -C $SNAPSHOT_DIR $(cd $SNAPSHOT_DIR && ls -dl1 $snapshotGroup*) \
        && rm -rf $SNAPSHOT_DIR/$snapshotGroup* \
        && printf "\t- Created archive %s and removed the folders starting with %s\n" $DAILY_ARCHIVES_DIR/$snapshotGroup.tar.gz $SNAPSHOT_DIR/$snapshotGroup >> $LOGFILE
    fi
  done

################################################################################
# Step #3: Encrypt the archives with PGP
################################################################################

# Step 3.1: If there are archives not encrypted, encrypt them and delete the archive
if [ $(ls -d $DAILY_ARCHIVES_DIR/*.tar.gz 2> /dev/null | wc -l) != "0" ]
then
  gpg -r $EMAIL --encrypt-files $DAILY_ARCHIVES_DIR/*.tar.gz \
    && rm -rf $DAILY_ARCHIVES_DIR/*.tar.gz \
    && printf "\t- Encrypted archive in %s and removed the unencrypted version\n" $DAILY_ARCHIVES_DIR  
fi

################################################################################
# Step #4: rotate the backups 
################################################################################

find -E $DAILY_ARCHIVES_DIR -type f -mindepth 1 -maxdepth 1 -regex '.*/[0-9]{8}\.tar\.gz\.gpg$' -exec basename {} \; | \
while read encryptedArchive
do
  archiveMonth=${encryptedArchive:0:6}

  # Step #4.1: Keep weekly backups for previous month
  if [[ $encryptedArchive =~ ^$PREVIOUSMONTH ]]; then
    archiveDay=${encryptedArchive:6:2}
    weekNum=$(((10#$archiveDay)/7))
    mv $DAILY_ARCHIVES_DIR/$encryptedArchive $WEEKLY_ARCHIVES_DIR/$PREVIOUSMONTH.WK_$weekNum.tar.gz.gpg \
      && printf "\t- Moved %s to %s\n" $DAILY_ARCHIVES_DIR/$encryptedArchive $WEEKLY_ARCHIVES_DIR/$PREVIOUSMONTH.WK_$weekNum.tar.gz.gpg >> $LOGFILE
  fi

  # Step #4.2: if the daily archive is older than the previous month we move it to monthly
  if [[ $archiveMonth -lt $PREVIOUSMONTH ]]; then
    mv -n $DAILY_ARCHIVES_DIR/$encryptedArchive $MONTHLY_ARCHIVES_DIR/$archiveMonth.tar.gz.gpg \
      && printf "\t- Moved %s to %s\n" $DAILY_ARCHIVES_DIR/$encryptedArchive $MONTHLY_ARCHIVES_DIR/$archiveMonth.tar.gz.gpg >> $LOGFILE
  fi
done 

# Step #4.3: Keep monthly backups for older backups
find -E $WEEKLY_ARCHIVES_DIR -mindepth 1 -maxdepth 1 -type f -regex '.*/[0-9]{6}\.WK_[1-4]\.tar\.gz\.gpg$' -exec basename {} \; | \
while read encryptedArchive
do
  archiveMonth=${encryptedArchive:0:6}
  if [[ $archiveMonth -lt $PREVIOUSMONTH ]]; then
    mv $WEEKLY_ARCHIVES_DIR/$encryptedArchive $MONTHLY_ARCHIVES_DIR/$archiveMonth.tar.gz.gpg \
      && printf "\t- Moved %s to %s\n" $WEEKLY_ARCHIVES_DIR/$encryptedArchive $MONTHLY_ARCHIVES_DIR/$archiveMonth.tar.gz.gpg >> $LOGFILE
  fi
done 

end_time=`date +%s`
printf "\t===== Backup execute successfully in %6d s. =====\n" $(($end_time - $start_time)) >> $LOGFILE
