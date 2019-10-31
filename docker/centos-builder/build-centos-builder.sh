#!/usr/bin/env bash

if [[ -n "${JENKINS_URL}" ]]; then
	export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:(${FUNCNAME[0]:-"?"}):'
else
	export PS4='\[\033[0;33m\]+ ${BASH_SOURCE##*/}:${LINENO}:(${FUNCNAME[0]:-"?"}): \[\033[0;37m\]'
fi

set -e

name="${0##*/}"
DOCKER_TOP=${DOCKER_TOP:-"$(cd "${BASH_SOURCE%/*}/.." && pwd)"}

project_name="centos-builder"
project_from="centos"
project_description="Builds a docker image that contains tools for ThunderX CI."

PROJECT_TOP="${DOCKER_TOP}/${project_name}"
VERSION=${VERSION:-"1"}
DOCKER_NAME=${DOCKER_NAME:-"tci-${project_name}"}

docker_build_setup() {
	true
}

host_install_extra() {
	true
}

source ${DOCKER_TOP}/build-common.sh
