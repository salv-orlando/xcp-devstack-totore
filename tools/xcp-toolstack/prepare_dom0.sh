#!/bin/sh
set -o xtrace
set -o errexit

# Install basics for vi and git
apt-get -y install git iptables-persistent

# Clone devstack
DEVSTACK=${DEVSTACK:-/root/devstack}

if [ ! -d ${DEVSTACK} ]; then
    git clone git://github.com/cloudbuilders/devstack.git ${DEVSTACK}
fi
