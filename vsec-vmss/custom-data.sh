#!/bin/bash

LOG_FILE=/var/log/custom-data.log
exec >>$LOG_FILE 2>&1

# description: echo instance metadata
# args :
# optional: string contatining api version date.
# default is to "2017-08-01".
# usage :
# getInstanceMetadata "2017-12-01"
function getInstanceMetadata {
    # get instance metadata using Azure Instance Metadata service:
    if test -z "$#" ; then
        api_version="$1"
    else
        api_version="2017-08-01"
    fi
    metadata="$(get-cloud-data.sh         "metadata/instance/?api-version=$api_version" |         jq ".")"


    echo "$metadata"
    log-data "Instance metadata retrieved using api version: $api_version" >&2
}

# description: echo $@ to std output wrapped with date and additional data
# args :
# add "-w" before the content to log warning message.
# add "-e" before the content to log error message.
# default is to log info message.
# usage :
# log-data "-w" "my message"
function log-data {
    test -z "$1" && echo "$(date +"%F %T") CUSTOM-DATA [INFO]" || {
        if [[ "$1" == "-w" ]] ; then
            prefix="[WARNING] "
            shift
        elif [[ "$1" == "-e" ]] ; then
            prefix="[ERROR] "
            shift
        else
            prefix="[INFO] "
        fi
        for i in "$@"; do
            echo -e "$(date +"%F %T") CUSTOM-DATA $prefix$i"
            shift
        done
    }
}

# description: wrapper to command to enable retries
# args :
# To specify return codes:
# "-rc" followed by string of numbers seperated by a space: "int1 int2".
# default is "0".
# To specify maximum duration for retries:
# "-md" followed by a number: 5.
# default is 8.
# To specift sleep time between retries:
# "-st" followed by a number: 1.
# default is 2.
# usage :
# runcmd -rc "19 0 3" "-md" 6 "-st" 1 my-command
function runcmd {
    expected_returnval=()
    if [ "$1" == "-rc" ] ; then
        shift
        for val in $1
        do
            expected_returnval["$val"]="1"
        done
        shift
    else
        expected_returnval["0"]="1"
    fi
    if [ "$1" == "-md" ] ; then
        shift
        MAX_DURATION=$1
        shift
    else
        MAX_DURATION=8
    fi
    if [ "$1" == "-st" ] ; then
        shift
        SLEEP_TIME=$1
        shift
    else
        SLEEP_TIME=2
    fi
    cmd="$@"
    log-data "Executing $cmd" "    Allowed return values: $(echo ${!expected_returnval[@]})" "    Maximum retries duration: $MAX_DURATION" "    Sleep time between retries: $SLEEP_TIME" >&2



    SECONDS=0
    while [ "$SECONDS" -lt "$MAX_DURATION" ] ; do
        returnmsg="$("$@" 2>&1)"
        returnval="$?"
        if [[ ${expected_returnval[$returnval]} ]] ; then
            log-data "Success executing: $cmd
\\tReturn Value: $(echo $returnval)
\\tReturn message: $(echo $returnmsg)" >&2
            return 0
        fi
        log-data "-w" "Retrying to execute command: $cmd
\\tReturn Value: $(echo $returnval)
\\tReturn message: $(echo $returnmsg)" >&2
        sleep "$SLEEP_TIME"
    done
    log-data "-e" "Failed to execute command: $cmd
\\tReturn Value: $(echo $returnval) (expected: $expected_returnval)
\\tReturn message: $(echo $returnmsg)
\\tTotal run time: $SECONDS [seconds]" >&2
    return 1
}

log-data "Start of custom-data.sh"
log-data "Time Zone: $(date +"%Z %:z")"
log-data "Instance metadata at beginning: \\n$(getInstanceMetadata)"
log-data "Contents of $FWDIR/boot/modules/fwkern.conf at beginning: \\n$(cat "$FWDIR/boot/modules/fwkern.conf")"

installationType="', variables('installationType'), '"', '
allowUploadDownload="', variables('allowUploadDownload'), '"', '
osVersion="', variables('osVersion'), '"', '
templateName="', variables('templateName'), '"', '
templateVersion="', variables('templateVersion'), '"', '

