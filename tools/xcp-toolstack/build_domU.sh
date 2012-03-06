#!/bin/bash

set -e

# Abort if localrc is not set
if [ ! -e ../../localrc ]; then
    echo "You must have a localrc with ALL necessary passwords defined before proceeding."
    echo "See the xen README for required passwords."
    exit 1
fi

# This directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

TMP_DIR=${TMP_DIR:-/tmp}

# Source params
cd ../.. && source ./stackrc && cd $TOP_DIR

# Echo commands
set -o xtrace

# Name of this guest
GUEST_NAME=${GUEST_NAME:-ALLINONE}

# dom0 ip
HOST_IP=${HOST_IP:-`ifconfig xenbr0 | grep "inet addr" | cut -d ":" -f2 | sed "s/ .*//"`}

# Our nova host's network info 
VM_IP=${VM_IP:-10.255.255.255} # A host-only ip that let's the interface come up, otherwise unused
MGT_IP=${MGT_IP:-172.16.100.55}
PUB_IP=${PUB_IP:-192.168.1.55}

# Public network
PUB_BR=${PUB_BR:-xenbr0}
PUB_NETMASK=${PUB_NETMASK:-255.255.255.0}

# VM network params
VM_NETMASK=${VM_NETMASK:-255.255.255.0}
VM_BR=${VM_BR:-xapi1}
VM_VLAN=${VM_VLAN:-100}

# MGMT network params
MGT_NETMASK=${MGT_NETMASK:-255.255.255.0}
MGT_BR=${MGT_BR:-xapi2}
MGT_VLAN=${MGT_VLAN:-101}

# VM Password
GUEST_PASSWORD=${GUEST_PASSWORD:-secrete}

# Size of image
VDI_MB=${VDI_MB:-2500}

# Make sure we have git
if ! which git; then
    apt-get -y install git
fi

# Helper to create networks
function create_network() {
    if ! xe network-list | grep bridge | grep -q $1; then
        echo "Creating bridge $1"
        xe network-create name-label=$1
    fi
}

# Create host, vm, mgmt, pub networks
create_network xapi0
create_network $VM_BR
create_network $MGT_BR
create_network $PUB_BR

# Get the uuid for our physical (public) interface
PIF=`xe pif-list --minimal device=eth0`

# Create networks/bridges for vm and management
VM_NET=`xe network-list --minimal bridge=$VM_BR`
MGT_NET=`xe network-list --minimal bridge=$MGT_BR`

# Helper to create vlans
function create_vlan() {
    pif=$1
    vlan=$2
    net=$3
    if ! xe vlan-list | grep tag | grep -q $vlan; then
        xe vlan-create pif-uuid=$pif vlan=$vlan network-uuid=$net
    fi
}

# Create vlans for vm and management
create_vlan $PIF $VM_VLAN $VM_NET
create_vlan $PIF $MGT_VLAN $MGT_NET

# Setup host-only nat rules
HOST_NET=169.254.0.0/16
if ! iptables -L -v -t nat | grep -q $HOST_NET; then
    iptables -t nat -A POSTROUTING -s $HOST_NET -j SNAT --to-source $HOST_IP
    iptables -I FORWARD 1 -s $HOST_NET -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
fi

# Set up persistent ip forwarding
sysctl -w net.ipv4.ip_forward=1
if ! egrep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi

# Directory where we stage the build
STAGING_DIR=$TOP_DIR/stage

# Option to clean out old stuff
CLEAN=${CLEAN:-0}
if [ "$CLEAN" = "1" ]; then
    rm -rf $STAGING_DIR
fi

