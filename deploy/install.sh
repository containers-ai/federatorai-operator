#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for installing Federator.ai Operator
#
#   1. Interactive Mode
#      Usage: ./install.sh
#
#   2. Silent Mode - Persistent storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y \
#                   -s persistent -l 11 -d 12 -c managed-nfs-storage
#
#   3. Silent Mode - Ephemeral storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y \
#                   -s ephemeral
#
#   -t followed by tag_number
#   -n followed by install_namespace
#   -s followed by storage_type
#   -l followed by log_size
#   -d followed by data_size
#   -i followed by influxdb_size
#   -c followed by storage_class
#   -x followed by expose_service (y or n)
#################################################################################################################

is_pod_ready()
{
  [[ "$(kubectl get po "$1" -n "$2" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]]
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"

  kubectl get pod -n $namespace \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.phase}{"\t"}{.status.reason}{"\n"}{end}' \
      | while read name status phase reason _junk; do
          if [ "$status" != "True" ]; then
            msg="Waiting for pod $name in namespace $namespace to be ready."
            [ "$phase" != "" ] && msg="$msg phase: [$phase]"
            [ "$reason" != "" ] && msg="$msg reason: [$reason]"
            echo "$msg"
            return 1
          fi
        done || return 1

  return 0
}

leave_prog()
{
    echo -e "\n$(tput setaf 5)Downloaded YAML files are located under $file_folder $(tput sgr 0)"
    cd $current_location > /dev/null
}

webhook_exist_checker()
{
    kubectl get alamedanotificationchannels -o 'jsonpath={.items[*].metadata.annotations.notifying\.containers\.ai\/test-channel}' 2>/dev/null | grep -q 'done'
    if [ "$?" = "0" ];then
        webhook_exist="y"
    fi
}

webhook_reminder()
{
    if [ "$openshift_minor_version" != "" ]; then
        echo -e "\n========================================"
        echo -e "$(tput setaf 9)Note!$(tput setaf 10) The following $(tput setaf 9)two admission plugins $(tput setaf 10)need to be enabled on $(tput setaf 9)each master node $(tput setaf 10)to make Email Notification work properly."
        echo -e "$(tput setaf 6)1. ValidatingAdmissionWebhook 2. MutatingAdmissionWebhook$(tput sgr 0)"
        echo -e "Steps: (On every master nodes)"
        echo -e "A. Edit /etc/origin/master/master-config.yaml"
        echo -e "B. Insert following content after admissionConfig:pluginConfig:"
        echo -e "$(tput setaf 3)    ValidatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "    MutatingAdmissionWebhook:"
        echo -e "      configuration:"
        echo -e "        kind: DefaultAdmissionConfig"
        echo -e "        apiVersion: v1"
        echo -e "        disable: false"
        echo -e "$(tput sgr 0)C. Save the file."
        echo -e "D. Execute below commands to restart OpenShift API and controller:"
        echo -e "$(tput setaf 6)1. master-restart api 2. master-restart controllers$(tput sgr 0)"
    fi
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

    oc get clusterversion 2>/dev/null|grep -vq "VERSION"
    if [ "$?" = "0" ];then
        # OpenShift 4.x
        openshift_minor_version="12"
        return 0
    fi

    oc_token="$(oc whoami token 2>/dev/null)"
    oc_route="$(oc get route console -n openshift-console -o=jsonpath='{.status.ingress[0].host}' 2>/dev/null)"
    if [ "$oc_token" != "" ] && [ "$oc_route" != "" ]; then
        curl -s -k -H "Authorization: Basic ${oc_token}" https://${oc_route}:8443/version/openshift |grep -q '"minor":'
        if [ "$?" = "0" ]; then
            # OpenShift 3.11
            openshift_minor_version="11"
            return 0
        fi
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

check_alameda_datahub_tag()
{
    period="$1"
    interval="$2"
    namespace="$3"

    for ((i=0; i<$period; i+=$interval)); do
         current_tag="`kubectl get pod -n $namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image | grep datahub | head -1 |awk -F'/' '{print $NF}'|cut -d ':' -f2`"
        if [ "$current_tag" = "$tag_number" ]; then
            echo -e "\ndatahub pod is running.\n"
            return 0
        fi
        # echo "Waiting for datahub pod with current tag number shows up as $tag_number ..."
        echo "Waiting for datahub($tag_number) pod to be ready ..."
        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but datahub pod doesn't show up. Please check $namespace namespace$(tput sgr 0)"
    leave_prog
    exit 7
}

# prometheus_abnormal_handle()
# {
#     default="y"
#     echo ""
#     echo "$(tput setaf 127)We found that the Prometheus in system doesn't meet Federator.ai requirement.$(tput sgr 0)"
#     echo "$(tput setaf 127)Do you want to continue Federator.ai installation?$(tput sgr 0)"
#     echo "$(tput setaf 3) y) Only Datadog integration function works.$(tput sgr 0)"
#     echo "$(tput setaf 3) n) Abort installation.$(tput sgr 0)"
#     read -r -p "$(tput setaf 127)[default: y]: $(tput sgr 0)" continue_even_abnormal </dev/tty
#     continue_even_abnormal=${continue_even_abnormal:-$default}

#     if [ "$continue_even_abnormal" = "n" ]; then
#         echo -e "\n$(tput setaf 1)Uninstalling Federator.ai operator...$(tput sgr 0)"
#         for yaml_fn in `ls [0-9]*.yaml | sort -nr`; do
#             echo "Deleting ${yaml_fn}..."
#             kubectl delete -f ${yaml_fn}
#         done
#         leave_prog
#         exit 8
#     else
#         set_prometheus_rule_to="n"
#     fi
# }

# check_prometheus_metrics()
# {
#     echo "Checking Prometheus..."
#     current_operator_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-operator-"|awk '{print $1}'|head -1`"
#     kubectl exec $current_operator_pod_name -n $install_namespace -- /usr/bin/federatorai-operator prom_check > /dev/null 2>&1
#     return_state="$?"
#     echo "Return state = $return_state"
#     if [ "$return_state" = "0" ];then
#         # State = OK
#         set_prometheus_rule_to="y"
#     elif [ "$return_state" = "1" ];then
#         # State = Patchable
#         default="y"
#         read -r -p "$(tput setaf 127)Do you want to update the Prometheus rule to meet the Federator.ai requirement? [default: y]: $(tput sgr 0)" patch_answer </dev/tty
#         patch_answer=${patch_answer:-$default}
#         if [ "$patch_answer" = "n" ]; then
#             # Need to double confirm
#             prometheus_abnormal_handle
#         else
#             set_prometheus_rule_to="y"
#         fi
#     elif [ "$return_state" = "2" ];then
#         # State = Abnormal
#         prometheus_abnormal_handle
#     fi
# }

wait_until_pods_ready()
{
  period="$1"
  interval="$2"
  namespace="$3"
  target_pod_number="$4"

  wait_pod_creating=1
  for ((i=0; i<$period; i+=$interval)); do

    if [[ "$wait_pod_creating" = "1" ]]; then
        # check if pods created
        if [[ "`kubectl get po -n $namespace 2>/dev/null|wc -l`" -ge "$target_pod_number" ]]; then
            wait_pod_creating=0
            echo -e "\nChecking pods..."
        else
            echo "Waiting for pods in namespace $namespace to be created..."
        fi
    else
        # check if pods running
        if pods_ready $namespace; then
            echo -e "\nAll $namespace pods are ready."
            return 0
        fi
        echo "Waiting for pods in namespace $namespace to be ready..."
    fi

    sleep "$interval"
    
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but all pods are not ready yet. Please check $namespace namespace$(tput sgr 0)"
  leave_prog
  exit 4
}

get_grafana_route()
{
    if [ "$openshift_minor_version" != "" ] ; then
        link=`oc get route -n $1 2>/dev/null|grep "federatorai-dashboard-frontend"|awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access GUI through $(tput setaf 6)https://${link} $(tput sgr 0)"
        echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo -e "\nAlso, you can start to apply alamedascaler CR for the target you would like to monitor."
        echo "$(tput setaf 6)Review the administration guide for further details.$(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain grafana route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access GUI through $(tput setaf 6)https://<YOUR IP>:$dashboard_frontend_node_port $(tput sgr 0)"
            echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo -e "\nAlso, you can start to apply alamedascaler CR for the target you would like to monitor."
            echo "$(tput setaf 6)Review the administration guide for further details.$(tput sgr 0)"
            echo "========================================"
        fi
    fi
}

get_restapi_route()
{
    if [ "$openshift_minor_version" != "" ] ; then
        link=`oc get route -n $1 2>/dev/null|grep "federatorai-rest" |awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access Federatorai REST API through $(tput setaf 6)https://${link} $(tput sgr 0)"
        echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo "The REST API online document can be found in $(tput setaf 6)https://${link}/apis/v1/swagger/index.html $(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain Federatorai REST API route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access Federatorai REST API through $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port $(tput sgr 0)"
            echo "The default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo "The REST API online document can be found in $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port/apis/v1/swagger/index.html $(tput sgr 0)"
            echo "========================================"
        fi
    fi
}

setup_data_adapter_secret()
{
    secret_name="federatorai-data-adapter-secret"
    secret_api_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_api_key}'|base64 -d`"
    secret_app_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_application_key}'|base64 -d`"

    modified="n"
    if [ "$secret_api_key" = "" ] || [ "$secret_app_key" = "" ] || [ "$secret_api_key" = "dummy" ] || [ "$secret_app_key" = "dummy" ]; then
        modified="y"
        while [ "$input_api_key" = "" ] || [ "$input_app_key" = "" ]
        do
            read -r -p "$(tput setaf 2)Please input Datadog API key: $(tput sgr 0)" input_api_key </dev/tty
            input_api_key=`echo -n "$input_api_key" | base64`
            read -r -p "$(tput setaf 2)Please input Datadog Application key: $(tput sgr 0)" input_app_key </dev/tty
            input_app_key=`echo -n "$input_app_key" | base64`
        done
    else
        while [ "$reconfigure_action" != "y" ] && [ "$reconfigure_action" != "n" ]
        do
            default="n"
            read -r -p "$(tput setaf 2)Do you want to reconfigure Datadog API & Application keys? [default: $default]: $(tput sgr 0)" reconfigure_action </dev/tty
            reconfigure_action=${reconfigure_action:-$default}
            reconfigure_action=$(echo "$reconfigure_action" | tr '[:upper:]' '[:lower:]')
        done
        if [ "$reconfigure_action" = "y" ]; then
            modified="y"
            while [ "$input_api_key" = "" ] || [ "$input_app_key" = "" ]
            do
                default="$secret_api_key"
                read -r -p "$(tput setaf 2)Please input Datadog API key [current: $default]: $(tput sgr 0)" input_api_key </dev/tty
                input_api_key=${input_api_key:-$default}
                input_api_key=`echo -n "$input_api_key" | base64`

                default="$secret_app_key"
                read -r -p "$(tput setaf 2)Please input Datadog Application key [current: $default]: $(tput sgr 0)" input_app_key </dev/tty
                input_app_key=${input_app_key:-$default}
                input_app_key=`echo -n "$input_app_key" | base64`
            done
        fi
    fi

    if [ "$modified" = "y" ]; then
        kubectl patch secret $secret_name -n $install_namespace --type merge --patch "{\"data\":{\"datadog_api_key\": \"$input_api_key\"}}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update datadog API key in data adapter secret.$(tput sgr 0)"
            exit 1
        fi
        kubectl patch secret $secret_name -n $install_namespace --type merge --patch "{\"data\":{\"datadog_application_key\": \"$input_app_key\"}}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update datadog Application key in data adapter secret.$(tput sgr 0)"
            exit 1
        fi
        restart_data_adapter_pod
    fi
}