log-data "templateName: $templateName" "templateVersion: $templateVersion" "installationType: $installationType" "osVersion: $osVersion"




echo "template_name: $templateName" >> /etc/cloud-version
echo "template_version: $templateVersion" >> /etc/cloud-version

log-data "Executing bootstrap script:"
bootstrap="$(dirname "$0")/bootstrap"
cat <<<"', variables('bootstrapScript64'), '" | tr -d "\n" | base64 -d >"$bootstrap"', '
dos2unix "$bootstrap"
chmod +x "$bootstrap"
cp "$bootstrap" "/var/log/custom-data-bootstrap"
"$bootstrap"

function has_iam {
    local url
    local out
    url="http://169.254.169.254/metadata/identity/oauth2/token"
    url="$url?api-version=2018-02-01&resource=https://no-such-domain/"
    for i in 1 2 3 ; do
        out="$(curl_cli --header metadata:true --url "$url" --max-time 10)"
        if test "$(echo "$out" | jq -r .error)" = "invalid_resource" ; then
            echo true
            return
        fi
        if test "$(echo "$out" | jq -r .error_description)" = "Identity not found" ; then

            break
        fi
    done
    echo false
}

# description: create file $FWDIR/conf/azure-ha.json
# args : no args
# usage : cluster
function cluster {
    log-data "Cluster - Executing cluster function"
    subscriptionId="', subscription().subscriptionId, '"', '
    tenantId="', subscription().tenantId, '"', '
    resourceGroup="', resourceGroup().name, '"', '
    virtualNetwork="', parameters('virtualNetworkName'), '"', '
    clusterName="', parameters('vmName'), '"', '
    lbName="frontend-lb"
    location="', variables('location'), '"', '
    has_iam=false

    case "$location" in
    us*)
        environment="AzureUSGovernment"
        ;;
    china*)
        environment="AzureChinaCloud"
        ;;
    germany*)
        environment="AzureGermanCloud"
        ;;
    *)
        environment="AzureCloud"
        has_iam="$(has_iam)"
        ;;
    esac

    cat <<EOF >"$FWDIR/conf/azure-ha.json"
{
  "debug": false,
  "subscriptionId": "$subscriptionId",
  "location": "$location",
  "environment": "$environment",
  "resourceGroup": "$resourceGroup",
EOF
    if $has_iam ; then
        cat <<EOF >>"$FWDIR/conf/azure-ha.json"
  "credentials": "IAM",
EOF
    else
        cat <<EOF >>"$FWDIR/conf/azure-ha.json"
  "credentials": {
    "tenant": "$tenantId",
    "grant_type": "client_credentials",
    "client_id": "",
    "client_secret": ""
  },
EOF
    fi
    cat <<EOF >>"$FWDIR/conf/azure-ha.json"
  "proxy": "",
  "virtualNetwork": "$virtualNetwork",
  "clusterName": "$clusterName",
  "templateName": "$templateName",
EOF
    cat <<EOF >>"$FWDIR/conf/azure-ha.json"
  "lbName": "$lbName"
}
EOF
    log-data "Cluster - Write cluster values to $FWDIR/conf/azure-ha.json"
    log-data "File content: \\n$(cat "$FWDIR/conf/azure-ha.json")"
    cluster_hyb=false






}

# description:
# check if an alias exists on VM, in case there is no alias,
# try to retrieve it from instance metadata & add it
# args : no args.
# usage : pub_addr="$(checkPublicAddress)"
function checkPublicAddress {
    log-data "Executing checkPublicAddress function" >&2
    ipaddr="$(ip addr show dev eth0)"
    pub_addr="$(echo "$ipaddr" |         sed -n -e "s|^ *inet \\([^/]*\\)/.* eth0:1\$|\\1|p")"

    log-data "At start - " "ip addr show dev eth0: \\n$ipaddr" "pub_addr: $pub_addr" >&2
    if test -z "$pub_addr" ; then
        log-data "Trying to set alias for public ip address" >&2
        pub_addr="$(get-cloud-data.sh             "metadata/instance/network/interface?api-version=2017-04-02" |             jq -r ".[].ipv4.ipAddress[].publicIpAddress" |             grep --max-count 1 .)"



        log-data "Public Address from instance metadata: $pub_addr" >&2
        test -z "$pub_addr" || {
            runcmd -rc "1 0" clish -c "lock database override" >&2
            runcmd clish -s -c "add interface eth0 alias $pub_addr/32" >&2
            if [ "$?" -eq "0" ] ; then
                log-data "Setting alias for eth0 completed successfuly" >&2
            else
                log-data "Failed to set alias for eth0" >&2
            fi
        }
    fi
    log-data "Interfaces at end: \\n$(ifconfig)" >&2
    test -z "$pub_addr" || echo "$pub_addr"
}

