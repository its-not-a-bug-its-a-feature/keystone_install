#!/usr/bin/env bash 


echo "Please Enter your Swift and Keystone IP for the Service Catalog:"
read SWIFT_IP
echo 
echo 
ORIGINAL_DIR=$(pwd)

#FIX me
#PASSWORD=password


echo "=================================Starting to install KEYSTONE==========================================="
echo
echo

apt-get -y install ubuntu-cloud-keyring

cat > /etc/apt/sources.list.d/20-cloudarchive.list  << EOF
deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/havana main
deb-src http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/havana main
EOF

apt-get update ; apt-get -y install keystone

# Stop it! tend to start to install-time
/etc/init.d/keystone stop


echo "=================================Starting to install MYSQL ==========================================="
echo
echo

#Prepare MySQL 
sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password password cangetin'
sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password cangetin'
apt-get -y install mysql-server python-mysqldb
mysql -uroot -pcangetin -e "CREATE DATABASE keystone"
mysql -uroot -pcangetin -e "GRANT ALL ON keystone.* TO 'keystone'@'*' IDENTIFIED BY 'cangetin'"
mysql -uroot -pcangetin -e "GRANT ALL ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'cangetin'"
sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf
sudo service mysql restart

#Configuration Section

sed -e 's@connection = sqlite:////var/lib/keystone/keystone.db@connection = mysql://keystone:cangetin\@localhost/keystone@' -i /etc/keystone/keystone.conf

sed 's/#token_format =/token_format = UUID/' -i /etc/keystone/keystone.conf
sed 's/ec2_extension user_crud_extension/ec2_extension s3_extension user_crud_extension/' -i /etc/keystone/keystone-paste.ini

echo "=================================Starting keystone app DB sync ==========================================="
echo

echo "== connection line in /etc/keystone/keystone.conf : "
echo
grep ^connection /etc/keystone/keystone.conf
echo "EXIT now if that is incorrect !"
sleep 5

#Populate Data into keystone DB
keystone-manage db_sync

sleep 10


echo "=================================Starting keystone ==========================================="
echo

/etc/init.d/keystone start

echo "=================================Starting data entry =========================================="
echo

###### Inject Sample Data ######
CONTROLLER_PUBLIC_ADDRESS=$SWIFT_IP
CONTROLLER_ADMIN_ADDRESS=$SWIFT_IP
CONTROLLER_INTERNAL_ADDRESS='127.0.0.1'

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
                                         --pass=secret)

ADMIN_ROLE=$(get_id keystone role-create --name=admin)

OPERATOR_ROLE=$(get_id keystone role-create --name=SwiftOperator)

RESELLER_ROLE=$(get_id keystone role-create --name=ResellerAdmin)

MEMBER_ROLE=$(get_id keystone role-create --name=Member)


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
    keystone endpoint-create --region LON --service-id $KEYSTONE_SERVICE \
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
    keystone endpoint-create --region LON --service-id $SWIFT_SERVICE \
        --publicurl   "http://$SWIFT_IP/v1/KEY_\$(tenant_id)s" \
        --adminurl    "http://$CONTROLLER_ADMIN_ADDRESS/v1" \
        --internalurl "http://$CONTROLLER_INTERNAL_ADDRESS/v1/KEY_\$(tenant_id)s"
fi

echo "==================Smaple data Inject Finished=========================="
echo
sleep 2
echo
echo "==================Create User/Password/Tenant : swiftstack/password/SS===================="

$SOHONET_T_NAME=sohonet

SOHONET_TENANT=$(get_id \
keystone tenant-create --name $SOHONET_T_NAME --enabled true --description "Sohonet Tenant")
keystone user-create --name demo1 --pass password --tenant-id $SOHONET_TENANT --email support@sohonet.com --enabled true
keystone user-role-add --user-id 'demo1' \
                       --role-id 'SwiftOperator' \
                       --tenant-id $SOHONET_T_NAME
keystone user-create --name demo2 --pass password --tenant-id $SOHONET_TENANT --email support@sohonet.com --enabled true
keystone user-role-add --user 'demo2' \
                       --role 'SwiftOperator' \
                       --tenant $SOHONET_T_NAME

echo
echo "================= Test v2.0 API to get TOKEN/Service Catalog of user swiftstack =================="
sleep 2

curl -d '{"auth":{"passwordCredentials":{"username": "demo1", "password": "password"},"tenantName":"sohonet"}}' -H "Content-type: application/json" http://localhost:5000/v2.0/tokens | python -mjson.tool

sleep 5

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

echo "========== DB information =========="
echo "user : root"
echo "password : cangetin"
echo ""
echo "=====Done====="





