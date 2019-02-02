#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}
DOCKER_TOP=${DOCKER_TOP:-"$(cd "${SCRIPTS_TOP}/../docker" && pwd)"}

source ${SCRIPTS_TOP}/lib-common.sh

usage() {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace

	echo "${name} - Builds TCI container image, Linux kernel, root file system image, and runs QEMU." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  --arch            - Target architecture. Default: ${target_arch}." >&2
	echo "  -h --help         - Show this help and exit." >&2
	echo "  --build-name      - Build name. Default: '${build_name}'." >&2
	echo "  --linux-branch    - Linux kernel git repository branch. Default: ${linux_branch}." >&2
	echo "  --linux-repo      - Linux kernel git repository URL. Default: ${linux_repo}." >&2
	echo "  --linux-src-dir   - Linux kernel git working tree. Default: ${linux_src_dir}." >&2
	echo "  --test-machine    - Test machine name. Default: '${test_machine}'." >&2
	echo "  --systemd-debug   - Run systemd with debug options. Default: '${systemd_debug}'." >&2
	echo "  --rootfs-type     - Rootfs type {$(clean_ws ${rootfs_types})}." >&2
	echo "                      Default: '${rootfs_type}'." >&2
	echo "Option steps:" >&2
	echo "  --enter               - Enter container, no builds." >&2
	echo "  -1 --build-kernel     - Build kernel." >&2
	echo "  -2 --build-bootstrap  - Build rootfs bootstrap." >&2
	echo "  -3 --build-rootfs     - Build rootfs." >&2
	echo "  -4 --build-tests      - Build tests." >&2
	echo "  -5 --run-qemu-tests   - Run Tests." >&2
	echo "  -6 --run-remote-tests - Run Tests." >&2
	if [[ ! -f /.dockerenv ]]; then
	echo "Environment:" >&2
	echo "  TCI_ROOT          - Default: ${TCI_ROOT}." >&2
	echo "  TEST_ROOT         - Default: ${TEST_ROOT}." >&2
	fi
	eval "${old_xtrace}"
}

process_opts() {
	local short_opts="h123456"
	local long_opts="\
arch:,help,build-name:,linux-branch:,linux-repo:,linux-src-dir:,test-machine:,\
systemd-debug,rootfs-type:,\
enter,build-kernel,build-bootstrap,build-rootfs,build-tests,run-qemu-tests,\
run-remote-tests"

	local opts
	opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

	eval set -- "${opts}"

	while true ; do
		#echo "${FUNCNAME[0]}: @${1}@ @${2}@"
		case "${1}" in
		--arch)
			target_arch=$(get_arch "${2}")
			shift 2
			;;
		-h | --help)
			usage=1
			shift
			;;
		--build-name)
			build_name="${2}"
			shift 2
			;;
		--linux-branch)
			linux_branch="${2}"
			shift 2
			;;
		--linux-repo)
			linux_repo="${2}"
			shift 2
			;;
		--linux-src-dir)
			linux_src_dir="${2}"
			shift 2
			;;
		--test-machine)
			test_machine="${2}"
			shift 2
			;;
		--systemd-debug)
			systemd_debug=1
			shift
			;;
		--rootfs-type)
			rootfs_type="${2}"
			shift 2
			;;
		--enter)
			step_enter=1
			shift
			;;
		-1 | --build-kernel)
			step_build_kernel=1
			shift
			;;
		-2 | --build-bootstrap)
			step_build_bootstrap=1
			shift
			;;
		-3 | --build-rootfs)
			step_build_rootfs=1
			shift
			;;
		-4 | --build-tests)
			step_build_tests=1
			shift
			;;
		-5 | --run-qemu-tests)
			step_run_qemu_tests=1
			shift
			;;
		-6 | --run-remote-tests)
			step_run_remote_tests=1
			shift
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
}

on_exit() {
	local result=${1}

	if [[ -d ${tmp_dir} ]]; then
		${sudo} rm -rf ${tmp_dir}
	fi

	local end_time="$(date)"
	local end_sec="${SECONDS}"
	local end_min
	if test -x "$(command -v bc)"; then
		end_min="$(bc <<< "scale=2; ${end_sec} / 60")"
	else
		end_min="$((end_sec / 60)).$(((end_sec * 100) / 60))"
	fi

	set +x
	echo "${name}: start time: ${start_time}" >&2
	echo "${name}: end time:   ${end_time}" >&2
	echo "${name}: duration:   ${end_sec} seconds (${end_min} min)" >&2
	echo "${name}: Done:       ${result}" >&2
}