restart_data_adapter_pod()
{
    adapter_pod_name=`kubectl get pods -n $install_namespace -o name |grep "federatorai-data-adapter-"|cut -d '/' -f2`
    if [ "$adapter_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get Federator.ai data adapter pod name!$(tput sgr 0)"
        exit 2
    fi
    kubectl delete pod $adapter_pod_name -n $install_namespace
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to delete Federator.ai data adapter pod $adapter_pod_name$(tput sgr 0)"
        exit 8
    fi
    wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 5
}

check_previous_alamedascaler()
{
    while read version alamedascaler_name alamedascaler_ns
    do
        if [ "$version" = "" ] || [ "$alamedascaler_name" = "" ] || [ "$alamedascaler_ns" = "" ]; then
           continue
        fi

        if [ "$version" = "autoscaling.containers.ai/v1alpha1" ]; then
            echo -e "\n$(tput setaf 3)Warning!! Found alamedascaler with previous v1alpha1 version. Name: $alamedascaler_name Namespace: $alamedascaler_ns $(tput sgr 0)"
        fi
    done <<< "$(kubectl get alamedascaler --all-namespaces --output jsonpath='{range .items[*]}{"\n"}{.apiVersion}{"\t"}{.metadata.name}{"\t"}{.metadata.namespace}' 2>/dev/null)"
}

get_datadog_agent_info()
{
    while read a b c
    do
        dd_namespace=$a
        dd_key=$b
        dd_api_secret_name=$c
        if [ "$dd_namespace" != "" ] && [ "$dd_key" != "" ] && [ "$dd_api_secret_name" != "" ]; then
           break
        fi
    done<<<"$(kubectl get daemonset --all-namespaces -o jsonpath='{range .items[*]}{@.metadata.namespace}{"\t"}{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_API_KEY")].name}{"\t"}{.env[?(@.name=="DD_API_KEY")].valueFrom.secretKeyRef.name}{"\n"}{end}{"\t"}{end}' 2>/dev/null| grep "DD_API_KEY")"

    if [ "$dd_key" = "" ] || [ "$dd_namespace" = "" ] || [ "$dd_api_secret_name" = "" ]; then
        return
    fi
    dd_api_key="`kubectl get secret -n $dd_namespace $dd_api_secret_name -o jsonpath='{.data.api-key}'`"
    dd_app_key="`kubectl get secret -n $dd_namespace -o jsonpath='{range .items[*]}{.data.app-key}'`"
    dd_cluster_agent_deploy_name="$(kubectl get deploy -n $dd_namespace|grep -v NAME|awk '{print $1}'|grep "cluster-agent$")"
    dd_cluster_name="$(kubectl get deploy $dd_cluster_agent_deploy_name -n $dd_namespace 2>/dev/null -o jsonpath='{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_CLUSTER_NAME")].value}')"
}

