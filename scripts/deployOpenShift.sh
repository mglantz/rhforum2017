#!/bin/bash

echo $(date) " - Starting Script"

set -e

SUDOUSER=$1
PASSWORD="$2"
PRIVATEKEY=$3
MASTER=$4
MASTERPUBLICIPHOSTNAME=$5
MASTERPUBLICIPADDRESS=$6
INFRA=$7
NODE=$8
NODECOUNT=$9
MASTERCOUNT=${10}
ROUTING=${11}
BASTION=$(hostname -f)

MASTERLOOP=$((MASTERCOUNT - 1))
NODELOOP=$((NODECOUNT - 1))

DOMAIN=$( awk 'NR==2' /etc/resolv.conf | awk '{ print $2 }' )

echo $PASSWORD

# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

echo "Generating Private Keys"

runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo "Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg

# Create Ansible Playbook for Post Installation task
echo $(date) " - Create Ansible Playbook for Post Installation task"

# Run on all nodes
cat > /home/${SUDOUSER}/preinstall.yml <<EOF
---
- hosts: nodes
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: copy hosts file
    copy:
      src: /tmp/hosts
      dest: /etc/hosts
      owner: root
      group: root
      mode: 0644
EOF

# Run on all masters
cat > /home/${SUDOUSER}/postinstall.yml <<EOF
---
- hosts: masters
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: create directory
    file: path=/etc/origin/master state=directory
  - name: add initial OpenShift user
    shell: htpasswd -cb /etc/origin/master/htpasswd ${SUDOUSER} "${PASSWORD}"
EOF

# Run on only MASTER-0
cat > /home/${SUDOUSER}/postinstall2.yml <<EOF
---
- hosts: nfs
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Make user cluster admin"
  tasks:
  - name: make OpenShift user cluster admin
    shell: oadm policy add-cluster-role-to-user cluster-admin $SUDOUSER --config=/etc/origin/master/admin.kubeconfig
EOF


# Run on all masters
cat > /home/${SUDOUSER}/postinstall4.yml <<EOF
---
- hosts: masters
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Unset default registry DNS name"
  tasks:
  - name: copy atomic-openshift-master file
    copy:
      src: /tmp/atomic-openshift-master
      dest: /etc/sysconfig/atomic-openshift-master
      owner: root
      group: root
      mode: 0644
  - name: restart master
    shell: systemctl restart atomic-openshift-master
EOF

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

if [ $MASTERCOUNT -eq 1 ]
then

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=false
deployment_type=openshift-enterprise
docker_udev_workaround=true
openshift_use_dnsmasq=true
openshift_disable_check=disk_availability
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
osm_use_cockpit=false

openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
#openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# host group for masters
[masters]
$MASTER-0.$DOMAIN

# host group for nodes
[nodes]
$MASTER-0.$DOMAIN openshift_node_labels="{'region': 'master', 'zone': 'default'}"
$INFRA-0.$DOMAIN openshift_node_labels="{'region': 'infra', 'zone': 'default'}"
$NODE-[0:${NODELOOP}].$DOMAIN openshift_node_labels="{'region': 'nodes', 'zone': 'default'}"
EOF

else

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
nfs
lb

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=false
deployment_type=openshift-enterprise
docker_udev_workaround=true
openshift_use_dnsmasq=true
openshift_disable_check=disk_availability
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true

openshift_master_cluster_method=native
openshift_master_cluster_hostname=$BASTION
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
#openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# host group for masters
[masters]
$MASTER-[0:${MASTERLOOP}].$DOMAIN

# host group for etcd
[etcd]
$MASTER-[0:${MASTERLOOP}].$DOMAIN

[nfs]
$MASTER-0.$DOMAIN

[lb]
$BASTION

# host group for nodes
[nodes]
$MASTER-[0:${MASTERLOOP}].$DOMAIN openshift_node_labels="{'region': 'master', 'zone': 'default'}"
$INFRA-[0:${MASTERLOOP}].$DOMAIN openshift_node_labels="{'region': 'infra', 'zone': 'default'}"
$NODE-[0:${NODELOOP}].$DOMAIN openshift_node_labels="{'region': 'nodes', 'zone': 'default'}"
EOF

fi

# Create and distribute hosts file to all nodes, this is due to us having to use 
(
echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4"
echo "::1         localhost localhost.localdomain localhost6 localhost6.localdomain6"
for node in ocpm-0 ocpm-1 ocpm-2; do
	ping -c 1 $node 2>/dev/null|grep ocp|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//'i -e "s/.net/.net $node/"
done

for node in ocpi-{0..5}; do
	ping -c 1 $node 2>/dev/null|grep ocp|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//' -e "s/.net/.net $node/"
done

for node in ocpn-{0..30}; do
	ping -c 1 $node 2>/dev/null|grep ocp|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//' -e "s/.net/.net $node/"
done
) >/tmp/hosts

chmod a+r /tmp/hosts

# Create correct hosts file on all servers
runuser -l $SUDOUSER -c "ansible-playbook ~/preinstall.yml"

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml"

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) "- Registry deployed to infra node"

# Deploying Router
echo $(date) "- Router deployed to infra nodes"

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall.yml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall2.yml"

# Unset of OPENSHIFT_DEFAULT_REGISTRY. Just the easiest way out.

cat > /tmp/atomic-openshift-master <<EOF
OPTIONS=--loglevel=2
CONFIG_FILE=/etc/origin/master/master-config.yaml
#OPENSHIFT_DEFAULT_REGISTRY=docker-registry.default.svc:5000


# Proxy configuration
# See https://docs.openshift.com/enterprise/latest/install_config/install/advanced_install.html#configuring-global-proxy
# Origin uses standard HTTP_PROXY environment variables. Be sure to set
# NO_PROXY for your master
#NO_PROXY=master.example.com
#HTTP_PROXY=http://USER:PASSWORD@IPADDR:PORT
#HTTPS_PROXY=https://USER:PASSWORD@IPADDR:PORT
EOF

chmod a+r /tmp/atomic-openshift-master

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall4.yml"

echo $(date) " - Script complete"
