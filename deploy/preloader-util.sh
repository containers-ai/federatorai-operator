#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for demo purpose.
#   Usage:
#       [-p] # Prepare environment
#       [-x pod autoscaling method] # Specified hpa or vpa as pod autoscaling method 
#       [-c] # clean environment for preloader test
#       [-e] # Enable preloader pod
#       [-r] # Run preloader
#       [-f future data point (hour)] # Run preloader future mode
#       [-d] # Disable & Remove preloader
#       [-v] # Revert environment to normal mode
#       [-n nginx_prefix_name] # Specify nginx prefix name (optional)
#       [-h] # Display script usage
#   Standalone options:
#       [-i] # Install Nginx
#       [-k] # Remove Nginx
#
#################################################################################################################

show_usage()
{
    cat << __EOF__

    Usage:
        [-p] # Prepare environment
        [-x pod autoscaling method] # Specified hpa or vpa as pod autoscaling method
        [-c] # clean environment for preloader test
        [-e] # Enable preloader pod
        [-r] # Run preloader
        [-f future data point (hour)] # Run preloader future mode
        [-d] # Disable & Remove preloader
        [-v] # Revert environment to normal mode
        [-n nginx_prefix_name] # Specify nginx prefix name (optional)
        [-h] # Display script usage
    Standalone options:
        [-i] # Install Nginx
        [-k] # Remove Nginx

__EOF__
    exit 1
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
    scale_up_pods
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

wait_until_data_pump_finish()
{
  period="$1"
  interval="$2"
  type="$3"

  for ((i=0; i<$period; i+=$interval)); do
    if [ "$type" = "future" ]; then
        echo "Waiting for data pump (future mode) to finish ..."
        kubectl logs -n $install_namespace $current_preloader_pod_name | grep -q "Completed to loader container future metrics data"
        if [ "$?" = "0" ]; then
            echo -e "\n$(tput setaf 6)Data pump (future mode) is finished.$(tput sgr 0)"
            return 0
        fi
    else #historical mode
        echo "Waiting for data pump to finish ..."
        if [[ "`kubectl logs -n $install_namespace $current_preloader_pod_name | egrep "Succeed to generate pods historical metrics|Succeed to generate nodes historical metrics" | wc -l`" -gt "1" ]]; then
            echo -e "\n$(tput setaf 6)Data pump is finished.$(tput sgr 0)"
            return 0
        fi
    fi
    
    sleep "$interval"
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but data pump is still running.$(tput sgr 0)"
  leave_prog
  exit 4
}

get_current_preloader_name()
{
    current_preloader_pod_name=""
    current_preloader_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-agent-preloader-"|awk '{print $1}'|head -1`"
    echo "current_preloader_pod_name = $current_preloader_pod_name"
}

delete_all_alamedascaler()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Deleting old alamedascaler if necessary...$(tput sgr 0)"
    while read alamedascaler_name alamedascaler_ns
    do
        if [ "$alamedascaler_name" = "" ] || [ "$alamedascaler_ns" = "" ]; then
           continue
        fi

        kubectl delete alamedascaler $alamedascaler_name -n $alamedascaler_ns
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting old alamedascaler named $alamedascaler_name in ns $alamedascaler_ns.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    done <<< "$(kubectl get alamedascaler --all-namespaces --output jsonpath='{range .items[*]}{"\n"}{.metadata.name}{"\t"}{.metadata.namespace}' 2>/dev/null)"
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration delete_all_alamedascaler = $duration" >> $debug_log
}

wait_for_cluster_status_data_ready()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking cluster status...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    repeat_count="30"
    sleep_interval="20"
    for i in $(seq 1 $repeat_count)
    do
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "select * from pod" 2>/dev/null |grep -q "nginx-app"
        if [ "$?" != 0 ]; then
            echo "Not ready, keep retrying cluster status..."
            sleep $sleep_interval
        else
            break
        fi
    done

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration wait_for_cluster_status_data_ready = $duration" >> $debug_log
}

