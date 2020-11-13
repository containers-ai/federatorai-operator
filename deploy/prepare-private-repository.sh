#!/usr/bin/env bash

show_usage()
{
    cat << __EOF__

    Usage:
        Scenario A - Pull Federator.ai containter images and push to private repo
          Requirements:
            --pull
            --tag [Build Tag]
              (e.g., --tag v4.2.799)
            --push
            --repo-url [Private Repository URL]
              (e.g., --repo-url repo.prophetstor.com/federatorai)

        Scenario B - Pull Federator.ai containter images and save files locally
          Requirements:
            --pull
            --tag [Build Tag]
              (e.g., --tag v4.2.799)

        Scenario C - Push to private repository
          Requirements:
            --push
            --repo-url [Private Repository URL]
              (e.g., --repo-url repo.prophetstor.com/federatorai)

__EOF__
    exit 1
}

# original approach
all_operation()
{
    for image in ${image_list}; do
        echo -e "Preparing image ${repo_url}/${image}:${build_tag}"
        echo -e "     from image ${original_url_prefix}/${image}:${build_tag}"
        docker pull ${original_url_prefix}/${image}:${build_tag} >> $script_output
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to pull image.$(tput sgr 0)"
            exit 3
        fi
        docker tag ${original_url_prefix}/${image}:${build_tag} ${repo_url}/${image}:${build_tag}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to tag image.$(tput sgr 0)"
            exit 3
        fi
        docker push ${repo_url}/${image}:${build_tag} >> $script_output
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to push image.$(tput sgr 0)"
            exit 3
        fi
        echo -e "Done\n"
    done
}

pull_operation()
{
    for image in ${image_list}; do
        echo -e "$(tput setaf 10)Pulling image ${original_url_prefix}/${image}:${build_tag} ...$(tput sgr 0)"
        docker pull ${original_url_prefix}/${image}:${build_tag} >> $script_output
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to pull image.$(tput sgr 0)"
            exit 3
        fi
        echo -e "$(tput setaf 10)Saving $image image to file ...$(tput sgr 0)"
        docker save ${original_url_prefix}/$image:$build_tag | gzip > $image.$build_tag.tgz
        if [ "${PIPESTATUS[0]}" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to save image to local.$(tput sgr 0)"
            exit 3
        fi
        echo -e "$(tput setaf 10)$image.$build_tag.tgz saved.\n$(tput sgr 0)"
    done
}

push_operation()
{
    for image in ${image_list}; do
        file_name="`ls *.tgz|grep -E "$image\.[v][[:digit:]]+\.[[:digit:]]+\.[[:alnum:]]+\."`"
        if [ "$file_name" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to find \"$image.<tag>.tgz\" file name in $PWD.$(tput sgr 0)"
            exit 3
        fi
        build_ver="`echo $file_name|awk -F'.' '{print $2"."$3"."$4}'`"
        if [ "$build_ver" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to parse build tag version.$(tput sgr 0)"
            exit 3
        fi
        echo -e "$(tput setaf 10)Loading image file $file_name ...$(tput sgr 0)"
        docker load < $file_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to load image file $file_name.$(tput sgr 0)"
            exit 3
        fi
        echo -e "$(tput setaf 10)Tagging $image:$build_ver image ...$(tput sgr 0)"
        docker tag ${original_url_prefix}/${image}:${build_ver} ${repo_url}/${image}:${build_ver}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to tag $image:$build_ver image.$(tput sgr 0)"
            exit 3
        fi
        echo -e "$(tput setaf 10)Pushing $image:$build_ver image to $repo_url ...$(tput sgr 0)"
        docker push ${repo_url}/${image}:${build_ver} >> $script_output
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to push $image:$build_ver image to $repo_url $(tput sgr 0)"
            exit 3
        fi
        echo -e "Done\n"
    done
}

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                pull)
                    do_pull="y"
                    ;;
                push)
                    do_push="y"
                    ;;
                tag)
                    tag_specified="y"
                    build_tag="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$build_tag" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                    fi
                    ;;
                repo-url)
                    url_specified="y"
                    repo_url="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$repo_url" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                    fi
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

## Global variables
image_list="alameda-ai-dispatcher alameda-ai alameda-analyzer-ubi alameda-datahub-ubi alameda-executor-ubi alameda-influxdb alameda-notifier-ubi alameda-operator-ubi alameda-rabbitmq alameda-recommender-ubi fedemeter-api-ubi fedemeter-influxdb federatorai-agent-preloader federatorai-agent-ubi federatorai-dashboard-backend federatorai-dashboard-frontend federatorai-data-adapter federatorai-operator-ubi federatorai-rest-ubi"
script_output="execution_output_`date +%s`.log"
if [ "$source_repo_url" = "" ]; then
    original_url_prefix="quay.io/prophetstor"
else
    original_url_prefix="$source_repo_url"
fi


# Check docker command
docker version >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo -e "\n$(tput setaf 1)Error! docker daemon is unavailable.$(tput sgr 0)"
    exit 8
fi

check_build_tag()
{
    if [ "$tag_specified" != "y" ];then
        echo -e "\n$(tput setaf 1)Error! need to specify --tag parameter for pull operation.$(tput sgr 0)"
        show_usage
    fi

    if [[ ! $build_tag =~ ^[v][[:digit:]]+\.[[:digit:]]+\.[[:alnum:]]+$ ]]; then
        echo -e "\n$(tput setaf 1)Error! The tag should follow the correct format (e.g., v4.2.755) $(tput sgr 0)"
        show_usage
    fi
}

check_repo_url()
{
    if [ "$url_specified" != "y" ];then
        echo -e "\n$(tput setaf 1)Error! need to specify --repo-url parameter for push operation.$(tput sgr 0)"
        show_usage
    fi
}

if [ "$do_pull" = "y" ] && [ "$do_push" = "y" ]; then
    check_build_tag
    check_repo_url
    all_operation
    # Leave (Original path)
    exit 0
fi

if [ "$do_pull" = "y" ]; then
    check_build_tag
    pull_operation
fi

if [ "$do_push" = "y" ]; then
    check_repo_url
    push_operation
fi

exit 0
