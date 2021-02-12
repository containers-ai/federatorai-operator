#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for installing Federator.ai Operator on AWS
#
#   1. Interactive Mode
#      Usage: ./install.sh --image-path 88888976.dkr.ecr.us-east-1.amazonaws.com/888888-37c8-4328-91b2-62c1acd2a04b/cg-1231030144/federatorai-operator:4.2-latest
#                   --cluster awsmp-new --region us-west-2
#
#   --image-path <space> AWS ECR url
#   --cluster <space> AWS EKS cluster name
#   --region <space> AWS region
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
    k8s_version=`kubectl version 2>/dev/null|grep Server|grep -o "Minor:\"[0-9]."|sed 's/[^0-9]*//g'`

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
            echo "The REST API online document can be find in $(tput setaf 6)http://${link}/apis/v1/swagger/index.html $(tput sgr 0)"
            echo "========================================"
        else
            echo "Warning! Failed to obtain Federatorai REST API route address."
        fi
    fi
}

check_aws_version()
{
    awscli_required_version="1.16.283"
    awscli_required_version_major=`echo $awscli_required_version | cut -d'.' -f1`
    awscli_required_version_minor=`echo $awscli_required_version | cut -d'.' -f2`
    awscli_required_version_build=`echo $awscli_required_version | cut -d'.' -f3`

    # aws --version: aws-cli/2.0.0dev0
    awscli_version=`aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2`
    awscli_version_major=`echo $awscli_version | cut -d'.' -f1`
    awscli_version_minor=`echo $awscli_version | cut -d'.' -f2`
    awscli_version_build=`echo $awscli_version | cut -d'.' -f3`
    awscli_version_build=${awscli_version_build%%[^0-9]*}   # remove everything from the first non-digit

    if [ "$awscli_version_major" -gt "$awscli_required_version_major" ]; then
        return 0
    fi

    if [ "$awscli_version_major" = "$awscli_required_version_major" ] && \
        [ "$awscli_version_minor" -gt "$awscli_required_version_minor" ]; then
            return 0
    fi

    if [ "$awscli_version_major" = "$awscli_required_version_major" ] && \
        [ "$awscli_version_minor" = "$awscli_required_version_minor" ] && \
        [ "$awscli_version_build" -ge "$awscli_required_version_build" ]; then
            return 0
    fi

    echo -e "\n$(tput setaf 10)Error! AWS CLI version must be $awscli_required_version or greater.$(tput sgr 0)"
    exit 9
}

setup_aws_iam_role()
{
    REGION_NAME=$aws_region
    CLUSTER_NAME=$eks_cluster

    # Create an OIDC provider for the cluster
    ISSUER_URL=$(aws eks describe-cluster \
                    --name $CLUSTER_NAME \
                    --region $REGION_NAME \
                    --query cluster.identity.oidc.issuer \
                    --output text )
    ISSUER_URL_WITHOUT_PROTOCOL=$(echo $ISSUER_URL | sed 's/https:\/\///g' )
    ISSUER_HOSTPATH=$(echo $ISSUER_URL_WITHOUT_PROTOCOL | sed "s/\/id.*//" )
    # Grab all certificates associated with the issuer hostpath and save them to files. The root certificate is last
    rm -f *.crt || echo "No files that match *.crt exist"
    ROOT_CA_FILENAME=$(openssl s_client -showcerts -connect $ISSUER_HOSTPATH:443 < /dev/null 2>&1 \
                        | awk '/BEGIN/,/END/{ if(/BEGIN/){a++}; out="cert"a".crt"; print > out } END {print "cert"a".crt"}')
    ROOT_CA_FINGERPRINT=$(openssl x509 -fingerprint -noout -in $ROOT_CA_FILENAME \
                        | sed 's/://g' | sed 's/SHA1 Fingerprint=//')
    result=$(aws iam create-open-id-connect-provider \
                --url $ISSUER_URL \
                --thumbprint-list $ROOT_CA_FINGERPRINT \
                --client-id-list sts.amazonaws.com \
                --region $REGION_NAME 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The provider for $ISSUER_URL already exists"
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_URL_WITHOUT_PROTOCOL"
    ROLE_NAME="FederatorAI-$CLUSTER_NAME"
    POLICY_NAME="AWSMarketplaceMetering-$CLUSTER_NAME"
    POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

    # Update trust relationships of pod execution roles so pods on our cluster can assume them
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "$PROVIDER_ARN"
            },
            "Action": "sts:AssumeRoleWithWebIdentity"
        }
    ]
}
EOF

    result=$(aws iam create-role \
                --role-name $ROLE_NAME \
                --assume-role-policy-document file://trust-policy.json 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The IAM role $ROLE_NAME already exists"
    fi

    # Attach policy to give required permission to call RegisterUsage API
cat > iam-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "aws-marketplace:RegisterUsage"
            ],
            "Effect": "Allow",
            "Resource": "*"
        }
    ]
}
EOF
    result=$(aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file://iam-policy.json 2>&1 | grep EntityAlreadyExists)
    if [ "$result" != "" ]; then
        echo "The policy $POLICY_NAME already exists"
    fi

    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
}


