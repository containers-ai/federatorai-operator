#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for demo purpose.
#   Usage:
#
#################################################################################################################

show_usage()
{
    cat << __EOF__

    Usage:
        Scenario A (For Resource Allocation):
          Requirements:
            --namespace <space> target namespace name [e.g., --namespace nginx]
            --controller-name <space> controller name [e.g., --controller-name nginx-ex]
          Operations:
            --get-current-controller-resources
            --get-controller-planning
            --generate-controller-patch
            --apply-controller-patch <space> patch file full path [e.g., --apply-controller-patch /tmp/planning-util/$controller_patch_yaml]
        Scenario B (For Namespace Quotas):
          Requirements:
            --namespace <space> target namespace name [e.g., --namespace nginx]
          Operations:
            --get-current-namespace-quotas
            --get-namespace-planning
            --generate-namespace-quota-patch
            --apply-namespace-quota-patch <space> patch file full path [e.g., --apply-namespace-quota-patch /tmp/planning-util/$namespace_patch_yaml]
__EOF__
    exit 1
}

is_pod_ready()
{
  [[ "$(kubectl get po "$1" -n "$2" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]]
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"

  kubectl get pod -n $namespace \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |egrep -v "\-build|\-deploy"\
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
    if [ ! -z "$(ls -A $file_folder)" ]; then      
        echo -e "\n$(tput setaf 6)Downloaded YAML files are located under $file_folder $(tput sgr 0)"
    fi
 
    cd $current_location > /dev/null
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

get_k8s_rest_api_node_port()
{
    #K8S
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting REST API service NodePort...$(tput sgr 0)"
    https_node_port="`kubectl get svc -n $install_namespace |grep -E -o "5056:.{0,22}"|cut -d '/' -f1|cut -d ':' -f2`"
    if [ "$https_node_port" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't find NodePort of REST API service.$(tput sgr 0)"
        leave_prog
        exit 8 
        
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration get_k8s_rest_api_node_port = $duration" >> $debug_log
}

check_rest_api_url()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking REST API URL...$(tput sgr 0)"
    if [ "$openshift_minor_version" != "" ]; then
        # OpenShift
        api_url="`oc get route -n $install_namespace | grep "federatorai-rest"|awk '{print $2}'`"
        if [ "$api_url" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't get REST API URL.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        api_url="https://$api_url"
    else
        # K8S
        #get_k8s_rest_api_node_port
        read -r -p "$(tput setaf 2)Please input REST API service URL:(e.g. https://<URL>:<PORT>) $(tput sgr 0) " api_url </dev/tty
        if [ "$api_url" != "" ]; then
            echo "api_url = $api_url"
        else
            echo -e "\n$(tput setaf 1)Error! Please input correct REST API URL.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_rest_api_url = $duration" >> $debug_log
    echo "REST API URL = $api_url"
}

rest_api_login()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Logging into REST API...$(tput sgr 0)"
    check_api_url
    #echo "curl -sS -k -X POST \"$api_url/apis/v1/users/login\" -H \"accept: application/json\" -H \"authorization: Basic YWRtaW46YWRtaW4=\" |jq '.accessToken'|tr -d \"\"\""
    access_token=`curl -sS -k -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic YWRtaW46YWRtaW4=" |jq '.accessToken'|tr -d "\""`
    check_user_token

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration rest_api_login = $duration" >> $debug_log
}

check_api_url()
{
    if [ "$api_url" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! REST API URL is empty.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
}

check_user_token()
{
    if [ "$access_token" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! User token is empty.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
}

check_cluster_name()
{
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! cluster name is empty.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
}

rest_api_get_cluster_name()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting cluster name...$(tput sgr 0)"
    cluster_name=`curl -sS -k -X GET "$api_url/apis/v1/resources/clusters" -H "accept: application/json" -H "Authorization: Bearer $access_token" |jq '.data[].name'|tr -d "\""`
    check_cluster_name

    echo "cluster_name = $cluster_name"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration rest_api_get_cluster_name = $duration" >> $debug_log
}

rest_api_get_pod_planning()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting planning for pod ($target_pod_name) in ns ($target_namespace)...$(tput sgr 0)"
    interval_start_time="$start"
    interval_end_time=$(($interval_start_time + 3599)) #59min59sec
    granularity="3600"
    type="recommendation"

    planning_values=`curl -sS -k -X GET "$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/pods?granularity=$granularity&type=$type&names=$target_pod_name&limit=1&order=desc&startTime=$interval_start_time&endTime=$interval_end_time" -H "accept: application/json" -H "Authorization: Bearer $access_token" |jq ".plannings[].containerPlannings[0]|\"\(.limitPlannings.${query_cpu_string}[].numValue) \(.requestPlannings.${query_cpu_string}[].numValue) \(.limitPlannings.${query_memory_string}[].numValue) \(.requestPlannings.${query_memory_string}[].numValue)\""|tr -d "\""`
    limits_pod_cpu="`echo $planning_values |awk '{print $1}'`"
    requests_pod_cpu="`echo $planning_values |awk '{print $2}'`"
    limits_pod_memory="`echo $planning_values |awk '{print $3}'`"
    requests_pod_memory="`echo $planning_values |awk '{print $4}'`"
    echo "-------Planning for pod $target_pod_name"
    echo "resources.limits.cpu = $limits_pod_cpu(m)"
    echo "resources.limits.momory = $limits_pod_memory(byte)"
    echo "resources.requests.cpu = $requests_pod_cpu(m)"
    echo "resources.requests.memory = $requests_pod_memory(byte)"
    echo "--------------------------------------------"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get pod ($target_pod_name) planning. Missing value.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration rest_api_get_pod_planning = $duration" >> $debug_log
}

rest_api_get_controller_planning()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting planning for controller ($owner_reference_name) in ns ($target_namespace)...$(tput sgr 0)"
    interval_start_time="$start"
    interval_end_time=$(($interval_start_time + 3599)) #59min59sec
    granularity="3600"
    type="recommendation"

    if [ "$openshift_minor_version" != "" ]; then
        # OpenShift
        planning_values=`curl -sS -k -X GET "$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/deploymentconfigs?granularity=$granularity&type=$type&names=$owner_reference_name&limit=1&order=desc&startTime=$interval_start_time&endTime=$interval_end_time" -H "accept: application/json" -H "Authorization: Bearer $access_token"|jq ".plannings[].plannings[0]|\"\(.limitPlannings.${query_cpu_string}[].numValue) \(.requestPlannings.${query_cpu_string}[].numValue) \(.limitPlannings.${query_memory_string}[].numValue) \(.requestPlannings.${query_memory_string}[].numValue)\""|tr -d "\""`
    else
        # K8S
        planning_values=`curl -sS -k -X GET "$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/deployments?granularity=$granularity&type=$type&names=$owner_reference_name&limit=1&order=desc&startTime=$interval_start_time&endTime=$interval_end_time" -H "accept: application/json" -H "Authorization: Bearer $access_token"|jq ".plannings[].plannings[0]|\"\(.limitPlannings.${query_cpu_string}[].numValue) \(.requestPlannings.${query_cpu_string}[].numValue) \(.limitPlannings.${query_memory_string}[].numValue) \(.requestPlannings.${query_memory_string}[].numValue)\""|tr -d "\""`
    fi

    replica_number="`kubectl get $owner_reference_kind $owner_reference_name -n $target_namespace -o json|jq '.spec.replicas'`"
    if [ "$replica_number" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get replica number from controller ($owner_reference_name) in ns $target_namespace$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "replica_number= $replica_number"

    limits_pod_cpu="`echo $planning_values |awk '{print $1}'`"
    requests_pod_cpu="`echo $planning_values |awk '{print $2}'`"
    limits_pod_memory="`echo $planning_values |awk '{print $3}'`"
    requests_pod_memory="`echo $planning_values |awk '{print $4}'`"

    # Round up the result (planning / replica)
    limits_pod_cpu=`echo "($limits_pod_cpu + $replica_number - 1)/$replica_number" | bc`
    requests_pod_cpu=`echo "($requests_pod_cpu + $replica_number - 1)/$replica_number" | bc`
    limits_pod_memory=`echo "($limits_pod_memory + $replica_number - 1)/$replica_number" | bc`
    requests_pod_memory=`echo "($requests_pod_memory + $replica_number - 1)/$replica_number" | bc`

    echo "-------Planning for controller $owner_reference_name"
    echo "resources.limits.cpu = $limits_pod_cpu(m)"
    echo "resources.limits.momory = $limits_pod_memory(byte)"
    echo "resources.requests.cpu = $requests_pod_cpu(m)"
    echo "resources.requests.memory = $requests_pod_memory(byte)"
    echo "--------------------------------------------"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get controller ($owner_reference_name) planning. Missing value.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration rest_api_get_controller_planning = $duration" >> $debug_log
}

rest_api_get_namespace_planning()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting planning for namespace ($target_namespace)...$(tput sgr 0)"
    interval_start_time="$start"
    interval_end_time=$(($interval_start_time + 3599)) #59min59sec
    granularity="3600"
    type="recommendation"

    planning_values=`curl -sS -k -X GET "$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace?granularity=$granularity&type=$type&limit=1&order=desc&startTime=$interval_start_time&endTime=$interval_end_time" -H "accept: application/json" -H "Authorization: Bearer $access_token" |jq ".plannings[].plannings[0]|\"\(.limitPlannings.${query_cpu_string}[].numValue) \(.requestPlannings.${query_cpu_string}[].numValue) \(.limitPlannings.${query_memory_string}[].numValue) \(.requestPlannings.${query_memory_string}[].numValue)\""|tr -d "\""`
    limits_ns_cpu="`echo $planning_values |awk '{print $1}'`"
    requests_ns_cpu="`echo $planning_values |awk '{print $2}'`"
    limits_ns_memory="`echo $planning_values |awk '{print $3}'`"
    requests_ns_memory="`echo $planning_values |awk '{print $4}'`"
    echo "-------Planning for namespace $target_namespace"
    echo "resources.limits.cpu = $limits_ns_cpu(m)"
    echo "resources.limits.momory = $limits_ns_memory(byte)"
    echo "resources.requests.cpu = $requests_ns_cpu(m)"
    echo "resources.requests.memory = $requests_ns_memory(byte)"
    echo "--------------------------------------------"

    if [ "$limits_ns_cpu" = "" ] || [ "$requests_ns_cpu" = "" ] || [ "$limits_ns_memory" = "" ] || [ "$requests_ns_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get namespace ($target_namespace) planning. Missing value.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration rest_api_get_namespace_planning = $duration" >> $debug_log
}

get_needed_info()
{
    check_rest_api_url
    rest_api_login
    rest_api_get_cluster_name
    if [ "$do_pod_related" != "" ]; then
        get_controller_info_from_pod
    fi
    if [ "$do_controller_related" != "" ]; then
        get_controller_info_from_controller
    fi
    check_federatorai_version
}

check_federatorai_version()
{
    kubectl get alamedaservices --all-namespaces -o jsonpath='{.items[].spec.version}' 2>/dev/null|grep -q "4.2"
    if [ "$?" = "0" ]; then
        # 4.2 version
        query_cpu_string="CPU_USAGE_SECONDS_PERCENTAGE"
        query_memory_string="MEMORY_USAGE_BYTES"
    else
        # 4.3 or later
        query_cpu_string="CPU_MILLICORES_USAGE"
        query_memory_string="MEMORY_BYTES_USAGE"
    fi
}

get_owner_reference()
{
    local kind="$1"
    local name="$2"
    local owner_ref=`kubectl get $kind $name -n $target_namespace -o json | jq -r '.metadata.ownerReferences[] | "\(.controller) \(.kind) \(.name)"' 2>/dev/null`
    echo "$owner_ref"
}

get_controller_info_from_pod()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting pod controller type and name...$(tput sgr 0)"
    owner_reference_kind="pod"
    owner_reference_name="$target_pod_name"
    fist_run="y"
    while true
    do
        owner_ref=$(get_owner_reference $owner_reference_kind $owner_reference_name)
        if [ "$fist_run" = "y" ] && [ "$owner_ref" = "" ]; then
            # Pod # First run
            echo -e "\n$(tput setaf 1)Error! Can't find pod ($target_pod_name) ownerReferences in namespace $target_namespace$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        fist_run="n"
        if [ "$owner_ref" != "" ]; then
            owner_reference_kind="`echo $owner_ref |grep 'true'|awk '{print $2}'`"
            owner_reference_name="`echo $owner_ref |grep 'true'|awk '{print $3}'`"
            if [ "$owner_reference_kind" = "DeploymentConfig" ] || [ "$owner_reference_kind" = "Deployment" ] || [ "$owner_reference_kind" = "StatefulSet" ]; then
                break
            fi
        else
            break
        fi
    done

    echo "target_namespace = $target_namespace"
    echo "target_pod_name = $target_pod_name"
    echo "owner_reference_kind = $owner_reference_kind"
    echo "owner_reference_name = $owner_reference_name"

    if [ "$owner_reference_kind" != "DeploymentConfig" ] && [ "$owner_reference_kind" != "Deployment" ] && [ "$owner_reference_kind" != "StatefulSet" ]; then
        echo -e "\n$(tput setaf 1)Error! Only support DeploymentConfig, Deployment, or StatefulSet for now.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration get_controller_info_from_pod = $duration" >> $debug_log
}

get_controller_info_from_controller()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting controller type...$(tput sgr 0)"
    owner_reference_kind=""
    owner_reference_name="$target_controller_name"

    kubectl get Deployment $owner_reference_name -n $target_namespace > /dev/null 2>&1
    if [ "$?" = "0" ]; then
        owner_reference_kind="Deployment"
    else
        kubectl get DeploymentConfig $owner_reference_name -n $target_namespace > /dev/null 2>&1
        if [ "$?" = "0" ]; then
            owner_reference_kind="DeploymentConfig"
        else
            kubectl get StatefulSet $owner_reference_name -n $target_namespace > /dev/null 2>&1
            if [ "$?" = "0" ]; then
                owner_reference_kind="StatefulSet"
            fi
        fi
    fi

    echo "target_namespace = $target_namespace"
    echo "owner_reference_kind = $owner_reference_kind"
    echo "owner_reference_name = $owner_reference_name"

    if [ "$owner_reference_kind" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to find owner_reference_kind. Only support DeploymentConfig, Deployment, or StatefulSet for now.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration get_controller_info_from_controller = $duration" >> $debug_log
}


check_support_controller()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking if controller supported...$(tput sgr 0)"
    if [ "$openshift_minor_version" != "" ]; then
        # OpenShift
        if [ "$target_namespace" != "nginx-preloader-sample" ] || [ "$owner_reference_kind" != "DeploymentConfig" ]; then
            echo -e "\n$(tput setaf 1)Warning! We only support internal NGINX pod for now.$(tput sgr 0)"
        fi
    else
        # K8S
        if [ "$target_namespace" != "nginx-preloader-sample" ] || [ "$owner_reference_kind" != "Deployment" ]; then
            echo -e "\n$(tput setaf 1)Warning! We only support internal NGINX pod for now.$(tput sgr 0)"
        fi
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_support_controller = $duration" >> $debug_log
}

generate_controller_patch()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Generating controller patch...$(tput sgr 0)"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Please specify either --get-pod-planning or --get-controller-planning before --generate-controller-patch option.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    #check_support_controller


    image_name="`kubectl get $owner_reference_kind $owner_reference_name -n $target_namespace -o json|jq '.spec.template.spec.containers[0].image'`"

    cat > ${controller_patch_yaml} << __EOF__
spec:
  template:
    spec:
      containers:
        - image: ${image_name}
          name: ${owner_reference_name}
          resources:
            requests:
              cpu: ${requests_pod_cpu}m
              memory: ${requests_pod_memory}
            limits:
              cpu: ${limits_pod_cpu}m
              memory: ${limits_pod_memory}
__EOF__

    echo "Patch file \"${controller_patch_yaml}\" is generated under $file_folder"
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration generate_controller_patch = $duration" >> $debug_log
}

