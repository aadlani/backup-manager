ORIGINALY PUBLISHED ON MY BLOG AT: http://anouar.im/2011/12/how-to-backup-with-rsync-tar-gpg-on-osx.html

# Backup Manager: How to backup with RSYNC, TAR, CRON and GPG

the aim of this post is to describe how I have created my modest personal backup that I use during my working days. I will not expend myself on the importance of Backing up your files, but since it's not Rocket Science, I will spend more time describing the commands and tools I use with their related options since there are some unix tricks that are good to know.

created_on: 01/12/2011 22:15

## Context

I really like the principle of the Apple Time Capsule or the Dropbox,
that I use on my personal computers, but these solutions are not
suitable, at least in my case, for a corporate use. Time capsule is not
really scalable when you have too many connected machines and concerning
DropBox I'm not comfortable to store confidential documents in a shared
drive handle by a third company. That's why sometimes it's easier to use
what you have usually at your disposal, for my part that is to say a Unix
Operating System and all the tools that come with it.

As described in the title, I'm using exclusively Unix tools like RSYNC
for the remote copy, and CRON for the tasks scheduling and some other
Unix sugars to have this working all together. I have set a predefined
folder structure where I'm storing my backed up files, and have a file
archiver with a rotation system that compresses and groups snapshots
together.  

At the time I'm writing this article, I know that there are plenty
OpenSource softwares that provide nearly the same features that I'm
presenting here, but I like to do this kind of scripting task to train
myself. I love programming, I love practicing and for me the best way to
improve your skills is by practicing again and again and again...

So to sum up, the objective of this article is to create step by step a
simple but efficient backup solution with recognized standard tools to
provide at least the following features:

* **Regular**       : Scheduled at a regular frequency
* **Unobstructive** : ran as a background job and not require any manual intervention
* **Incremental**   : save only the  increments of change between points in time
* **Snapshots**     : Several instaneous copy of the concerned folder
* **Fast**          : Need to be executed rapidly without being blocker
* **Secured**       : To have the archives encrypted to be stored on external systems
* **Consistent**    : Need to preserve files, links, rights and dates

In the next 5 sections I'll try as far as I can to go about many details of the tools and
technics we will be using.

1. Data repository model
2. Retrieve files to create snapshots with RSYNC
3. Create encrypted and compressed archives
4. Schedule the backup tasks
5. final script and cron tab

## Data repository models

I'll start this section by describing the Folder structure that
represents my repository model, which aimed to be an incremental. 

### The layout

The folder structure that I'm using is composed by a main root folder
named `backup` here, within which I set 2 folders (`archives` and
`snapshots`) and a symbolic link named `current`.  I will explain the
responsibilities of all of them afterword, but first here is a small
representation of it:

```
backups
|-- archives
|   |-- 20111121.tar.gz.gpg
|   `-- 20111122.tar.gz.gpg
|-- current -> /tmp/backups/snapshots/201111232314
`-- snapshots
    |-- 201111232305
    |-- 201111232310
    `-- 201111232314
```

To keep things simple and to not bother you with understandable paths,
I'll handle this layout by defining the variables that I'll use in all
my future commands.

```bash
NOW=$(date +%Y%m%d%H%M)
YESTERDAY=$(date -v -1d +%Y%m%d)

