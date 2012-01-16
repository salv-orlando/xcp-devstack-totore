#!/bin/sh
set -o xtrace
set -o errexit

# Install basics for vi and git
apt-get install gcc make vim zlib1g-dev libssl-dev git

# Clone devstack
if [ -z ${DEVSTACK} ]; then
    DEVSTACK=/root/devstack
fi

if [ ! -d ${DEVSTACK} ]; then
    git clone git://github.com/cloudbuilders/devstack.git ${DEVSTACK}
fi