generate_namespace_quotas_patch()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Generating namespace patch...$(tput sgr 0)"

    if [ "$limits_ns_cpu" = "" ] || [ "$requests_ns_cpu" = "" ] || [ "$limits_ns_memory" = "" ] || [ "$requests_ns_memory" = "" ]; then
        echo "Calling 'get namespace planning' first..."
        rest_api_get_namespace_planning
    fi

    cat > ${namespace_patch_yaml} << __EOF__
apiVersion: v1
kind: ResourceQuota
metadata:
  name: resource-quota
spec:
  hard:
    requests.cpu: ${requests_ns_cpu}m
    requests.memory: ${requests_ns_memory}
    limits.cpu: ${limits_ns_cpu}m
    limits.memory: ${limits_ns_memory}
__EOF__

    echo "Patch file \"${namespace_patch_yaml}\" is generated under $file_folder"
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration generate_namespace_quotas_patch = $duration" >> $debug_log
}

apply_controller_patch()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Applying controller patch...$(tput sgr 0)"

    if [ ! -f "$controller_patch_path" ]; then
        echo -e "\n$(tput setaf 1)Error! Patch file doesn't exist. Need to run --generate-controller-patch function first.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    kubectl patch $owner_reference_kind $owner_reference_name -n $target_namespace --type merge --patch "$(cat $controller_patch_yaml)"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in patching $owner_reference_kind $owner_reference_name in namespace $target_namespace.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    wait_until_pods_ready 600 20 $target_namespace 1

    # Get new target pod name
    target_pod_name="`kubectl get pods -n $target_namespace -o name |head -1|cut -d '/' -f2`"

    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration apply_controller_patch = $duration" >> $debug_log
}