case "$installationType" in
gateway)
    installSecurityGateway=true
    gateway_cluster_member=false
    installSecurityManagement=false
    sicKey="', variables('sicKey'), '"', '
    ;;
cluster)
    installSecurityGateway=true
    gateway_cluster_member=true
    installSecurityManagement=false
    sicKey="', variables('sicKey'), '"', '
    cluster
    ;;
vmss)
    installSecurityGateway=true
    gateway_cluster_member=false
    installSecurityManagement=false
    sicKey="', variables('sicKey'), '"', '
    ;;
management)
    installSecurityGateway=false
    installSecurityManagement=true
    sicKey=notused
    ;;
custom)
    pub_addr="$(checkPublicAddress)"
    log-data "Instance metadata at end: \\n$(getInstanceMetadata)"
    exit 0
    ;;
standalone | *)
    installSecurityGateway=true
    installSecurityManagement=true
    gateway_cluster_member=false
    sicKey=notused
    ;;
esac

log-data "installSecurityGateway: $installSecurityGateway" "gateway_cluster_member: $gateway_cluster_member" "installSecurityManagement: $installSecurityManagement"



conf="install_security_gw=$installSecurityGateway"
if "$installSecurityGateway"; then
    conf="${conf}&install_ppak=true"
    conf="${conf}&gateway_cluster_member=$gateway_cluster_member"
fi
conf="${conf}&install_security_managment=$installSecurityManagement"
if "$installSecurityManagement"; then
    if [ "R7730" == "$osVersion" ]; then
        managementAdminPassword="$(dd if=/dev/urandom count=1 2>/dev/null | sha1sum | cut -c -28)"
        conf="${conf}&mgmt_admin_name=admin"
        conf="${conf}&mgmt_admin_passwd=${managementAdminPassword}"
    else
        conf="${conf}&mgmt_admin_radio=gaia_admin"
    fi

    managementGUIClientNetwork="', variables('managementGUIClientNetwork'), '"', '
    ManagementGUIClientBase="$(echo "$managementGUIClientNetwork" | cut -d / -f 1)"
    ManagementGUIClientMaskLength="$(echo "$managementGUIClientNetwork" | cut -d / -f 2)"

    conf="${conf}&install_mgmt_primary=true"
    conf="${conf}&mgmt_gui_clients_radio=network"
    conf="${conf}&mgmt_gui_clients_ip_field=$ManagementGUIClientBase"
    conf="${conf}&mgmt_gui_clients_subnet_field=$ManagementGUIClientMaskLength"
fi

conf="${conf}&download_info=$allowUploadDownload"
conf="${conf}&upload_info=$allowUploadDownload"
log-data "conf: $conf"
# add sicKey value after loging the rest of conf parameters in order not to save the SIC key.
conf="${conf}&ftw_sic_key=$sicKey"

#since DA process is running parallel to FTW and may cause to problems like SIM (TaskId=72815)
#the DA is being stoped before FTW is running, and restart again after FTW is finished.
log-data "Stop DA process: $(/opt/CPda/bin/dastop)"

log-data "Running first time wizard"
config_system -s "$conf"

log-data "Start DA process: $(/opt/CPda/bin/dastart)"

pub_addr="$(checkPublicAddress)"
log-data "VM public address is: $pub_addr"

