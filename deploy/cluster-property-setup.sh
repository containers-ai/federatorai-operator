#!/usr/bin/env bash

get_current_yaml()
{
    kubectl get alamedaorganization $default_org_name -o yaml > $current_yaml
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get alamedaorganization $default_org_name $(tput sgr 0)"
        exit 2
    fi
}

check_yq_tool()
{
    if [ ! -f "yq" ]; then
        if ! curl -sL --fail https://github.com/mikefarah/yq/releases/download/3.3.4/yq_linux_amd64 -O; then
            echo -e "\n$(tput setaf 1)Abort, download yq binary failed!!!$(tput sgr 0)"
            exit 2
        fi
        mv yq_linux_amd64 yq
        chmod u+x yq
    fi
}

get_cluster_settings()
{
    get_current_yaml
    cluster_nums="`./yq r $current_yaml -l  "spec.clusters"`"
    name_list=()
    cost_enable_list=()
    cost_mode_list=()
    watched_namespace_operator_list=()
    watched_namespaces_list=()
    for cluster_index in `seq 0 $(($cluster_nums - 1))`
    do
        cluster_name="`./yq r $current_yaml "spec.clusters[$cluster_index].name"|tr -d '[:space:]'`"
        name_list=("${name_list[@]}" "$cluster_name")
    
        cost_enable_value="`./yq r $current_yaml "spec.clusters[$cluster_index].features[*].costAnalysis.enabled"|tr -d '[:space:]'`"
        cost_enable_list=("${cost_enable_list[@]}" "$cost_enable_value")

        cost_mode_value="`./yq r $current_yaml "spec.clusters[$cluster_index].features[*].costAnalysis.mode"|tr -d '[:space:]'`"
        cost_mode_list=("${cost_mode_list[@]}" "$cost_mode_value")

        watched_namespace_operator="`./yq r $current_yaml "spec.clusters[$cluster_index].watchedNamespace.operator"|tr -d '[:space:]'`"
        watched_namespace_operator_list=("${watched_namespace_operator_list[@]}" "$watched_namespace_operator")

        watched_namespaces="`./yq r $current_yaml "spec.clusters[$cluster_index].watchedNamespace.names"|xargs|sed 's/ - /,/g'|sed 's/- //g'`"
        watched_namespaces_list=("${watched_namespaces_list[@]}" "$watched_namespaces")
    done
}

get_global_cluster_settings()
{
    global_cost_enable_value="`./yq r $current_yaml "spec.features[0].costAnalysis.enabled"|tr -d '[:space:]'`"
    global_cost_mode="`./yq r $current_yaml "spec.features[0].costAnalysis.mode"|tr -d '[:space:]'`"
    global_watched_namespace_operator="`./yq r $current_yaml "spec.watchedNamespace.operator"|tr -d '[:space:]'`"
    global_watched_namespaces="`./yq r $current_yaml "spec.watchedNamespace.names"|xargs|sed 's/ - /,/g'|sed 's/- //g'`"
}

display_current_setting()
{
    get_cluster_settings

    get_global_cluster_settings
    
    for cluster_index in `seq 0 $(($cluster_nums - 1))`
    do
        echo -e "======== $(tput setaf 213)Cluster $(($cluster_index + 1)) Settings $(tput sgr 0)================================================"
        echo -e "$(tput setaf 6)cluster name:$(tput sgr 0) ${name_list[$cluster_index]}"
        echo -e "$(tput setaf 6)cost analysis enabled:$(tput sgr 0) ${cost_enable_list[$cluster_index]:-N/A}"
        echo -e "$(tput setaf 6)cost analysis mode:$(tput sgr 0) ${cost_mode_list[$cluster_index]:-N/A}"
        echo -e "$(tput setaf 6)watched namespaces operator:$(tput sgr 0) ${watched_namespace_operator_list[$cluster_index]:-N/A}"
        echo -e "$(tput setaf 6)watched namespaces:$(tput sgr 0) ${watched_namespaces_list[$cluster_index]:-N/A}"
        echo "============================================================================"
    done

    echo -e "======== $(tput setaf 213)Global Settings $(tput sgr 0)==================================================="
    echo -e "$(tput setaf 3)cost analysis enabled:$(tput sgr 0) ${global_cost_enable_value:-N/A}"
    echo -e "$(tput setaf 3)cost analysis mode:$(tput sgr 0) ${global_cost_mode:-N/A}"
    echo -e "$(tput setaf 3)watched namespaces operator:$(tput sgr 0) ${global_watched_namespace_operator:-N/A}"
    echo -e "$(tput setaf 3)watched namespaces:$(tput sgr 0) ${global_watched_namespaces:-N/A}"
    echo "============================================================================"
}