apply_namespace_quotas_patch()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Applying namespace quotas patch...$(tput sgr 0)"

    if [ ! -f "$namespace_patch_path" ]; then
        echo -e "\n$(tput setaf 1)Error! Patch file doesn't exist. Need to run --generate-namespace-quota-patch function first.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    kubectl apply -f $namespace_patch_path --namespace=$target_namespace
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in set up quota for namespace $target_namespace$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration apply_namespace_quotas_patch = $duration" >> $debug_log
}

display_pod_resources()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting current pod resources...$(tput sgr 0)"
    echo "target_namespace= $target_namespace"
    echo "target_pod_name= $target_pod_name"
    echo "--------------------------------------------"
    kubectl get pod $target_pod_name -n $target_namespace -o json |jq '.spec.containers[].resources'
    echo "--------------------------------------------"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration display_pod_resources = $duration" >> $debug_log
}

display_controller_resources()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting current controller resources...$(tput sgr 0)"
    echo "target_namespace= $target_namespace"
    echo "target_controller_name= $target_controller_name"
    echo "--------------------------------------------"
    kubectl get $owner_reference_kind $target_controller_name -n $target_namespace -o json |jq '.spec.template.spec.containers[].resources'
    echo "--------------------------------------------"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration display_controller_resources = $duration" >> $debug_log
}