run_preloader_command()
{
    # check env is ready
    wait_for_cluster_status_data_ready

    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running preloader...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter enable
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader enable command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Checking..."
    sleep 20
    kubectl logs -n $install_namespace $current_preloader_pod_name | grep -i "Start PreLoader agent"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Preloader pod is not running correctly. Please contact support stuff$(tput sgr 0)"
        leave_prog
        exit 5
    fi

    wait_until_data_pump_finish 3600 60 "historical"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_preloader_command = $duration" >> $debug_log
}

run_futuremode_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running future mode preloader...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    
    kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter loadfuture --hours=$future_mode_length
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader loadfuture command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Checking..."
    sleep 10
    wait_until_data_pump_finish 3600 60 "future"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_futuremode_preloader = $duration" >> $debug_log
}

scale_down_pods()
{
    echo -e "\n$(tput setaf 6)Scaling down alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    original_alameda_ai_replicas="`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`"
    # Bring down federatorai-operator to prevent it start scale down pods automatically
    kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-recommender -n $install_namespace -p '{"spec":{"replicas": 0}}'
    echo "Done"
}

scale_up_pods()
{
    echo -e "\n$(tput setaf 6)Scaling up alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    if [ "`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        if [ "$original_alameda_ai_replicas" != "" ]; then
            kubectl patch deployment alameda-ai -n $install_namespace -p "{\"spec\":{\"replicas\": $original_alameda_ai_replicas}}"
        else
            kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 1}}'
        fi
        do_something="y"
    fi

    if [ "`kubectl get deploy alameda-ai-dispatcher -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy alameda-recommender -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment alameda-recommender -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy federatorai-operator -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "$do_something" = "y" ]; then
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
}

reschedule_dispatcher()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rescheduling alameda-ai dispatcher...$(tput sgr 0)"
    current_dispatcher_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-ai-dispatcher-"|awk '{print $1}'|head -1`"
    if [ "$current_dispatcher_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find alameda-ai dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    kubectl delete pod -n $install_namespace $current_dispatcher_pod_name
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in deleting dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo ""
    wait_until_pods_ready 600 30 $install_namespace 5
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration reschedule_dispatcher = $duration" >> $debug_log

}

patch_datahub_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Patching datahub for preloader...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q influxdb
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "influxdb"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in patching datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_for_preloader = $duration" >> $debug_log
}

patch_datahub_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rolling back datahub...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q prometheus
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "prometheus"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in rolling back datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_back_to_normal = $duration" >> $debug_log
}

check_influxdb_retention()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking retention policy...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show retention policies"|grep "autogen"|grep -q "3600h"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! retention policy of alameda_metric pod is not 3600h.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_influxdb_retention = $duration" >> $debug_log
}

patch_grafana_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag for grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q true
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=true"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! add flag for grafana is failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_for_preloader = $duration" >> $debug_log
}

patch_grafana_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag to roll back grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q false
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=false"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! add flag to roll back grafana is failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_back_to_normal = $duration" >> $debug_log
}

verify_metrics_exist()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Verifying metrics in influxdb ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    metrics_list=$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements")
    metrics_num=$(echo "$metrics_list"| egrep "application_cpu|application_memory|cluster_cpu|cluster_memory|container_cpu|container_memory|controller_cpu|controller_memory|namespace_cpu|namespace_memory|node_cpu|node_memory" |wc -l)

    echo "metrics_num = $metrics_num"
    if [ "$metrics_num" -lt "12" ]; then
        echo -e "\n$(tput setaf 1)Error! metrics in alameda_metric is not complete.$(tput sgr 0)"
        echo "$metrics_list"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration verify_metrics_exist = $duration" >> $debug_log
}

delete_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Deleting NGINX sample ...$(tput sgr 0)"
    dc_name="`kubectl get dc -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$dc_name" != "" ]; then
        kubectl delete dc $dc_name -n $nginx_ns
    fi
    deploy_name="`kubectl get deploy -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$deploy_name" != "" ]; then
        kubectl delete deploy $deploy_name -n $nginx_ns
    fi
    kubectl get ns $nginx_ns >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        kubectl delete ns $nginx_ns
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration delete_nginx_example = $duration" >> $debug_log
}

