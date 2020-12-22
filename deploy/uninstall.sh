#!/usr/bin/env bash

remove_containersai_crds()
{
    containersai_crd_list=`kubectl get crd -o name | grep containers.ai 2>/dev/null`
    for crd in `echo $containersai_crd_list`
    do
        echo -e "$(tput setaf 2)\nDeleting $crd ...$(tput sgr 0)"
        kubectl delete $crd
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing crd $crd$(tput sgr 0)"
            #exit 2
        fi
    done
}

remove_all_alamedaservice()
{
    alamedaservice_list=`kubectl get alamedaservice --all-namespaces -o name 2>/dev/null`

    kubectl get alamedaservice --all-namespaces|grep -v NAMESPACE|while read ns servicename extra
    do
        echo -e "$(tput setaf 2)\nDeleting $servicename in $ns namespace...$(tput sgr 0)"
        #kubectl delete alamedaservice $servicename -n $ns
        kubectl delete clusterrole alameda-gc
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $servicename in $ns namespace$(tput sgr 0)"
            #exit 2
        fi
    done

    # wait for pods to be deleted
    sleep 10
}

parse_version(){
    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

download_operator_yaml_if_needed()
{
    operator_files=`curl --silent https://api.github.com/repos/containers-ai/federatorai-operator/contents/deploy/upstream?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`

    for file in `echo $operator_files`
    do
        if [ ! -f "$file" ]; then
            echo "Downloading file $file ..."
            if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/deploy/upstream/${file} -O; then
                echo -e "\n$(tput setaf 1)Abort, download file failed!!!$(tput sgr 0)"
                echo "Please check tag name and network"
                #exit 1
            fi
        fi
    done

    tag_without_v="${tag_number:1}"

    if [ "$installed_namespace" != "" ]; then
        if [ $(parse_version $tag_without_v) -ge $(parse_version "4.2.272") ] && [ $(parse_version $tag_without_v) -le $(parse_version "4.2.275") ]; then
            sed -i "s/ubi:latest/ubi:${tag_number}/g" 05*.yaml
            # for namespace
            sed -i "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
            sed -i "s/federatorai/${installed_namespace}/g" 04*.yaml
            sed -i "s/namespace: federatorai/namespace: ${installed_namespace}/g" 01*.yaml 05*.yaml 07*.yaml 08*.yaml 09*.yaml
        else
            sed -i "s/ubi:latest/ubi:${tag_number}/g" 03*.yaml
            # for namespace
            sed -i "s/name: federatorai/name: ${installed_namespace}/g" 00*.yaml
            sed -i "s/namespace: federatorai/namespace: ${installed_namespace}/g" 01*.yaml 03*.yaml 05*.yaml 06*.yaml 07*.yaml
        fi
    fi

}

remove_operator_yaml()
{
    for yaml_fn in `ls [0-9]*yaml | sort -n -r`
    do
        echo -e "$(tput setaf 2)\nDeleting $yaml_fn ...$(tput sgr 0)"
        kubectl delete -f ${yaml_fn}
        if [ "$?" != "0" ]; then
            echo -e "$(tput setaf 1)Error in removing $yaml_fn$(tput sgr 0)"
            #exit 2
        fi
    done
}

wait_until_namespace_removed()
{
  period="$1"
  interval="$2"

  for ((i=0; i<$period; i+=$interval)); do

    # check if namespace still exist
    kubectl get ns "$installed_namespace" 2>/dev/null |grep -q "$installed_namespace"
    if [ "$?" != "0" ]; then
        echo -e "\nNamespace $installed_namespace is removed successfully."
        return 0
    else
        echo "Waiting for the namespace to be removed..."
    fi

    sleep "$interval"
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but namespace $installed_namespace still exist.$(tput sgr 0)"
  #exit 4
}

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

file_folder="/tmp/install-op"
mkdir -p $file_folder
current_location=`pwd`
cd $file_folder

echo -e "$(tput setaf 3)\n----------------------------------------"
echo -e "Starting remove Federator.ai product"
echo -e "----------------------------------------\n$(tput sgr 0)"

while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
do
    # init variables
    tag_number=""

    read -r -p "$(tput setaf 2)Please input your Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty

    echo -e "\n----------------------------------------"
    echo "Your tag number = $tag_number"
    echo "----------------------------------------"

    default="y"
    read -r -p "$(tput setaf 2)Is the above information correct? [default: y]: $(tput sgr 0)" info_correct </dev/tty
    info_correct=${info_correct:-$default}
done

installed_namespace=`kubectl get pods --all-namespaces|grep "federatorai-operator"|awk '{print $1}'`

download_operator_yaml_if_needed

remove_all_alamedaservice

remove_operator_yaml

wait_until_namespace_removed 900 60

remove_containersai_crds
