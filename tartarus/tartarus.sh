#!/bin/bash
#
# Tartarus by Stefan Tomanek <stefan.tomanek@wertarbyte.de>
#            http://wertarbyte.de/tartarus.shtml
#
# Last change: $Date$
declare -r VERSION="0.6.3.xp"

CMD_INCREMENTAL="no"
CMD_UPDATE="no"
PROFILE=""
# check command line
while ! [ "$1" == "" ]; do
    if [ "$1" == "-i" -o "$1" == "--inc" ]; then
        CMD_INCREMENTAL="yes"
    elif [ "$1" == "-u" -o "$1" == "--update" ]; then
        CMD_UPDATE="yes"
    else
        PROFILE=$1
    fi
    shift
done

debug() {
    DEBUGMSG="$*"
    hook DEBUG
    echo $DEBUGMSG >&2
}

isEnabled() {
    V="$1"
    case "$V" in
        yes|YES|1|on|ON|true|enabled)
            return 0
        ;;
        no|NO|0|off|OFF|false|disabled|"")
            return 1
        ;;
        *)
            return 1
        ;;
    esac
}

requireCommand() {
    local ERROR=0
    for CMD in $@; do
        which $CMD > /dev/null
        if [ ! $? -eq 0 ]; then
            echo "Unable to locate command '$CMD'"
            ERROR=1
        fi
    done
    return $ERROR
}

cleanup() {
    local ABORT=${1:-0}
    local REASON=${2:-""}
    hook PRE_CLEANUP

    if [ -n "$REASON" ]; then
        debug $REASON
    fi

    if [ "$ABORT" -eq "1" ]; then
        debug "Canceling backup procedure and cleaning up..."
    fi

    if isEnabled "$CREATE_LVM_SNAPSHOT"; then
        umount $SNAPDEV 2> /dev/null
        lvremove -f $SNAPDEV 2> /dev/null
    fi
    if [ "$ABORT" -eq "1" ]; then
        debug "done"
    fi
    hook POST_CLEANUP
    exit $ABORT
}

# When processing a hook, we disable the triggering
# of new hooks to avoid loops
HOOKS_ENABLED=1
hook() {
    if [ "$HOOKS_ENABLED" -ne 1 ]; then
        return
    fi
    HOOKS_ENABLED=0
    HOOK="TARTARUS_$1_HOOK"
    # debug "Searching for $HOOK"
    shift
    # is there a defined hook function?
    if type "$HOOK" &> /dev/null; then
        debug "Executing $HOOK"
        "$HOOK" "$@"
    fi
    HOOKS_ENABLED=1
}

# Execute a command and embrace it with hooks
call() {
    local METHOD="$1"
    shift
    # Hook functions are upper case
    local MHOOK="$(echo "$METHOD" | tr '[:lower:]' '[:upper:]')"
    hook "PRE_$MHOOK"
    "$METHOD" "$@"
    local RETURNCODE=$?
    if [ "$RETURNCODE" -ne 0 ]; then
        debug "Command '$METHOD $@' failed with exit code $RETURNCODE"
    fi
    hook "POST_$MHOOK"
    return $RETURNCODE
}

# We can now check for newer versions of tartarus
update_check() {
    requireCommand curl awk || return
    local VERSION_URL="http://wertarbyte.de/tartarus/upgrade-$VERSION"

    local NEW_VERSION="$(curl -fs "$VERSION_URL")"
    if [ ! "$?" -eq 0 ]; then
        debug "Error checking version information."
        return 0
    fi

    awk -vCURRENT="$VERSION" -vNEW="$NEW_VERSION" '
BEGIN {
    n1 = split(CURRENT,current,".");
    n2 = split(NEW,new,".");
    while (i<=n1 || i<=n2) {
        x = current[i]
        y = new[i]
        if (x < y) exit 1
        if (x > y) exit 0
        i++;
    }
}
'
    if [ "$?" -eq 1 ]; then
        debug "!!! This script is probably outdated !!!"
        debug "An upgrade to version $NEW_VERSION is available. Please visit http://wertarbyte.de/tartarus.shtml"
        debug ""
        return 1
    fi
    return 0
}

# for splitting up an archive stream, we use this function
# to read a specified amount of data from a pipe and then
# return the exit code 1 the size limit has been reached
# (and there is more data waiting) while returning code 0
# if there is no data left to read (EOF reached)

readChunk() {
    local MiB=$1
    perl -Mbytes -e 'my $l=$ARGV[0]*1024*1024;
        my $size = 1024;
        $| = 1;
        while( $r = sysread(STDIN, $foo, $size) ) {
            print $foo;
            $l -= $r;
            exit 1 if $l<$size;
        }' "$MiB"
}