display_cluster_scaler_file_location()
{
    echo -e "You can find $alamedascaler_cluster_filename template file inside $file_folder"
}

# get_cluster_name()
# {
#     cluster_name=`kubectl get cm cluster-info -n default -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#     if [ "$cluster_name" = "" ];then
#         cluster_name=`kubectl get cm cluster-info -n kube-public -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#         if [ "$cluster_name" = "" ];then
#             cluster_name=`kubectl get cm cluster-info -n kube-service-catalog’ -o yaml 2>/dev/null|grep uid|awk '{print $2}'`
#         fi
#     fi
# }

setup_cluster_alamedascaler()
{
    alamedascaler_cluster_filename="alamedascaler_federatorai.yaml"

    cat > ${alamedascaler_cluster_filename} << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha2
kind: AlamedaScaler
metadata:
  name: clusterscaler
  namespace: ${install_namespace}
spec:
  clusterName: NeedToBeReplacedByClusterName
__EOF__

    # Get Datadog agent info (User configuration)
    get_datadog_agent_info

    if [ "$dd_cluster_agent_deploy_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to auto-discover Datadog cluster agent deployment.$(tput sgr 0)"
        echo -e "\n$(tput setaf 1)Datadog cluster agent needs to be installed to make WPA/HPA work properly.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    fi

    if [ "$dd_cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to auto-discover DD_CLUSTER_NAME value in Datadog cluster agent env variable.$(tput sgr 0)"
        echo -e "\n$(tput setaf 1)Please help to set up cluster name accordingly.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    else
        kubectl describe alamedascaler --all-namespaces 2>/dev/null |grep "Cluster Name"|grep -q "$dd_cluster_name"
        if [ "$?" = "0" ];then
            # Found at least one alamedascaler. No need to apply alamedascaler for cluster
            return
        fi
    fi

    while [ "$monitor_cluster" != "y" ] && [ "$monitor_cluster" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 127)Do you want to monitor this cluster? [default: $default]: $(tput sgr 0)" monitor_cluster </dev/tty
        monitor_cluster=${monitor_cluster:-$default}
        monitor_cluster=$(echo "$monitor_cluster" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$monitor_cluster" = "n" ]; then
        display_cluster_scaler_file_location
        return
    fi

    if [ "$dd_namespace" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent installed namespace.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    elif [ "$dd_api_key" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent API key. Please correctly configure the datadog agent API key.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    elif [ "$dd_app_key" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find the datadog agent APP key. Please correctly configure the datadog agent APP key.$(tput sgr 0)"
        display_cluster_scaler_file_location
        return
    fi

    echo -e "$(tput setaf 3)Use \"$dd_cluster_name\" as the cluster name and DD_CLUSTER_NAME$(tput sgr 0)"
    sed -i "s|\bclusterName:.*|clusterName: ${dd_cluster_name}|g" $alamedascaler_cluster_filename

    echo "Applying file $alamedascaler_cluster_filename ..."
    kubectl apply -f $alamedascaler_cluster_filename
    if [ "$?" != "0" ];then
        echo -e "$(tput setaf 3)Warning!! Failed to apply $alamedascaler_cluster_filename $(tput sgr 0)"
    fi
    echo "Done"
    display_cluster_scaler_file_location
}

# get_recommended_prometheus_url()
# {
#     if [[ "$openshift_minor_version" == "11" ]] || [[ "$openshift_minor_version" == "12" ]]; then
#         prometheus_port="9091"
#         prometheus_protocol="https"
#     else
#         # OpenShift 3.9 # K8S
#         prometheus_port="9090"
#         prometheus_protocol="http"
#     fi

#     found_none="n"
#     while read namespace name _junk
#     do
#         prometheus_namespace="$namespace"
#         prometheus_svc_name="$name"
#         found_none="y"
#     done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep 9090|grep " None "|sort|head -1)"

#     if [ "$prometheus_svc_name" = "" ]; then
#         while read namespace name _junk
#         do
#             prometheus_namespace="$namespace"
#             prometheus_svc_name="$name"
#         done<<<"$(kubectl get svc --all-namespaces --show-labels|grep -i prometheus|grep $prometheus_port |sort|head -1)"
#     fi

#     key="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f1|xargs`"
#     value="`kubectl get svc $prometheus_svc_name -n $prometheus_namespace -o yaml|awk '/ selector:/{getline; print}'|cut -d ":" -f2|xargs`"

#     if [ "${key}" != "" ] && [ "${value}" != "" ]; then
#         prometheus_pod_name="`kubectl get pods -l "${key}=${value}" -n $prometheus_namespace|grep -v NAME|awk '{print $1}'|grep ".*\-[0-9]$"|sort -n|head -1`"
#     fi

#     # Assign default value
#     if [ "$found_none" = "y" ] && [ "$prometheus_pod_name" != "" ]; then
#         prometheus_url="$prometheus_protocol://$prometheus_pod_name.$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
#     else
#         prometheus_url="$prometheus_protocol://$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
#     fi
# }


while getopts "t:n:e:p:s:l:d:c:x:o" o; do
    case "${o}" in
        o)
            offline_mode_enabled="y"
            ;;
        t)
            t_arg=${OPTARG}
            ;;
        n)
            n_arg=${OPTARG}
            ;;
        e)
            e_arg=${OPTARG}
            ;;
        # p)
        #     p_arg=${OPTARG}
        #     ;;
        s)
            s_arg=${OPTARG}
            ;;
        l)
            l_arg=${OPTARG}
            ;;
        i)
            i_arg=${OPTARG}
            ;;
        d)
            d_arg=${OPTARG}
            ;;
        c)
            c_arg=${OPTARG}
            ;;
        x)
            x_arg=${OPTARG}
            ;;
        *)
            echo "Warning! wrong parameter, ignore it."
            ;;
    esac