display_namespace_quotas()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Getting current namespace quotas...$(tput sgr 0)"
    echo "target_namespace= $target_namespace"
    resourcequota_name="`kubectl get resourcequota -n $target_namespace -o name 2>/dev/null |cut -d '/' -f2`"
    echo "--------------------------------------------"
    if [ "$resourcequota_name" = "" ]; then
        echo "{}"
    else
        kubectl get resourcequota $resourcequota_name -n $target_namespace -o json|jq '.spec'
    fi
    echo "--------------------------------------------"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration display_namespace_quotas = $duration" >> $debug_log
}

controller_patch_yaml="nginx_patch.yaml"
namespace_patch_yaml="namespace_patch.yaml"

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                namespace)
                    target_namespace="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$target_namespace" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit
                    fi
                    ;;
                pod-name)
                    target_pod_name="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$target_pod_name" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit
                    fi
                    ;;
                controller-name)
                    target_controller_name="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$target_controller_name" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit
                    fi
                    ;;
                get-current-pod-resources)
                    should_get_current_pod_resources="y"
                    ;;
                get-current-controller-resources)
                    should_get_current_controller_resources="y"
                    ;;
                get-current-namespace-quotas)
                    should_get_current_namespace_quotas="y"
                    ;;
                get-pod-planning)
                    should_get_pod_planning="y"
                    ;;
                get-controller-planning)
                    should_get_controller_planning="y"
                    ;;
                get-namespace-planning)
                    should_get_namespace_planning="y"
                    ;;
                generate-controller-patch)
                    should_gen_controller_patch="y"
                    ;;
                generate-namespace-quota-patch)
                    should_gen_namespace_quota_patch="y"
                    ;;
                apply-controller-patch)
                    should_apply_controller_patch="y"
                    controller_patch_path="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$controller_patch_path" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit
                    fi
                    ;;
                apply-namespace-quota-patch)
                    should_apply_namespace_quota_patch="y"
                    namespace_patch_path="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$namespace_patch_path" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit
                    fi
                    ;;
                *)
                    echo -e "\n$(tput setaf 1)Error! Unknown option --${OPTARG}$(tput sgr 0)"
                    exit
                    ;;
            esac;;
        h)
            show_usage
            ;;
        *)
            echo -e "\n$(tput setaf 1)Error! wrong paramter.$(tput sgr 0)"
            exit 5
            ;;
    esac