build_kernel() {
	rm -rf ${linux_build_dir} ${linux_install_dir}

	if [[ ! -d "${linux_src_dir}" ]]; then
		git clone ${linux_repo} "${linux_src_dir}"
	fi

	(cd ${linux_src_dir} && git remote update &&
		git checkout --force ${linux_branch})

	${SCRIPTS_TOP}/build-linux-kernel.sh \
		--build-dir=${linux_build_dir} \
		--install-dir=${linux_install_dir} \
		${target_arch} ${linux_src_dir} defconfig

	${SCRIPTS_TOP}/set-config-opts.sh \
		--verbose \
		${SCRIPTS_TOP}/tx2-fixup.spec ${linux_build_dir}/.config

	${SCRIPTS_TOP}/build-linux-kernel.sh \
		--build-dir=${linux_build_dir} \
		--install-dir=${linux_install_dir} \
		${target_arch} ${linux_src_dir} oldconfig

	${SCRIPTS_TOP}/build-linux-kernel.sh \
		--build-dir=${linux_build_dir} \
		--install-dir=${linux_install_dir} \
		${target_arch} ${linux_src_dir} fresh

	mkdir -p ${file_cache}
	rsync -a --delete "${linux_install_dir}/" \
		"${file_cache}/$(basename ${linux_install_dir})/"
}

build_bootstrap() {
	${sudo} rm -rf ${rootfs_dir}
	rm -rf ${top_build_dir}/${image_name}.*

	${SCRIPTS_TOP}/build-rootfs.sh \
		--arch=${target_arch} \
		--kernel-modules="${modules}" \
		--build-dir=${top_build_dir} \
		--image-name=${image_name} \
		--rootfs-type=${rootfs_type} \
		--bootstrap \
		--verbose

	mkdir -p ${file_cache}
	${sudo} rsync -a --delete ${rootfs_dir}/ ${bootstrap_dir}/
}

build_rootfs() {
	${sudo} rm -rf ${rootfs_dir}
	rm -rf ${top_build_dir}/${image_name}.*

	local modules
	modules="$(find ${linux_install_dir}/lib/modules/* -maxdepth 0 -type d)"
	check_directory "${modules}"

	${sudo} rsync -a --delete ${bootstrap_dir}/ ${rootfs_dir}/

	${SCRIPTS_TOP}/build-rootfs.sh \
		--arch=${target_arch} \
		--kernel-modules="${modules}" \
		--build-dir=${top_build_dir} \
		--image-name=${image_name} \
		--rootfs-type=${rootfs_type} \
		--keep-rootfs \
		--rootfs-setup \
		--make-image \
		--verbose
}

build_tests() {
	${sudo} rm -rf ${tests_dir}

	${SCRIPTS_TOP}/test-runner.sh \
		--arch=${target_arch} \
		--tests-dir=${tests_dir} \
		--verbose \
		--build \
		--sysroot=${rootfs_dir}
}

run_qemu_tests() {
	echo "${name}: run_qemu_tests" >&2

	if [[ ${systemd_debug} ]]; then
		local extra_args="--systemd-debug"
	fi

	${SCRIPTS_TOP}/run-kernel-qemu-tests.sh \
		--arch=${target_arch} \
		--kernel=${linux_install_dir}/boot/Image \
		--initrd=${top_build_dir}/${image_name}.initrd \
		--ssh-login-key=${top_build_dir}/${image_name}.login-key \
		--tests-dir=${tests_dir} \
		--out-file=${top_build_dir}/${image_name}-qemu-console.txt \
		--result-file=${top_build_dir}/${image_name}-qemu-result.txt \
		${extra_args} \
		--verbose
}

run_remote_tests() {
	local test=${1}

	echo "${name}: run_remote_tests" >&2

	if [[ ${systemd_debug} ]]; then
		local extra_args="--systemd-debug"
	fi

	${SCRIPTS_TOP}/run-kernel-remote-tests.sh \
		--test-machine=${test_machine} \
		--kernel=${linux_install_dir}/boot/Image \
		--initrd=${top_build_dir}/${image_name}.initrd \
		--ssh-login-key=${top_build_dir}/${image_name}.login-key \
		--out-file=${top_build_dir}/${image_name}-${test_machine}-console.txt \
		--result-file=${top_build_dir}/${image_name}-${test_machine}-result.txt \
		--test-script=${test} \
		${extra_args} \
		--verbose
}

#===============================================================================
# program start
#===============================================================================
sudo="sudo -S"
parent_ops="$@"

start_time="$(date)"
SECONDS=0

trap "on_exit 'failed.'" EXIT

process_opts "${@}"

if [[ ! -f /.dockerenv ]]; then
	TEST_ROOT=${TEST_ROOT:-"$(pwd)"}
	TCI_ROOT=${TCI_ROOT:-"$(cd ${SCRIPTS_TOP}/.. && pwd)"}
fi

rootfs_type=${rootfs_type:-"debian"}
rootfs_types="
	alpine
	debian
"

case "${rootfs_type}" in
alpine|debian)
	;;
*)
	echo "${name}: ERROR: Unknown rootfs type: '${rootfs_type}'" >&2
	usage
	exit 1
	;;
esac

test_machine=${test_machine:-"t88"}
build_name=${build_name:-"${name%.*}-$(date +%m.%d)"}
target_arch=${target_arch:-"arm64"}
image_name="image"
kernel_name="kernel"

top_build_dir="$(pwd)/${build_name}"
file_cache="${top_build_dir}/file-cache"