new_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Creating new NGINX sample pod ...$(tput sgr 0)"

    if [[ "`kubectl get po -n $nginx_ns 2>/dev/null|grep -v "NAME"|grep "Running"|wc -l`" -gt "0" ]]; then
        echo "nginx-preloader-sample namespace and pod are already exist."
    else
        if [ "$openshift_minor_version" != "" ]; then
            # OpenShift
            nginx_openshift_yaml="nginx_openshift.yaml"
            cat > ${nginx_openshift_yaml} << __EOF__
{
    "kind": "List",
    "apiVersion": "v1",
    "metadata": {},
    "items": [
        {
            "apiVersion": "apps.openshift.io/v1",
            "kind": "DeploymentConfig",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "replicas": 1,
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                },
                "strategy": {
                    "resources": {},
                    "rollingParams": {
                        "intervalSeconds": 1,
                        "maxSurge": "25%",
                        "maxUnavailable": "25%",
                        "timeoutSeconds": 600,
                        "updatePeriodSeconds": 1
                    },
                    "type": "Rolling"
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "${nginx_name}",
                            "deploymentconfig": "${nginx_name}"
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "image": "twalter/openshift-nginx:stable-alpine",
                                "imagePullPolicy": "Always",
                                "name": "${nginx_name}",
                                "ports": [
                                    {
                                        "containerPort": 8081,
                                        "protocol": "TCP"
                                    }
                                ],
                                "resources":
                                {
                                    "limits":
                                        {
                                        "cpu": "150m",
                                        "memory": "400Mi"
                                        },
                                    "requests":
                                        {
                                        "cpu": "100m",
                                        "memory": "50Mi"
                                        }
                                },
                                "terminationMessagePath": "/dev/termination-log"
                            }
                        ],
                        "dnsPolicy": "ClusterFirst",
                        "restartPolicy": "Always",
                        "securityContext": {},
                        "terminationGracePeriodSeconds": 30
                    }
                }
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "ports": [
                    {
                        "name": "http",
                        "port": 8081,
                        "protocol": "TCP",
                        "targetPort": 8081
                    }
                ],
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                }
            }
        },
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "port": {
                    "targetPort": 8081
                },
                "to": {
                    "kind": "Service",
                    "name": "${nginx_name}"
                },
                "weight": 100,
                "wildcardPolicy": "None"
            }
        }
    ]
}
__EOF__
            oc new-project $nginx_ns
            oc apply -f ${nginx_openshift_yaml}
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns 1
            oc project $install_namespace
        else
            # K8S
            nginx_k8s_yaml="nginx_k8s.yaml"
            cat > ${nginx_k8s_yaml} << __EOF__
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
  labels:
     app: ${nginx_name}
spec:
  selector:
    matchLabels:
      app: ${nginx_name}
  replicas: 1
  template:
    metadata:
      labels:
        app: ${nginx_name}
    spec:
      containers:
      - name: ${nginx_name}
        image: nginx:1.7.9
        resources:
            limits:
                cpu: "150m"
                memory: "400Mi"
            requests:
                cpu: "100m"
                memory: "50Mi"
        ports:
        - containerPort: 80
      serviceAccount: ${nginx_name}
      serviceAccountName: ${nginx_name}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${nginx_name}
rules:
- apiGroups:
  - policy
  resources:
  - podsecuritypolicies
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${nginx_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${nginx_name}
subjects:
- kind: ServiceAccount
  name: ${nginx_name}
  namespace: ${nginx_ns}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
__EOF__
            kubectl create ns $nginx_ns
            kubectl apply -f $nginx_k8s_yaml
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns 1
        fi
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration new_nginx_example = $duration" >> $debug_log
}

add_alamedascaler_for_nginx()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding NGINX alamedascaler ...$(tput sgr 0)"
    nginx_alamedascaler_file="nginx_alamedascaler_file"
    kubectl get alamedascaler -n ${nginx_ns} 2>/dev/null|grep -q "nginx-alamedascaler"
    if [ "$?" != "0" ]; then
        cat > ${nginx_alamedascaler_file} << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha1
kind: AlamedaScaler
metadata:
    name: nginx-app
    namespace: ${nginx_ns}
spec:
    policy: stable
    enableExecution: false
    scalingTool:
        type: ${autoscaling_method}
    selector:
        matchLabels:
            app: ${nginx_name}
__EOF__
        kubectl apply -f ${nginx_alamedascaler_file}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Add alamedascaler for NGINX app failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        sleep 10
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration add_alamedascaler_for_nginx = $duration" >> $debug_log
}