done

[ "${t_arg}" = "" ] && silent_mode_disabled="y"
[ "${n_arg}" = "" ] && silent_mode_disabled="y"
#[ "${e_arg}" = "" ] && silent_mode_disabled="y"
#[ "${p_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${l_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${d_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${c_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${i_arg}" = "" ] && silent_mode_disabled="y"

[ "${t_arg}" != "" ] && specified_tag_number="${t_arg}"
[ "${n_arg}" != "" ] && install_namespace="${n_arg}"
#[ "${e_arg}" != "" ] && enable_execution="${e_arg}"
#[ "${p_arg}" != "" ] && prometheus_address="${p_arg}"
[ "${s_arg}" != "" ] && storage_type="${s_arg}"
[ "${l_arg}" != "" ] && log_size="${l_arg}"
[ "${i_arg}" != "" ] && influxdb_size="${i_arg}"
[ "${d_arg}" != "" ] && data_size="${d_arg}"
[ "${c_arg}" != "" ] && storage_class="${c_arg}"
[ "${x_arg}" != "" ] && expose_service="${x_arg}"
[ "$expose_service" = "" ] && expose_service="y" # Will expose service by default if not specified

if [ "$offline_mode_enabled" = "y" ] && [ "$RELATED_IMAGE_URL_PREFIX" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Need to specify export RELATED_IMAGE_URL_PREFIX for offline installation.$(tput sgr 0)"
    exit
fi

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

if [ "$offline_mode_enabled" != "y" ]; then
    which curl > /dev/null 2>&1
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
        exit
    fi
fi

previous_alameda_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
previous_tag="`kubectl get pods -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image 2>/dev/null| grep datahub | head -1 |awk -F'/' '{print $NF}'| cut -d ':' -f2`"
previous_alamedaservice="`kubectl get alamedaservice -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name 2>/dev/null|grep -v NAME|head -1`"

if [ "$previous_alameda_namespace" != "" ];then
    need_upgrade="y"
    ## find value of RELATED_IMAGE_URL_PREFIX for upgrading alamedaservice CR
    if [ "${RELATED_IMAGE_URL_PREFIX}" = "" ]; then
        previous_imageLocation="`kubectl get alamedaservice $previous_alamedaservice -n $previous_alameda_namespace -o 'jsonpath={.spec.imageLocation}'`"
        ## Compute previous value as RELATED_IMAGE_URL_PREFIX from federatorai-operator deployment
        if [ "$previous_imageLocation" = "" ]; then
            RELATED_IMAGE_URL_PREFIX="`kubectl get deployment federatorai-operator -n $previous_alameda_namespace -o yaml \
                                       | grep -A1 'name: .*RELATED_IMAGE_' | grep 'value: ' | grep '/alameda-ai:' \
                                       | sed -e 's|/alameda-ai:| |' | awk '{print $2}'`"
           ## Skip RELATED_IMAGE_URL_PREFIX if it is default value
           [ "${RELATED_IMAGE_URL_PREFIX}" = "quay.io/prophetstor" ] && RELATED_IMAGE_URL_PREFIX=""
        fi
    fi
fi

if [ "$silent_mode_disabled" = "y" ];then

    while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
    do
        # init variables
        install_namespace=""
        # Check if tag number is specified
        if [ "$specified_tag_number" = "" ]; then
            tag_number=""
            read -r -p "$(tput setaf 2)Please input Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty
        else
            tag_number=$specified_tag_number
        fi

        if [ "$need_upgrade" = "y" ];then
            echo -e "\n$(tput setaf 11)Previous build with tag$(tput setaf 1) $previous_tag $(tput setaf 11)detected in namespace$(tput setaf 1) $previous_alameda_namespace$(tput sgr 0)"
            install_namespace="$previous_alameda_namespace"
        else
            default="federatorai"
            read -r -p "$(tput setaf 2)Enter the namespace you want to install Federator.ai [default: federatorai]: $(tput sgr 0)" install_namespace </dev/tty
            install_namespace=${install_namespace:-$default}
        fi

        echo -e "\n----------------------------------------"
        if [ "$need_upgrade" = "y" ];then
            echo "$(tput setaf 11)Upgrade:$(tput sgr 0)"
        fi
        echo "tag_number = $tag_number"
        echo "install_namespace = $install_namespace"
        echo "----------------------------------------"

        default="y"
        read -r -p "$(tput setaf 2)Is the above information correct? [default: y]: $(tput sgr 0)" info_correct </dev/tty
        info_correct=${info_correct:-$default}
    done
else
    tag_number=$specified_tag_number
    echo -e "\n----------------------------------------"
    echo "tag_number=$specified_tag_number"
    echo "install_namespace=$install_namespace"
    #echo "enable_execution=$enable_execution"
    #echo "prometheus_address=$prometheus_address"
    echo "storage_type=$storage_type"
    echo "log_size=$log_size"
    echo "influxdb_size=$influxdb_size"
    echo "data_size=$data_size"
    echo "storage_class=$storage_class"
    if [ "$openshift_minor_version" = "" ]; then
        #k8s
        echo "expose_service=$expose_service"
    fi
    echo -e "----------------------------------------\n"
fi

file_folder="/tmp/install-op"
[ "$max_wait_pods_ready_time" = "" ] && max_wait_pods_ready_time=900  # maximum wait time for pods become ready

rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
script_located_path=$(dirname $(readlink -f "$0"))
cd $file_folder

if [ "$offline_mode_enabled" != "y" ]; then
    operator_files=`curl --silent https://api.github.com/repos/containers-ai/federatorai-operator/contents/deploy/upstream?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`
    if [ "$operator_files" = "" ]; then
        echo -e "\n$(tput setaf 1)Abort, download operator file list failed!!!$(tput sgr 0)"
        echo "Please check tag name and network"
        exit 1
    fi

    for file in `echo $operator_files`
    do
        echo "Downloading file $file ..."
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/deploy/upstream/${file} -O; then
            echo -e "\n$(tput setaf 1)Abort, download file failed!!!$(tput sgr 0)"
            echo "Please check tag name and network"
            exit 1
        fi
        echo "Done"
    done
else
    # Offline Mode
    # Copy Federator.ai operator 00-07 yamls
    echo "Copying Federator.ai operator yamls ..."
    if [[ "`ls ${script_located_path}/../operator/[0][0-7]*.yaml 2>/dev/null|wc -l`" -lt "8" ]]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate all Federator.ai operator yaml files$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute install.sh under scripts folder  "
        exit 1
    fi
    cp ${script_located_path}/../operator/[0][0-7]*.yaml .
    echo "Done"
fi

# Modify federator.ai operator yaml(s)
# for tag
sed -i "s/:latest$/:${tag_number}/g" 03*.yaml

# Specified alternative container image location
if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
    sed -i -e "s%quay.io/prophetstor%${RELATED_IMAGE_URL_PREFIX}%g" 03*.yaml
fi

# No need for recent build
# if [ "$need_upgrade" = "y" ];then
#     # for upgrade - stop operator before applying new alamedaservice
#     sed -i "s/replicas: 1/replicas: 0/g" 03*.yaml
# fi

# for namespace
sed -i "s/name: federatorai/name: ${install_namespace}/g" 00*.yaml
sed -i "s/namespace: federatorai/namespace: ${install_namespace}/g" 01*.yaml 03*.yaml 05*.yaml 06*.yaml 07*.yaml

if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ]; then
    sed -i -e "/image: /a\          resources:\n            limits:\n              cpu: 4000m\n              memory: 8000Mi\n            requests:\n              cpu: 100m\n              memory: 100Mi" `ls 03*.yaml`
