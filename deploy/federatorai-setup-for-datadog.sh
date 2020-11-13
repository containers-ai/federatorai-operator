#!/usr/bin/env bash

show_usage()
{
    cat << __EOF__

    Usage:
        Requirement:
            # Note: -k is for OpenShift env only.
            [-k OpenShift kubeconfig file] # e.g. -k .kubeconfig
                File .kubeconfig can be created by using the following command.
                sh -c "export KUBECONFIG=.kubeconfig; oc login <K8s_LOGIN_URL>"
                e.g. sh -c "export KUBECONFIG=.kubeconfig; oc login https://api.ocp4.example.com:6443"

__EOF__
    exit 1
}


patch_data_adapter_secret()
{
    if [ "$key_modified" = "y" ]; then
        echo -e "\n$(tput setaf 3)Updating Federator.ai data adapter secret...$(tput sgr 0)"
        if [ "$datadogAPIKey" = "" ] || [ "$datadogApplicationKey" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! API key and Application key can't be empty.$(tput sgr 0)"
            exit
        fi

        secret_yaml_name="adapter-secret.yaml"

        kubectl get secret $secret_name -n $install_namespace -o yaml > $file_folder/$secret_yaml_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get secret $secret_name$(tput sgr 0)"
            exit 1
        fi

        apikey_base64=`echo -n "$datadogAPIKey" | base64`
        applicationkey_base64=`echo -n "$datadogApplicationKey" | base64`
        sed -i "s|datadog_api_key:.*|datadog_api_key: $apikey_base64|g" $file_folder/$secret_yaml_name
        sed -i "s|datadog_application_key:.*|datadog_application_key: $applicationkey_base64|g" $file_folder/$secret_yaml_name

        kubectl apply -n $install_namespace -f $file_folder/$secret_yaml_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to apply update $file_folder/$secret_yaml_name on data adapter secret $secret_name$(tput sgr 0)"
            echo -e "$(tput setaf 1)Please review file content.$(tput sgr 0)"
            exit 1
        fi
        echo -e "\n$(tput setaf 3)...Done.$(tput sgr 0)"
    fi
}

add_alamedascaler_for_kafka()
{
    if [ "$configure_kafka" != "y" ]; then
        echo -e "\n$(tput setaf 3)Skipping Kafka alamedascaler setting...$(tput sgr 0)"
        return
    fi
    echo -e "\n$(tput setaf 3)Adding alamedascaler for Kafka...$(tput sgr 0)"

    scaler_index=0
    scaler_count=$(./jq -r '.dataAdapterConfigmapForKafka | length' $json_file)
    while [[ $scaler_index -lt $scaler_count ]]
    do
        scaler_name=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'] | .scalerName' $json_file)
        yaml_name="${scaler_name}.yaml"
        clusterName=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'] | .clusterName' $json_file)

        cat > $file_folder/$yaml_name << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha2
kind: AlamedaScaler
metadata:
  name: ${scaler_name}
  namespace: ${install_namespace}
spec:
  clusterName: ${clusterName}
  controllers:
__EOF__
        controller_index=0
        controller_count=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller | length' $json_file)
        while [[ $controller_index -lt $controller_count ]]
        do
            enableExecution=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .enableExecution' $json_file)
            kafkaExporterNamespace=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaExporterNamespace' $json_file)
            kafkaConsumerGroupKind=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerGroupKind' $json_file)
            kafkaConsumerGroupName=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerGroupName' $json_file)
            kafkaConsumerGroupNamespace=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerGroupNamespace' $json_file)
            kafkaTopicName=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaTopicName' $json_file)
            kafkaConsumerGroupId=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerGroupId' $json_file)
            kafkaConsumerMinimumReplica=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerMinimumReplica' $json_file)
            kafkaConsumerMaximumReplica=$(./jq -r '.dataAdapterConfigmapForKafka['$scaler_index'].controller['$controller_index'] | .kafkaConsumerMaximumReplica' $json_file)
            cat >> $file_folder/$yaml_name << __EOF__
    - type: kafka
      enableExecution: ${enableExecution}
      scaling: hpa
      kafka:
        exporterNamespace: ${kafkaExporterNamespace}
        consumerGroup:
          namespace: ${kafkaConsumerGroupNamespace}
          name: ${kafkaConsumerGroupName}
          kind: ${kafkaConsumerGroupKind}
          topic: ${kafkaTopicName}
          groupId: ${kafkaConsumerGroupId}
        hpaParameters:
          maxReplicas: ${kafkaConsumerMaximumReplica}
          minReplicas: ${kafkaConsumerMinimumReplica}
