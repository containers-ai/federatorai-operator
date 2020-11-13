#!/usr/bin/env bash

check_version()
{
    openshift_required_minor_version="9"
    k8s_required_version="11"
    k8s_max_allowed_version="17"

    echo "======= oc version =======" >> $preflight_check_result_file
    oc version >> $preflight_check_result_file 2>/dev/null
    echo "======= kubectl version =======" >> $preflight_check_result_file
    kubectl version >> $preflight_check_result_file 2>/dev/null
    echo "======= helm version =======" >> $preflight_check_result_file
    helm version >> $preflight_check_result_file 2>/dev/null
    
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
    {
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
    }
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" != "" ] && [ "$k8s_version" -lt "$k8s_required_version" ]; then
    {
        echo -e "\n$(tput setaf 10)Error! Kubernetes version less than 1.$k8s_required_version is not supported by Federator.ai$(tput sgr 0)"
    }
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" != "" ] && [ "$k8s_version" -gt "$k8s_max_allowed_version" ]; then
    {
        echo -e "\n$(tput setaf 10)Error! Kubernetes version greater than 1.$k8s_max_allowed_version is not supported by Federator.ai$(tput sgr 0)"
    }
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" = "" ]; then
    {
        echo -e "\n$(tput setaf 10)Error! Can't get Kubernetes or OpenShift version$(tput sgr 0)"
    }
    fi
}

get_prometheus_info()
{
    if [[ "$openshift_minor_version" == "11" ]] || [[ "$openshift_minor_version" == "12" ]]; then
        prometheus_port="9091"
        prometheus_protocol="https"
    else
        # OpenShift 3.9 # K8S
        prometheus_port="9090"
        prometheus_protocol="http"
    fi

    while read namespace name _junk
    do
        prometheus_namespace="$namespace"
        prometheus_svc_name="$name"
    done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep 9090|grep " None "|sort|head -1)"

    if [ "$prometheus_svc_name" = "" ]; then
        while read namespace name _junk
        do
            prometheus_namespace="$namespace"
            prometheus_svc_name="$name"
        done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep $prometheus_port |sort|head -1)"
    fi

    key="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f1|xargs`"
    value="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f2|xargs`"

    if [ "${key}" != "" ] && [ "${value}" != "" ]; then
        prometheus_pod_name="`kubectl get pods -l "${key}=${value}" -n $prometheus_namespace|grep -v NAME|awk '{print $1}'|grep ".*\-[0-9]$"|sort -n|head -1`"
    fi

    echo "======= prometheus info =======" >> $preflight_check_result_file
    echo "prometheus_pod_name = $prometheus_pod_name" >> $preflight_check_result_file
    echo "prometheus_namespace = $prometheus_namespace" >> $preflight_check_result_file
    operator_image=`kubectl get deployment -n $prometheus_namespace -o yaml 2>/dev/null|grep 'image:'|grep 'prometheus-operator'`
    echo "promtheus operator image = $operator_image" >> $preflight_check_result_file
    echo "======= prometheus server info =======" >> $preflight_check_result_file
    server_version="`kubectl exec -t $prometheus_pod_name -n $prometheus_namespace 2>&1 -- sh -c 'prometheus --version'`"
    echo "$server_version" >> $preflight_check_result_file
}

get_node_info()
{
    echo "======= node list =======" >> $preflight_check_result_file
    kubectl get nodes |grep -v ROLES >> $preflight_check_result_file
    echo "======= node label =======" >> $preflight_check_result_file
    kubectl get nodes --show-labels|grep -v ROLES|awk '{print $1"\n"$3"\n"$NF"\n"}' >> $preflight_check_result_file

    echo "======= node cpu and memory =======" >> $preflight_check_result_file
    while read name status roles _junk
    do
        cpu_raw=`kubectl get node $name -o 'jsonpath={.status.capacity.cpu}'`
        mem_raw=`kubectl get node $name -o 'jsonpath={.status.capacity.memory}'`
        echo "Node $name CPU $cpu_raw Memory $mem_raw" >> $preflight_check_result_file
    done <<< "$(kubectl get nodes|grep -v ROLES)"
}

login_check()
{
    result="`echo ""|kubectl cluster-info 2>/dev/null`"
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Error! Please login into OpenShift/K8S cluster first.$(tput sgr 0)"
        exit
    fi
    
    echo "======= cluster-info =======" >> $preflight_check_result_file
    echo "$result" >> $preflight_check_result_file
}

preflight_check_result_file="/tmp/preflight_result.output"
echo "" > $preflight_check_result_file

login_check
echo -e "\n$(tput setaf 2)Collecting info ...$(tput sgr 0)"
check_version
get_prometheus_info
get_node_info
echo -e "$(tput setaf 2)Done.\n$(tput sgr 0)"
echo -e "$(tput setaf 6)The preflght check result is saved to $preflight_check_result_file$(tput sgr 0)"
echo -e "\n$(tput setaf 6)Please help to collect this file. Thank you.$(tput sgr 0)"