cleanup_influxdb_prediction_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb prediction/recommendation/planning records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    for database in `echo "alameda_prediction alameda_recommendation alameda_planning"`
    do
        echo "database=$database"
        measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "show measurements" 2>&1 |tail -n+4`"
        for measurement in `echo $measurement_list`
        do
            echo "clean up measurement: $measurement"
            kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "drop measurement $measurement"
        done
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_prediction_related_contents = $duration" >> $debug_log
}

cleanup_alamedaai_models()
{
    start=`date +%s`
    #/var/lib/alameda/alameda-ai/models/online/workload_prediction
    echo -e "\n$(tput setaf 6)Cleaning old alameda ai model ...$(tput sgr 0)"
    for ai_pod_name in `kubectl get pods -n $install_namespace -o jsonpath='{range .items[*]}{"\n"}{.metadata.name}'|grep alameda-ai-|grep -v dispatcher`
    do
        kubectl exec $ai_pod_name -n $install_namespace -- rm -rf /var/lib/alameda/alameda-ai/models/online/workload_prediction
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_alamedaai_models = $duration" >> $debug_log
}

cleanup_influxdb_preloader_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb preloader metrics records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    
    measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements" 2>&1 |tail -n+4`"
    echo "db=alameda_metric"
    for measurement in `echo $measurement_list`
    do
        if [ "$measurement" = "grafana_config" ]; then
            continue
        fi
        echo "clean up measurement: $measurement"
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "drop measurement $measurement"
    done
    
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_preloader_related_contents = $duration" >> $debug_log
}

check_prediction_status()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking prediction status of monitored objects ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    measurements_list="`oc exec alameda-influxdb-54949c7c-jp4lk -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "show measurements"|tail -n+4`"
    for measurement in `echo $measurements_list`
    do
        record_number="`oc exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "select count(*) from $measurement"|tail -1|awk '{print $NF}'`"
        echo "$measurement = $xx"
        case $future_mode_length in
                ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be integer.$(tput sgr 0)" && show_usage ;;
                *) ;;
        esac

        re='^[0-9]+$'
        if ! [[ $xx =~ $re ]] ; then
            echo "error: Not a number" >&2; exit 1
        else
            yy=$(($yy + $xx))
        fi
    done
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_prediction_status() = $duration" >> $debug_log
}

enable_preloader_in_alamedaservice()
{
    start=`date +%s`
    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        echo -e "\n$(tput setaf 6)Skip preloader installation due to preloader pod exist.$(tput sgr 0)"
        echo -e "Deleting preloader pod to renew the pod state..."
        kubectl delete pod -n $install_namespace $current_preloader_pod_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    else
        echo -e "\n$(tput setaf 6)Enabling preloader in alamedaservice...$(tput sgr 0)"
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enablePreloader": true}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in patching alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    # Check if preloader is ready
    echo ""
    wait_until_pods_ready 600 30 $install_namespace 5
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration enable_preloader_in_alamedaservice = $duration" >> $debug_log
}

add_svc_for_nginx()
{
    # K8S only
    if [ "$openshift_minor_version" = "" ]; then
        start=`date +%s`
        echo -e "\n$(tput setaf 6)Adding svc for NGINX ...$(tput sgr 0)"

        # Check if svc already exist
        kubectl get svc nginx-svc -n $nginx_ns &>/dev/null
        if [ "$?" = "0" ]; then
            echo "svc already exist in namespace $nginx_ns"
            echo "Done"
            return
        fi

        nginx_svc_yaml="nginx_svc.yaml"
        cat > ${nginx_svc_yaml} << __EOF__
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
  namespace: ${nginx_ns}
  labels:
    app: nginx-svc
spec:
  type: NodePort
  ports:
  - port: 80
    nodePort: 31020
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: ${nginx_name}
__EOF__

        kubectl apply -f $nginx_svc_yaml
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Apply NGINX svc yaml failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        echo "Done"
        end=`date +%s`
        duration=$((end-start))
        echo "Duration add_svc_for_nginx = $duration" >> $debug_log
    fi
}