__EOF__
            ((controller_index = controller_index + 1))
        done

        fileArray+=( "$file_folder/$yaml_name" )
        ((scaler_index = scaler_index + 1))
    done

    for file_path in "${fileArray[@]}"
    do
        kubectl apply -f $file_path
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to apply Kafka alamedascaler file $file_path $(tput sgr 0)"
            echo -e "$(tput setaf 1)Please review file content.$(tput sgr 0)"
            exit 1
        fi
    done

    echo -e "\n$(tput setaf 3)...Done.$(tput sgr 0)"
}

add_alamedascaler_for_generic_app()
{
    if [ "$configure_general" != "y" ]; then
        echo -e "\n$(tput setaf 3)Skipping generic application alamedascaler setting....$(tput sgr 0)"
        return
    fi

    echo -e "\n$(tput setaf 3)Adding alamedascaler for generic applications...$(tput sgr 0)"

    scaler_index=0
    scaler_count=$(./jq -r '.dataAdapterConfigmapForGeneralApplication | length' $json_file)
    fileArray=()
    while [[ $scaler_index -lt $scaler_count ]]
    do
        scaler_name=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'] | .scalerName' $json_file)
        yaml_name="${scaler_name}.yaml"
        clusterName=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'] | .clusterName' $json_file)

        cat > $file_folder/$yaml_name << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha2
kind: AlamedaScaler
metadata:
  name: ${scaler_name}
  namespace: ${install_namespace}
spec:
  clusterName: ${clusterName}
  controllers:
__EOF__

        controller_index=0
        controller_count=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller | length' $json_file)
        while [[ $controller_index -lt $controller_count ]]
        do
            enableExecution=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .enableExecution' $json_file)
            genericTargetKind=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .genericTargetKind' $json_file)
            genericTargetName=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .genericTargetName' $json_file)
            genericTargetNamespace=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .genericTargetNamespace' $json_file)
            minReplicas=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .minReplicas' $json_file)
            maxReplicas=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .maxReplicas' $json_file)
            enableHPARecommendation=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$scaler_index'].controller['$controller_index'] | .enableHPARecommendation' $json_file)
            cat >> $file_folder/$yaml_name << __EOF__
    - type: generic
      enableExecution: ${enableExecution}
__EOF__
            if [ "$enableHPARecommendation" = "y" ]; then
                scaling_type="hpa"
                cat >> $file_folder/$yaml_name << __EOF__
      scaling: ${scaling_type}
      generic:
        target:
          namespace: ${genericTargetNamespace}
          name: ${genericTargetName}
          kind: ${genericTargetKind}
        hpaParameters:
          maxReplicas: ${maxReplicas}
          minReplicas: ${minReplicas}
__EOF__
            else
                scaling_type="predictOnly"
                cat >> $file_folder/$yaml_name << __EOF__
      scaling: ${scaling_type}
      generic:
        target:
          namespace: ${genericTargetNamespace}
          name: ${genericTargetName}
          kind: ${genericTargetKind}
__EOF__
            fi
            ((controller_index = controller_index + 1))
        done

        fileArray+=( "$file_folder/$yaml_name" )
        ((scaler_index = scaler_index + 1))
    done

    for file_path in "${fileArray[@]}"
    do
        kubectl apply -f $file_path
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to apply generic alamedascaler file $file_path $(tput sgr 0)"
            echo -e "$(tput setaf 1)Please review file content.$(tput sgr 0)"
            exit 1
        fi
    done

    echo -e "\n$(tput setaf 3)...Done.$(tput sgr 0)"
}

