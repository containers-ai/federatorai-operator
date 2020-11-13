#!/bin/sh
##
## This script pull Federator.ai containter images from quay.io and push into private repository.
## By using the following example, you can install Federator.ai with private repository.
##    # export RELATED_IMAGE_URL_PREFIX="repo.prophetservice.com/federatorai"
##    # ./install.sh
##
set -e

##
show_usage()
{
    cat << __EOF__

    Usage: $0 [build_name] [private_repository_url]
    Example: $0 v4.2.614 repo.prophetstor.com/federatorai

__EOF__
    exit 1
}

##
## Main
##
build_name="$1"
PRIVATE_REPOSITORY_IMAGE_URL_PREFIX="$2"
[ "${PRIVATE_REPOSITORY_IMAGE_URL_PREFIX}" = "" -o "${build_name}" = "" ] && show_usage

## Global vairables
ORIGIN_URL_PREFIX="quay.io/prophetstor"

IMAGE_LIST="alameda-admission-ubi alameda-ai-dispatcher alameda-ai alameda-analyzer-ubi alameda-datahub-ubi alameda-evictioner-ubi alameda-executor-ubi alameda-grafana alameda-influxdb alameda-notifier-ubi alameda-operator-ubi alameda-rabbitmq alameda-recommender-ubi fedemeter-api-ubi fedemeter-influxdb federatorai-agent-app federatorai-agent-gpu federatorai-agent-preloader federatorai-agent-ubi federatorai-dashboard-backend federatorai-dashboard-frontend federatorai-data-adapter federatorai-operator-ubi federatorai-rest-ubi"
for image in ${IMAGE_LIST}; do
    echo "Preparing image ${PRIVATE_REPOSITORY_IMAGE_URL_PREFIX}/${image}:${build_name}"
    echo "     from image ${ORIGIN_URL_PREFIX}/${image}:${build_name}"
    docker pull ${ORIGIN_URL_PREFIX}/${image}:${build_name}
    docker tag ${ORIGIN_URL_PREFIX}/${image}:${build_name} ${PRIVATE_REPOSITORY_IMAGE_URL_PREFIX}/${image}:${build_name}
    docker push ${PRIVATE_REPOSITORY_IMAGE_URL_PREFIX}/${image}:${build_name}
    /bin/echo -e "\n\n"
done

exit 0