chunknstore() {
    if [ -n "$STORAGE_CHUNK_SIZE" ]; then
        local CURRENT_CHUNK=1
        local MORE=1
        while [ "$MORE" -eq 1 ]; do
            debug "Processing chunk $CURRENT_CHUNK"
            readChunk "$STORAGE_CHUNK_SIZE" | storage
            # Copy PIPESTATUS
            local STATUS=( ${PIPESTATUS[@]} )
            MORE=${STATUS[0]}
            # if storage fails, we have to abort
            if [ "${STATUS[1]}" -ne 0 ]; then
                return "${STATUS[1]}"
            fi
            let CURRENT_CHUNK++
        done
    else
        storage
        local STORAGE_CODE=$?
        return $STORAGE_CODE
    fi
}

# Do we only want to check for a new version?
if isEnabled "$CMD_UPDATE"; then
    update_check && debug "No new version available"
    cleanup 0
fi

if ! [ -e "$PROFILE" ]; then
    debug "You have to supply the path to a backup profile file."
    cleanup 1
fi


# Set default values:
SNAPSHOT_DIR="/snap"
LVM_SNAPSHOT_SIZE="200m"
BASEDIR="/"
EXCLUDE=""
EXCLUDE_FILES=""
# Profile specific
NAME=""
DIRECTORY=""
STAY_IN_FILESYSTEM="no"
CREATE_LVM_SNAPSHOT="no"
LVM_VOLUME_NAME=""
# Valid methods are:
# * tar (default)
# * afio
ASSEMBLY_METHOD="tar"
# Valid methods are:
# * FTP
# * FILE
# * SSH
# * SIMULATE
STORAGE_METHOD=""
STORAGE_FILE_DIR=""
STORAGE_FTP_SERVER=""
STORAGE_FTP_DIR="/"
STORAGE_FTP_USER=""
STORAGE_FTP_PASSWORD=""
STORAGE_FTP_USE_SSL="no"
STORAGE_FTP_SSL_INSECURE="no"
STORAGE_SSH_DIR=""
STORAGE_SSH_USER=""
STORAGE_SSH_SERVER=""

STORAGE_CHUNK_SIZE=""

# Options for incremental backups
INCREMENTAL_BACKUP="no"
INCREMENTAL_TIMESTAMP_FILE=""

# Encrypt the backup using a passphrase?
ENCRYPT_SYMMETRICALLY="no"
ENCRYPT_PASSPHRASE_FILE=""
# Encrypt using a public key?
ENCRYPT_ASYMMETRICALLY="no"
ENCRYPT_KEY_ID=""
# Where to find the keyring file
ENCRYPT_KEYRING=""
ENCRYPT_GPG_OPTIONS=""

LIMIT_DISK_IO="no"

CHECK_FOR_UPDATE="yes"

# Write a logfile with all files found for backup?
FILE_LIST_CREATION="no"
FILE_LIST_DIRECTORY=""

requireCommand tr find || cleanup 1

source "$PROFILE"

hook PRE_PROCESS

hook PRE_CONFIGVERIFY
# Has an incremental backup been demanded from the command line?
if isEnabled "$CMD_INCREMENTAL"; then
    # overriding config file and default setting
    INCREMENTAL_BACKUP="yes"
    debug "Switching to incremental backup because of commandline switch '-i'"
fi

# Do we want to check for a new version?
if isEnabled "$CHECK_FOR_UPDATE"; then
    debug "Checking for updates..."
    update_check
    debug "done"
fi

# NAME and DIRECTORY are mandatory
if [ -z "$NAME" -o -z "$DIRECTORY" ]; then
    cleanup 1 "NAME and DIRECTORY are mandatory arguments."
fi

# Want incremental backups? Specify INCREMENTAL_TIMESTAMP_FILE
if isEnabled "$INCREMENTAL_BACKUP" && [ ! -e "$INCREMENTAL_TIMESTAMP_FILE"  ]; then
    cleanup 1 "Unable to access INCREMENTAL_TIMESTAMP_FILE ($INCREMENTAL_TIMESTAMP_FILE)."
fi

# Do we want to limit the io load?
if isEnabled "$LIMIT_DISK_IO"; then
    requireCommand ionice || cleanup 1
    ionice -c3 -p $$
fi

# Do we want a file list?
if isEnabled "$FILE_LIST_CREATION"; then
    if [ -z "$FILE_LIST_DIRECTORY" -o ! -d "$FILE_LIST_DIRECTORY" ]; then
        cleanup 1 "Unable to access FILE_LIST_DIRECTORY ($FILE_LIST_DIRECTORY)."
    fi