done

if [ "$should_get_pod_planning" != "" ] && [ "$should_get_controller_planning" != "" ]; then
    echo -e "\n$(tput setaf 1)Error! Can only choose either --get-pod-planning or --get-controller-planning option$(tput sgr 0)"
    exit 5
fi

if [ "$should_get_current_pod_resources" != "" ] || [ "$should_get_pod_planning" != "" ] || [ "$should_gen_controller_patch" != "" ] || [ "$should_apply_controller_patch" != "" ]; then
    if [ "$target_pod_name" != "" ] && [ "$target_namespace" != "" ]; then
        do_pod_related="y"
    fi
fi

if [ "$should_get_current_controller_resources" != "" ] || [ "$should_get_controller_planning" != "" ] || [ "$should_gen_controller_patch" != "" ] || [ "$should_apply_controller_patch" != "" ]; then
    if [ "$target_controller_name" != "" ] && [ "$target_namespace" != "" ]; then
        do_controller_related="y"
    fi
fi

if [ "$should_get_current_namespace_quotas" != "" ] || [ "$should_get_namespace_planning" != "" ] || [ "$should_gen_namespace_quota_patch" != "" ] || [ "$should_apply_namespace_quota_patch" != "" ]; then
    if [ "$target_namespace" != "" ]; then
        do_ns_related="y"
    fi