fi

echo -e "\n$(tput setaf 2)Applying Federator.ai operator yaml files...$(tput sgr 0)"

# kubectl get APIService v1beta1.admission.certmanager.k8s.io >/dev/null 2>&1
# if [ "$?" = "0" ]; then
#     # system has certmanager
#     # check if it is deployed by ProphetStor
#     annotation=`kubectl get APIService v1beta1.admission.certmanager.k8s.io -o 'jsonpath={.metadata.annotations.app\.kubernetes\.io\/managed-by}' 2>/dev/null`
#     if [ "$annotation" != "federator.ai" ]; then
#         install_certmanager="n"
#     fi 
# fi

if [ "$need_upgrade" = "y" ];then
    # for upgrade - delete old federatorai-operator deployment before apply new yaml(s)

    while read deploy_name deploy_ns useless
    do
        kubectl delete deployment $deploy_name -n $deploy_ns
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting old Federator.ai operator deployment $deploy_name in ns $deploy_ns.$(tput sgr 0)"
            exit 8
        fi
    done <<< "$(kubectl get deployment --all-namespaces --output jsonpath='{range .items[*]}{"\n"}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{range .spec.template.spec.containers[*]}{.image}{end}{end}' 2>/dev/null | grep 'federatorai-operator-ubi')"

