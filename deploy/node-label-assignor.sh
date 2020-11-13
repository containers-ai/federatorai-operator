#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for assign node label for cost analysis function
#
#################################################################################################################

show_usage()
{
    cat << __EOF__

    Usage:
        -f <space> label file full path [e.g., -f /tmp/label_file]

__EOF__
    exit 1
}

check_version()
{
    openshift_required_minor_version="9"
    k8s_required_version="11"

    oc version 2>/dev/null|grep "oc v"|grep -q " v[4-9]"
    if [ "$?" = "0" ];then
        # oc version is 4-9, passed
        openshift_minor_version="12"
        return 0
    fi

    # OpenShift Container Platform 4.x
    oc version 2>/dev/null|grep -q "Server Version: 4"
    if [ "$?" = "0" ];then
        # oc server version is 4, passed
        openshift_minor_version="12"
        return 0
    fi

    oc version 2>/dev/null|grep "oc v"|grep -q " v[0-2]"
    if [ "$?" = "0" ];then
        # oc version is 0-2, failed
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    fi

    # oc major version = 3
    openshift_minor_version=`oc version 2>/dev/null|grep "oc v"|cut -d '.' -f2`
    # k8s version = 1.x
    k8s_version=`kubectl version 2>/dev/null|grep Server|grep -o "Minor:\"[0-9]*.\""|tr ':+"' " "|awk '{print $2}'`

    if [ "$openshift_minor_version" != "" ] && [ "$openshift_minor_version" -lt "$openshift_required_minor_version" ]; then
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" != "" ] && [ "$k8s_version" -lt "$k8s_required_version" ]; then
        echo -e "\n$(tput setaf 10)Error! Kubernetes version less than 1.$k8s_required_version is not supported by Federator.ai$(tput sgr 0)"
        exit 6
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" = "" ]; then
        echo -e "\n$(tput setaf 10)Error! Can't get Kubernetes or OpenShift version$(tput sgr 0)"
        exit 5
    fi
}

assign_label_to_each_nodes()
{
    while read node_name node_role instance_type availability_zone instance_id others
    do
        echo -e "\n$(tput setaf 6)Starting label $node_name : $node_role node ...$(tput sgr 0)"
        if [ "$node_name" = "" ] || [ "$node_role" = "" ] || [ "$instance_type" = "" ] || [ "$availability_zone" = "" ] || [ "$instance_id" = "" ]; then
           continue
        fi

        if [[ $node_role == *"master"* ]]; then
            kubectl get nodes $node_name --show-labels | grep -q "node-role.kubernetes.io/master"
            if [ "$?" != "0" ]; then
                kubectl label --overwrite node $node_name node-role.kubernetes.io/master=""
            fi
        fi
        region="`echo $availability_zone|sed 's/.$//'`"
        kubectl label --overwrite node $node_name beta.kubernetes.io/instance-type=$instance_type
        kubectl label --overwrite node $node_name failure-domain.beta.kubernetes.io/region=$region
        kubectl label --overwrite node $node_name failure-domain.beta.kubernetes.io/zone=$availability_zone
        kubectl patch nodes $node_name --type merge --patch "{\"spec\":{\"providerID\": \"aws:///us-west-2a/$instance_id\"}}"
        echo "Done"
    done <<< "$(cat $label_file)"
}

if [ "$#" -eq "0" ]; then
    show_usage
    exit
fi

while getopts "f:h" o; do
    case "${o}" in
        f)
            label_file_enabled="y"
            label_file=${OPTARG}
            ;;
        h)
            show_usage
            exit
            ;;
        *)
            echo -e "\n$(tput setaf 1)Error! wrong paramter.$(tput sgr 0)"
            show_usage
            exit 5
    esac
done

[ "$label_file_enabled" = "" ] && label_file_enabled="n"

if [ "$label_file_enabled" = "y" ]; then
    if [ "$label_file" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing label file path value$(tput sgr 0)"
        show_usage
        exit
    fi

    if [ ! -f "$label_file" ]; then
        echo -e "\n$(tput setaf 1)Error! label file doesn't exist, please check file path value.$(tput sgr 0)"
        exit
    fi
fi

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

if [ "$label_file_enabled" = "y" ]; then
    assign_label_to_each_nodes
fi

exit 0