fi

if [ "$do_pod_related" = "" ] && [ "$do_controller_related" = "" ] && [ "$do_ns_related" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Missing or wrong parameters.$(tput sgr 0)"
    show_usage
fi

[ "$should_get_current_pod_resources" = "" ] && should_get_current_pod_resources="n"
[ "$should_get_pod_planning" = "" ] && should_get_pod_planning="n"

[ "$should_get_current_controller_resources" = "" ] && should_get_current_controller_resources="n"
[ "$should_get_controller_planning" = "" ] && should_get_controller_planning="n"

[ "$should_gen_controller_patch" = "" ] && should_gen_controller_patch="n"
[ "$should_apply_controller_patch" = "" ] && should_apply_controller_patch="n"
[ "$should_get_current_namespace_quotas" = "" ] && should_get_current_namespace_quotas="n"
[ "$should_get_namespace_planning" = "" ] && should_get_namespace_planning="n"
[ "$should_gen_namespace_quota_patch" = "" ] && should_gen_namespace_quota_patch="n"
[ "$should_apply_namespace_quota_patch" = "" ] && should_apply_namespace_quota_patch="n"

echo "target_namespace = $target_namespace"
echo "target_pod_name = $target_pod_name"
echo "target_controller_name = $target_controller_name"

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to kubernetes first."
    exit
fi

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

which jq > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"jq\" command is needed for this tool.$(tput sgr 0)"
    echo "You may issue following commands to install jq."
    echo "1. wget https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 -O jq"
    echo "2. chmod +x jq"
    echo "3. mv jq /usr/local/bin"
    echo "4. rerun the script"
    exit
fi

echo -e "\n$(tput setaf 6)Checking environment version...$(tput sgr 0)"
check_version
echo "...Passed"

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"

if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please Install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

file_folder="/tmp/planning-util"
debug_log="debug.log"

# To reserve patch file
#rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
cd $file_folder
echo "Receiving command '$0 $@'" > $debug_log

get_needed_info

if [ "$should_get_current_pod_resources" = "y" ];then
    display_pod_resources
fi

if [ "$should_get_current_controller_resources" = "y" ];then
    display_controller_resources
fi

if [ "$should_get_pod_planning" = "y" ];then
    rest_api_get_pod_planning
fi

if [ "$should_get_controller_planning" = "y" ];then
    rest_api_get_controller_planning
fi

if [ "$should_gen_controller_patch" = "y" ];then
    generate_controller_patch
fi

if [ "$should_apply_controller_patch" = "y" ];then
    apply_controller_patch
    if [ "$do_pod_related" = "y" ]; then
        display_pod_resources
    elif [ "$do_controller_related" = "y" ]; then
        display_controller_resources
    fi
fi

if [ "$should_get_current_namespace_quotas" = "y" ];then
    display_namespace_quotas
fi

if [ "$should_get_namespace_planning" = "y" ];then
    rest_api_get_namespace_planning
fi

if [ "$should_gen_namespace_quota_patch" = "y" ];then
    generate_namespace_quotas_patch
fi

if [ "$should_apply_namespace_quota_patch" = "y" ];then
    apply_namespace_quotas_patch
    display_namespace_quotas
fi

leave_prog
exit 0