fi

# Do we want to freeze the filesystem during the backup run?
if isEnabled "$CREATE_LVM_SNAPSHOT"; then
    if [ -z "$LVM_VOLUME_NAME" ]; then
        cleanup "LVM_VOLUME_NAME is mandatory when using LVM snapshots"
    fi

    if [ -z "$LVM_MOUNT_DIR" ]; then
        cleanup 1 "LVM_MOUNT_DIR is mandatory when using LVM snapshots"
    fi

    requireCommand lvdisplay lvcreate lvremove || cleanup 1

    # Check whether $LVM_VOLUME_NAME is a valid logical volume
    if ! lvdisplay "$LVM_VOLUME_NAME" > /dev/null; then
        cleanup 1"'$LVM_VOLUME_NAME' is not a valid LVM volume."
    fi

    # Check whether we have a direcory to mount the snapshot to
    if ! [ -d "$SNAPSHOT_DIR" ]; then
        cleanup 1 "Snapshot directory '$SNAPSHOT_DIR' not found."
    fi
fi

constructFilename() {
    if isEnabled "$INCREMENTAL_BACKUP"; then
        BASEDON=$(date -r "$INCREMENTAL_TIMESTAMP_FILE" '+%Y%m%d-%H%M')
        INC="-inc-${BASEDON}"
    fi
    CHUNK=""
    if [ -n "$CURRENT_CHUNK" ]; then
        CHUNK="chunk-$CURRENT_CHUNK"
    fi
    FILENAME="tartarus-${NAME}-${DATE}${INC}.${ASSEMBLY_METHOD}${ARCHIVE_EXTENSION:-}${CHUNK}"

    hook FILENAME
    
    echo $FILENAME
}

constructListFilename() {
    echo "${NAME}.${DATE}.list"
}

# Check backup collation methods
if [ -z "$ASSEMBLY_METHOD" -o "$ASSEMBLY_METHOD" == "tar" ]; then
    # use the traditional tar setup
    requireCommand tar || cleanup 1
    collate() {
        local TAROPTS="--no-unquote --no-recursion"
        call tar cp $TAROPTS --null -T -
        local EXITCODE=$?
        # exit code 1 means that some files have changed while backing them
        # up, we think that is OK for now
        if [ $EXITCODE -eq 1 ]; then
            debug "Some files changed during the backup process, proceeding anyway"
            return 0
        fi
        return $EXITCODE
    }
elif [ "$ASSEMBLY_METHOD" == "afio" ]; then
    # afio is the new hotness
    requireCommand afio || cleanup 1
    AFIO_OPTIONS=""
    if [ "$COMPRESSION_METHOD" == "gzip" ]; then
        AFIO_OPTIONS="$AFIO_OPTIONS -Z -P gzip"
        ARCHIVE_EXTENSION=".gz"
    elif [ "$COMPRESSION_METHOD" == "bzip2" ]; then
        AFIO_OPTIONS="$AFIO_OPTIONS -Z -P bzip2"
        ARCHIVE_EXTENSION=".bz2"
    fi
    collate() {
        call afio -o $AFIO_OPTIONS -0 -
    }
else
    cleanup 1 "Unknown ASSEMBLY_METHOD '$ASSEMBLY_METHOD' specified"
fi

# Check backup storage options
if [ "$STORAGE_METHOD" == "FTP" ]; then
    if [ -z "$STORAGE_FTP_SERVER" -o -z "$STORAGE_FTP_USER" -o -z "$STORAGE_FTP_PASSWORD" ]; then
        cleanup 1 "If FTP is used, STORAGE_FTP_SERVER, STORAGE_FTP_USER and STORAGE_FTP_PASSWORD are mandatory."
    fi
    
    requireCommand curl || cleanup 1

    # define storage procedure
    storage() {
        # stay silent, but print error messages if aborting
        local OPTS="-u $STORAGE_FTP_USER:$STORAGE_FTP_PASSWORD -s -S"
        if isEnabled "$STORAGE_FTP_USE_SSL"; then
            OPTS="$OPTS --ftp-ssl"
        fi
        if isEnabled "$STORAGE_FTP_SSL_INSECURE"; then
            OPTS="$OPTS -k"
        fi
        local FILE=$(constructFilename)
        local URL="ftp://$STORAGE_FTP_SERVER/$STORAGE_FTP_DIR/$FILE"
        debug "Uploading backup to $URL..."
        curl $OPTS --upload-file - "$URL"
    }
