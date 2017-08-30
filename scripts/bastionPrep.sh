#!/bin/bash
echo $(date) " - Starting Script"

USER=$1
PASSWORD="$2"
POOL_ID=$3

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

subscription-manager register --username="$USER" --password="$PASSWORD" --force
if [ $? -eq 0 ]
then
   echo "Subscribed successfully"
else
   echo "Incorrect Username and / or Password specified"
   exit 3
fi

subscription-manager attach --pool=$POOL_ID
if [ $? -eq 0 ]
then
   echo "Pool attached successfully"
else
   echo "Incorrect Pool ID or no entitlements available"
   exit 4
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
    --enable="rhel-7-server-ose-3.6-rpms"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct httpd-tools
yum -y update --exclude=WALinuxAgent

# Install OpenShift utilities
echo $(date) " - Installing OpenShift utilities"

yum -y install atomic-openshift-utils

echo $(date) " - Script Complete"