patch_data_adapter_configmap()
{
    echo -e "\n$(tput setaf 3)Updating Federator.ai data adapter configmap...$(tput sgr 0)"
    configmap_name="federatorai-data-adapter-config"
    configmap_yaml_name="adapter-configmap.yaml"

    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${alameda_version}/assets/ConfigMap/federatorai-data-adapter-config.yaml -o $file_folder/$configmap_yaml_name; then
        echo -e "\n$(tput setaf 1)Abort, download federatorai-data-adapter-config.yaml file failed!!!$(tput sgr 0)"
        exit 2
    fi

    sed -i "s|namespace:.*|namespace: $install_namespace|g" $file_folder/$configmap_yaml_name

    # if [ "$configure_general" = "y" ]; then
    #     # Enable GUI for now, after datadog release. These line must be removed
    #     sed -i "s|enable_general_dashboard =.*|enable_general_dashboard = true|g" $file_folder/$configmap_yaml_name
    # fi

    # if [ "$configure_kafka" = "y" ]; then
    #     # Enable GUI for now, after datadog release. These line must be removed
    #     sed -i "s|enable_kafka_dashboard =.*|enable_kafka_dashboard = true|g" $file_folder/$configmap_yaml_name
    # fi

    # Per SL&Jason, remain GUI switch as default "OFF".
    # sed -i "s|enable_general_dashboard =.*|enable_general_dashboard = true|g" $file_folder/$configmap_yaml_name
    # sed -i "s|enable_kafka_dashboard =.*|enable_kafka_dashboard = true|g" $file_folder/$configmap_yaml_name

    kubectl apply -n $install_namespace -f $file_folder/$configmap_yaml_name
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to apply update $file_folder/$configmap_yaml_name on data adapter configmap.$(tput sgr 0)"
        echo -e "$(tput setaf 1)Please review file content.$(tput sgr 0)"
        exit 1
    fi
    echo -e "\n$(tput setaf 3)...Done.$(tput sgr 0)"
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

get_datadog_key()
{
    secret_name="federatorai-data-adapter-secret"
    secret_api_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_api_key}'|base64 -d`"
    secret_app_key="`kubectl get secret $secret_name -n $install_namespace -o jsonpath='{.data.datadog_application_key}'|base64 -d`"

    key_modified="n"
    if [ "$secret_api_key" = "" ] || [ "$secret_app_key" = "" ] || [ "$secret_api_key" = "dummy" ] || [ "$secret_app_key" = "dummy" ]; then
        key_modified="y"
        while [ "$datadogAPIKey" = "" ] || [ "$datadogApplicationKey" = "" ]
        do
            read -r -p "$(tput setaf 6)Please input Datadog API key: $(tput sgr 0)" datadogAPIKey </dev/tty
            read -r -p "$(tput setaf 6)Please input Datadog Application key: $(tput sgr 0)" datadogApplicationKey </dev/tty
        done
    else
        while [ "$reconfigure_action" != "y" ] && [ "$reconfigure_action" != "n" ]
        do
            default="n"
            read -r -p "$(tput setaf 10)Do you want to reconfigure Datadog API & Application keys? [default: $default]: $(tput sgr 0)" reconfigure_action </dev/tty
            reconfigure_action=${reconfigure_action:-$default}
            reconfigure_action=$(echo "$reconfigure_action" | tr '[:upper:]' '[:lower:]')
        done
        if [ "$reconfigure_action" = "y" ]; then
            key_modified="y"
            while [ "$datadogAPIKey" = "" ] || [ "$datadogApplicationKey" = "" ]
            do
                read -r -p "$(tput setaf 6)Please input Datadog API key [current: $secret_api_key]: $(tput sgr 0)" datadogAPIKey </dev/tty
                datadogAPIKey=${datadogAPIKey:-$secret_api_key}

                read -r -p "$(tput setaf 6)Please input Datadog Application key [current: $secret_app_key]: $(tput sgr 0)" datadogApplicationKey </dev/tty
                datadogApplicationKey=${datadogApplicationKey:-$secret_app_key}
            done
        fi
    fi

    if [ "$key_modified" = "y" ]; then
        configStr=$( ./jq -c $(printf '.dataAdapterSecret.datadogAPIKey="%s"' $datadogAPIKey) <<<$configStr )
        configStr=$( ./jq -c $(printf '.dataAdapterSecret.datadogApplicationKey="%s"' $datadogApplicationKey) <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file
    fi
}

get_kafka_info()
{
    default="y"
    echo ""
    read -r -p "$(tput setaf 3)Do you want to configure alamedascaler for kafka? [default: $default]: $(tput sgr 0): " configure_kafka </dev/tty
    configure_kafka=${configure_kafka:-$default}

    if [ "$configure_kafka" != "y" ]; then
        configStr=$( ./jq -c 'del(.dataAdapterConfigmapForKafka[0:])' <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file
        return
    fi

    set_index=0
    next_set="y"
    while [[ "$next_set" = "y" ]]
    do
        echo -e "\nGetting Kafka info... No.$((set_index+1))"

        # scalerName
        default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'] | .scalerName' $json_file | sed 's:null::g')
        read -r -p "$(tput setaf 6)Input alamedascaler name [$default]: $(tput sgr 0)" scalerName </dev/tty
        scalerName=${scalerName:-$default}

        configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].scalerName="%s"' $set_index $scalerName) <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file

        # clusterName
        default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'] | .clusterName' $json_file | sed 's:null::g')
        read -r -p "$(tput setaf 6)Input cluster name [$default]: $(tput sgr 0)" clusterName </dev/tty
        clusterName=${clusterName:-$default}
        configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].clusterName="%s"' $set_index $clusterName) <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file

        # controller info
        controller_index=0
        next_controller="y"
        while [[ "$next_controller" = "y" ]]
        do
            echo -e "\nGetting controller info for $scalerName alamedascaler... No.$((controller_index+1))"
            ## For 4.3-husky, set enableExecution = 'false' per SL
            enableExecution="false"

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaExporterNamespace' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka exporter namespace [$default]: $(tput sgr 0)" kafkaExporterNamespace </dev/tty
            kafkaExporterNamespace=${kafkaExporterNamespace:-$default}

            kafkaConsumerGroupKind=""
            while [ "$kafkaConsumerGroupKind" != "Deployment" ] && [ "$kafkaConsumerGroupKind" != "DeploymentConfig" ] && [ "$kafkaConsumerGroupKind" != "StatefulSet" ]
            do
                default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerGroupKind' $json_file | sed 's:null::g')
                read -r -p "$(tput setaf 6)Input Kafka consumer group kind (Deployment/DeploymentConfig/StatefulSet) [$default]: $(tput sgr 0)" kafkaConsumerGroupKind </dev/tty
                kafkaConsumerGroupKind=${kafkaConsumerGroupKind:-$default}
            done

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerGroupName' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka consumer group kind name [$default]: $(tput sgr 0)" kafkaConsumerGroupName </dev/tty
            kafkaConsumerGroupName=${kafkaConsumerGroupName:-$default}

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerGroupNamespace' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka consumer group namespace [$default]: $(tput sgr 0)" kafkaConsumerGroupNamespace </dev/tty
            kafkaConsumerGroupNamespace=${kafkaConsumerGroupNamespace:-$default}

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaTopicName' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka consumer topic name [$default]: $(tput sgr 0)" kafkaTopicName </dev/tty
            kafkaTopicName=${kafkaTopicName:-$default}

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerGroupId' $json_file | sed 's:null::g')
            echo -e "\nYou can use Kafka command-line tool 'kafka-consumer-group.sh' (download separately or enter into a broker pod, in /bin directory) to list consumer groups."
            echo -e "e.g.: \"/bin/kafka-consumer-groups.sh --bootstrap-server <kafka-bootstrap-service>:9092 --describe --all-groups --members\""
            echo -e "The first column of output is the 'kafkaConsumerGroupId'."
            read -r -p "$(tput setaf 6)Input Kafka consumer group id [$default]: $(tput sgr 0)" kafkaConsumerGroupId </dev/tty
            kafkaConsumerGroupId=${kafkaConsumerGroupId:-$default}

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerMinimumReplica' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka consumer minimum replica number [$default]: $(tput sgr 0)" kafkaConsumerMinimumReplica </dev/tty
            kafkaConsumerMinimumReplica=${kafkaConsumerMinimumReplica:-$default}

            case $kafkaConsumerMinimumReplica in
                ''|*[!0-9]*) echo -e "\n$(tput setaf 1)Error! Kafka consumer minimum replicas number needs to be an integer.$(tput sgr 0)" && exit;;
                *) ;;
            esac

            default=$(./jq -r '.dataAdapterConfigmapForKafka['$set_index'].controller['$controller_index'] | .kafkaConsumerMaximumReplica' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input Kafka consumer maximum replica number [$default]: $(tput sgr 0)" kafkaConsumerMaximumReplica </dev/tty
            kafkaConsumerMaximumReplica=${kafkaConsumerMaximumReplica:-$default}

            case $kafkaConsumerMaximumReplica in
                ''|*[!0-9]*) echo -e "\n$(tput setaf 1)Error! Kafka consumer maximum replicas number needs to be an integer.$(tput sgr 0)" && exit;;
                *) ;;
            esac

            if [ "$clusterName" = "" ] || [ "$enableExecution" = "" ] || [ "$kafkaExporterNamespace" = "" ] || [ "$kafkaConsumerGroupKind" = "" ] || [ "$kafkaConsumerMinimumReplica" = "" ] || [ "$kafkaConsumerMaximumReplica" = "" ] || [ "$kafkaConsumerGroupName" = "" ] || [ "$kafkaConsumerGroupNamespace" = "" ] || [ "$kafkaTopicName" = "" ] || [ "$kafkaConsumerGroupId" = "" ]; then
                echo -e "\n$(tput setaf 1)Error! Kafka info can't be empty.$(tput sgr 0)"
                exit 7
            fi

            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].enableExecution="%s"' $set_index $controller_index $enableExecution) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaExporterNamespace="%s"' $set_index $controller_index $kafkaExporterNamespace) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerGroupKind="%s"' $set_index $controller_index $kafkaConsumerGroupKind) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerGroupName="%s"' $set_index $controller_index $kafkaConsumerGroupName) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerGroupNamespace="%s"' $set_index $controller_index $kafkaConsumerGroupNamespace) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaTopicName="%s"' $set_index $controller_index $kafkaTopicName) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerGroupId="%s"' $set_index $controller_index $kafkaConsumerGroupId) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerMinimumReplica="%s"' $set_index $controller_index $kafkaConsumerMinimumReplica) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForKafka[%s].controller[%s].kafkaConsumerMaximumReplica="%s"' $set_index $controller_index $kafkaConsumerMaximumReplica) <<<$configStr )
            ./jq -r '.' <<< $configStr > $json_file

            ((controller_index = controller_index + 1))
            echo ""
            sleep 1
            default="n"
            read -r -p "$(tput setaf 10)Do you want to add another controller in $scalerName alamedascaler? [default: $default]: $(tput sgr 0)" next_controller </dev/tty
            next_controller=${next_controller:-$default}
            while [[ "$next_controller" != "y" ]] && [[ "$next_controller" != "n" ]]
            do
                read -r -p "$(tput setaf 10)Do you want to add another controller in $scalerName alamedascaler? [default: $default]: $(tput sgr 0)" next_controller </dev/tty
                next_controller=${next_controller:-$default}
            done
            if [ "$next_controller" = "n" ]; then
                configStr=$( ./jq -c $(printf 'del(.dataAdapterConfigmapForKafka[%s].controller[%s:])' $set_index $controller_index) <<<$configStr )
                ./jq -r '.' <<< $configStr > $json_file
            fi
        done

        ((set_index = set_index + 1))
        echo ""
        sleep 1

        default="n"
        read -r -p "$(tput setaf 10)Do you want to add another Kafka set? [default: n]: $(tput sgr 0)" next_set </dev/tty
        next_set=${next_set:-$default}
        while [[ "$next_set" != "y" ]] && [[ "$next_set" != "n" ]]
        do
            read -r -p "$(tput setaf 10)Do you want to add another Kafka set? [default: n]: $(tput sgr 0)" next_set </dev/tty
            next_set=${next_set:-$default}
        done
        if [ "$next_set" = "n" ]; then
            configStr=$( ./jq -c $(printf 'del(.dataAdapterConfigmapForKafka[%s:])' $set_index) <<<$configStr )
            ./jq -r '.' <<< $configStr > $json_file
        fi
    done
}

