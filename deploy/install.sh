#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for installing Federator.ai Operator
#
#   1. Interactive Mode
#      Usage: ./install.sh
#
#   2. Silent Mode - Persistent storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y -p https://prometheus-k8s.openshift-monitoring:9091 \
#                   -s persistent -l 11 -d 12 -c managed-nfs-storage
#
#   3. Silent Mode - Ephemeral storage
#      Usage: ./install.sh -t v4.2.260 -n federatorai -e y -p https://prometheus-k8s.openshift-monitoring:9091 \
#                   -s ephemeral
#
#   -t followed by tag_number
#   -n followed by install_namespace
#   -e followed by enable_execution (y or n)
#   -p followed by prometheus_address
#   -s followed by storage_type
#   -l followed by log_size
#   -d followed by data_size
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
            msg="Waiting pod $name in namespace $namespace to be ready."
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
        echo -e "$(tput setaf 9)Note!$(tput setaf 10) Below $(tput setaf 9)two admission plugins $(tput setaf 10)needed to be enabled on $(tput setaf 9)every master nodes $(tput setaf 10)to let VPA Execution and Email Notifier working properly."
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
        echo -e "D. Execute below commands to restart OpenShift api and controller:"
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
         current_tag="`kubectl get pod -n $namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image | grep datahub | head -1 | cut -d ':' -f2`"
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

check_prometheus_metrics()
{
    current_operator_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-operator-"|awk '{print $1}'|head -1`"
    kubectl exec $current_operator_pod_name -n $install_namespace -- /usr/bin/federatorai-operator prom_check > /dev/null 2>&1
    if [ "$?" != "0" ];then
        need_prometheus_rule_patch="y"
    else
        need_prometheus_rule_patch="n"
    fi
}

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
        echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo -e "\nAlso, you can start to apply alamedascaler CR for the namespace you would like to monitor."
        echo "$(tput setaf 6)Review administration guide for further details.$(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain grafana route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access GUI through $(tput setaf 6)https://<YOUR IP>:$dashboard_frontend_node_port $(tput sgr 0)"
            echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo -e "\nAlso, you can start to apply alamedascaler CR for the namespace you would like to monitor."
            echo "$(tput setaf 6)Review administration guide for further details.$(tput sgr 0)"
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
        echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo "The REST API online document can be found in $(tput setaf 6)https://${link}/apis/v1/swagger/index.html $(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain Federatorai REST API route address."
        fi
    else
        if [ "$expose_service" = "y" ]; then
            echo -e "\n========================================"
            echo "You can now access Federatorai REST API through $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port $(tput sgr 0)"
            echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
            echo "The REST API online document can be found in $(tput setaf 6)https://<YOUR IP>:$rest_api_node_port/apis/v1/swagger/index.html $(tput sgr 0)"
            echo "========================================"
        fi
    fi
}

get_recommended_prometheus_url()
{
    if [[ "$openshift_minor_version" == "11" ]] || [[ "$openshift_minor_version" == "12" ]]; then
        prometheus_port="9091"
        prometheus_protocol="https"
    else
        # OpenShift 3.9 # K8S
        prometheus_port="9090"
        prometheus_protocol="http"
    fi

    found_none="n"
    while read namespace name _junk
    do
        prometheus_namespace="$namespace"
        prometheus_svc_name="$name"
        found_none="y"
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

    # Assign default value
    if [ "$found_none" = "y" ] && [ "$prometheus_pod_name" != "" ]; then
        prometheus_url="$prometheus_protocol://$prometheus_pod_name.$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
    else
        prometheus_url="$prometheus_protocol://$prometheus_svc_name.$prometheus_namespace:$prometheus_port"
    fi
}


while getopts "t:n:e:p:s:l:d:c:x:" o; do
    case "${o}" in
        t)
            t_arg=${OPTARG}
            ;;
        n)
            n_arg=${OPTARG}
            ;;
        e)
            e_arg=${OPTARG}
            ;;
        p)
            p_arg=${OPTARG}
            ;;
        s)
            s_arg=${OPTARG}
            ;;
        l)
            l_arg=${OPTARG}
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
            echo "Warning! wrong paramter, ignore it."
            ;;
    esac
done

[ "${t_arg}" = "" ] && silent_mode_disabled="y"
[ "${n_arg}" = "" ] && silent_mode_disabled="y"
[ "${e_arg}" = "" ] && silent_mode_disabled="y"
[ "${p_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${l_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${d_arg}" = "" ] && silent_mode_disabled="y"
[ "${s_arg}" = "persistent" ] && [ "${c_arg}" = "" ] && silent_mode_disabled="y"

[ "${t_arg}" != "" ] && tag_number="${t_arg}"
[ "${n_arg}" != "" ] && install_namespace="${n_arg}"
[ "${e_arg}" != "" ] && enable_execution="${e_arg}"
[ "${p_arg}" != "" ] && prometheus_address="${p_arg}"
[ "${s_arg}" != "" ] && storage_type="${s_arg}"
[ "${l_arg}" != "" ] && log_size="${l_arg}"
[ "${d_arg}" != "" ] && data_size="${d_arg}"
[ "${c_arg}" != "" ] && storage_class="${c_arg}"
[ "${x_arg}" != "" ] && expose_service="${x_arg}"
[ "$expose_service" = "" ] && expose_service="y" # Will expose service by default if not specified

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

previous_alameda_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
previous_tag="`kubectl get pods -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image 2>/dev/null| grep datahub | head -1 | cut -d ':' -f2`"
previous_alamedaservice="`kubectl get alamedaservice -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name 2>/dev/null|grep -v NAME|head -1`"