fi

for yaml_fn in `ls [0-9]*.yaml | sort -n`; do

    # if [ "$install_certmanager" = "n" ]; then
    #     if [ "$yaml_fn" = "`ls 03*.yaml`" ] || [ "$yaml_fn" = "`ls 04*.yaml`" ]; then
    #        # Only apply 03 and 04 yaml when
    #        # 1. certmanager is deployed by ProphetStor
    #        # 2. certmanager is not installed
    #        echo "Skipping ${yaml_fn}..."
    #        continue
    #     fi
    # fi
    echo "Applying ${yaml_fn}..."
    kubectl apply -f ${yaml_fn}
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in applying yaml file ${yaml_fn}.$(tput sgr 0)"
        exit 8
    fi
done

if [ "$need_upgrade" != "y" ];then
    # Skip pod checking due to federatorai-operator with advanced version may cause some pods keep crashing (Jira FA-597)
    # So we delay pod checking until alamedaservice is patched.
    wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 1
    echo -e "\n$(tput setaf 6)Install Federator.ai operator $tag_number successfully$(tput sgr 0)"
fi

alamedaservice_example="alamedaservice_sample.yaml"
if [ "$offline_mode_enabled" != "y" ]; then
    cr_files=( "alamedadetection.yaml" "alamedanotificationchannel.yaml" "alamedanotificationtopic.yaml" )

    echo -e "\nDownloading Federator.ai CR sample files ..."
    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/example/${alamedaservice_example} -O; then
        echo -e "\n$(tput setaf 1)Abort, download alamedaservice sample file failed!!!$(tput sgr 0)"
        exit 2
    fi

    for file_name in "${cr_files[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/alameda/${tag_number}/example/samples/nginx/${file_name} -O; then
            echo -e "\n$(tput setaf 1)Abort, download $file_name sample file failed!!!$(tput sgr 0)"
            exit 3
        fi
    done
    echo "Done"

    # Three kinds of alamedascaler
    # In offline mode, alamedascaler files will be downloaded by federatorai-launcher.sh
    alamedascaler_filename="alamedascaler.yaml"
    src_pool=( "kafka" "nginx" "redis" )

    echo -e "\nDownloading Federator.ai alamedascaler sample files ..."
    for pool in "${src_pool[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/alameda/${tag_number}/example/samples/${pool}/${alamedascaler_filename} -O; then
            echo -e "\n$(tput setaf 1)Abort, download $alamedascaler_filename sample file from $pool folder failed!!!$(tput sgr 0)"
            exit 3
        fi
        if [ "$pool" = "kafka" ]; then
            mv $alamedascaler_filename alamedascaler_kafka.yaml
        elif [ "$pool" = "nginx" ]; then
            mv $alamedascaler_filename alamedascaler_nginx.yaml
        else
            mv $alamedascaler_filename alamedascaler_generic.yaml
        fi
    done
    echo "Done"