get_general_application_info()
{
    default="y"
    echo ""
    read -r -p "$(tput setaf 3)Do you want to configure alamedascaler for generic application? [default: $default]: $(tput sgr 0): " configure_general </dev/tty
    configure_general=${configure_general:-$default}

    if [ "$configure_general" != "y" ]; then
        configStr=$( ./jq -c 'del(.dataAdapterConfigmapForGeneralApplication[0:])' <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file
        return
    fi

    set_index=0
    next_set="y"

    while [[ "$next_set" = "y" ]]
    do
        echo -e "\nGetting generic application info... No.$((set_index+1))"

        # scalerName
        default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'] | .scalerName' $json_file | sed 's:null::g')
        read -r -p "$(tput setaf 6)Input alamedascaler name [$default]: $(tput sgr 0)" scalerName </dev/tty
        scalerName=${scalerName:-$default}

        configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].scalerName="%s"' $set_index $scalerName) <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file

        # clusterName
        default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'] | .clusterName' $json_file | sed 's:null::g')
        read -r -p "$(tput setaf 6)Input cluster name [$default]: $(tput sgr 0)" clusterName </dev/tty
        clusterName=${clusterName:-$default}

        configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].clusterName="%s"' $set_index $clusterName) <<<$configStr )
        ./jq -r '.' <<< $configStr > $json_file

        # controller info
        controller_index=0
        next_controller="y"
        while [[ "$next_controller" = "y" ]]
        do
            echo -e "\nGetting controller info for $scalerName alamedascaler... No.$((controller_index+1))"

            genericTargetKind=""
            while [ "$genericTargetKind" != "Deployment" ] && [ "$genericTargetKind" != "DeploymentConfig" ] && [ "$genericTargetKind" != "StatefulSet" ]
            do
                default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .genericTargetKind' $json_file | sed 's:null::g')
                read -r -p "$(tput setaf 6)Input target app kind (Deployment/DeploymentConfig/StatefulSet)[$default]: $(tput sgr 0)" genericTargetKind </dev/tty
                genericTargetKind=${genericTargetKind:-$default}
            done

            default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .genericTargetNamespace' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input target app namespace [$default]: $(tput sgr 0)" genericTargetNamespace </dev/tty
            genericTargetNamespace=${genericTargetNamespace:-$default}

            # Comment out to support remote monitoring alamedascaler
            # deployment_lists="`kubectl -n ${genericTargetNamespace} get $genericTargetKind -o custom-columns=NAME:.metadata.name --no-headers | xargs`"
            # if [ "${deployment_lists}" = "" ]; then
            #     echo -e "\n$(tput setaf 1)Error! Namespace ${genericTargetNamespace} found no $genericTargetKind.$(tput sgr 0)"
            #     exit 7
            # fi
            # echo -e "\nExisting ${genericTargetKind} in namespace ${genericTargetNamespace}: ${deployment_lists}"
            default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .genericTargetName' $json_file | sed 's:null::g')
            read -r -p "$(tput setaf 6)Input ${genericTargetKind} name [$default]: $(tput sgr 0)" genericTargetName </dev/tty
            genericTargetName=${genericTargetName:-$default}

            ## For 4.3-husky, set enableExecution = 'false' per SL
            enableExecution="false"

            enableHPARecommendation=""
            while [ "$enableHPARecommendation" != "y" ] && [ "$enableHPARecommendation" != "n" ]
            do
                default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .enableHPARecommendation' $json_file | sed 's:null::g')
                if [ "$default" = "" ]; then
                    default="y"
                fi
                read -r -p "$(tput setaf 6)Do you want to enable HPA recommendation? [default: $default]: $(tput sgr 0)" enableHPARecommendation </dev/tty
                enableHPARecommendation=${enableHPARecommendation:-$default}
                enableHPARecommendation=$(echo "$enableHPARecommendation" | tr '[:upper:]' '[:lower:]')
            done

            if [ "$enableHPARecommendation" = "y" ]; then
                default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .minReplicas' $json_file | sed 's:null::g')
                read -r -p "$(tput setaf 6)Input minimum replicas number [$default]: $(tput sgr 0)" minReplicas </dev/tty
                minReplicas=${minReplicas:-$default}

                case $minReplicas in
                    ''|*[!0-9]*) echo -e "\n$(tput setaf 1)Error! The minimum replicas number needs to be an integer.$(tput sgr 0)" && exit;;
                    *) ;;
                esac

                default=$(./jq -r '.dataAdapterConfigmapForGeneralApplication['$set_index'].controller['$controller_index'] | .maxReplicas' $json_file | sed 's:null::g')
                read -r -p "$(tput setaf 6)Input maximum replicas number [$default]: $(tput sgr 0)" maxReplicas </dev/tty
                maxReplicas=${maxReplicas:-$default}

                case $maxReplicas in
                    ''|*[!0-9]*) echo -e "\n$(tput setaf 1)Error! The maximum replicas number needs to be an integer.$(tput sgr 0)" && exit;;
                    *) ;;
                esac
            else
                minReplicas="null"
                maxReplicas="null"
            fi

            if [ "$clusterName" = "" ] || [ "$genericTargetKind" = "" ] || [ "$genericTargetName" = "" ] || [ "$genericTargetNamespace" = "" ] || [ "$enableExecution" = "" ] || [ "$minReplicas" = "" ] || [ "$maxReplicas" = "" ]; then
                echo -e "\n$(tput setaf 1)Error! Application info can't be empty.$(tput sgr 0)"
                exit 7
            fi

            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].enableExecution="%s"' $set_index $controller_index $enableExecution) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].genericTargetKind="%s"' $set_index $controller_index $genericTargetKind) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].genericTargetName="%s"' $set_index $controller_index $genericTargetName) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].genericTargetNamespace="%s"' $set_index $controller_index $genericTargetNamespace) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].minReplicas="%s"' $set_index $controller_index $minReplicas) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].maxReplicas="%s"' $set_index $controller_index $maxReplicas) <<<$configStr )
            configStr=$( ./jq -c $(printf '.dataAdapterConfigmapForGeneralApplication[%s].controller[%s].enableHPARecommendation="%s"' $set_index $controller_index $enableHPARecommendation) <<<$configStr )
            ./jq -r '.' <<< $configStr > $json_file
            ((controller_index = controller_index + 1))
            echo ""
            sleep 1
            default="n"
            read -r -p "$(tput setaf 10)Do you want to add another controller in $scalerName alamedascaler? [default: $default]: $(tput sgr 0)" next_controller </dev/tty
            next_controller=${next_controller:-$default}
            while [[ "$next_controller" != "y" ]] && [[ "$next_controller" != "n" ]]
            do
                read -r -p "$(tput setaf 10)Do you want to add another controller in $scalerName alamedascaler? [default: $default]: $(tput sgr 0)" next_controller </dev/tty
                next_controller=${next_controller:-$default}
            done
            if [ "$next_controller" = "n" ]; then
                configStr=$( ./jq -c $(printf 'del(.dataAdapterConfigmapForGeneralApplication[%s].controller[%s:])' $set_index $controller_index) <<<$configStr )
                ./jq -r '.' <<< $configStr > $json_file
            fi
        done

        ((set_index = set_index + 1))
        echo ""
        sleep 1
        default="n"
        read -r -p "$(tput setaf 10)Do you want to add another generic application? [default: $default]: $(tput sgr 0)" next_set </dev/tty
        next_set=${next_set:-$default}
        while [[ "$next_set" != "y" ]] && [[ "$next_set" != "n" ]]
        do
            read -r -p "$(tput setaf 10)Do you want to add another generic application? [default: $default]: $(tput sgr 0)" next_set </dev/tty
            next_set=${next_set:-$default}
        done
        if [ "$next_set" = "n" ]; then
            configStr=$( ./jq -c $(printf 'del(.dataAdapterConfigmapForGeneralApplication[%s:])' $set_index) <<<$configStr )
            ./jq -r '.' <<< $configStr > $json_file
        fi
    done
}

