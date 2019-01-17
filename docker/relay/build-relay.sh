#!/usr/bin/env bash

set -e

name="$(basename $0)"
DOCKER_TOP=${DOCKER_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"}

project_name="relay"
#project_from="alpine"
project_from="debian" # for debugging
project_description="Builds a docker image that contains the TCI relay service."

PROJECT_TOP="${DOCKER_TOP}/${project_name}"
VERSION=${VERSION:="1"}
DOCKER_NAME=${DOCKER_NAME:="tci-relay"}

tmp_image="${PROJECT_TOP}/tci-relay"

on_exit() {
	rm -rf ${tmp_dir}
	rm -f ${tmp_image}
}

docker_build_setup() {

	if [[ ! -f ${tmp_image} ]]; then
		echo "${name}: Building tci-relay image." >&2

		local builder_tag="$("${DOCKER_TOP}/builder/build-builder.sh" --tag)"

		tmp_dir="$(mktemp --directory --tmpdir tci-XXXX.bld)"

		trap on_exit EXIT

		cp -a ${PROJECT_TOP}/src/* ${tmp_dir}/

		cat << EOF > ${tmp_dir}/build.sh
./bootstrap
./configure --enable-debug
make
EOF

		docker run --rm \
			-v ${tmp_dir}:/work -w /work \
			-u $(id --user --real):$(id --group --real) \
			${builder_tag} bash -ex ./build.sh

		cp -vf ${tmp_dir}/tci-relay ${tmp_image}
	fi
}

install_extra() {
	true
}

source ${DOCKER_TOP}/build-common.sh
