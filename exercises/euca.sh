#!/usr/bin/env bash

# we will use the ``euca2ools`` cli tool that wraps the python boto
# library to test ec2 compatibility

echo "**************************************************"
echo "Begin DevStack Exercise: $0"
echo "**************************************************"

# This script exits on an error so that errors don't compound and you see
# only the first error that occured.
set -o errexit

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following allowing as the install occurs.
set -o xtrace

# Settings
# ========

# Use openrc + stackrc + localrc for settings
pushd $(cd $(dirname "$0")/.. && pwd) >/dev/null

# Import common functions
source ./functions

# Import configuration
source ./openrc
popd >/dev/null

# Max time to wait while vm goes from build to active state
ACTIVE_TIMEOUT=${ACTIVE_TIMEOUT:-30}

# Max time till the vm is bootable
BOOT_TIMEOUT=${BOOT_TIMEOUT:-30}

# Max time to wait for proper association and dis-association.
ASSOCIATE_TIMEOUT=${ASSOCIATE_TIMEOUT:-15}

# Instance type to create
DEFAULT_INSTANCE_TYPE=${DEFAULT_INSTANCE_TYPE:-m1.tiny}

# Find a machine image to boot
IMAGE=`euca-describe-images | grep machine | cut -f2 | head -n1`

# Define secgroup
SECGROUP=euca_secgroup

# Add a secgroup
if ! euca-describe-groups | grep -q $SECGROUP; then
    euca-add-group -d "$SECGROUP description" $SECGROUP
    if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! euca-describe-groups | grep -q $SECGROUP; do sleep 1; done"; then
        echo "Security group not created"
        exit 1
    fi
fi

# Launch it
INSTANCE=`euca-run-instances -g $SECGROUP -t $DEFAULT_INSTANCE_TYPE $IMAGE | grep INSTANCE | cut -f2`
die_if_not_set INSTANCE "Failure launching instance"

# Assure it has booted within a reasonable time
if ! timeout $RUNNING_TIMEOUT sh -c "while ! euca-describe-instances $INSTANCE | grep -q running; do sleep 1; done"; then
    echo "server didn't become active within $RUNNING_TIMEOUT seconds"
    exit 1
fi

# Allocate floating address
FLOATING_IP=`euca-allocate-address | cut -f2`
die_if_not_set FLOATING_IP "Failure allocating floating IP"

# Associate floating address
euca-associate-address -i $INSTANCE $FLOATING_IP
die_if_error "Failure associating address $FLOATING_IP to $INSTANCE"

# Authorize pinging
euca-authorize -P icmp -s 0.0.0.0/0 -t -1:-1 $SECGROUP
die_if_error "Failure authorizing rule in $SECGROUP"

# Test we can ping our floating ip within ASSOCIATE_TIMEOUT seconds
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! ping -c1 -w1 $FLOATING_IP; do sleep 1; done"; then
    echo "Couldn't ping server with floating ip"
    exit 1
fi

# Revoke pinging
euca-revoke -P icmp -s 0.0.0.0/0 -t -1:-1 $SECGROUP
die_if_error "Failure revoking rule in $SECGROUP"

# Release floating address
euca-disassociate-address $FLOATING_IP
die_if_error "Failure disassociating address $FLOATING_IP"

# Wait just a tick for everything above to complete so release doesn't fail
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while euca-describe-addresses | grep $INSTANCE | grep -q $FLOATING_IP; do sleep 1; done"; then
    echo "Floating ip $FLOATING_IP not disassociated within $ASSOCIATE_TIMEOUT seconds"
    exit 1
fi

# Release floating address
euca-release-address $FLOATING_IP
die_if_error "Failure releasing address $FLOATING_IP"

# Wait just a tick for everything above to complete so terminate doesn't fail
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while euca-describe-addresses | grep -q $FLOATING_IP; do sleep 1; done"; then
    echo "Floating ip $FLOATING_IP not released within $ASSOCIATE_TIMEOUT seconds"
    exit 1
fi

# Terminate instance
euca-terminate-instances $INSTANCE
die_if_error "Failure terminating instance $INSTANCE"

# Assure it has terminated within a reasonable time
if ! timeout $TERMINATE_TIMEOUT sh -c "while euca-describe-instances $INSTANCE | grep -q running; do sleep 1; done"; then
    echo "server didn't terminate within $TERMINATE_TIMEOUT seconds"
    exit 1
fi

# Delete group
euca-delete-group $SECGROUP
die_if_error "Failure deleting security group $SECGROUP"

set +o xtrace
echo "**************************************************"
echo "End DevStack Exercise: $0"
echo "**************************************************"
