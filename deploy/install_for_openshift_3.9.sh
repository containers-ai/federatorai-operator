#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for installing Federator.ai Operator
#
#   1. Usage: 
#        ./install.sh
#
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
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      | while read name status _junk; do
          if [ "$status" != "True" ]; then
            echo "Waiting pod $name in namespace $namespace to be ready..."
            return 1
          fi
        done || return 1

  return 0
}

leave_prog()
{
    echo -e "\n$(tput setaf 5)Downloaded files are located under $file_folder $(tput sgr 0)"
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
        link=`oc get route -n $1 2>/dev/null|grep grafana|awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access GUI through $(tput setaf 6)http://${link} $(tput sgr 0)"
        echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo -e "\nAlso, you can start to apply alamedascaler CR for the namespace you would like to monitor."
        echo "$(tput setaf 6)Review administration guide for further details.$(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain grafana route address."
        fi
    fi
}

get_restapi_route()
{
    if [ "$openshift_minor_version" != "" ] ; then
        link=`oc get route -n $1 2>/dev/null|grep "federatorai-rest" |awk '{print $2}'`
        if [ "$link" != "" ] ; then
        echo -e "\n========================================"
        echo "You can now access Federatorai REST API through $(tput setaf 6)http://${link} $(tput sgr 0)"
        echo "Default login credential is $(tput setaf 6)admin/admin$(tput sgr 0)"
        echo "The REST API online document can be found in $(tput setaf 6)http://${link}/apis/v1/swagger/index.html $(tput sgr 0)"
        echo "========================================"
        else
            echo "Warning! Failed to obtain Federatorai REST API route address."
        fi
    fi
}

check_helm()
{
    helm version 2>&1|grep -q "^Client:"
    client_ret=$?
    helm version 2>&1|grep -q "^Server:"
    server_ret=$?
    if [ "$client_ret" -eq "0" ];then
        helm_client_ready="y"
    else
        helm_client_ready="n"
    fi
    if [ "$server_ret" -eq "0" ];then
        helm_server_ready="y"
    else
        helm_server_ready="n"
    fi
}

check_prometheus()
{
    echo -e "Checking Prometheus metrics ..."
    prom_script_name="prometheus-metrics-checker.sh"
    if [ ! -f "$prom_script_name" ];then
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/4.2.2xx/deploy/$prom_script_name -O; then
            echo -e "\n$(tput setaf 1)Abort, download prometheus-metrics-checker.sh failed!!!$(tput sgr 0)"
            echo "Please check your network"
            exit 1
        fi
    fi

    prom_result=`bash prometheus-metrics-checker.sh 2>&1`
    echo "$prom_result" |grep -q "Prometheus metrics check - Passed"
    if [ "$?" = "0" ];then
        install_prometheus_needed="n"
        echo -e "Passed. All needed metrics are found."
        # Remove color code "sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g""
        suggest_prometheus_url=`echo "$prom_result" |awk '/Suggest to use below Prometheus/{getline; print}'|sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" |sed -r "s/[[:cntrl:]]\[[0-9]{1,3}m//g"`
    else
        install_prometheus_needed="y"
        echo "$prom_result"
        echo "$prom_result" |grep -q "prometheus_namespace="
        script_found=$?
        pod_result=`kubectl get pods --all-namespaces|awk '{print $2}'|grep "prometheus"`
        pod_found=$?
        svc_result=`kubectl get svc --all-namespaces|awk '{print $2}'|grep "prometheus"`
        svc_found=$?
        if [ "$script_found" = "0" ] || [ "$pod_found" = "0" ] || [ "$svc_found" = "0" ];then
            # prometheus exists but not all needed metrics are found
            echo -e "\n$(tput setaf 1)Found following existing Prometheus info:$(tput sgr 0)"
            echo -e "-----------------------------------------------"
            echo -e "Prometheus pod:"
            echo -e "$(tput setaf 11)$pod_result$(tput sgr 0)"
            echo -e "-----------------------------------------------"
            echo -e "Prometheus svc:"
            echo -e "$(tput setaf 11)$svc_result$(tput sgr 0)"
            echo -e "-----------------------------------------------"
            echo -e "\n$(tput setaf 1)Please fix Prometheus metrics missing issue before running installation script.$(tput sgr 0)"
            echo "Check this page for further details:"
            echo "$(tput setaf 6)https://github.com/containers-ai/alameda/blob/master/docs/metrics_used_in_Alameda.md$(tput sgr 0)"
            leave_prog
            exit 11
        else
            # prometheus doens't exist
            echo -e "Prometheus doesn't exist."
        fi
    fi
}

install_helm_client()
{
    if ! curl -sL --fail https://git.io/get_helm.sh -O; then
        echo -e "\n$(tput setaf 1)Abort, download get_helm.sh failed!!!$(tput sgr 0)"
        echo "Please check your network"
        exit 1
    fi

    chmod 700 get_helm.sh
    bash ./get_helm.sh -v ${DESIRED_HELM_VERSION}
    sleep 3
}

install_helm_server()
{
    kubectl create serviceaccount -n kube-system tiller
    kubectl create clusterrolebinding tiller-binding --clusterrole=cluster-admin --serviceaccount kube-system:tiller
    helm init --service-account tiller

    count=20
    interval=30
    # Wait for helm ready
    echo -e "$(tput setaf 2)Waiting for Helm server become ready ...$(tput sgr 0)"
    for i in `seq 1 $count`
    do
        check_helm
        if [ "$helm_server_ready" = "y" ]; then
            break
        fi
        echo "..."
        sleep $interval
    done

    if [ "$helm_server_ready" != "y" ]; then
        echo -e "\n$(tput setaf 1)Error!! Waited for $(( $count * $interval )) seconds, but Helm server is still not ready.$(tput sgr 0)"
        leave_prog
        exit 11
    else
        echo -e "Helm server is ready."
    fi
}

install_prometheus()
{
    echo -e "$(tput setaf 2)Downloading Prometheus chart...$(tput sgr 0)"
    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/4.2.2xx/deploy/prometheus_4.3.1_chart_for_openshift_3.9_prophetstor_version.tar.gz -O; then
        echo -e "\n$(tput setaf 1)Abort, download prometheus_4.3.1_chart_for_openshift_3.9_prophetstor_version.tar.gz failed!!!$(tput sgr 0)"
        echo "Please check your network"
        exit 1
    fi
    tar zxf prometheus_4.3.1_chart_for_openshift_3.9_prophetstor_version.tar.gz
    oc new-project $prometheus_namespace 2>/dev/null
    oc patch namespace $prometheus_namespace -p '{"metadata": {"annotations": {"openshift.io/node-selector": ""}}}'
    echo -e "$(tput setaf 2)Installing Prometheus chart...$(tput sgr 0)"
    sleep 3
    helm install ./prometheus-operator/ --name prom --namespace $prometheus_namespace
    oc adm policy add-scc-to-user privileged -n $prometheus_namespace -z prom-prometheus-node-exporter
}

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

file_folder="/tmp/install-op"
rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
cd $file_folder

check_prometheus

check_helm

DESIRED_HELM_VERSION=v2.14.3

if [ "$helm_client_ready" = "n" ] && [ "$install_prometheus_needed" = "y" ];then
    default="y"
    read -r -p "$(tput setaf 2)Do you want to install Helm client for installing Prometheus? [default: y]: $(tput sgr 0)" install_helm_client </dev/tty
    install_helm_client=${install_helm_client:-$default}
    if [ "$install_helm_client" = "y" ];then
        install_helm_client
    else
        echo -e "\n$(tput setaf 1)Abort installation."
        echo -e "Please manually configure Prometheus rules to meet Alameda requirement and rerun the installation script$(tput sgr 0)"
        leave_prog
        exit 11
    fi
fi

check_helm

if [ "$helm_server_ready" = "n" ] && [ "$install_prometheus_needed" = "y" ];then
    default="y"
    read -r -p "$(tput setaf 2)Do you want to install Helm server for installing Prometheus? [default: y]: $(tput sgr 0)" install_helm_server </dev/tty
    install_helm_server=${install_helm_server:-$default}
    if [ "$install_helm_server" = "y" ];then
        install_helm_server
    else
        echo -e "\n$(tput setaf 1)Abort installation."
        echo -e "Please manually configure Prometheus rules to meet Alameda requirement and rerun the installation script$(tput sgr 0)"
        leave_prog
        exit 11
    fi
fi

if [ "$install_prometheus_needed" = "y" ];then
    prometheus_namespace="monitoring"
    install_prometheus
    echo -e "$(tput setaf 2)Checking Prometheus pods status...$(tput sgr 0)"
    wait_until_pods_ready 600 20 $prometheus_namespace 5
    echo -e "$(tput setaf 2)Sleeping 2 minutes for Prometheus to get metrics and do metrics checking again...$(tput sgr 0)"
    sleep 120
    check_prometheus
fi

previous_alameda_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
previous_tag="`kubectl get pods -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image 2>/dev/null| grep datahub | head -1 | cut -d ':' -f2`"

if [ "$previous_alameda_namespace" != "" ];then
    need_upgrade="y"
fi

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
sed -i "s/ubi:latest/ubi:${tag_number}/g" 03*.yaml
if [ "$need_upgrade" = "y" ];then
    # for upgrade - stop operator before applying new alamedaservice
    sed -i "s/replicas: 1/replicas: 0/g" 03*.yaml
fi
# for namespace
sed -i "s/name: federatorai/name: ${install_namespace}/g" 00*.yaml
sed -i "s/namespace: federatorai/namespace: ${install_namespace}/g" 01*.yaml 03*.yaml 05*.yaml 06*.yaml 07*.yaml

echo -e "\n$(tput setaf 2)Starting apply Federator.ai operator yaml files$(tput sgr 0)"

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

wait_until_pods_ready 600 30 $install_namespace 1
echo -e "\n$(tput setaf 6)Install Federator.ai operator $tag_number successfully$(tput sgr 0)"

alamedaservice_example="alamedaservice_sample.yaml"
alamedascaler_example="alamedascaler.yaml"

echo -e "\nDownloading alamedaservice and alamedascaler sample files ..."
if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/example/${alamedaservice_example} -O; then
    echo -e "\n$(tput setaf 1)Abort, download alamedaservice sample file failed!!!$(tput sgr 0)"
    exit 2
fi

if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/alameda/${tag_number}/example/samples/nginx/${alamedascaler_example} -O; then
    echo -e "\n$(tput setaf 1)Abort, download alamedascaler sample file failed!!!$(tput sgr 0)"
    exit 3
fi
echo "Done"

sed -i "s/version: latest/version: ${tag_number}/g" ${alamedaservice_example}

echo "========================================"

while [[ "$install_alameda" != "y" ]] && [[ "$install_alameda" != "n" ]]
do
    default="y"
    read -r -p "$(tput setaf 2)Do you want to launch interactive installation of Federator.ai [default: y]: $(tput sgr 0)" install_alameda </dev/tty
    install_alameda=${install_alameda:-$default}
done

if [[ "$install_alameda" == "y" ]]; then

    while [[ "$information_correct" != "y" ]] && [[ "$information_correct" != "Y" ]]
    do
        # init variables
        enable_execution=""
        prometheus_address=""
        storage_type=""
        log_size=""
        data_size=""
        storage_class=""

        default="y"
        read -r -p "$(tput setaf 127)Do you want to enable execution? [default: y]: $(tput sgr 0): " enable_execution </dev/tty
        enable_execution=${enable_execution:-$default}

        if [ "$suggest_prometheus_url" != "" ]; then
            default="$suggest_prometheus_url"
        elif [[ "$openshift_minor_version" == "11" ]]; then
            default="https://prometheus-k8s.openshift-monitoring:9091"
        elif [[ "$openshift_minor_version" == "9" ]]; then
            default="http://prom-prometheus-operator-prometheus.monitoring.svc:9090"
        else
            default="https://prometheus-k8s.openshift-monitoring:9091"
        fi

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
        echo "----------------------------------------"

        default="y"
        read -r -p "$(tput setaf 2)Is the above information correct [default: y]:$(tput sgr 0)" information_correct </dev/tty
        information_correct=${information_correct:-$default}
    done
fi

if [[ "$install_alameda" == "y" ]]; then
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

    kubectl apply -f $alamedaservice_example &>/dev/null
    if [ "$need_upgrade" = "y" ];then
        # for upgrade - start operator after applying new alamedaservice
        kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
    fi

    echo "Processing..."
    check_alameda_datahub_tag 900 60 $install_namespace
    wait_until_pods_ready 900 60 $install_namespace 5

    webhook_exist_checker
    if [ "$webhook_exist" != "y" ];then
        webhook_reminder
    fi

    get_grafana_route $install_namespace
    get_restapi_route $install_namespace
    echo -e "$(tput setaf 6)\nInstall Alameda $tag_number successfully$(tput sgr 0)"
    leave_prog
    exit 0
else
    if [ "$need_upgrade" = "y" ];then
        # for upgrade - start operator after applying new alamedaservice
        kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
    fi
fi

webhook_exist_checker
if [ "$webhook_exist" != "y" ];then
    webhook_reminder
fi
leave_prog
exit 0
