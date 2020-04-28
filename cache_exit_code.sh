#!/usr/bin/env bash

# Return codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_QUEUEING=5

if [[ -z "$TARGET" ]] ; then
    echo 'ERROR: must define TARGET from environment'
    exit $STATE_CRITICAL
fi

if [[ -n "$LOGX_DEBUG" ]] ; then
    # Enable additional execution logs for debugging.
    set -x
    exec 1>> /tmp/${TARGET}.log 2>&1
fi

set -u

# Max age (in seconds) to use a cached command result before running the
# command again.
MAX_CACHE_AGE=${1:?Please provide timeout value}

# Where to store cached NDT e2e test results
CACHE_DIR=/tmp/cache-${2:?Please provide a command to run}

# Flags whether this is the first time an e2e test has been run against this
# node since this VM has been running. See comment later in this script to
# understand why this variable exists.
RANDOMIZE_TIMESTAMP=false

# If the $CACHE_DIR doesn't exist create it.
if [[ ! -d $CACHE_DIR ]]; then
    mkdir -p $CACHE_DIR
fi

CACHE_STATUS=$(cat $CACHE_DIR/$TARGET 2> /dev/null)

# If the cached status for this $TARGET was successful and the mtime of
# the cache file is less than $MAX_CACHE_AGE, then return $STATE_OK.
if [[ -n "$CACHE_STATUS" ]]; then
    if [[ "$CACHE_STATUS" -eq "$STATE_OK" ]]; then
        file_age=$(expr $(date +%s) - $(stat --printf "%Y" $CACHE_DIR/$TARGET ))
        if [[ "$file_age" -lt $MAX_CACHE_AGE ]]; then
            exit $STATE_OK
        fi
    fi
else
    # The cache file didn't already exist, so this must be the first run of the
    # e2e test for this node. Flag this for later use.
    RANDOMIZE_TIMESTAMP=true
fi

shift 1  # Remove first parameter.
# Run command.
OUTPUT=$( $@ )
STATUS=$?

# Cache result.
echo $STATUS > $CACHE_DIR/$TARGET

# If the cache file didn't previously exist, then this is the first run. To
# help distribute the cache expiration randomly (and the command execution), we
# set the cache file's mtime from 1 second to $MAX_CACHE_AGE seconds into the
# past, randomly. This means that the second command will run sooner, but it
# will also cause the cached statuses to expire at random times, distributing
# the command execution times.
if [[ $RANDOMIZE_TIMESTAMP = "true" ]]; then
    RAND=$(($RANDOM % $MAX_CACHE_AGE))
    touch --date "${RAND} seconds ago" $CACHE_DIR/$TARGET
fi

if [ "$STATUS" -eq "0" ]; then
    exit $STATE_OK
else
    exit $STATE_CRITICAL
fi