else
    # Offline Mode
    # Copy CR yamls
    echo "Copying Federator.ai CR yamls ..."
    if [[ "`ls ${script_located_path}/../yamls/alameda*.yaml 2>/dev/null|wc -l`" -lt "4" ]]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate Federator.ai CR yaml files$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute install.sh under scripts folder  "
        exit 1
    fi
    cp ${script_located_path}/../yamls/alameda*.yaml .
    echo "Done"
fi

# Specified alternative container image location
if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
    sed -i -e "/version: latest/i\  imageLocation: ${RELATED_IMAGE_URL_PREFIX}" ${alamedaservice_example}
fi
# Specified version tag
sed -i "s/version: latest/version: ${tag_number}/g" ${alamedaservice_example}

echo "========================================"

if [ "$silent_mode_disabled" = "y" ] && [ "$need_upgrade" != "y" ];then

    # Check prometheus support in first non silent installation mode
    # check_prometheus_metrics

    while [[ "$information_correct" != "y" ]] && [[ "$information_correct" != "Y" ]]
    do
        # init variables
        #prometheus_address=""
        storage_type=""
        log_size=""
        data_size=""
        influxdb_size=""
        storage_class=""
        expose_service=""

        # if [ "$set_prometheus_rule_to" = "y" ]; then
        #     get_recommended_prometheus_url
        #     default="$prometheus_url"
        #     echo "$(tput setaf 127)Enter the Prometheus service address"
        #     read -r -p "[default: ${default}]: $(tput sgr 0)" prometheus_address </dev/tty
        #     prometheus_address=${prometheus_address:-$default}
        # fi

        while [[ "$storage_type" != "ephemeral" ]] && [[ "$storage_type" != "persistent" ]]
        do
            default="ephemeral"
            echo "$(tput setaf 127)Which storage type you would like to use? ephemeral or persistent?"
            read -r -p "[default: ephemeral]: $(tput sgr 0)" storage_type </dev/tty
            storage_type=${storage_type:-$default}
        done

        if [[ "$storage_type" == "persistent" ]]; then
            default="10"
            read -r -p "$(tput setaf 127)Specify log storage size [e.g., 10 for 10GB, default: 10]: $(tput sgr 0)" log_size </dev/tty
            log_size=${log_size:-$default}
            default="10"
            read -r -p "$(tput setaf 127)Specify data storage size [e.g., 10 for 10GB, default: 10]: $(tput sgr 0)" data_size </dev/tty
            data_size=${data_size:-$default}
            default="100"
            read -r -p "$(tput setaf 127)Specify InfluxDB storage size [e.g., 100 for 100GB, default: 100]: $(tput sgr 0)" influxdb_size </dev/tty
            influxdb_size=${influxdb_size:-$default}

            while [[ "$storage_class" == "" ]]
            do
                read -r -p "$(tput setaf 127)Specify storage class name: $(tput sgr 0)" storage_class </dev/tty
            done
        fi

        if [ "$openshift_minor_version" = "" ]; then
            #k8s
            default="y"
            read -r -p "$(tput setaf 127)Do you want to expose dashboard and REST API services for external access? [default: y]:$(tput sgr 0)" expose_service </dev/tty
            expose_service=${expose_service:-$default}
        fi

        echo -e "\n----------------------------------------"
        echo "install_namespace = $install_namespace"

        # if [ "$set_prometheus_rule_to" = "y" ]; then
        #     echo "prometheus_address = $prometheus_address"
        # fi
        echo "storage_type = $storage_type"
        if [[ "$storage_type" == "persistent" ]]; then
            echo "log storage size = $log_size GB"
            echo "data storage size = $data_size GB"
            echo "InfluxDB storage size = $influxdb_size GB"
            echo "storage class name = $storage_class"
        fi
        if [ "$openshift_minor_version" = "" ]; then
            #k8s
            echo "expose service = $expose_service"
        fi
        echo "----------------------------------------"

        default="y"
        read -r -p "$(tput setaf 2)Is the above information correct [default: y]:$(tput sgr 0)" information_correct </dev/tty
        information_correct=${information_correct:-$default}
    done
