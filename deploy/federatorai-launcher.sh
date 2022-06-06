#!/usr/bin/env bash
#
# Need bash to run this script
if [ "${BASH_VERSION}" = "" ]; then
    /bin/echo -e "\n$(tput setaf 1)Error! You need to use bash to run this script.$(tput sgr 0)\n"
    exit 1
fi

show_usage()
{
    cat << __EOF__

    Usage:
        a. Interactive Mode
           bash $0
        b. Prepare offline media
           bash $0 --prepare-media
        c. Install offline media
           bash $0 --offline-install
__EOF__
    exit 1
}

leave_prog()
{
    echo -e "\n$(tput setaf 5)Downloaded files are located under $file_folder $(tput sgr 0)"
    cd $current_location > /dev/null
}
verify_tag()
{
    if [[ $tag_number =~ ^[v][[:digit:]]+\.[[:digit:]]+\.[0-9a-z\-]+$ ]]; then
        echo "y"
    else
        echo "n"
    fi
}

get_build_tag()
{
    # read tag_number from ALAMEDASERVICE_FILE_PATH
    if [ "${ALAMEDASERVICE_FILE_PATH}" != "" ]; then
        tag_number=`grep "^[[:space:]]*version:[[:space:]]" $ALAMEDASERVICE_FILE_PATH|grep -v 'version: ""'|awk -F'[^ \t]' '{print length($1), $0}'|sort -k1 -n|head -1|awk '{print $3}'`
        if [ "$tag_number" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't parse the version info from alamedaservice file ($ALAMEDASERVICE_FILE_PATH).$(tput sgr 0)"
            exit
        fi
    fi
    default_tag="latest"
    datadog_tag="datadog"
    if [ "$ECR_URL" != "" ]; then
        # Parse tag number from url
        tag_number="$(echo "$ECR_URL" |rev|cut -d':' -f1|rev)"
        url_minus_tag="$(echo "$ECR_URL" |rev|cut -d':' -f2-|rev)"
        if [ "$VERSION_TAG" != "" ]; then
            tag_number="$VERSION_TAG"
            pass="y"
            SKIP_TAG_NUMBER_CHECK=1
        else
            if [ "$tag_number" != "$default_tag" ]; then
                if [ "$(verify_tag)" = "n" ]; then
                    echo -e "\n$(tput setaf 1)Error! Failed to parse valid version info from env variable ECR_URL ($ECR_URL).$(tput sgr 0)"
                    exit 3
                fi
            fi
        fi
    fi
    while [ "$pass" != "y" ]
    do
        [ "${tag_number}" = "" ] && read -r -p "$(tput setaf 2)Please enter Federator.ai version tag [default: $default_tag]: $(tput sgr 0) " tag_number </dev/tty
        tag_number=${tag_number:-$default_tag}
        if [ "$tag_number" = "$default_tag" ] || [ "$tag_number" = "$datadog_tag" ]; then
            pass="y"
        else
            if [ "$(verify_tag)" = "y" ]; then
                pass="y"
            fi
            # Enable SKIP_TAG_NUMBER_CHECK=1 if tag_number prefix is 'dev-' for development build
            if [[ $tag_number =~ ^dev- ]]; then SKIP_TAG_NUMBER_CHECK=1; fi
            # Purposely ignore error of unofficial tag_number for development build
            if [ "${SKIP_TAG_NUMBER_CHECK}" = "1" ]; then pass="y"; fi
        fi

        if [ "$pass" != "y" ]; then
            echo -e "\n$(tput setaf 1)Error! The version tag should follow the correct format (e.g., v4.2.755).$(tput sgr 0)"
            [ "${ALAMEDASERVICE_FILE_PATH}" != "" ] && exit 1
            tag_number=""
        fi
    done

    if [ "$tag_number" = "$default_tag" ]; then
        # Get latest version from github prophetstor project
        latest_tag=$(curl -s https://raw.githubusercontent.com/containers-ai/prophetstor/master/deploy/manifest/version.txt|cut -d '=' -f2)
        if [ "$latest_tag" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get latest build version.$(tput sgr 0)"
            exit 3
        else
            tag_number=$latest_tag
        fi
    elif [ "$tag_number" = "$datadog_tag" ]; then
        # Get latest version from github datadog project
        latest_tag=$(curl -s https://raw.githubusercontent.com/containers-ai/datadog/master/deploy/manifest/version.txt|cut -d '=' -f2)
        if [ "$latest_tag" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get latest build version.$(tput sgr 0)"
            exit 3
        else
            tag_number=$latest_tag
        fi
        # export tag for datadog launcher
        export tag_number="$tag_number"
        exec bash -c "curl -sS https://raw.githubusercontent.com/containers-ai/datadog/master/deploy/federatorai-launcher.sh|bash"
    fi

    full_tag=$(echo "$tag_number"|cut -d '-' -f1)           # Delete - and after
    tag_first_digit=${full_tag%%.*}                         # Delete first dot and what follows.
    tag_last_digit=${full_tag##*.}                          # Delete up to last dot.
    tag_middle_digit=${full_tag##$tag_first_digit.}         # Delete first number and dot.
    tag_middle_digit=${tag_middle_digit%%.$tag_last_digit}  # Delete dot and last number.
    tag_first_digit=$(echo $tag_first_digit|cut -d 'v' -f2) # Delete v
    # Purposely ignore error of unofficial tag_number for development build, start from v4.4
    if [ "${SKIP_TAG_NUMBER_CHECK}" = "1" ]; then tag_first_digit="5"; tag_middle_digit="0"; fi

    if [ "$tag_first_digit" -le "4" ] && [ "$tag_middle_digit" -le "3" ]; then
        # <= 4.3
        echo -e "\n$(tput setaf 1)Abort! Please use previous version of federatorai-launcher.sh$(tput sgr 0)"
        echo -e "\n$(tput setaf 3)curl https://raw.githubusercontent.com/containers-ai/federatorai-operator/master/deploy/federatorai-launcher.sh |bash $(tput sgr 0)"
        exit 3
    fi
    echo -e "$(tput setaf 3)Federator.ai version = $tag_number$(tput sgr 0)"
    if ([ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -ge "5" ]) || [ "$tag_first_digit" -ge "5" ]; then
        # >= 4.5
        default="/opt"
        read -r -p "$(tput setaf 2)Please enter the path of Federator.ai directory [default: $default]: $(tput sgr 0) " save_path </dev/tty
        save_path=${save_path:-$default}
        save_path=$(echo "$save_path" | tr '[:upper:]' '[:lower:]')
        file_folder="$save_path/federatorai/repo/${tag_number}"
    else
        file_folder="/tmp/federatorai-scripts/${tag_number}"
    fi

    if [ -d "$file_folder" ]; then
        rm -rf $file_folder
    fi
    mkdir -p $file_folder
    if [ ! -d "$file_folder" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to create folder ($file_folder) to save Federator.ai files.$(tput sgr 0)"
        exit 3
    fi
    save_path="$(dirname "$(dirname "$(realpath $file_folder)")")"
    cd $file_folder
}

check_previous_build_tag_and_do_download_for_upgrade(){
    previous_fed_ns="`kubectl get alamedaservice --all-namespaces 2>/dev/null|tail -1|awk '{print $1}'`"
    if [ "$previous_fed_ns" = "" ]; then
        # Skip due to fresh install
        return 0
    fi
    previous_fed_tag="`kubectl get alamedaservices -n $previous_fed_ns -o custom-columns=VERSION:.spec.version 2>/dev/null|grep -v VERSION|head -1`"
    if [[ $previous_fed_tag =~ ^dev- ]]; then
        # Skip due to dev build found
        return 0
    fi

    previous_full_tag=$(echo "$previous_fed_tag"|cut -d '-' -f1)           # Delete - and after
    previous_tag_first_digit=${previous_full_tag%%.*}                         # Delete first dot and what follows.
    previous_tag_last_digit=${previous_full_tag##*.}                          # Delete up to last dot.
    previous_tag_middle_digit=${previous_full_tag##$previous_tag_first_digit.}         # Delete first number and dot.
    previous_tag_middle_digit=${previous_tag_middle_digit%%.$previous_tag_last_digit}  # Delete dot and last number.
    previous_tag_first_digit=$(echo $previous_tag_first_digit|cut -d 'v' -f2) # Delete v

    if [ "0$previous_tag_first_digit" -eq "4" ] && [ "0$tag_first_digit" -ge "5" ]; then
        # Prevent 4.x upgrade to 5.x or later
        echo -e "\n$(tput setaf 1)Error! Upgrade from Federator.ai 4.x version to 5.x version or later is not supported.$(tput sgr 0)"
        exit 3
    fi

    if [ "0$previous_tag_first_digit" -ge "5" ]; then
        # Download backup script of previous version.
        backup_script_path="$(dirname "$(realpath $file_folder)")/$previous_fed_tag/scripts"
        mkdir -p $backup_script_path
        cd $backup_script_path
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/${previous_fed_tag}/deploy/backup-restore.sh -O; then
            echo -e "\n$(tput setaf 1)Abort, download backup-restore.sh file failed!!!$(tput sgr 0)"
            exit 1
        fi
        cd - > /dev/null
    fi
}

get_repo_url()
{
    while [ "$repo_url" = "" ] # prevent 'enter' is pressed without input
    do
        read -r -p "$(tput setaf 2)Please enter the URL of private repository (e.g., repo.prophetservice.com/prophetstor): $(tput sgr 0) " repo_url </dev/tty
        repo_url=$(echo "$repo_url" | tr '[:upper:]' '[:lower:]')
    done

    # For install.sh
    export RELATED_IMAGE_URL_PREFIX=$repo_url
}

ask_push_image()
{
    while [ "$push_image" != "y" ] && [ "$push_image" != "n" ]
    do
        default="n"
        read -r -p "$(tput setaf 2)Do you want to upload images to the private repository \"$repo_url\"? [default: $default]: $(tput sgr 0) " push_image </dev/tty
        push_image=${push_image:-$default}
        push_image=$(echo "$push_image" | tr '[:upper:]' '[:lower:]')
    done
}

which curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Abort, \"curl\" command is needed for this tool.$(tput sgr 0)"
    exit
fi

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                prepare-media)
                    do_prepare_media="y"
                    ;;
                offline-install)
                    do_offline_install="y"
                    ;;
                source-repo-url)
                    source_url_specified="y"
                    source_repo_url="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$source_repo_url" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                    fi
                    ;;
                help)
                    show_usage
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

download_files()
{
    echo -e "\n$(tput setaf 6)Downloading ${tag_number} tgz file ...$(tput sgr 0)"
    tgz_name="${tag_number}.tar.gz"
    if ! curl -sL --fail https://github.com/containers-ai/prophetstor/archive/${tgz_name} -O; then
        echo -e "\n$(tput setaf 1)Error, download file $tgz_name failed!!!$(tput sgr 0)"
        echo "Please check tag name and network"
        exit 1
    fi

    tar -zxf $tgz_name
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Error, untar $tgz_name file failed!!!$(tput sgr 0)"
        exit 3
    fi

    tgz_folder_name=$(tar -tzf $tgz_name | head -1 | cut -f1 -d"/")
    if [ "$tgz_folder_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error, failed to get extracted directory name.$(tput sgr 0)"
        exit 3
    fi

    scriptarray=("install.sh" "email-notifier-setup.sh" "node-label-assignor.sh" "preloader-util.sh" "prepare-private-repository.sh" "uninstall.sh" "federatorai-setup-for-datadog.sh")

    if [ "$tag_first_digit" -ge "5" ]; then
        # >= 5.0, remove federatorai-setup-for-datadog.sh script
        delete="federatorai-setup-for-datadog.sh"
        for i in "${!scriptarray[@]}"; do
            if [ "${scriptarray[i]}" = "$delete" ]; then
                unset 'scriptarray[i]'
            fi
        done
    fi

    if ([ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -ge "4" ]) || [ "$tag_first_digit" -ge "5" ]; then
        # >= 4.4
        scriptarray=("${scriptarray[@]}" "cluster-property-setup.sh" "backup-restore.sh")
    fi

    if [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -lt "5" ]; then
        # < 4.5
        scriptarray=("${scriptarray[@]}" "planning-util.sh")
    fi

    mkdir -p $scripts_folder

    # Download launcher itself.
    cd $scripts_folder
    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/prophetstor/master/deploy/federatorai-launcher.sh -O; then
        echo -e "\n$(tput setaf 1)Abort, download federatorai-launcher.sh failed!!!$(tput sgr 0)"
        echo "Please check network"
        exit 1
    fi
    cd - > /dev/null

    # Copy all scripts.
    for file_name in "${scriptarray[@]}"
    do
        cp $tgz_folder_name/deploy/$file_name $scripts_folder
    done

    # Copy Ansible folders.
    ansible_folder_name="ansible_for_federatorai"
    cp -r $tgz_folder_name/deploy/$ansible_folder_name $scripts_folder

    # Copy preloader ab runnder folder
    ab_folder_name="preloader_ab_runner"
    cp -r $tgz_folder_name/deploy/$ab_folder_name $scripts_folder

    if ([ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -ge "5" ]) || [ "$tag_first_digit" -ge "5" ]; then
        # >= 4.5
        # Copy planning util folder
        planning_folder_name="planning_util"
        cp -r $tgz_folder_name/deploy/$planning_folder_name $scripts_folder
    fi

    # Copy yamls
    mkdir -p $yamls_folder
    for file_name in "*.yaml"
    do
        cp $tgz_folder_name/deploy/example/$file_name $yamls_folder
    done

    # Three kinds of alamedascaler
    alamedascaler_filename="alamedascaler.yaml"
    src_pool=( "kafka" "nginx" "redis" )

    for pool in "${src_pool[@]}"
    do
        if [ ! -f "$tgz_folder_name/deploy/example/$pool/$alamedascaler_filename" ]; then
            # skip if folder not exist
            continue
        fi
        cp $tgz_folder_name/deploy/example/$pool/$alamedascaler_filename $yamls_folder
        if [ "$pool" = "kafka" ]; then
            mv $yamls_folder/$alamedascaler_filename $yamls_folder/alamedascaler_kafka.yaml
        elif [ "$pool" = "nginx" ]; then
            mv $yamls_folder/$alamedascaler_filename $yamls_folder/alamedascaler_nginx.yaml
        else
            mv $yamls_folder/$alamedascaler_filename $yamls_folder/alamedascaler_generic.yaml
        fi
    done

    # Copy operator yamls
    mkdir -p $operator_folder
    if ([ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -ge "7" ]) || [ "$tag_first_digit" -ge "5" ]; then
        # >= 4.7
        # copy upstream-1.15 and upstream
        mkdir -p $operator_folder/upstream
        cp $tgz_folder_name/deploy/upstream/* $operator_folder/upstream
        if [ -d "$tgz_folder_name/deploy/upstream-1.15" ]; then
            mkdir -p $operator_folder/upstream-1.15
            cp $tgz_folder_name/deploy/upstream-1.15/* $operator_folder/upstream-1.15
        fi
    else
        cp $tgz_folder_name/deploy/upstream/* $operator_folder
    fi

    # Clean up
    rm -rf $tgz_folder_name
    rm -f $tgz_name
    echo "Done"
}

go_interactive()
{
    # ECR_URL, EKS_CLUSTER, AWS_REGION all are empty or all have values
    if [ "$ECR_URL" != "" ] && [ "$EKS_CLUSTER" != "" ] && [ "$AWS_REGION" != "" ]; then
        aws_mode="y"
    fi

    get_build_tag
    download_files
    check_previous_build_tag_and_do_download_for_upgrade

    while [ "$enable_private_repo" != "y" ] && [ "$enable_private_repo" != "n" ]
    do
        default="n"
        read -r -p "$(tput setaf 2)Do you want to use a private repository URL? [default: $default]: $(tput sgr 0)" enable_private_repo </dev/tty
        enable_private_repo=${enable_private_repo:-$default}
        enable_private_repo=$(echo "$enable_private_repo" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$enable_private_repo" = "y" ]; then
        get_repo_url
    fi

    if [ "$enable_private_repo" = "y" ]; then
        ask_push_image
        if [ "$push_image" = "y" ]; then
            if [ "$source_repo_url" != "" ]; then
                bash $scripts_folder/prepare-private-repository.sh --pull --tag $tag_number --push --repo-url $repo_url --source-repo-url $source_repo_url
            else
                bash $scripts_folder/prepare-private-repository.sh --pull --tag $tag_number --push --repo-url $repo_url
            fi

            if [ "$?" != "0" ];then
                echo -e "\n$(tput setaf 1)Abort, prepare-private-repository.sh ran with errors.$(tput sgr 0)"
                exit 3
            fi
        fi
    fi

    while [ "$run_installation" != "y" ] && [ "$run_installation" != "n" ]
    do
        default="y"
        read -r -p "$(tput setaf 2)Do you want to launch the Federator.ai installation script? [default: $default]: $(tput sgr 0)" run_installation </dev/tty
        run_installation=${run_installation:-$default}
        run_installation=$(echo "$run_installation" | tr '[:upper:]' '[:lower:]')
    done

    if [ "$run_installation" = "y" ]; then
        echo -e "\n$(tput setaf 6)Executing install.sh ...$(tput sgr 0)"
        # Pass files path to install.sh
        if [ "$save_path" != "" ]; then
            export FEDERATORAI_FILE_PATH=$save_path
        fi

        if [ "$aws_mode" = "y" ]; then
            bash $scripts_folder/install.sh -t $tag_number --image-path $ECR_URL --cluster $EKS_CLUSTER --region $AWS_REGION
        else
            if [ "$ECR_URL" != "" ]; then
                export ECR_URL="${url_minus_tag}:${tag_number}"
            fi
            bash $scripts_folder/install.sh -t $tag_number
        fi
    fi
}

prepare_media()
{
    get_build_tag
    download_files

    mkdir -p $image_folder
    cd $image_folder

    if [ "$source_repo_url" != "" ]; then
        bash ../$scripts_folder/prepare-private-repository.sh --pull --tag $tag_number --source-repo-url $source_repo_url
    else
        bash ../$scripts_folder/prepare-private-repository.sh --pull --tag $tag_number
    fi

    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Abort, prepare-private-repository.sh ran with errors.$(tput sgr 0)"
        exit 3
    fi
    cd - > /dev/null
    echo "build_version=$tag_number" > build_version
    echo -e "\n$(tput setaf 6)Creating offline install package ...$(tput sgr 0)"
    target_filename="${target_name_prefix}.${tag_number}.tgz"
    if [ "$machine_type" = "Linux" ]; then
        tar --warning=no-file-changed --exclude="$target_filename" -zcf $target_filename ../${tag_number}/
    else
        # Mac
        cd ../
        tar --exclude="$target_filename" -zcf $target_filename ${tag_number}/
        mv $target_filename ${tag_number}
        cd -
    fi
    echo -e "\n$(tput setaf 11)Offline install package $target_filename saved in $PWD $(tput sgr 0)"
}

offline_install()
{
    # federatorai-launcher.sh should be ran inside scripts folder
    # images folder should be located under ../
    tag_number="`cat ../build_version |cut -d '=' -f2`"
    if [ "$tag_number" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get build version$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute federatorai-launcher.sh under scripts folder.$(tput sgr 0)"
        exit 3
    fi
    get_repo_url
    ask_push_image
    if [ "$push_image" = "y" ]; then
        if [ ! -f "../$scripts_folder/prepare-private-repository.sh" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to locate prepare-private-repository.sh$(tput sgr 0)"
            echo "Please make sure you extract the offline install package and execute federatorai-launcher.sh under scripts folder.$(tput sgr 0)"
            exit 3
        fi
        if [ ! -d "../$image_folder" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to locate image folder.$(tput sgr 0)"
            echo "Please make sure you extract the offline install package and execute federatorai-launcher.sh under scripts folder.$(tput sgr 0)"
            exit 3
        fi

        # Make sure images are saved under image folder
        cd ../$image_folder

        if [ "$source_repo_url" != "" ]; then
            bash ../$scripts_folder/prepare-private-repository.sh --push --repo-url $repo_url --source-repo-url $source_repo_url
        else
            bash ../$scripts_folder/prepare-private-repository.sh --push --repo-url $repo_url
        fi

        if [ "$?" != "0" ];then
            echo -e "\n$(tput setaf 1)Abort, prepare-private-repository.sh ran with errors.$(tput sgr 0)"
            exit 3
        fi
        cd - > /dev/null
    fi
    if [ ! -f "install.sh" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to locate install.sh$(tput sgr 0)"
        echo "Please make sure you extract the offline install package and execute federatorai-launcher.sh under scripts folder.$(tput sgr 0)"
        exit 3
    fi
    bash install.sh -t $tag_number -o
}

scripts_folder="scripts"
yamls_folder="yamls"
image_folder="images"
operator_folder="operator"
target_name_prefix="federatorai-media"
current_location=`pwd`

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)
        machine_type=Linux;;
    Darwin*)
        machine_type=Mac;;
    *)
        echo -e "\n$(tput setaf 1)Error! Unsupported machine type (${unameOut}).$(tput sgr 0)"
        exit
        ;;
esac

if [ "$do_prepare_media" != "y" ] && [ "$do_offline_install" != "y" ]; then
    # Interactive mode
    go_interactive
fi

if [ "$do_prepare_media" = "y" ]; then
    prepare_media
fi

if [ "$do_offline_install" = "y" ]; then
    offline_install
fi

leave_prog