linux_repo=${linux_repo:-"https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"}
linux_branch=${linux_branch:-"linux-5.0.y"}
linux_repo_name="$(basename ${linux_repo})"
linux_repo_name="${linux_repo_name%.*}"
linux_src_dir=${linux_src_dir:-"$(pwd)/${linux_repo_name}"}
linux_build_dir="${top_build_dir}/${kernel_name}-build"
linux_install_dir="${top_build_dir}/${kernel_name}-install"

bootstrap_dir=${file_cache}/${image_name}.bootstrap
rootfs_dir=${top_build_dir}/${image_name}.rootfs
tests_dir=${top_build_dir}/${image_name}.tests

if [[ -n "${usage}" ]]; then
	usage
	trap - EXIT
	exit 0
fi

set -x

#tmp_dir="$(mktemp --tmpdir --directory ${name}.XXXX)"

if [ ! -f /.dockerenv ]; then
	check_directory ${TCI_ROOT} "" "usage"
	check_directory ${TEST_ROOT} "" "usage"

	${DOCKER_TOP}/builder/build-builder.sh

	echo "${name}: Entering ${build_name} container..." >&2

	if [[ ${step_enter} ]]; then
		docker_cmd="/bin/bash"
	else
		docker_cmd="/tci/scripts/run-all.sh ${parent_ops}"
	fi

	${SCRIPTS_TOP}/run-builder.sh \
		--verbose \
		--container-name="${build_name}" \
		--docker-args="\
			-e build_name \
			-v ${TCI_ROOT}:/tci:ro \
			-e TCI_ROOT=/tci \
			-v ${TEST_ROOT}:/tci--test:rw,z \
			-e TCI_TEST=/tci--test \
			-w /tci--test" \
		-- "${docker_cmd}"

	trap - EXIT
	on_exit 'container success.'
	exit
fi

# steps graph:
#  kernel -----+
#  bootstrap --+--> rootfs --+--> tests --+--> qemu
#                                         +--> remote
step_code="${step_build_kernel:-"0"}${step_build_bootstrap:-"0"}${step_build_rootfs:-"0"}${step_build_tests:-"0"}${step_run_qemu_tests:-"0"}${step_run_remote_tests:-"0"}"
echo "step_code=@${step_code}@"

case "${step_code}" in
000000)
	step_build_kernel=1
	step_build_bootstrap=1
	step_build_rootfs=1
	step_build_tests=1
	step_run_qemu_tests=1
	step_run_remote_tests=1
	;;
esac

if [[ ${step_run_qemu_tests} || ${step_run_remote_tests} ]]; then
	step_run_tests=1
fi

if [[ ${step_build_kernel} || ${step_build_bootstrap} ]]; then
	# backward
	# (none)
	# forward
	if [[ (${step_build_tests}) && ! ${step_build_rootfs} ]]; then
		echo "${name}: ERROR: Need --build-rootfs" >&2
		usage
		exit 1
	fi
	if [[ (${step_run_tests}) && ! ${step_build_rootfs} ]]; then
		echo "${name}: ERROR: Need --build-rootfs" >&2
		usage
		exit 1
	fi
fi

if [[ ${step_build_rootfs} ]]; then
	# backward
	if [[ ! ${step_build_kernel} && ! -d ${linux_install_dir} ]]; then
		echo "${name}: ERROR: Need --build-kernel" >&2
		usage
		exit 1
	fi
	if [[ ! ${step_build_bootstrap} && ! -d ${bootstrap_dir} ]]; then
		echo "${name}: ERROR: Need --build-bootstrap" >&2
		usage
		exit 1
	fi
	# forward
	if [[ (${step_run_tests}) && ! ${step_build_tests} ]]; then
		echo "${name}: ERROR: Need --build-tests" >&2
		usage
		exit 1
	fi
fi

if [[ ${step_build_tests} ]]; then
	# backward
	if [[ ! ${step_build_rootfs} && ! -d ${rootfs_dir} ]]; then
		echo "${name}: ERROR: Need --build-rootfs" >&2
		usage
		exit 1
	fi
	# forward
	# (none)
fi

if [[ ${step_run_tests} ]]; then
	# backward
	if [[ ! ${step_build_tests} && ! -d ${tests_dir} ]]; then
		echo "${name}: ERROR: Need --build-tests" >&2
		usage
		exit 1
	fi
	# forward
	# (none)
fi

printenv
${sudo} true

if [[ ${step_build_kernel} ]]; then
	trap "on_exit 'build_kernel failed.'" EXIT
	build_kernel
fi

if [[ ${step_build_bootstrap} ]]; then
	trap "on_exit 'build_bootstrap failed.'" EXIT
	build_bootstrap
fi

if [[ ${step_build_rootfs} ]]; then
	trap "on_exit 'build_rootfs failed.'" EXIT
	build_rootfs
fi

if [[ ${step_build_tests} ]]; then
	trap "on_exit 'build_tests failed.'" EXIT
	build_tests
fi

if [[ ${step_run_qemu_tests} ]]; then
	trap "on_exit 'run_qemu_tests failed.'" EXIT
	run_qemu_tests
fi

if [[ ${step_run_remote_tests} ]]; then
	trap "on_exit 'run_remote_tests failed.'" EXIT
	run_remote_tests
fi

trap - EXIT
on_exit 'build success.'
