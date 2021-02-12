#!/usr/bin/env bash

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

echo "Checking prometheus service port 9090 ..."
while read namespace name _junk
do
    prometheus_namespace="$namespace"
    prometheus_svc_name="$name"
done < <(kubectl get svc --all-namespaces |grep 9090|head -1)

[ "${prometheus_svc_name}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't find prometheus_svc_name(port 9090)!$(tput sgr 0)" && exit
[ "${prometheus_namespace}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't find prometheus_namespace!$(tput sgr 0)" && exit
echo -e "\tprometheus_namespace=$prometheus_namespace"
echo -e "\tprometheus_svc_name=$prometheus_svc_name"

key="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/selector:/{getline; print}'|cut -d ":" -f1|xargs`"
value="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/selector:/{getline; print}'|cut -d ":" -f2|xargs`"

[ "${key}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't find prometheus svc selector key!$(tput sgr 0)" && exit
[ "${value}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't find prometheus svc selector value!$(tput sgr 0)" && exit
echo -e "\tselector=\"$key=$value\""

prometheus_pod_name="`kubectl get pods -l "${key}=${value}" -n $prometheus_namespace|grep -v NAME|head -1|awk '{print $1}'`"

[ "${prometheus_pod_name}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't find prometheus_pod_name!$(tput sgr 0)" && exit
echo -e "\tprometheus_pod_name=$prometheus_pod_name"

echo -e "\nCheck all current prometheus metrics ..."

# Method 1
prometheus_metrics_list="`curl -s http://${prometheus_svc_name}.${prometheus_namespace}.svc:9090/api/v1/label/__name__/values 2>/dev/null|python -m json.tool 2>/dev/null`"
if [ "$prometheus_metrics_list" != "" ];then
    suggested_prometheus_url="http://${prometheus_svc_name}.${prometheus_namespace}.svc:9090"
fi

# Method 2
if [ "$prometheus_metrics_list" = "" ];then
    prometheus_metrics_list=$(kubectl run -it --rm debug --image=containersai/alpine-curl --restart=Never -- -w "\n" http://${prometheus_svc_name}.${prometheus_namespace}:9090/api/v1/label/__name__/values 2>/dev/null | grep -v "pod \"debug\" deleted"|python -m json.tool 2>/dev/null)
    if [ "$prometheus_metrics_list" != "" ];then
        suggested_prometheus_url="http://${prometheus_svc_name}.${prometheus_namespace}:9090"
    fi
fi

# Method 3
openshift_minor_version=`oc version 2>/dev/null|grep "oc v"|cut -d '.' -f2`
if [ "$prometheus_metrics_list" = "" ] && [ "$openshift_minor_version" != "" ];then
    while [[ "$interactive_enabled" != "y" ]] && [[ "$interactive_enabled" != "n" ]]
    do
        default="y"
        read -r -p "$(tput setaf 2)Do you want to input OpenShift admin account&password to query prometheus metrics? [default: y]: $(tput sgr 0)" interactive_enabled </dev/tty
        interactive_enabled=${interactive_enabled:-$default}
    done

    if [ "$interactive_enabled" = "y" ];then
        read -r -p "Input OpenShift admin account: " user_account
        read -rs -p "Input OpenShift admin password: " user_password
        echo ""
        base64_info=`echo -n "${user_account}:${user_password}" | base64`
        access_token=`curl -k -H "Authorization: Basic ${base64_info}" -I https://localhost:8443/oauth/authorize\?response_type\=token\&client_id\=openshift-challenging-client 2>&1 | grep -oP "access_token=\K[^&]*"`
        # svc for 9091
        prometheus_svc_name=`kubectl get svc -n ${prometheus_namespace}|grep 9091|awk '{print $1}'`
        prometheus_metrics_list=$(kubectl run -it --rm debug --image=containersai/alpine-curl --restart=Never -- -w "\n" -k -H "Authorization: Bearer ${access_token}" https://${prometheus_svc_name}.${prometheus_namespace}:9091/api/v1/label/__name__/values 2>/dev/null | grep -v "pod \"debug\" deleted"|python -m json.tool 2>/dev/null)
    fi

    if [ "$prometheus_metrics_list" != "" ];then
        suggested_prometheus_url="https://${prometheus_svc_name}.${prometheus_namespace}:9091"
    fi
fi

# Method 4
if [ "$prometheus_metrics_list" = "" ];then
    prometheus_metrics_list="`kubectl exec $prometheus_pod_name -n $prometheus_namespace -- curl -s http://localhost:9090/api/v1/label/__name__/values 2>/dev/null|python -m json.tool 2>/dev/null`"
fi

[ "${prometheus_metrics_list}" = "" ] && echo -e "\n$(tput setaf 10)Warning! prometheus_metrics_list is empty due to prometheus api query failed$(tput sgr 0)"

echo -e "\nGet all needed metrics from Alameda github project ..."
needed_metrics_list="`curl -sL --fail https://raw.githubusercontent.com/containers-ai/alameda/master/docs/metrics_used_in_Alameda.md |grep "\- metric name:"|cut -d ":" -f2-|xargs`"

[ "${needed_metrics_list}" = "" ] && echo -e "\n$(tput setaf 1)Error, can't get needed_metrics_list! Please check internet connection.$(tput sgr 0)" && exit

echo -e "\n======================================================================================"

check_result_passed="y"
for metrics in `echo $needed_metrics_list`
#for metrics in `echo $needed_metrics_list`
do
    echo "$prometheus_metrics_list" |grep -q "$metrics"
    if [ "$?" = "0" ]; then
        printf '%-80s %-10s\n' $metrics "$(tput setaf 6)Found$(tput sgr 0)"
    else
        check_result_passed="n"
        printf '%-80s %-10s\n' $metrics "$(tput setaf 1)Not Found$(tput sgr 0)"
    fi
done
echo -e "======================================================================================"
if [ "$check_result_passed" = "y" ];then
    echo -e "\n$(tput setaf 11)Prometheus metrics check - Passed\n$(tput sgr 0)"

    if [ "$suggested_prometheus_url" != "" ];then
        echo -e "$(tput setaf 10)Suggest to use below Prometheus URL while installing Federator.ai:$(tput sgr 0)"
        echo -e "$(tput setaf 11)${suggested_prometheus_url}\n$(tput sgr 0)"
    fi
else
    echo -e "\n$(tput setaf 11)Prometheus metrics check - Failed\n"
    echo "Check this page for further details:"
    echo "https://github.com/containers-ai/alameda/blob/master/docs/metrics_used_in_Alameda.md $(tput sgr 0)"
fi