# Backup Configuration
BACKUP_HOME="/tmp/backups"
CURRENT_LINK="$BACKUP_HOME/current"
SNAPSHOT_DIR="$BACKUP_HOME/snapshots"
ARCHIVES_DIR="$BACKUP_HOME/archives"
```

#### The Snapshots folder

The definition of Snapshot is a copy of your files at a given instant,
think of it as a Photo of your files by an instant camera. This kind of
backup are useful when you have several snapshots for the current day, to be able to recover easily a single file or folder from few hours earlier. 

We will need to take several snapshots a day, let's say one hourly
during the working day, which is not so huge since it will not exceed a dozen per day. For practical reasons, that you could figure out, they
are not compressed neither archived in order to recover a file easily. 

All the snapshots will be stored under
`backups/snapshots/YYYYMMDDHHMM/`.  And to keep snapshots fast and
efficient in term of disk usage, I will use hard links between
snapshots. This technic is available in RSYNC and will be detailed
below.

#### Archives

If we want to preserve your disc space, we should think about archiving old backups. No need to keep definitely all the snapshots folders since you rarely need to browse files older than one or two days. That's why we will create an archive everyday with the content of the previous day. 

All the previous snapshots will be gathered in an weekly, monthly and yearly encrypted backups archives. To do so we will use `tar`, compress with gunzip and encrypt with GnuPG.

#### Current

`current` is a symbolic link pointing to the last snapshot folder. This reference will be used in the future command lines, for example to request rsync to hard link to it.

## Retrieve files to create snapshots with RSYNC.

### Rsync

Rsync is an incremental file transfer software which synchronizes files
and directory from a source to a destination by sending only the delta
between them. Rsync is a good fit for our requirements, and has a lot of
options available that will let us tune it easily to our needs.

Here is the command we will use, with its options:

```bash
rsync --hard-links --archive --compress --link-dest=$CURRENT_LINK $BACKUP_SOURCE_DIR $SNAPSHOT_DIR/$NOW
```

The options are self descriptives, but let's detail them to be sure to
understand their roles:

* `--compress` or `-z`: means that the compression will be used to reduce
  the size of data sent.
* `--hard-links` and `--link-dest=DIR`: hard link to files in DIR when
  unchanged. I use this option to optimize the disk space since only
files updated or newly created will consume disk space. By the way, it also
addresses the speed issue. I use the path to the `current` symlink to
make sure that the hard link are executed on the most recent update.
* `--archive` or `-a`: is a shortcut for several options that acts like
  if you were creating a tar archive using the "tar pipe" technic, that is to
say:
   * recurse into directories
   * copy symlinks as symlinks
   * preserve permissions, times, group, owner and device

`du` displays disk usage statistics, if you want to confirm hard links are working fine, you can execute the `du -sch` on all the snapshots like this:

```
du -sch backups/snapshots/*

143M backups/snapshots/201112010900
 16K backups/snapshots/201112010930
 16K backups/snapshots/201112011000
 35M backups/snapshots/201112011030
 ...
178M total
```

* `-s` Displays an entry for each specified file.
* `-c` Displays a grand total.
* `-h` Human readable output.

**Warning**: I discovered it's not working with SAMBA NTFS drives because this filesystem does not understand hard links and it simply duplicates the files.

References:

* [The tar-pipe](http://blog.extracheese.org/2010/05/the-tar-pipe.html)
   
### Rotation management

#### Chained Commands 
Each time a snapshot backup has been successfully finished, we relink the symbolic link `current` to this one. For this, I'm using the Bash chained commands with an AND conditional execution.

```bash
command1 && command2
```

`command2` is executed if, and only if, `command1` succeeds

```bash
rsync --hard-links --archive --compress --link-dest=$CURRENT_LINK $BACKUP_SOURCE_DIR $SNAPSHOT_DIR/$NOW && ln -snf $(ls -1d $SNAPSHOT_DIR/* | tail -n1) $CURRENT_LINK
```

#### Symbolic Link

Here is the way we will create the symbolic link:

```bash
ln -snf $(ls -d1 snapshots | tail -n1) current
```

And here are the details of the different options used:

* `-s` obviously, to specify that is a symbolic link
* `-f` to force the override of the existing link
* `-n` do not follow the target if it's already a symlink.

Be aware that without the `-n` option, the `ln` command will act as if you were requesting it to link the last snapshot inside of the previous one, like this way:

```
backups
`-- current -> snapshots/201111201646
  |-- 201111220901 -> snapshots/201111220901
  |-- Downloads 
  ...
```

#### Subshell Command substitution

To find out the last snapshot to link to the `current` folder, I
list the folders in the `snapshots` directory, formatted as one entry per
line, that I pipe with `tail` to get the last entry.

```bash
ls -d1 snapshots | tail -n1
```

Since I want to use the result of this command directly in my `ln`
command, I'm using the Subshell Command Substitution offered by Bash.

```bash
$( <COMMANDS> )
```

The command substitution returns the `stdout` data after running the
command in a subshell. Everything inside the parentheses is executed in
a separate instance of bash.

## Create encrypted and compressed archives

To preserve disk space and to keep the backup folder manageable, we need
to find all the snapshots from the previous day, and create a compressed
timestamped archive. Then we will delete them once the archive successfully created.

### Compute dates

All this script long, we will be using dates several time for the
file names timestamps or to select eligible files for the rotations.
To keep the date coherent in the whole script, this is preferable to compute
them once at the beginning of the script to prevent sides effects.

Here is how we are retrieving the current and past's dates:

```bash
NOW=$(date +%Y%m%d%H%M)
YESTERDAY=$(date -v -1d +%Y%m%d)
```

Date options

* `-v-1d` return the value of the current date -1 day
* `+%Y%m%d` format the output with the YYYYMMDD format

### Create the archive

Now that we have the yesterday's date, let's create the compressed archive
with all the snapshots folders of this day if they exist, and remove them
in case of success, using a chained command.

We first test if the snapshots folder contains some subfolders matching
the yesterday timestamp, by listing only folders, redirecting the errors
to /dev/null and counting lines of the output.

```bash
if [ $(ls -d $SNAPSHOT_DIR/$YESTERDAY* 2> /dev/null | wc -l) != "0" ]
then
  tar -czf $ARCHIVES_DIR/$YESTERDAY.tar.gz $SNAPSHOT_DIR/$YESTERDAY* && rm -rf $SNAPSHOT_DIR/$YESTERDAY*
fi
```

Tar options:

* `-c` create an archive
* `-z` compress the archive witt gunzip
* `-f` force the creation of the archive 

### Encrypt the archives with GPG

The best backup files are the one you store far from the source file,
which means some security risks. If you store your backups on shared drive or
simply if you have confidential information, you should think about
encrypt them.

When we start talking about encryption on Unix, the tool that comes first in mind is GnuPG, a complete OpenPGP implementation. It's simple and effective and is not limited to emails.

I'll not describe how to install, setup and generate keys since there
are plenty sites doing it the right way. I will link some of them in
the references of this section.

In my case, I encrypt the archive with the following command:

```
gpg -r anouar@adlani.com --encrypt-files $ARCHIVES_DIR/$YESTERDAY.tar.gz
```

Which means: encrypt the archive to be decrypted only by the public key of
anouar@adlani.com.

The GPG encryptions options:

* `-r` the recipient name or email used to retrieve the public key
* `--encrypt-files` encrypt the 

When you will need to decrypt the archive, the only thing you have to do is call the following command.

```
gpg --decrypt-files $ARCHIVES_DIR/$YESTERDAY.tar.gz.gpg
```

During the decryption process you will be asked to enter your passphrase:

```
You need a passphrase to unlock the secret key for user:
" Anouar ADLANI (aadlani) <anouar@adlani.com> "
2048 bits RSA key, ID 840212D2, created 2011-11-23 (main key ID 540DC0B8)

Enter passphrase:

gpg: encrypted with 2048-bits RSA key, ID 840212D2, created 2011-11-23
      " Anouar ADLANI (aadlani) <anouar@adlani.com> "
```

The GPG decryption options:

* `--decrypt-files` decrypts all files passed in parameter

References:

* GPG: [The GNU Privacy Guard](http://www.gnupg.org/)
* GPGTools: [Open source initiative to bring OpenPGP to Apple OS
  X](http://www.gpgtools.org/)
* PGP Global Directory: [free service designed to make it easier to find
  and trust PGP
keys](http://keyserver.pgp.com/vkd/GetWelcomeScreen.event) 
* MIT Key Server: [MIT PGP Public Key Server](http://pgp.mit.edu/)

## Schedule the backup tasks

Here we are, our script started to be quite complete, but we need now to
execute the backup task regularly, and for that job we will use the
CRON tool, with our user's crontab.

### Cron

Visualize and edit your user crontab:

```bash
crontab -l      # List the actual crontab tasks
crontab -e      # Edit the crontab
```

Crontab options:

* `-l` display the CRONTAB of the current user
* `-e` edit the CRONTAB in your `$EDITOR`

A crontab task has five fields for specifying day, date and time
followed by the command to be run at that interval.

```bash
*  *  *  *  *       command to be executed
-  -  -  -  -
|  |  |  |  +-----  day of week   (0 - 6) (Sunday=0)
|  |  |  +--------  month         (1 - 12)
|  |  +-----------  day of month  (1 - 31)
|  +--------------  hour          (0 - 23)
+-----------------  min           (0 - 59)
```

To set our task to be executed every 30 minutes from 8am to 6pm during
the workdays, that leads to:

```bash
*/30 8-18 * * 1-5 ~/bin/backup/backup.sh

```

 * **\*/30** : "Every 30 minutes"
 * **8-18** : "From 8 to 6"
 * **1-5** : "Workdays"

If you are not comfortable with the CRONTAB syntax, I found some times
ago a website which could help you to create your tasks visually, named CORNTAB that you will find in the references.

* Introduction: [Newbie Introduction to
  cron](http://www.unixgeeks.org/security/newbie/unix/cron-1.html)
* CornTab: [A visual crontab
  utility](http://www.corntab.com/pages/crontab-gui)
