# osp14
OSP 14 deployment using ESX VMs as deploy targets.  This deploy is only for functional testing and hands on learning of OSP.  
The compute node will use ephemeral storage.  The total deploy will consist of 3 infra/controller nodes and 1 compute node for testing.

Install Centos 7 In a VM, make sure to enable nested functionality for virtualization, OSP14 uses docker containers for all services.  
Think of the director node as a PXE boot strapping/orchestration service.  
The director runs the same services as the overcloud/openstack, think NOVA, Neutron, Swift, Ironic, heat.  
Ironic handles the bootstrapping and introspection of the nodes.

Networking layout:
PXE/ControlPlane - 10.1.2.0/24 - VLAN 11 ROUTEABLE
External_net - 10.240.1.0/24 - VLAN 12 ROUTEABLE
Neutron tenant network - 192.168.222.0/24 - VLAN 4000 ROUTEABLE
Storage - 172.16.1.0/24 - VLAN 952
StorageMGMT - 172.16.3.0/24 - VLAN 953
InternalAPI - 172.16.2.0/24 - VLAN 950
Tenant - 172.16.0.0/24 - VLAN 951

To start, install director node, two interfaces attached: 
eth0 (ens192) - 10.1.1.0/24 - simple routable network
Eth1 (ens224) - 10.1.2.0/24 - PXE network NATIVE

Perform the following tasks on director:

sudo useradd stack
sudo passwd stack  # specify a password
echo "stack ALL=(root) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/stack
sudo chmod 0440 /etc/sudoers.d/stack
su - stack

sudo yum install -y https://trunk.rdoproject.org/centos7/current/python2-tripleo-repos-<version>.el7.centos.noarch.rpm

OSP14 (Rocky)
sudo -E tripleo-repos -b rocky current
sudo -E tripleo-repos -b rocky current ceph
sudo yum install -y python-tripleoclient