elif [ "$STORAGE_METHOD" == "FILE" ]; then
    if [ -z "$STORAGE_FILE_DIR" -a -d "$STORAGE_FILE_DIR" ]; then
        cleanup 1 "If file storage is used, STORAGE_FILE_DIR is mandatory and must exist."
    fi
    
    requireCommand cat || cleanup 1
    
    # define storage procedure
    storage() {
        local FILE="$STORAGE_FILE_DIR/$(constructFilename)"
        debug "Storing backup to $FILE..."
        cat - > $FILE
    }
elif [ "$STORAGE_METHOD" == "SSH" ]; then
    if [ -z "$STORAGE_SSH_SERVER" -o -z "$STORAGE_SSH_USER" -o -z "$STORAGE_SSH_DIR" ]; then
        cleanup 1 "If SSH storage is used, STORAGE_SSH_SERVER, STORAGE_SSH_USER and STORAGE_SSH_DIR are mandatory."
    fi
    
    requireCommand ssh || cleanup 1

    # define storage procedure
    storage() {
        local FILENAME=$( constructFilename )
        ssh -l "$STORAGE_SSH_USER" "$STORAGE_SSH_SERVER" "cat > $STORAGE_SSH_DIR/$FILENAME"
    }
elif [ "$STORAGE_METHOD" == "SIMULATE" ]; then

    storage() {
        local FILENAME=$( constructFilename )
        debug "Proposed filename is $FILENAME"
        cat - > /dev/null
    }
elif [ "$STORAGE_METHOD" == "CUSTOM" ]; then
    if ! type "TARTARUS_CUSTOM_STORAGE_METHOD" &> /dev/null; then
        cleanup 1 "If custom storage is used, a function TARTARUS_CUSTOM_STORAGE_METHOD has to be defined."
    fi
    storage() {
        TARTARUS_CUSTOM_STORAGE
    }
else
    cleanup 1 "No valid STORAGE_METHOD defined."
fi

# compression method that does nothing
compression() {
    cat -
}

# afio handles compression by itself
if [ "$ASSEMBLY_METHOD" != "afio" ]; then
    if [ "$COMPRESSION_METHOD" == "bzip2" ]; then
        requireCommand bzip2 || cleanup 1
        compression() {
            bzip2
        }
        ARCHIVE_EXTENSION=".bz2"
    elif [ "$COMPRESSION_METHOD" == "gzip" ]; then
        requireCommand gzip || cleanup 1
        compression() {
            gzip
        }
        ARCHIVE_EXTENSION=".gz"
    fi
fi

# Just a method that does nothing
encryption() {
    cat -
}

# We can only use one method of encryption at once
if isEnabled "$ENCRYPT_SYMMETRICALLY" && isEnabled "$ENCRYPT_ASYMMETRICALLY"; then
    cleanup 1 "ENCRYPT_SYMMETRICALLY and ENCRYPT_ASYMMETRICALLY are mutually exclusive."
fi

GPGOPTIONS="--batch --no-use-agent --no-tty --trust-model always $ENCRYPT_GPG_OPTIONS"

if isEnabled "$ENCRYPT_SYMMETRICALLY"; then
    requireCommand gpg || cleanup 1

    # Can we access the passphrase file?
    if ! [ -r "$ENCRYPT_PASSPHRASE_FILE" ]; then
        cleanup 1 "ENCRYPT_PASSPHRASE_FILE '$ENCRYPT_PASSPHRASE_FILE' is not readable."
    else
        ARCHIVE_EXTENSION="$ARCHIVE_EXTENSION.gpg"
        encryption() {
            # symmetric encryption
            gpg $GPGOPTIONS -c --passphrase-file "$ENCRYPT_PASSPHRASE_FILE"
        }
    fi
fi

if isEnabled "$ENCRYPT_ASYMMETRICALLY"; then
    requireCommand gpg || cleanup 1
    
    if [ -n "$ENCRYPT_KEYRING" ]; then
        if [ -f "$ENCRYPT_KEYRING" ]; then
            GPGOPTIONS=$GPGOPTIONS' --keyring '$ENCRYPT_KEYRING
        else
            cleanup 1 "ENCRYPT_KEYRING '$ENCRYPT_KEYRING' specified but not found."
        fi
    fi
    # Can we find the key id?
    if ! gpg $GPGOPTIONS --list-key "$ENCRYPT_KEY_ID" >/dev/null 2>&1; then
        cleanup 1 "Unable to find ENCRYPT_KEY_ID '$ENCRYPT_KEY_ID'."
    else
        ARCHIVE_EXTENSION="$ARCHIVE_EXTENSION.gpg"
        encryption() {
            # asymmetric encryption
            gpg $GPGOPTIONS --encrypt -r "$ENCRYPT_KEY_ID"
        }
    fi