# Download our base image.  This image is made using prepare_guest.sh
BASE_IMAGE_URL=${BASE_IMAGE_URL:-http://images.ansolabs.com/xen/stage.tgz}
if [ ! -e $STAGING_DIR ]; then
    if [ ! -e ${TMP_DIR}/stage.tgz ]; then
        wget $BASE_IMAGE_URL -O ${TMP_DIR}/stage.tgz
    fi
    tar xfz ${TMP_DIR}/stage.tgz
    cd $TOP_DIR
fi

# Free up precious disk space
rm -f ${TMP_DIR}/stage.tgz

# Make sure we have a stage
if [ ! -d $STAGING_DIR/etc ]; then
    echo "Stage is not properly set up!"
    exit 1
fi

# Directory where our conf files are stored
FILES_DIR=$TOP_DIR/files
TEMPLATES_DIR=$TOP_DIR/templates

# Directory for supporting script files
SCRIPT_DIR=$TOP_DIR/scripts

# Version of ubuntu with which we are working
UBUNTU_VERSION=`cat $STAGING_DIR/etc/lsb-release | grep "DISTRIB_CODENAME=" | sed "s/DISTRIB_CODENAME=//"`
KERNEL_VERSION=`ls $STAGING_DIR/boot/vmlinuz* | head -1 | sed "s/.*vmlinuz-//"`

# Setup fake grub
rm -rf $STAGING_DIR/boot/grub/
mkdir -p $STAGING_DIR/boot/grub/
cp $TEMPLATES_DIR/menu.lst.in $STAGING_DIR/boot/grub/menu.lst
sed -e "s,@KERNEL_VERSION@,$KERNEL_VERSION,g" -i $STAGING_DIR/boot/grub/menu.lst

# Setup fstab, tty, and other system stuff
cp $FILES_DIR/fstab $STAGING_DIR/etc/fstab
cp $FILES_DIR/hvc0.conf $STAGING_DIR/etc/init/

# Put the VPX into UTC.
rm -f $STAGING_DIR/etc/localtime

# Configure dns (use same dns as dom0)
cp /etc/resolv.conf $STAGING_DIR/etc/resolv.conf

# Copy over devstack
rm -f ${TMP_DIR}/devstack.tar
tar --exclude='stage' --exclude='xen/xvas' --exclude='xen/nova' -cvf ${TMP_DIR}/devstack.tar $TOP_DIR/../../../devstack
cd $STAGING_DIR/opt/stack/
tar xf ${TMP_DIR}/devstack.tar
cd $TOP_DIR

# Configure OVA
VDI_SIZE=$(($VDI_MB*1024*1024))
PRODUCT_BRAND=${PRODUCT_BRAND:-openstack}
PRODUCT_VERSION=${PRODUCT_VERSION:-001}
BUILD_NUMBER=${BUILD_NUMBER:-001}
LABEL="$PRODUCT_BRAND $PRODUCT_VERSION-$BUILD_NUMBER"
OVA=$STAGING_DIR/tmp/ova.xml
cp $TEMPLATES_DIR/ova.xml.in  $OVA
sed -e "s,@VDI_SIZE@,$VDI_SIZE,g" -i $OVA
sed -e "s,@PRODUCT_BRAND@,$PRODUCT_BRAND,g" -i $OVA
sed -e "s,@PRODUCT_VERSION@,$PRODUCT_VERSION,g" -i $OVA
sed -e "s,@BUILD_NUMBER@,$BUILD_NUMBER,g" -i $OVA

# Directory for xvas
XVA_DIR=$TOP_DIR/xvas

# Create xva dir
mkdir -p $XVA_DIR

# Clean nova if desired
if [ "$CLEAN" = "1" ]; then
    rm -rf $TOP_DIR/nova
fi

# Checkout nova
if [ ! -d $TOP_DIR/nova ]; then
    git clone $NOVA_REPO
    cd $TOP_DIR/nova
    git checkout $NOVA_BRANCH
fi 

# Run devstack on launch
cat <<EOF >$STAGING_DIR/etc/rc.local
GUEST_PASSWORD=$GUEST_PASSWORD STAGING_DIR=/ DO_TGZ=0 bash /opt/stack/devstack/tools/xen/prepare_guest.sh
su -c "/opt/stack/run.sh > /opt/stack/run.sh.log" stack
exit 0
EOF

# Install plugins
chmod a+x $TOP_DIR/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/*
cp -pr $TOP_DIR/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/* /usr/lib/xcp/plugins/
apt-get install -y parted # nova-xcp-network nova-xcp-plugins
mkdir -p /boot/guest

# Set local storage il8n
SR_UUID=`xe sr-list --minimal name-label="Local storage"`
xe sr-param-set uuid=$SR_UUID other-config:i18n-key=local-storage


# Shutdown previous runs
DO_SHUTDOWN=${DO_SHUTDOWN:-1}
if [ "$DO_SHUTDOWN" = "1" ]; then
    # Shutdown all domU's that created previously
    xe vm-list --minimal name-label="$LABEL" | xargs ${TOP_DIR}/scripts/uninstall-os-vpx.sh

    # Destroy any instances that were launched
    for uuid in `xe vm-list | grep -1 instance | grep uuid | sed "s/.*\: //g"`; do
        echo "Shutting down nova instance $uuid"
        xe vm-unpause uuid=$uuid || true
        xe vm-shutdown uuid=$uuid
        xe vm-destroy uuid=$uuid
    done

    # Destroy orphaned vdis
    for uuid in `xe vdi-list | grep -1 Glance | grep uuid | sed "s/.*\: //g"`; do
        xe vdi-destroy uuid=$uuid
    done
fi

# Path to head xva.  By default keep overwriting the same one to save space
USE_SEPARATE_XVAS=${USE_SEPARATE_XVAS:-0}
if [ "$USE_SEPARATE_XVAS" = "0" ]; then
    XVA=$XVA_DIR/$UBUNTU_VERSION.xva 
else
    XVA=$XVA_DIR/$UBUNTU_VERSION.$GUEST_NAME.xva 
fi

# Clean old xva. In the future may not do this every time.
rm -f $XVA

# Configure the hostname
echo $GUEST_NAME > $STAGING_DIR/etc/hostname

# Hostname must resolve for rabbit
cat <<EOF >$STAGING_DIR/etc/hosts
$MGT_IP $GUEST_NAME
127.0.0.1 localhost localhost.localdomain
EOF

# Configure the network
INTERFACES=$STAGING_DIR/etc/network/interfaces
cp $TEMPLATES_DIR/interfaces.in  $INTERFACES
sed -e "s,@ETH1_IP@,$VM_IP,g" -i $INTERFACES
sed -e "s,@ETH1_NETMASK@,$VM_NETMASK,g" -i $INTERFACES
sed -e "s,@ETH2_IP@,$MGT_IP,g" -i $INTERFACES
sed -e "s,@ETH2_NETMASK@,$MGT_NETMASK,g" -i $INTERFACES
sed -e "s,@ETH3_IP@,$PUB_IP,g" -i $INTERFACES
sed -e "s,@ETH3_NETMASK@,$PUB_NETMASK,g" -i $INTERFACES

# Gracefully cp only if source file/dir exists
function cp_it {
    if [ -e $1 ] || [ -d $1 ]; then
        cp -pRL $1 $2
    fi
}

# Copy over your ssh keys and env if desired
COPYENV=${COPYENV:-1}
if [ "$COPYENV" = "1" ]; then
    cp_it ~/.ssh $STAGING_DIR/opt/stack/.ssh
    cp_it ~/.ssh/id_rsa.pub $STAGING_DIR/opt/stack/.ssh/authorized_keys
    cp_it ~/.gitconfig $STAGING_DIR/opt/stack/.gitconfig
    cp_it ~/.vimrc $STAGING_DIR/opt/stack/.vimrc
    cp_it ~/.bashrc $STAGING_DIR/opt/stack/.bashrc
fi

# Configure run.sh
cat <<EOF >$STAGING_DIR/opt/stack/run.sh
#!/bin/bash
cd /opt/stack/devstack
killall screen
IP=\`ifconfig eth3 | grep 'inet addr' | awk '{print $2}' | awk -F: '{print $2}'\`
UPLOAD_LEGACY_TTY=yes HOST_IP=${IP} VIRT_DRIVER=xenserver FORCE=yes MULTI_HOST=1 $STACKSH_PARAMS ./stack.sh
EOF
chmod 755 $STAGING_DIR/opt/stack/run.sh

# Create xva
if [ ! -e $XVA ]; then
    rm -rf ${TMP_DIR}/mkxva*
    $SCRIPT_DIR/mkxva -o $XVA -t xva -x $OVA $STAGING_DIR $VDI_MB ${TMP_DIR}/
fi

# Start guest
$TOP_DIR/scripts/install-os-vpx.sh -f $XVA -v $VM_BR -m $MGT_BR -p $PUB_BR

# If we have copied our ssh credentials, use ssh to monitor while the installation runs
WAIT_TILL_LAUNCH=${WAIT_TILL_LAUNCH:-1}
if [ "$WAIT_TILL_LAUNCH" = "1" ]  && [ -e ~/.ssh/id_rsa.pub  ] && [ "$COPYENV" = "1" ]; then
    # Done creating the container, let's tail the log
    echo
    echo "============================================================="
    echo "                          -- YAY! --"
    echo "============================================================="
    echo
    echo "We're done launching the vm, about to start tailing the"
    echo "stack.sh log. It will take a second or two to start."
    echo
    echo "Just CTRL-C at any time to stop tailing."

    set +o xtrace

    while ! ssh -q stack@$PUB_IP "[ -e run.sh.log ]"; do
      sleep 1
    done

    ssh stack@$PUB_IP 'tail -f run.sh.log' &

    TAIL_PID=$!

    function kill_tail() {
        kill $TAIL_PID
        exit 1
    }

    # Let Ctrl-c kill tail and exit
    trap kill_tail SIGINT

    echo "Waiting stack.sh to finish..."
    while ! ssh -q stack@$PUB_IP "grep -q 'stack.sh completed in' run.sh.log"; do
        sleep 1
    done

    kill $TAIL_PID

    if ssh -q stack@$PUB_IP "grep -q 'stack.sh failed' run.sh.log"; then
        exit 1
    fi
    echo ""
    echo "Finished - Zip-a-dee Doo-dah!"
    echo "You can then visit the OpenStack Dashboard"
    echo "at http://$PUB_IP, and contact other services at the usual ports."
else
    echo "################################################################################"
    echo ""
    echo "All Finished!"
    echo "Now, you can monitor the progress of the stack.sh installation by "
    echo "tailing /opt/stack/run.sh.log from within your domU."
    echo ""
    echo "ssh into your domU now: 'ssh stack@$PUB_IP' using your password"
    echo "and then do: 'tail -f /opt/stack/run.sh.log'"
    echo ""
    echo "When the script completes, you can then visit the OpenStack Dashboard"
    echo "at http://$PUB_IP, and contact other services at the usual ports."

fi
