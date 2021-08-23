
#!/bin/bash

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# This is a post configuration script works on Ubuntu Linux machine which has migrated to AWS or Azure
# using the workflow Pure has designed to expedite your migration to Pure CLoud Block Store (CBS), check the links below for detailed guides:
# https://support.purestorage.com/Pure_Cloud_Block_Store/VMware_VM_Migratation_to_AWS_with_Cloud_Block_Store_and_AWS_Application_Migration_Services
# The script will achieve the following:
# 1. Install required packages.
# 2. Apply iSCSi and multipath best practice configuration.
# 3. Connect to CBS and create a host. 
# 4. provision the storage by cloning the replicated data volume.
# 5. Create iSCSi initiator and discover the connected volume
# 6. Mount the volume


CBS_MNGMT_IP=172.23.2.180
SNAPSHOT=flasharray-m20-1:cbs-aws-migration-policy.36.vvol-Linux-ubuntu-2004-68951764-vg/Data-a2e2d086
DATA_VOLUME_PATH=/mnt/data

# VARIABLES
# CBS_MNGMT_IP=<enter_IP_address>
# SNAPSHOT=<enter_replicated_snapshot>
# DATA_VOLUME_PATH=<enter_mount_path>

# Example
# CBS_MNGMT_IP=10.21.202.52
# SNAPSHOT=flasharray-m20-2:Data-aa029a51
# DATA_VOLUME_PATH=/data



# Update and install required packages 
sudo apt update 
sudo apt upgrade -y
sudo apt install open-iscsi -y
sudo apt install lsscsi -y
sudo apt install jq -y


# mutlipath and iscsi best practices configuration
sudo service iscsid start
sudo /etc/init.d/open-iscsi restart

# Increase number of iscsi sessions per connection
sudo sed -i 's/^\(node\.session\.nr_sessions\s*=\s*\).*$/\132/' /etc/iscsi/iscsid.conf

# Change iscsi service to start automatically on boot
sudo sed -e '/^node.startup/s/manual/automatic/g' -i /etc/iscsi/iscsid.conf



sudo sed -e 's/^#*/#/g' -i /etc/multipath.conf

sudo cat << EOF >> /etc/multipath.conf
defaults {
       polling_interval 10
       user_friendly_names yes
       find_multipaths yes
}
devices {
       device {
               vendor                "PURE"
               path_selector         "queue-length 0"
               path_grouping_policy  group_by_prio
               path_checker          tur
               fast_io_fail_tmo      10
               no_path_retry         queue
               hardware_handler      "1 alua"
               prio                  alua
               failback              immediate
       }
}
EOF

sudo service multipathd restart

# Get IQN
IQN=$( sudo grep InitiatorName /etc/iscsi/initiatorname.iscsi | awk -F= '{ print $2 }')
IQN=`echo $IQN | sed 's/ *$//g'`

# Generate api token
CBS_API_TOKEN=$(curl -s -k -X POST -H "Content-Type: application/json" -d '{"username": "pureuser","password": "pureuser"}' 'https://'$CBS_MNGMT_IP'/api/1.19/auth/apitoken')

# Create a session
curl -k -H "Content-Type:application/json" -X POST -k -d "$CBS_API_TOKEN" 'https://'$CBS_MNGMT_IP'/api/1.19/auth/session' -c ./cookies 

# Get iscsi interface ip
ISCSI_CBS_C0=$(curl -s -k --cookie ./cookies -X GET 'https://'$CBS_MNGMT_IP'/api/1.19/network/ct0.eth2' -H 'Content-Type: application/json' | jq --raw-output '.address')


# Create a host 
HOSTNAME=$(hostname)
curl -k --cookie ./cookies -X POST 'https://'$CBS_MNGMT_IP'/api/1.19/host/'$HOSTNAME'' -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "iqnlist": ["$IQN"]
}
EOF
)"


# Clone the Target snapshot to a volume 

curl -k --cookie ./cookies  -H "Content-Type:application/json" -X POST 'https://'$CBS_MNGMT_IP'/api/1.19/volume/clone_data01'  -d "$(cat <<EOF
{
  "source": "$SNAPSHOT"
}
EOF
)"

# Conenct cloned volume to the created host 
curl -k --cookie ./cookies -H "Content-Type:application/json" -X POST 'https://'$CBS_MNGMT_IP'/api/1.19/host/'$HOSTNAME'/volume/clone_data01' 


# iscsi initiator configuratione 
sudo iscsiadm -m iface -I iscsi0 -o new
sudo iscsiadm -m discovery -t st -p $ISCSI_CBS_C0:3260
sudo iscsiadm -m node --login
sudo iscsiadm -m node -L automatic


# The below are for confirming iSCSI session and mltipath are configured probably 
# sudo iscsiadm --mode session
# sudo lsscsi -d
# sudo multipath -ll


# mount volume
sudo mkdir $DATA_VOLUME_PATH
DISK=$(sudo multipath -ll|awk '{print $1;exit}')
sudo mount /dev/mapper/$DISK $DATA_VOLUME_PATH