get_alamedaservice_full_version()
{
    alameda_version=`kubectl get alamedaservice --all-namespaces|grep -v 'EXECUTION'|awk '{print $4}'`
    if [ "$alameda_version" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get Federator.ai version!$(tput sgr 0)"
        exit 2
    fi
}

restart_data_adapter_pod()
{
    echo -e "\n$(tput setaf 3)Restarting Federator.ai data adapter...$(tput sgr 0)"
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
    echo -e "\n$(tput setaf 3)...Done.$(tput sgr 0)"
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

prepare_env()
{
    get_alamedaservice_full_version

    if [ -f "$json_file" ]; then
        cat $json_file|grep -q "$json_file_version"
        if [ "$?" != "0" ]; then
            mv $json_file ${json_file}.old
            mv $json_file_template ${json_file_template}.old
        fi
    fi

    if [ ! -f "$json_file" ]; then
        if [ ! -f "$json_file_template" ]; then
            cat > $json_file_template << __EOF__
{
  "version": "${json_file_version}",
  "dataAdapterSecret": {
    "datadogAPIKey": "",
    "datadogApplicationKey": ""
  },
  "dataAdapterConfigmapForKafka": [
    {
      "scalerName": "",
      "clusterName": "",
      "controller": [
        {
            "enableExecution": "",
            "kafkaExporterNamespace": "",
            "kafkaConsumerGroupKind": "",
            "kafkaConsumerGroupName": "",
            "kafkaConsumerGroupNamespace": "",
            "kafkaTopicName": "",
            "kafkaConsumerGroupId": "",
            "kafkaConsumerMinimumReplica": "",
            "kafkaConsumerMaximumReplica": ""
        }
      ]
    }
  ],
  "dataAdapterConfigmapForGeneralApplication": [
    {
      "scalerName": "",
      "clusterName": "",
      "controller": [
        {
            "enableExecution": "",
            "enableHPARecommendation": "",
            "genericTargetKind": "",
            "genericTargetName": "",
            "genericTargetNamespace": "",
            "minReplicas": "",
            "maxReplicas": ""
        }
      ]
    }
  ]
}
__EOF__
        fi
        cp $json_file_template $json_file
    fi

    if [ ! -f "jq" ]; then
        if ! curl -sL --fail https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O; then
            echo -e "\n$(tput setaf 1)Abort, download jq binary failed!!!$(tput sgr 0)"
            exit 2
        fi
        mv jq-linux64 jq
        chmod u+x jq
    fi
    configStr=$(./jq -c '.' $json_file)
}

# If more option is added into script in the future, uncomment this section

# if [ "$#" -eq "0" ]; then
#     show_usage
#     exit 1
# fi

echo "Checking environment version..."
check_version
echo "...Passed"

while getopts "hk:" o; do
    case "${o}" in
        k)
            kubeconfig="${OPTARG}"
            ;;
        h)
            show_usage
            exit 1
            ;;
        *)
            echo "Error! Invalid parameter."
            show_usage
            ;;
    esac
