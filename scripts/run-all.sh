#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}
DOCKER_TOP=${DOCKER_TOP:="$( cd "${SCRIPTS_TOP}/../docker" && pwd )"}

source ${SCRIPTS_TOP}/common.sh

usage() {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace

	echo "${name} - Builds tci container image, Linux kernel, Debian file system image and runs QEMU." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -a --arch           - Target architecture. Default: ${target_arch}." >&2
	echo "  -b --no-tests       - Build only, no tests." >&2
	echo "  -h --help           - Show this help and exit." >&2
	echo "  -l --linux-repo     - Linux kernel git repository URL. Default: ${linux_repo}." >&2
	echo "  -n --container-name - Container name. Default: '${container_name}'." >&2
	echo "Environment:" >&2
	echo "  CI_ROOT         - Default: ${CI_ROOT}." >&2
	echo "  TEST_ROOT       - Default: ${TEST_ROOT}." >&2
	echo "  CACHE_ROOT      - Default: ${CACHE_ROOT}." >&2

	eval "${old_xtrace}"
}

short_opts="a:bhl:n:"
long_opts="arch:,no-tests,help,linux-repo:,container-name:"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

if [ $? != 0 ]; then
	echo "${name}: ERROR: Internal getopt" >&2
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-a | --arch)
		target_arch=$(get_arch "${2}")
		shift 2
		;;
	-b | --no-tests)
		no_tests=1
		shift
		;;
	-h | --help)
		usage=1
		shift
		;;
	-l | --linux-repo)
		linux-repo="${2}"
		shift 2
		;;
	-n | --container-name)
		container_name="${2}"
		shift 2
		;;
	--)
		shift
		break
		;;
	*)
		echo "${name}: ERROR: Internal opts: '${@}'" >&2
		exit 1
		;;
	esac
done

if [[ ! -f /.dockerenv ]]; then
	TEST_ROOT=${TEST_ROOT:="$(pwd)"}
	CI_ROOT=${CI_ROOT:="${TEST_ROOT}/../tci"}
	CACHE_ROOT=${CACHE_ROOT:="${TEST_ROOT}/tci-cache"}

	check_directory ${CI_ROOT} "" "usage"
	check_directory ${TEST_ROOT} "" "usage"
	check_directory ${CACHE_ROOT} "" "usage"
fi

if [[ -z "${target_arch}" ]]; then
	target_arch="arm64"
fi

if [[ -z "${linux_repo}" ]]; then
	linux_repo="git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
fi

repo_name="$(basename ${linux_repo})"
LINUX_SRC_DIR=${LINUX_SRC_DIR:="${repo_name%.*}"}

if [[ -z "${container_name}" ]]; then
	container_name="tci"
fi

if [[ -n "${usage}" ]]; then
	usage
	exit 0
fi

set -x

if [ ! -f /.dockerenv ]; then
	${DOCKER_TOP}/builder/build-builder.sh

	echo "${name}: Entering tci container..." >&2

	${SCRIPTS_TOP}/run-builder.sh \
		--verbose \
		--container-name=${container_name} \
		--docker-args="\
			-v ${CI_ROOT}:/tci:ro \
			-v ${TEST_ROOT}:/tci--test:rw,z \
			-v ${CACHE_ROOT}:/tci--cache:rw,z \
			-w /tci--test" \
		-- /tci/scripts/run-all.sh

	exit
fi

sudo true

# kernel.
if [[ ! -d "${LINUX_SRC_DIR}" ]]; then
	git clone ${linux_repo} "${LINUX_SRC_DIR}"
fi

if [[ 1 -eq 2 ]]; then
	rm -rf ./arm64-kernel-install/lib/modules/*

	${SCRIPTS_TOP}/build-linux-kernel.sh arm64 ${LINUX_SRC_DIR} defconfig

	${SCRIPTS_TOP}/set-config-opts.sh --verbose \
		${SCRIPTS_TOP}/tx2-fixup.spec ./arm64-kernel-build/.config
	${SCRIPTS_TOP}/build-linux-kernel.sh arm64 ${LINUX_SRC_DIR} oldconfig

	${SCRIPTS_TOP}/build-linux-kernel.sh arm64 ${LINUX_SRC_DIR} fresh

	rsync -a --delete ./arm64-kernel-install/ \
		/tci--cache/arm64-kernel-install/
fi

modules="$(find ./arm64-kernel-install/lib/modules/* -maxdepth 0 -type d)"

check_directory "${modules}"

# rootfs.
${SCRIPTS_TOP}/build-debian-rootfs.sh --arch=arm64 \
	--kernel-modules="${modules}" --keep-rootfs -1

sudo rsync -a --delete ./arm64-debian-buster.rootfs/ \
	/tci--cache/arm64-debian-buster.bootstrap/
	
${SCRIPTS_TOP}/build-debian-rootfs.sh --arch=arm64 \
	--kernel-modules="${modules}" --keep-rootfs -23

if [[ ${no_tests} ]]; then
	exit
fi

# tests.
${SCRIPTS_TOP}/run-kernel-qemu-tests.sh --arch=arm64 \
	--kernel=./arm64-kernel-install/boot/Image \
	--initrd=./arm64-debian-buster.initrd \
	--ssh-key=arm64-debian-buster.login-key \
	--out-file=q.out \
	--verbose

${SCRIPTS_TOP}/run-kernel-t88-tests.sh --arch=arm64 --verbose