ask_cost_analysis()
{
    # clean up
    unset_cost_analysis_settings_vars

    # Always true for now per SL
    cost_enable="true"

    while [ "$cost_mode" != "localOnly" ] && [ "$cost_mode" != "uploadResult" ]
    do
        default="y"
        read -r -p "$(tput setaf 11)Do you want to upload cost analysis metrics to monitoring cloud service (Datadog)? [default: y]: $(tput sgr 0)" cost_mode </dev/tty
        cost_mode=${cost_mode:-$default}
        cost_mode=$(echo "$cost_mode" | tr '[:upper:]' '[:lower:]')
        if [ "$cost_mode" = "y" ]; then
            cost_mode="uploadResult"
        elif [ "$cost_mode" = "n" ]; then
            cost_mode="localOnly"
        fi
    done
}

ask_watched_namespaces_settings()
{
    # clean up
    unset_watched_ns_settings_vars

    while [ "$configure_watch_ns" != "y" ] && [ "$configure_watch_ns" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 11)Do you want to configure watched namespaces of this cluster? [default: y]: $(tput sgr 0)" configure_watch_ns </dev/tty
        configure_watch_ns=${configure_watch_ns:-$default}
        configure_watch_ns=$(echo "$configure_watch_ns" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$configure_watch_ns" = "y" ]; then
        while [ "$watched_namespace_operator" != "include" ] && [ "$watched_namespace_operator" != "exclude" ]
        do
            read -r -p "$(tput setaf 11)Input watched namespace operator [include/exclude]: $(tput sgr 0)" watched_namespace_operator </dev/tty
            watched_namespace_operator=$(echo "$watched_namespace_operator" | tr '[:upper:]' '[:lower:]')
        done

        if [ "$watched_namespace_operator" = "exclude" ]; then
            while [ "$exclude_system_ns" != "y" ] && [ "$exclude_system_ns" != "n" ]
            do
                default="y"
                read -r -p "$(tput setaf 11)Do you want to exclude system namespaces? [default: y]: $(tput sgr 0)" exclude_system_ns </dev/tty
                exclude_system_ns=${exclude_system_ns:-$default}
                exclude_system_ns=$(echo "$exclude_system_ns" | tr '[:upper:]' '[:lower:]')
            done
        fi

        if [ "$exclude_system_ns" = "y" ]; then
            watched_namespaces="kube-public,kube-service-catalog,kube-system,management-infra,kube-node-lease,stackpoint-system,marketplace,openshift,openshift-*"
        else
            while [ "$watched_namespaces" = "" ]
            do
                read -r -p "$(tput setaf 11)Input watched namespace separated by comma [e.g., nginx1,influxdb2,ns3]: $(tput sgr 0)" watched_namespaces </dev/tty
                watched_namespaces=$(echo "$watched_namespaces" | tr '[:upper:]' '[:lower:]'|tr -d '[:space:]')
                # Need verification ???
            done
        fi
    fi
}

unset_cluster_settings_vars()
{
    unset cluster_name is_cluster_info_correct
}

unset_cost_analysis_settings_vars()
{
    unset cost_enable cost_mode
}

unset_watched_ns_settings_vars()
{
    unset configure_watch_ns watched_namespace_operator exclude_system_ns watched_namespaces
}

ask_cluster_settings()
{
    # Clean up
    unset_cluster_settings_vars

    while [ "$is_cluster_info_correct" != "y" ]
    do
        cluster_name=""
        while [ "$cluster_name" = "" ]
        do
            read -r -p "$(tput setaf 11)Input cluster name: $(tput sgr 0)" cluster_name </dev/tty
            cluster_name=$(echo "$cluster_name" | tr '[:upper:]' '[:lower:]')
        done

        ask_cost_analysis
        ask_watched_namespaces_settings

        default="y"
        read -r -p "$(tput setaf 6)Is the above information correct [default: y]: $(tput sgr 0)" is_cluster_info_correct </dev/tty
        is_cluster_info_correct=${is_cluster_info_correct:-$default}
        is_cluster_info_correct=$(echo "$is_cluster_info_correct" | tr '[:upper:]' '[:lower:]')
    done
}

patch_global_cluster_settings()
{
    if [ "$cost_enable" = "" ] || [ "$cost_mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! cost analysis enable or cost analysis mode can't be empty.$(tput sgr 0)"
        exit 8
    fi

    if [ "$configure_watch_ns" = "y" ]; then
        if [ "$watched_namespace_operator" = "" ] || [ "$watched_namespaces" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! watched_namespace_operator or watched_namespaces can't be empty.$(tput sgr 0)"
            exit 8
        fi
    fi
    
    cat > ${global_cluster_yaml} << __EOF__
apiVersion: tenant.containers.ai/v1alpha1
kind: AlamedaOrganization
metadata:
  name: ${default_org_name}
spec:
  tenant: default
__EOF__

    cat >> ${global_cluster_yaml} << __EOF__
  features:
  - type: costAnalysis
    costAnalysis:
      enabled: ${cost_enable}
      mode: ${cost_mode}
__EOF__

    if [ "$configure_watch_ns" = "y" ]; then
        cat >> ${global_cluster_yaml} << __EOF__
  watchedNamespace:
    operator: ${watched_namespace_operator}
    names:
__EOF__

        oldifs="$IFS"
        IFS=', '
        read -r -a ns_array <<< "$watched_namespaces"
        IFS="$oldifs"

        for ns in "${ns_array[@]}"
        do
            cat >> ${global_cluster_yaml} << __EOF__
    - $ns
__EOF__
        done
    else
        # clean up
        cat >> ${global_cluster_yaml} << __EOF__
  watchedNamespace: null
__EOF__
    fi

    kubectl patch alamedaorganization $default_org_name --type merge --patch "$(cat $global_cluster_yaml)"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to update global cost analysis settings in the $default_org_name alamedaorganization.$(tput sgr 0)"
        exit 8
    fi
    # refresh current yaml file
    get_current_yaml
}

create_cluster_append_yaml()
{
    cat > ${cluster_append_yaml} << __EOF__
apiVersion: tenant.containers.ai/v1alpha1
kind: AlamedaOrganization
metadata:
  name: ${default_org_name}
spec:
  clusters:
  - name: ${cluster_name}
__EOF__

    cat >> ${cluster_append_yaml} << __EOF__
    features:
    - costAnalysis:
        enabled: ${cost_enable}
        mode: ${cost_mode}
      type: costAnalysis
__EOF__

    if [ "$configure_watch_ns" = "y" ]; then
        cat >> ${cluster_append_yaml} << __EOF__
    watchedNamespace:
      operator: ${watched_namespace_operator}
      names:
__EOF__

        oldifs="$IFS"
        IFS=', '
        read -r -a ns_array <<< "$watched_namespaces"
        IFS="$oldifs"

        for ns in "${ns_array[@]}"
        do
            cat >> ${cluster_append_yaml} << __EOF__
      - $ns
__EOF__

        done
    fi
}

patch_cluster_settings()
{
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! cluster_name can't be empty.$(tput sgr 0)"
        exit 8
    fi

    if [ "$cost_enable" = "" ] || [ "$cost_mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! cost analysis enable or cost analysis mode can't be empty.$(tput sgr 0)"
        exit 8
    fi

    if [ "$configure_watch_ns" = "y" ]; then
        if [ "$watched_namespace_operator" = "" ] || [ "$watched_namespaces" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! watched_namespace_operator or watched_namespaces can't be empty.$(tput sgr 0)"
            exit 8
        fi
    fi
    
    # remoeve cluster entry in cluster_yaml if exist
    select_cluster_and_delete "$cluster_name" "n"

    # create append_yaml
    create_cluster_append_yaml

    # Merge cluster_yaml with append_yaml into cluster_yaml
    ./yq m -a -i ${cluster_yaml} ${cluster_append_yaml}

    # Apply cluster_yaml
    kubectl patch alamedaorganization $default_org_name --type merge --patch "$(cat $cluster_yaml)"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to update cluster $cluster_name settings in the $default_org_name alamedaorganization.$(tput sgr 0)"
        exit 8
    fi
    # refresh current yaml file
    get_current_yaml
}

delete_global_cluster_settings()
{
    cat > ${global_cluster_delete_yaml} << __EOF__
apiVersion: tenant.containers.ai/v1alpha1
kind: AlamedaOrganization
metadata:
  name: ${default_org_name}
spec:
  features: []
  watchedNamespace: null
__EOF__

    delete_confirmation=""
    while [ "$delete_confirmation" != "y" ] && [ "$delete_confirmation" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 11)Are you sure you want to delete the global cluster settings? [default: y]: $(tput sgr 0)" delete_confirmation </dev/tty
        delete_confirmation=${delete_confirmation:-$default}
        delete_confirmation=$(echo "$delete_confirmation" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$delete_confirmation" = "n" ]; then
        echo "OK! Operation aborted."
        return
    fi

    kubectl patch alamedaorganization $default_org_name --type merge --patch "$(cat $global_cluster_delete_yaml)"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to delete global cluster settings in the $default_org_name alamedaorganization.$(tput sgr 0)"
        exit 8
    fi
    # refresh current yaml file
    get_current_yaml
}

get_current_cluster_list()
{
    get_current_yaml

    oldifs="$IFS"
    IFS=$'\n'
    cluster_list=($(./yq r $current_yaml  "spec.clusters[*].name"))
    IFS="$oldifs"
}

select_cluster_and_delete()
{
    input_cluster_name="$1"
    execute_deletion="$2"

    get_current_yaml
    get_current_cluster_list

    if [ "$input_cluster_name" = "none" ]; then
        input_cluster_name=""
        while [ "$input_cluster_name" = "" ]
        do
            read -r -p "$(tput setaf 11)Input the cluster name you want to delete: $(tput sgr 0)" input_cluster_name </dev/tty
            # input_cluster_name=$(echo "$input_cluster_name" | tr '[:upper:]' '[:lower:]')
            if [ "$input_cluster_name" = "" ]; then
                echo -e "$(tput setaf 1)Can't input empty name.$(tput sgr 0)"
            elif [[ "${cluster_list[@]}" =~ "$input_cluster_name" ]]; then
                break
            else
                echo -e "$(tput setaf 1)The cluster name you input doesn't exist.$(tput sgr 0)"
                input_cluster_name=""
            fi
        done
    fi

    #find index of that cluster name
    cluster_index="`./yq r $current_yaml 'spec.clusters[*].name'|grep -n "$input_cluster_name"|cut -d ':' -f1`"
    
    # No need to do delete if found no record inside
    if [ "$cluster_index" != "" ]; then
        cluster_index="$(($cluster_index - 1))"
        ./yq d $current_yaml "spec.clusters[$cluster_index]" > $cluster_yaml

        if [ "$execute_deletion" = "y" ]; then
            delete_confirmation=""
            while [ "$delete_confirmation" != "y" ] && [ "$delete_confirmation" != "n" ]
            do
                default="y"
                read -r -p "$(tput setaf 11)Are you sure you want to delete the $input_cluster_name cluster settings? [default: y]: $(tput sgr 0)" delete_confirmation </dev/tty
                delete_confirmation=${delete_confirmation:-$default}
                delete_confirmation=$(echo "$delete_confirmation" | tr '[:upper:]' '[:lower:]')
            done

            if [ "$delete_confirmation" = "n" ]; then
                echo "OK! Operation aborted."
                return
            fi

            kubectl patch alamedaorganization $default_org_name --type merge --patch "$(cat $cluster_yaml)"
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! Failed to delete cluster $input_cluster_name settings in the $default_org_name alamedaorganization.$(tput sgr 0)"
                exit 8
            fi
            # refresh current yaml file
            get_current_yaml
        fi
    else
        # no update
        cp $current_yaml $cluster_yaml
    fi
}

default_org_name="default"
file_folder="/tmp/alamedaorganization"
current_yaml="current_setting.yaml"
global_cluster_yaml="global_cluster_settings.yaml"
global_cluster_delete_yaml="global_cluster_delete.yaml"
cluster_yaml="cluster_settings.yaml"
cluster_append_yaml="cluster_append.yaml"

mkdir -p $file_folder
cd $file_folder

check_yq_tool

rm -f $current_yaml
rm -f $global_cluster_yaml
rm -f $global_cluster_delete_yaml
rm -f $cluster_yaml
rm -f $cluster_append_yaml

clear

while :
do
    echo "Alameda Organization:"
    echo -e "\t(a) $(tput setaf 10)Display current settings.$(tput sgr 0)"
    echo -e "\t(b) $(tput setaf 10)Add/Edit individual cluster settings.$(tput sgr 0)"
    echo -e "\t(c) $(tput setaf 10)Remove individual cluster settings.$(tput sgr 0)"
    echo -e "\t(d) $(tput setaf 10)Add/Edit global cluster settings.$(tput sgr 0)"
    echo -e "\t(e) $(tput setaf 10)Remove global cluster settings.$(tput sgr 0)"
    echo -e "\t(f) $(tput setaf 10)Exit.$(tput sgr 0)"
    echo -n "Please enter your choice: "
    read choice
    case $choice in
        "a"|"A")
            # Display
            clear
            display_current_setting
        ;;
        "b"|"B")
            #Edit indivisual cluster settings
            clear
            ask_cluster_settings
            patch_cluster_settings
            read -p "$(tput setaf 10)Done. Press ENTER to continue.$(tput sgr 0)"
            clear
        ;;
        "c"|"C")
            #Remove indivisual cluster settings
            clear
            select_cluster_and_delete "none" "y"
            read -p "$(tput setaf 10)Done. Press ENTER to continue.$(tput sgr 0)"
            clear
        ;;
        "d"|"D")
            #Add/Edit global cluster settings
            clear
            ask_cost_analysis
            ask_watched_namespaces_settings
            patch_global_cluster_settings
            read -p "$(tput setaf 10)Done. Press ENTER to continue.$(tput sgr 0)"
            clear
        ;;
        "e"|"E")
            # Remove global cluster settings
            clear
            delete_global_cluster_settings
            read -p "$(tput setaf 10)Done. Press ENTER to continue.$(tput sgr 0)"
            clear
        ;;
        "f"|"F")
            # Leave
            clear
            exit
        ;;
        *)
            echo -e "$(tput setaf 1)Invalid option! please try again.$(tput sgr 0)"
        ;;

    esac
done