# set the main IP of the management object in SmartConsole to be the public IP:
if [ "$installationType" = "management" ] && [ "R7730" != "$osVersion" ]; then
    until mgmt_cli -r true discard ; do
        sleep 30
    done
    addr="$(ip addr show dev eth0 |         sed -n -e "s|^ *inet \\([^/]*\\)/.* eth0\$|\\1|p")"

    uid="$(mgmt_cli -r true show-generic-objects         class-name com.checkpoint.objects.classes.dummy.CpmiHostCkp         details-level full -f json |             jq -r ".objects[] | select(.ipaddr == \"$addr\") | .uid")"



    test -z "$uid" || test -z "$pub_addr" || mgmt_cli -r true set-generic-object uid "$uid" ipaddr "$pub_addr"

        log-data "Management - Set management object in SmartConsole IP address to $pub_addr"
fi
if "$installSecurityManagement" && [ "R7730" != "$osVersion" ]; then
    chkconfig --add autoprovision
    log-data "Add autoprovision service to chkconfig"
fi


if [ "$installationType" = "vmss" ] || [ "$installationType" = "cluster" ]; then
    # add dynamic objects to represent the GWs external NICs in management:
    dynamic_object_names="$(dynamic_objects -l | awk "/object/{print \$4}")"
    log-data "dynamic object names before are: $dynamic_object_names"

    ExtAddr="$(ip addr show dev eth0 | awk "/inet/{print \$2; exit}" | cut -d / -f 1)"
    runcmd -rc "19 0 3" dynamic_objects -n LocalGatewayExternal -r "$ExtAddr" "$ExtAddr" -a
    if [ "$?" -eq "0" ] ; then
        log-data "Created dynamic object for eth0"
    else
        log-data "Failed to create dynamic object for eth0"
    fi

    log-data "Set dynamic objects: (Ext: $ExtAddr) \\n$(dynamic_objects -l)"
fi


if [ "$installationType" == "vmss" ]; then
    # add dynamic objects to represent the GWs internal NICs in management:
    IntAddr="$(ip addr show dev eth1 | awk "/inet/{print \$2; exit}" | cut -d / -f 1)"
    runcmd -rc "19 0 3" dynamic_objects -n LocalGatewayInternal -r "$IntAddr" "$IntAddr" -a
    if [ "$?" -eq "0" ] ; then
        log-data "VMSS - created dynamic object for eth1"
    else
        log-data "VMSS - failed to create dynamic object for eth1"
    fi
    log-data "VMSS - Set dynamic objects: (Int: $IntAddr) \\n$(dynamic_objects -l)"

    # add static route for all vnet but Frontend to use eth1:
    subnet1Prefix="$(getInstanceMetadata | jq -r ".network.interface[0].ipv4.subnet[].address")"
    firstThreeOctats="$(echo $subnet1Prefix | cut -d / -f 1 | cut -d . -f 1,2,3)"
    forthOctats="$(echo $subnet1Prefix | cut -d / -f 1 | cut -d . -f 4)"
    forthOctats="$(( forthOctats + 1 ))"
    router="$firstThreeOctats.$forthOctats"
    log-data "Internal subnet CIDR: $subnet1Prefix" "Internal subnet gateway: $router"
    vnets=("$vnet" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
    runcmd -rc "1 0" clish -c "lock database override" >&2
    for vnet in "${vnets[@]}"; do
        runcmd clish -s -c "set static-route $vnet nexthop gateway address $router on"
        if [ "$?" == "0" ] ; then
            log-data "Set static-route for vnet: $vnet to router: $router"
        else
            log-data "Failed to set static-route for vnet: $vnet to router: $router"
        fi
    done
fi

log-data "VM static routes: \\n$(route)"
log-data "Contents of $FWDIR/boot/modules/fwkern.conf at end: \\n$(cat "$FWDIR/boot/modules/fwkern.conf")"

if "$installSecurityGateway"; then
    log-data "Instance metadata at end: \\n$(getInstanceMetadata)"
    log-data "VM is shuting down"
    shutdown -r now
else
    if "$installSecurityManagement" && [ "R7730" != "$osVersion" ]; then
        service autoprovision start
        log-data "Instance metadata at end: \\n$(getInstanceMetadata)"
        log-data "Start service autoprovision"
    fi
fi