fi

#grafana_node_port="31010"
rest_api_node_port="31011"
dashboard_frontend_node_port="31012"

if [ "$need_upgrade" != "y" ]; then 
    # First time installation case
    sed -i "s|\bnamespace:.*|namespace: ${install_namespace}|g" ${alamedaservice_example}

    # if [ "$set_prometheus_rule_to" = "y" ]; then
    #     sed -i "s|\bprometheusService:.*|prometheusService: ${prometheus_address}|g" ${alamedaservice_example}
    #     sed -i "s|\bautoPatchPrometheusRules:.*|autoPatchPrometheusRules: true|g" ${alamedaservice_example}
    # else
    #     sed -i "s|\bautoPatchPrometheusRules:.*|autoPatchPrometheusRules: false|g" ${alamedaservice_example}
    # fi

    if [[ "$storage_type" == "persistent" ]]; then
        sed -i '/- usage:/,+10d' ${alamedaservice_example}
        cat >> ${alamedaservice_example} << __EOF__
    - usage: log
      type: pvc
      size: ${log_size}Gi
      class: ${storage_class}
    - usage: data
      type: pvc
      size: ${data_size}Gi
      class: ${storage_class}

__EOF__
    fi

    # enableGPU: false
    # enableVPA: false
    cat >> ${alamedaservice_example} << __EOF__
  enableGPU: false
  enableVPA: false
__EOF__

    if [ "$openshift_minor_version" = "" ]; then #k8s
        if [ "$expose_service" = "y" ] || [ "$expose_service" = "Y" ]; then
            cat >> ${alamedaservice_example} << __EOF__
  serviceExposures:
    - name: federatorai-dashboard-frontend
      nodePort:
        ports:
          - nodePort: ${dashboard_frontend_node_port}
            port: 9001
      type: NodePort
    - name: federatorai-rest
      nodePort:
        ports:
          - nodePort: ${rest_api_node_port}
            port: 5056
      type: NodePort
__EOF__
        fi
    fi

    # Enable resource requirement configuration
    if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ]; then
        cat >> ${alamedaservice_example} << __EOF__
  resources:
    limits:
      cpu: 4000m
      memory: 8000Mi
    requests:
      cpu: 100m
      memory: 100Mi
  alamedaAi:
    resources:
      limits:
        cpu: 8000m
        memory: 8000Mi
      requests:
        cpu: 2000m
        memory: 500Mi
  alamedaDatahub:
    resources:
      requests:
        cpu: 100m
        memory: 500Mi
  alamedaNotifier:
    resources:
      requests:
        cpu: 50m
        memory: 100Mi
  alamedaOperator:
    resources:
      requests:
        cpu: 100m
        memory: 250Mi
  alamedaRabbitMQ:
    resources:
      requests:
        cpu: 100m
        memory: 250Mi
  federatoraiRest:
    resources:
      requests:
        cpu: 50m
        memory: 100Mi
__EOF__
    fi
    if [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ] && [ "$storage_type" = "persistent" ]; then
        cat >> ${alamedaservice_example} << __EOF__
  alamedaInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
    storages:
    - usage: data
      type: pvc
      size: ${influxdb_size}Gi
      class: ${storage_class}
__EOF__
    elif [ "${ENABLE_RESOURCE_REQUIREMENT}" = "y" ] && [ "$storage_type" = "ephemeral" ]; then
        cat >> ${alamedaservice_example} << __EOF__
  alamedaInfluxdb:
    resources:
      requests:
        cpu: 500m
        memory: 500Mi
__EOF__
    elif [ "${ENABLE_RESOURCE_REQUIREMENT}" != "y" ] && [ "$storage_type" = "persistent" ]; then
        cat >> ${alamedaservice_example} << __EOF__
  alamedaInfluxdb:
    storages:
    - usage: data
      type: pvc
      size: ${influxdb_size}Gi
      class: ${storage_class}
__EOF__
    fi

    kubectl apply -f $alamedaservice_example &>/dev/null
else
    # Upgrade case, patch version to alamedaservice only
    kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"version\": \"$tag_number\"}}"

    # Specified alternative container imageLocation
    if [ "${RELATED_IMAGE_URL_PREFIX}" != "" ]; then
        kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"imageLocation\": \"${RELATED_IMAGE_URL_PREFIX}\"}}"
    fi

    # Restart operator after patching alamedaservice
    kubectl scale deployment federatorai-operator -n $install_namespace --replicas=0
    kubectl scale deployment federatorai-operator -n $install_namespace --replicas=1
fi

echo "Processing..."
check_alameda_datahub_tag $max_wait_pods_ready_time 60 $install_namespace
wait_until_pods_ready $max_wait_pods_ready_time 60 $install_namespace 5

webhook_exist_checker
if [ "$webhook_exist" != "y" ];then
    webhook_reminder
fi

setup_data_adapter_secret
get_grafana_route $install_namespace
get_restapi_route $install_namespace
echo -e "$(tput setaf 6)\nInstall Federator.ai $tag_number successfully$(tput sgr 0)"
check_previous_alamedascaler
setup_cluster_alamedascaler
leave_prog
exit 0

