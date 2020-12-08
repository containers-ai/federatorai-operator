#!/usr/bin/env bash

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
    while [ "$pass" != "y" ]
    do
        [ "${tag_number}" = "" ] && read -r -p "$(tput setaf 2)Please input Federator.ai version tag (e.g., v4.2.755): $(tput sgr 0) " tag_number </dev/tty
        if [[ $tag_number =~ ^[v][[:digit:]]+\.[[:digit:]]+\.[0-9a-z\-]+$ ]]; then
            pass="y"
        fi
        if [ "$pass" != "y" ]; then
            echo -e "\n$(tput setaf 1)Error! The version tag should follow the correct format (e.g., v4.2.755).$(tput sgr 0)"
            [ "${ALAMEDASERVICE_FILE_PATH}" != "" ] && exit 1
            tag_number=""
        fi
    done

    full_tag=$(echo "$tag_number"|cut -d '-' -f1)           # Delete - and after
    tag_first_digit=${full_tag%%.*}                         # Delete first dot and what follows.
    tag_last_digit=${full_tag##*.}                          # Delete up to last dot.
    tag_middle_digit=${full_tag##$tag_first_digit.}         # Delete first number and dot.
    tag_middle_digit=${tag_middle_digit%%.$tag_last_digit}  # Delete dot and last number.
    tag_first_digit=$(echo $tag_first_digit|cut -d 'v' -f2) # Delete v

    if [ "$tag_first_digit" -ge "4" ] && [ "$tag_middle_digit" -ge "4" ]; then
        # >= 4.4
        echo -e "\n$(tput setaf 1)Abort! Please use new federatorai-launcher.sh for version tag v4.4.x or later.$(tput sgr 0)"
        echo -e "$(tput setaf 3)curl https://raw.githubusercontent.com/containers-ai/prophetstor/master/deploy/federatorai-launcher.sh | bash $(tput sgr 0)"
        exit 3
    fi

    file_folder="/tmp/federatorai-scripts/${tag_number}"
    rm -rf $file_folder
    mkdir -p $file_folder
    cd $file_folder
}

get_repo_url()
{
    while [ "$repo_url" = "" ] # prevent 'enter' is pressed without input
    do
        read -r -p "$(tput setaf 2)Please input private repository URL (e.g., repo.prophetservice.com/prophetstor): $(tput sgr 0) " repo_url </dev/tty
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
    scriptarray=("install.sh" "email-notifier-setup.sh" "node-label-assignor.sh" "planning-util.sh" "preloader-util.sh" "prepare-private-repository.sh" "uninstall.sh")
    if [ "$tag_first_digit" -ge "4" ] && [ "$tag_middle_digit" -ge "3" ]; then
        # >= 4.3
        scriptarray=("${scriptarray[@]}" "federatorai-setup-for-datadog.sh")
    fi

    if [ "$tag_first_digit" -ge "4" ] && [ "$tag_middle_digit" -ge "4" ]; then
        # >= 4.4
        scriptarray=("${scriptarray[@]}" "cluster-property-setup.sh")
    elif [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -eq "3" ]; then
        re='^[0-9]+$'
        if [[ $tag_last_digit =~ $re ]] ; then
            # tag_last_digit is a number
            if [ "$tag_last_digit" -gt "1006" ]; then
                # (= 4.3 and > 1006)
                scriptarray=("${scriptarray[@]}" "cluster-property-setup.sh")
            fi
        else
            # tag_last_digit not a number
            if [ "$tag_last_digit" = "datadog" ]; then
                # (= 4.3 and = datadog)
                scriptarray=("${scriptarray[@]}" "cluster-property-setup.sh")
            fi
        fi
    fi

    mkdir -p $scripts_folder
    cd $scripts_folder
    echo -e "\n$(tput setaf 6)Downloading scripts ...$(tput sgr 0)"
    for file_name in "${scriptarray[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/deploy/${file_name} -O; then
            echo -e "\n$(tput setaf 1)Abort, download file $file_name failed!!!$(tput sgr 0)"
            echo "Please check tag name and network"
            exit 1
        fi
    done
    # Download launcher itself.
    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/master/deploy/federatorai-launcher.sh -O; then
        echo -e "\n$(tput setaf 1)Abort, download federatorai-launcher.sh failed!!!$(tput sgr 0)"
        echo "Please check network"
        exit 1
    fi

    if [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -ge "3" ]; then
        # Download preloader ab runnder folder
        ab_folder_name="preloader_ab_runner"
        mkdir -p $ab_folder_name

        ab_file_lists=`curl --silent https://api.github.com/repos/containers-ai/federatorai-operator/contents/deploy/${ab_folder_name}?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`
        if [ "$ab_file_lists" = "" ]; then
            echo -e "\n$(tput setaf 3)Warning, download Federator.ai preloader ab files list failed!!!$(tput sgr 0)"
        fi

        for file in `echo $ab_file_lists`
        do
            if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/deploy/${ab_folder_name}/${file} -o $ab_folder_name/${file}; then
                echo -e "\n$(tput setaf 3)Warning, download Federator.ai preloader ab file \"${file}\" failed!!!$(tput sgr 0)"
            fi
        done
    fi

    cd - > /dev/null

    alamedaservice_example="alamedaservice_sample.yaml"
    yamlarray=( "alamedadetection.yaml" "alamedanotificationchannel.yaml" "alamedanotificationtopic.yaml" )
    if [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -eq "2" ]; then
        yamlarray=("${yamlarray[@]}" "alamedascaler.yaml")
    fi

    mkdir -p $yamls_folder
    cd $yamls_folder
    echo -e "\n$(tput setaf 6)Downloading Federator.ai CR yamls ...$(tput sgr 0)"
    if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/example/${alamedaservice_example} -O; then
        echo -e "\n$(tput setaf 1)Abort, download alamedaservice sample yaml file failed!!!$(tput sgr 0)"
        echo "Please check tag name and network"
        exit 2
    fi

    for file_name in "${yamlarray[@]}"
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/alameda/${tag_number}/example/samples/nginx/${file_name} -O; then
            echo -e "\n$(tput setaf 1)Abort, download $file_name file failed!!!$(tput sgr 0)"
            echo "Please check tag name and network"
            exit 3
        fi
    done

    if [ "$tag_first_digit" -ge "4" ] && [ "$tag_middle_digit" -ge "3" ]; then
        # Three kinds of alamedascaler
        alamedascaler_filename="alamedascaler.yaml"
        src_pool=( "kafka" "nginx" "redis" )

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
    fi
    cd - > /dev/null

    mkdir -p $operator_folder
    cd $operator_folder
    echo -e "\n$(tput setaf 6)Downloading Federator.ai operator yamls ...$(tput sgr 0)"
    operator_lists=`curl --silent https://api.github.com/repos/containers-ai/federatorai-operator/contents/deploy/upstream?ref=${tag_number} 2>&1|grep "\"name\":"|cut -d ':' -f2|cut -d '"' -f2`
    if [ "$operator_lists" = "" ]; then
        echo -e "\n$(tput setaf 1)Abort, download Federator.ai operator yaml list failed!!!$(tput sgr 0)"
        echo "Please check tag name and network"
        exit 1
    fi

    for file in `echo $operator_lists`
    do
        if ! curl -sL --fail https://raw.githubusercontent.com/containers-ai/federatorai-operator/${tag_number}/deploy/upstream/${file} -O; then
            echo -e "\n$(tput setaf 1)Abort, download file failed!!!$(tput sgr 0)"
            echo "Please check tag name and network"
            exit 1
        fi
    done
    cd - > /dev/null

    echo "Done"
}

go_interactive()
{
    get_build_tag
    download_files

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
            old_build="n"
            re='^[0-9]+$'
            if [[ $tag_last_digit =~ $re ]] ; then
                # tag_last_digit is a number
                if [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -eq "2" ] && [ "$tag_last_digit" -lt "759" ]; then
                    # < 4.2.759
                    old_build="y"
                fi
            fi

            if [ "$old_build" = "n" ]; then
                if [ "$source_repo_url" != "" ]; then
                    bash $scripts_folder/prepare-private-repository.sh --pull --tag $tag_number --push --repo-url $repo_url --source-repo-url $source_repo_url
                else
                    bash $scripts_folder/prepare-private-repository.sh --pull --tag $tag_number --push --repo-url $repo_url
                fi
            else
                bash $scripts_folder/prepare-private-repository.sh $tag_number $repo_url
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
        bash $scripts_folder/install.sh -t $tag_number
    fi
}

prepare_media()
{
    get_build_tag
    download_files

    mkdir -p $image_folder
    cd $image_folder

    re='^[0-9]+$'
    if [[ $tag_last_digit =~ $re ]] ; then
        # tag_last_digit is a number
        if [ "$tag_first_digit" -eq "4" ] && [ "$tag_middle_digit" -eq "2" ] && [ "$tag_last_digit" -lt "759" ]; then
            # < 4.2.759
            echo -e "\n$(tput setaf 1)Abort, --prepare_media only support build version greater than v4.2.758$(tput sgr 0)"
            exit 3
        fi
    fi

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
    tar --warning=no-file-changed --exclude="$target_filename" -zcf $target_filename ../${tag_number}/
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

        bash ../$scripts_folder/prepare-private-repository.sh --push --repo-url $repo_url
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