disable_preloader_in_alamedaservice()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Disabling preloader in alamedaservice...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace  --type merge --patch '{"spec":{"enablePreloader": false}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in patching alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        # Check if preloader is removed and other pods are ready
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
        get_current_preloader_name
        if [ "$current_preloader_pod_name" != "" ]; then
            echo -e "\n$(tput setaf 1)ERROR! Can't stop preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration disable_preloader_in_alamedaservice = $duration" >> $debug_log
}

clean_environment_operations()
{
    cleanup_influxdb_preloader_related_contents
    cleanup_influxdb_prediction_related_contents
    cleanup_alamedaai_models
}   

if [ "$#" -eq "0" ]; then
    show_usage
    exit
fi

while getopts "f:x:ecpvrdhikn:" o; do
    case "${o}" in
        p)
            prepare_environment="y"
            ;;
        i)
            install_nginx="y"
            ;;
        k)
            remove_nginx="y"
            ;;
        c)
            clean_environment="y"
            ;;
        e)
            enable_preloader="y"
            ;;
        r)
            run_preloader="y"
            ;;
        f)
            future_mode_enabled="y"
            f_arg=${OPTARG}
            ;;
        x)
            autoscaling_specified="y"
            x_arg=${OPTARG}
            ;;
        n)
            nginx_name_specified="y"
            n_arg=${OPTARG}
            ;;
        d)
            disable_preloader="y"
            ;;
        v)
            revert_environment="y"
            ;;
        h)
            show_usage
            exit
            ;;
        *)
            echo "Warning! wrong paramter, ignore it."
            ;;
    esac
done

if [ "$future_mode_enabled" = "y" ]; then
    future_mode_length=$f_arg
    case $future_mode_length in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
fi

if [ "$autoscaling_specified" = "y" ]; then
    autoscaling_method=$x_arg
    if [ "$autoscaling_method" != "vpa" ] && [ "$autoscaling_method" != "hpa" ]; then
        echo -e "\n$(tput setaf 1) Pod autoscaling method needs to be \"vpa\" or \"hpa\".$(tput sgr 0)" && show_usage
    fi
else
    autoscaling_method="hpa"
fi

if [ "$nginx_name_specified" = "y" ]; then
    nginx_name=$n_arg
    if [ "$nginx_name" = "" ]; then
        echo -e "\n$(tput setaf 1)nginx name needs to be specified with n parameter.$(tput sgr 0)"
    fi
else
    # Set default nginx name
    nginx_name="nginx-prepared"
fi

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"

if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please Install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

alamedaservice_name="`kubectl get alamedaservice -n $install_namespace -o jsonpath='{range .items[*]}{.metadata.name}'`"
if [ "$alamedaservice_name" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to get alamedaservice name.$(tput sgr 0)"
    leave_prog
    exit 8
fi

file_folder="/tmp/preloader"
nginx_ns="nginx-preloader-sample"

debug_log="debug.log"

rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
cd $file_folder
echo "Receiving command '$0 $@'" >> $debug_log

if [ "$prepare_environment" = "y" ]; then
    delete_all_alamedascaler
    new_nginx_example
    patch_datahub_for_preloader
    patch_grafana_for_preloader
    check_influxdb_retention
    add_alamedascaler_for_nginx
fi

if [ "$clean_environment" = "y" ]; then
    clean_environment_operations
fi

if [ "$enable_preloader" = "y" ]; then
    enable_preloader_in_alamedaservice
fi

if [ "$run_preloader" = "y" ]; then
    scale_down_pods
    run_preloader_command
    verify_metrics_exist
    scale_up_pods
    #check_prediction_status
fi

if [ "$future_mode_enabled" = "y" ]; then
    run_futuremode_preloader
    verify_metrics_exist
fi

if [ "$disable_preloader" = "y" ]; then
    disable_preloader_in_alamedaservice
fi

if [ "$revert_environment" = "y" ]; then
    delete_all_alamedascaler
    delete_nginx_example
    patch_datahub_back_to_normal
    patch_grafana_back_to_normal
    clean_environment_operations
fi

if [ "$install_nginx" = "y" ]; then
    new_nginx_example
    add_svc_for_nginx
fi

if [ "$remove_nginx" = "y" ]; then
    delete_nginx_example
fi

leave_prog
exit 0