while getopts "t:n:e:p:s:l:d:c:-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                image-path)
                    ecr_url="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$ecr_url" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                cluster)
                    eks_cluster="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$ecr_url" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                region)
                    aws_region="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$aws_region" = "" ]; then
                        echo "Error! Missing --${OPTARG} value"
                        exit
                    fi
                    ;;
                *)
                    echo "Unknown option --${OPTARG}"
                    exit
                    ;;
            esac;;
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
        *)
            echo "Warning! wrong paramter, ignore it."
            ;;
    esac
done

# ecr_url, eks_cluster, aws_region all are empty or all have values
if [ "$ecr_url" != "" ] || [ "$eks_cluster" != ""] || [ "$aws_region" != ""]; then
    if [ "$ecr_url" = "" ]; then
        echo "Missing --image-path parameter"
        exit
    elif [ "$eks_cluster" = "" ]; then
        echo "Missing --cluster parameter"
        exit
    elif [ "$aws_region" = "" ]; then
        echo "Missing --region parameter"
        exit
    fi
fi

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

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to kubernetes first."
    exit
fi

echo "Checking environment version..."
check_version
echo "...Passed"

echo -e "Checking AWS CLI version..."
check_aws_version
echo "...Passed"
echo

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

previous_alameda_namespace="`kubectl get pods --all-namespaces |grep "alameda-ai-"|awk '{print $1}'|head -1`"
previous_tag="`kubectl get pods -n $previous_alameda_namespace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image 2>/dev/null| grep datahub | head -1 | cut -d ':' -f2`"

if [ "$previous_alameda_namespace" != "" ];then
    need_upgrade="y"
fi

if [ "$silent_mode_disabled" = "y" ];then

    while [[ "$info_correct" != "y" ]] && [[ "$info_correct" != "Y" ]]
    do
        # init variables
        install_namespace=""
        tag_number=""

        # For 4.2 install.aws.sh, fix tag_number
        #read -r -p "$(tput setaf 2)Please input Federator.ai Operator tag:$(tput sgr 0) " tag_number </dev/tty
        tag_number="v4.2.301"

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
    echo -e "----------------------------------------\n"
fi

file_folder="/tmp/install-op"
[ "$max_wait_pods_ready_time" = "" ] && max_wait_pods_ready_time=900  # maximum wait time for pods become ready

rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
cd $file_folder

# Setup AWS IAM role for service account
echo -e "\n$(tput setaf 2)Setting AWS IAM role for service account...$(tput sgr 0)"
setup_aws_iam_role
role_arn=$(aws iam get-role --role-name ${ROLE_NAME} --query Role.Arn --output text)
echo "Done"

# Download federator.ai operator ymal(s)
echo -e "\n$(tput setaf 2)Downloading Federator.ai operator yaml files...$(tput sgr 0)"
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
# for tag (with or without ECR)
if [ "$ecr_url" != "" ]; then
    sed -i "s|quay.io/prophetstor/federatorai-operator-ubi:latest|$ecr_url|g" 03*.yaml
    sed -i "/\- federatorai-operator/d" 03*.yaml
    sed -i "/command:/d" 03*.yaml
cat >> 01*.yaml << __EOF__
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}
__EOF__
else
    sed -i "s/ubi:latest/ubi:${tag_number}/g" 03*.yaml
fi

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

wait_until_pods_ready $max_wait_pods_ready_time 30 $install_namespace 1
echo -e "\n$(tput setaf 6)Install Federator.ai operator $tag_number successfully$(tput sgr 0)"

# special version for aws marketplace only =======
leave_prog
exit 0
# special version for aws marketplace only =======

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

if [ "$silent_mode_disabled" = "y" ];then

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

            if [[ "$openshift_minor_version" == "11" ]]; then
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
                read -r -p "$(tput setaf 127)Specify log storage size [ex: 10 for 10GB, default: 10]: $(tput sgr 0)" log_size </dev/tty
                log_size=${log_size:-$default}
                default="10"
                read -r -p "$(tput setaf 127)Specify data storage size [ex: 10 for 10GB, default: 10]: $(tput sgr 0)" data_size </dev/tty
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
else
    install_alameda="y"
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
