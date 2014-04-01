#!/usr/bin/env bash 


echo "Please Enter your Swift PROXY IP/Hostname:"
read SWIFT_IP
echo 
echo 
ORIGINAL_DIR=$(pwd)

#FIX me
#PASSWORD=password

apt-get update ; apt-get -y install git python-pip

# Upgrade pip itself
pip install --upgrade pip
newgrp
pip install --upgrade pbr

#For compiling dependencies of several pip libraries , you need to install following packages first
apt-get install -y gcc python-dev libxml2-dev libxslt-dev

#Clone the Keystone Source code from GitHub and check the stable/grizzly version
cd /opt ; git clone https://github.com/openstack/keystone.git ; cd /opt/keystone
git checkout stable/havana

# Install packages from local cache
pip install -r /opt/keystone/requirements.txt

echo "=================================Starting to install KEYSTONE==========================================="
echo
echo
cd /opt/keystone ; python setup.py install

# Create Keystone configurartion Folder
mkdir -p /etc/keystone ; cd /etc/keystone ; cp /opt/keystone/etc/* /etc/keystone/
rename 's/\.sample//' /etc/keystone/*.sample


#Prepare MySQL 
sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password password swiftstack'
sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password swiftstack'
apt-get -y install mysql-server python-mysqldb
mysql -uroot -pswiftstack -e "CREATE DATABASE keystone"
mysql -uroot -pswiftstack -e "GRANT ALL ON keystone.* TO 'keystone'@'*' IDENTIFIED BY 'swiftstack'"
mysql -uroot -pswiftstack -e "GRANT ALL ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'swiftstack'"
sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf
sudo service mysql restart

#Configuration Section

sed -e 's/# connection = sqlite:\/\/\/keystone.db/connection = mysql:\/\/keystone:swiftstack@localhost\/keystone/' -i /etc/keystone/keystone.conf
sed 's/#token_format =/token_format = UUID/' -i /etc/keystone/keystone.conf
sed 's/ec2_extension user_crud_extension/ec2_extension s3_extension user_crud_extension/' -i /etc/keystone/keystone-paste.ini


#Add keystone user
useradd keystone

#Create log folder
mkdir /var/log/keystone  
sleep 2 
chown -R keystone:keystone /var/log/keystone

#Populate Data into keystone DB
keystone-manage db_sync

sleep 1
# Copy upstart and service start script 
################## UPSTART ######################

cd $ORIGINAL_DIR ; cp keystone-init.d /etc/init.d/keystone ; cp keystone.conf-init /etc/init/keystone.conf

service keystone start 
sleep 3
service keystone status

################################################

###### Inject Sample Data ######
CONTROLLER_PUBLIC_ADDRESS=${CONTROLLER_PUBLIC_ADDRESS:-localhost}
CONTROLLER_ADMIN_ADDRESS=${CONTROLLER_ADMIN_ADDRESS:-localhost}
CONTROLLER_INTERNAL_ADDRESS=${CONTROLLER_INTERNAL_ADDRESS:-localhost}

#TOOLS_DIR=$(cd $(dirname "$0") && pwd)
KEYSTONE_CONF=${KEYSTONE_CONF:-/etc/keystone/keystone.conf}

# Extract some info from Keystone's configuration file
if [[ -r "$KEYSTONE_CONF" ]]; then
    CONFIG_SERVICE_TOKEN=$(sed 's/[[:space:]]//g' $KEYSTONE_CONF | grep admin_token= | cut -d'=' -f2)
    CONFIG_ADMIN_PORT=$(sed 's/[[:space:]]//g' $KEYSTONE_CONF | grep admin_port= | cut -d'=' -f2)
fi

export SERVICE_TOKEN=${SERVICE_TOKEN:-$CONFIG_SERVICE_TOKEN}
if [[ -z "$SERVICE_TOKEN" ]]; then
    echo "No service token found."
    echo "Set SERVICE_TOKEN manually from keystone.conf admin_token."
    exit 1
fi

export SERVICE_ENDPOINT=http://localhost:35357/v2.0

function get_id () {
    echo `"$@" | grep ' id ' | awk '{print $4}'`
}



echo "===================================ENV VAR============================"
echo $SERVICE_TOKEN
echo $SERVICE_ENDPOINT
#
# Default tenant
#
DEMO_TENANT=$(get_id keystone tenant-create --name=demo \
                                            --description "Default Tenant")

ADMIN_USER=$(get_id keystone user-create --name=admin \
                                         --pass=secrete)

ADMIN_ROLE=$(get_id keystone role-create --name=admin)

keystone user-role-add --user-id $ADMIN_USER \
                       --role-id $ADMIN_ROLE \
                       --tenant-id $DEMO_TENANT

#
# Service tenant
#
SERVICE_TENANT=$(get_id keystone tenant-create --name=service \
                                               --description "Service Tenant")

SWIFT_USER=$(get_id keystone user-create --name=swift \
                                         --pass=password \
                                         --tenant-id $SERVICE_TENANT)

keystone user-role-add --user-id $SWIFT_USER \
                       --role-id $ADMIN_ROLE \
                       --tenant-id $SERVICE_TENANT


#
# Keystone service
#
KEYSTONE_SERVICE=$(get_id \
keystone service-create --name=keystone \
                        --type=identity \
                        --description="Keystone Identity Service")
if [[ -z "$DISABLE_ENDPOINTS" ]]; then
    keystone endpoint-create --region RegionOne --service-id $KEYSTONE_SERVICE \
        --publicurl "http://$CONTROLLER_PUBLIC_ADDRESS:\$(public_port)s/v2.0" \
        --adminurl "http://$CONTROLLER_ADMIN_ADDRESS:\$(admin_port)s/v2.0" \
        --internalurl "http://$CONTROLLER_INTERNAL_ADDRESS:\$(public_port)s/v2.0"
fi


#
# Swift service
#
SWIFT_SERVICE=$(get_id \
keystone service-create --name=swift \
                        --type="object-store" \
                        --description="Swift Service")
if [[ -z "$DISABLE_ENDPOINTS" ]]; then
    keystone endpoint-create --region RegionOne --service-id $SWIFT_SERVICE \
        --publicurl   "http://$SWIFT_IP/v1/KEY_\$(tenant_id)s" \
        --adminurl    "http://$CONTROLLER_ADMIN_ADDRESS/v1" \
        --internalurl "http://$CONTROLLER_INTERNAL_ADDRESS/v1/KEY_\$(tenant_id)s"
fi

echo "==================Smaple data Inject Finished=========================="
echo
sleep 2
echo
echo "==================Create User/Password/Tenant : swiftstack/password/SS===================="

SS_TENANT=$(get_id \
keystone tenant-create --name SS --enabled true --description "SwiftStack-DEV Tenant")
keystone user-create --name swiftstack --pass password --tenant-id $SS_TENANT --email support@swiftstack.com --enabled true

echo
echo "================= Test v2.0 API to get TOKEN/Service Catalog of user swiftstack =================="
sleep 2

curl -d '{"auth":{"passwordCredentials":{"username": "swiftstack", "password": "password"},"tenantName":"SS"}}' -H "Content-type: application/json" http://localhost:5000/v2.0/tokens | python -mjson.tool

sleep 2
echo
echo "================== Test Keystone V3 API to get TOKEN/Service Catalog of user swiftstack ====================="

curl -d '{"auth":{"identity":{"methods":["password"],"password":{"user":{"domain":{"name":"default"},"name":"swiftstack","password":"password"}}},"scope":{"project":{"domain":{"name":"default"},"name":"SS"}}}}' -H "Content-type: application/json" http://localhost:5000/v3/auth/tokens | python -mjson.tool

echo "===========Keystone Middleware setting for this deployment============="

echo "[ Keystone Auth ]"
echo "operator_roles : admin, swiftoperator, _member_"
echo "reseller_prefix : KEY_"
echo "reseller_admin_role : ResellerAdmin"
echo
echo "[Keystone Auth Token Support]"
echo "auth_admin_prefix : (leave blank)"
echo "auth_host : \$IP_OF_KEYSTONE_HOST"
echo "auth_port : 35357"
echo "auth_protocol : http"
echo "auth_uri : http://\$KEYSTONE_IP:5000/"
echo "admin_user : swift"
echo "admin_password : password"
echo "admin_tenant_name : service"
echo "signing_dir : /var/cache/swift"
echo "include_service_catalog : False"

echo "=====Done====="