if [ "$previous_alameda_namespace" != "" ];then
    need_upgrade="y"
fi

if [ "$silent_mode_disabled" = "y" ];then

    while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
    do
        # init variables
        install_namespace=""
        tag_number=""

        read -r -p "$(tput setaf 2)Please input Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty

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
    echo -e "\n----------------------------------------"
    echo "tag_number=$tag_number"
    echo "install_namespace=$install_namespace"
    echo "enable_execution=$enable_execution"
    echo "prometheus_address=$prometheus_address"
    echo "storage_type=$storage_type"
    echo "log_size=$log_size"
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
cd $file_folder

operator_files=`curl --silent https://api.github.com/repos/containers-ai/federatorai-operator/contents/deploy/upstream?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`

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

wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 1
echo -e "\n$(tput setaf 6)Install Federator.ai operator $tag_number successfully$(tput sgr 0)"

# Run check_prometheus_metrics only if not specified need_prometheus_rule_patch
[ "${need_prometheus_rule_patch}" = "" ] && check_prometheus_metrics

if [ "${patch_prometheus_rule}" = "" -a "${need_prometheus_rule_patch}" = "y" ]; then
    default="y"
    echo "$(tput setaf 127)Do you want to patch the prometheus rule to meet the Federator.ai requirement?$(tput sgr 0)"
    read -r -p "$(tput setaf 127)Choose 'n' will abort the installation process. [default: y]: $(tput sgr 0): " patch_prometheus_rule </dev/tty
    patch_prometheus_rule=${patch_prometheus_rule:-$default}
fi

if [ "$need_prometheus_rule_patch" = "y" ] && [ "$patch_prometheus_rule" = "n" ]; then
    echo -e "\n$(tput setaf 1)Uninstalling Federator.ai operator...$(tput sgr 0)"
    for yaml_fn in `ls [0-9]*.yaml | sort -nr`; do
        echo "Deletiabort the installationng ${yaml_fn}..."
        kubectl delete -f ${yaml_fn}
    done
    leave_prog
    exit 8
fi

alamedaservice_example="alamedaservice_sample.yaml"
cr_files=( "alamedascaler.yaml" "alamedadetection.yaml" "alamedanotificationchannel.yaml" "alamedanotificationtopic.yaml" )

echo -e "\nDownloading alameda CR sample files ..."
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

sed -i "s/version: latest/version: ${tag_number}/g" ${alamedaservice_example}

echo "========================================"

if [ "$silent_mode_disabled" = "y" ] && [ "$need_upgrade" != "y" ];then

    while [[ "$information_correct" != "y" ]] && [[ "$information_correct" != "Y" ]]
    do
        # init variables
        enable_execution=""
        prometheus_address=""
        storage_type=""
        log_size=""
        data_size=""
        storage_class=""
        expose_service=""

        default="y"
        read -r -p "$(tput setaf 127)Do you want to enable execution? [default: y]: $(tput sgr 0): " enable_execution </dev/tty
        enable_execution=${enable_execution:-$default}

        get_recommended_prometheus_url
        default="$prometheus_url"

        echo "$(tput setaf 127)Enter the Prometheus service address"
        read -r -p "[default: ${default}]: $(tput sgr 0)" prometheus_address </dev/tty
        prometheus_address=${prometheus_address:-$default}

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

            while [[ "$storage_class" == "" ]]
            do
                read -r -p "$(tput setaf 127)Specify storage class name: $(tput sgr 0)" storage_class </dev/tty
            done
        fi

        if [ "$openshift_minor_version" = "" ]; then
            #k8s
            default="y"
            read -r -p "$(tput setaf 127)Do you want to expose Grafana and Rest API services for external access? [default: y]:$(tput sgr 0)" expose_service </dev/tty
            expose_service=${expose_service:-$default}
        fi

        echo -e "\n----------------------------------------"
        echo "install_namespace = $install_namespace"
        if [[ "$enable_execution" == "y" ]]; then
            echo "enable_execution = true"
        else
            echo "enable_execution = false"
        fi
        echo "prometheus_address = $prometheus_address"
        echo "storage_type = $storage_type"
        if [[ "$storage_type" == "persistent" ]]; then
            echo "log storage size = $log_size GB"
            echo "data storage size = $data_size GB"
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

    if [[ "$enable_execution" == "y" ]]; then
        sed -i "s/\benableExecution:.*/enableExecution: true/g" ${alamedaservice_example}
    else
        sed -i "s/\benableExecution:.*/enableExecution: false/g" ${alamedaservice_example}
    fi

    sed -i "s|\bprometheusService:.*|prometheusService: ${prometheus_address}|g" ${alamedaservice_example}
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

    kubectl apply -f $alamedaservice_example &>/dev/null
else
    # Upgrade case, patch version to alamedaservice only
    kubectl patch alamedaservice $previous_alamedaservice -n $install_namespace --type merge --patch "{\"spec\":{\"version\": \"$tag_number\"}}"

    # Start operator after patching alamedaservice
    kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
fi

echo "Processing..."
check_alameda_datahub_tag $max_wait_pods_ready_time 60 $install_namespace
wait_until_pods_ready $max_wait_pods_ready_time 60 $install_namespace 5

webhook_exist_checker
if [ "$webhook_exist" != "y" ];then
    webhook_reminder
fi

get_grafana_route $install_namespace
get_restapi_route $install_namespace
echo -e "$(tput setaf 6)\nInstall Alameda $tag_number successfully$(tput sgr 0)"
leave_prog
exit 0