done

[ "$max_wait_pods_ready_time" = "" ] && max_wait_pods_ready_time=1500  # maximum wait time for pods become ready

file_folder="./config_result"
current_location=`pwd`
mkdir -p $file_folder

if [ "$openshift_minor_version" != "" ]; then
    # OpenShift
    if [ "${kubeconfig}" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Need to use \"-k\" to specify openshift kubeconfig file.$(tput sgr 0)"
        show_usage
    fi
    export KUBECONFIG=${kubeconfig}
fi

# Check if kubectl connect to server.
result="`echo ""|kubectl cluster-info 2>/dev/null`"
if [ "$?" != "0" ]; then
    echo -e "\n$(tput setaf 1)Error! Please login into cluster first.$(tput sgr 0)"
    exit 1
fi
current_server="`echo $result|sed 's/.*at //'|awk '{print $1}'`"
echo "You are connecting to the cluster: $current_server"

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

alamedaservice_name="`kubectl get alamedaservice -n $install_namespace -o jsonpath='{range .items[*]}{.metadata.name}'`"
if [ "$alamedaservice_name" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to get alamedaservice name.$(tput sgr 0)"
    exit 8
fi

json_file="adapter.json"
json_file_version="v4.3.102"
json_file_template="adapter.json.tmp"

prepare_env

get_datadog_key

get_general_application_info

get_kafka_info

patch_data_adapter_secret

## No need to update configmap content for now
#patch_data_adapter_configmap
add_alamedascaler_for_generic_app
add_alamedascaler_for_kafka

restart_data_adapter_pod

echo -e "$(tput setaf 6)\nSetup Federator.ai for Datadog successfully$(tput sgr 0)"
echo -e "$(tput setaf 6)Yaml files generated are under $file_folder $(tput sgr 0)"

exit 0