fi

###
# Now we should have verified all arguments
hook POST_CONFIGVERIFY

# Make sure we clean up if the user aborts
trap "cleanup 1 'canceled by user interruption'" INT

DATE="$(date +%Y%m%d-%H%M)"
# Let's start with the real work
debug "syncing..."
sync

if ! isEnabled "$INCREMENTAL_BACKUP" && [ -n "$INCREMENTAL_TIMESTAMP_FILE" ]; then
    # Create temporary timestamp file if a location is defined and
    # we are doing a full backup
    echo $DATE > "${INCREMENTAL_TIMESTAMP_FILE}.running"
fi

if isEnabled "$CREATE_LVM_SNAPSHOT"; then
    # create an LVM snapshot
    SNAPDEV="${LVM_VOLUME_NAME}_snap"
    # Call the hook script
    hook PRE_FREEZE

    lvcreate --size $LVM_SNAPSHOT_SIZE --snapshot --name ${LVM_VOLUME_NAME}_snap $LVM_VOLUME_NAME || cleanup 1 "Unable to create snapshot"
    # and another hook
    hook POST_FREEZE
    # mount the new volume
    mkdir -p "$SNAPSHOT_DIR/$LVM_MOUNT_DIR" || cleanup 1 "Unable to create mountpoint"
    mount "$SNAPDEV" "$SNAPSHOT_DIR/$LVM_MOUNT_DIR" || cleanup 1 "Unable to mount snapshot"
    BASEDIR="$SNAPSHOT_DIR"
fi

# Construct excludes for find
EXCLUDES=""
for i in $EXCLUDE; do
    i=$(echo $i | sed 's#^/#./#; s#/$##')
    # Don't descend in the excluded directory, but print the directory itself
    EXCLUDES="$EXCLUDES -path $i -prune -print0 -o"
done
for i in $EXCLUDE_FILES; do
    i=$(echo $i | sed 's#^/#./#; s#/$##')
    # Ignore files in the directory, but include subdirectories
    EXCLUDES="$EXCLUDES -path '$i/*' ! -type d -prune -o"
done

debug "Beginning backup run..."

OLDDIR=$(pwd)
# We don't want absolut paths
BDIR=$(echo $DIRECTORY | sed 's#^/#./#')
# $BASEDIR is either / or $SNAPSHOT_DIR
cd "$BASEDIR"


WRITE_LIST_FILE=""

if isEnabled "$FILE_LIST_CREATION"; then
    WRITE_LIST_FILE="-fls $FILE_LIST_DIRECTORY/$(constructListFilename).running"
fi

FINDOPTS=""
FINDARGS="-print0 $WRITE_LIST_FILE"
if isEnabled "$STAY_IN_FILESYSTEM"; then
    FINDOPTS="$FINDOPTS -xdev "
fi

if isEnabled "$INCREMENTAL_BACKUP"; then
    FINDARGS="-newer $INCREMENTAL_TIMESTAMP_FILE $FINDARGS"
fi

# Make sure that an error inside the pipeline propagates
set -o pipefail

hook PRE_STORE

call find "$BDIR" $FINDOPTS $EXCLUDES $FINDARGS | \
    call collate | \
    call compression | \
    call encryption | \
    call chunknstore

BACKUP_FAILURE=$?

hook POST_STORE

cd $OLDDIR

if [ ! "$BACKUP_FAILURE" -eq 0 ]; then
    cleanup 1 "ERROR creating/processing/storing backup, check above messages"
fi

# move list file to its final location
if isEnabled "$FILE_LIST_CREATION"; then
    mv "$FILE_LIST_DIRECTORY/$(constructListFilename).running" "$FILE_LIST_DIRECTORY/$(constructListFilename)"
fi

# If we did a full backup, we might want to update the timestamp file
if [ ! -z "$INCREMENTAL_TIMESTAMP_FILE" ] && ! isEnabled "$INCREMENTAL_BACKUP"; then
    if [ -e "$INCREMENTAL_TIMESTAMP_FILE" ]; then
        OLDDATE=$(< $INCREMENTAL_TIMESTAMP_FILE)
        cp -a "$INCREMENTAL_TIMESTAMP_FILE" "$INCREMENTAL_TIMESTAMP_FILE.$OLDDATE"
    fi
    mv "${INCREMENTAL_TIMESTAMP_FILE}.running" "$INCREMENTAL_TIMESTAMP_FILE"
fi

hook POST_PROCESS

cleanup 0
