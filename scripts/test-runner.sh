#!/usr/bin/env bash

set -e
set -x

name="$(basename $0)"

SCRIPTS_TOP=${SCRIPTS_TOP:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/lib-common.sh

usage() {
	local tests="$(clean_ws ${test_types})"

	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Builds test programs." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -a --arch        - Target architecture. Default: '${target_arch}'." >&2
	echo "  -h --help        - Show this help and exit." >&2
	echo "  -t --tests-dir   - Tests directory. Default: '${tests_dir}'." >&2
	echo "  -v --verbose     - Verbose execution." >&2
	echo "Operations:" >&2
	echo "  --build          - Tests to build {$(clean_ws ${test_types})}. Default: '$(clean_ws ${op_build})'." >&2
	echo "    --sysroot      - SYSROOT directory. Default: '${sysroot}'." >&2
	echo "  --run            - Tests to run {$(clean_ws ${test_types})}. Default: '$(clean_ws ${op_run})'." >&2
	echo "    --machine-type - Test machine type {$(clean_ws ${machine_types})}. Default: '${machine_type}'." >&2
	echo "    --ssh-host     - Default: '${ssh_host}'." >&2
	echo "    --ssh-opts     - Default: '${ssh_opts}'." >&2
	eval "${old_xtrace}"
}

process_opts() {
	local short_opts="a:ht:v12"
	local long_opts="arch:,help,tests-dir:,verbose,\
	build::,sysroot:,/
	run::,machine-type:,ssh-host:,ssh-opts:"

	local opts
	opts=$(getopt --options "${short_opts}" --long "${long_opts}" -n "${name}" -- "${@}")

	eval set -- "${opts}"

	while true ; do
		echo "**test @${1}@${2}@"
		case "${1}" in
		-a | --arch)
			target_arch=$(get_arch "${2}")
			shift 2
			;;
		-h | --help)
			usage=1
			shift
			;;
		-t | --tests-dir)
			tests_dir="${2}"
			shift 2
			;;
		-v | --verbose)
			set -x
			verbose=1
			shift
			;;
		--build)
			if [[ ${2} ]]; then
				op_build="${2}"
			else
				op_build="${test_types}"
			fi
			shift 2
			;;
		--sysroot)
			sysroot="${2}"
			shift 2
			;;
		--run)
			if [[ ${2} ]]; then
				op_run="${2}"
			else
				op_run="${test_types}"
			fi
			shift 2
			;;
		--machine-type)
			machine_type="${2}"
			shift 2
			;;
		--ssh-host)
			ssh_host="${2}"
			shift 2
			;;
		--ssh-opts)
			ssh_opts="${2}"
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
}

check_test() {
	local test=${1}

	case "${test}" in
	ltp | unixbench)
		echo "${FUNCNAME[0]}: '${test}' OK" >&2
		;;
	*)
		echo "${name}: ERROR: Unknown test name: '${test}'" >&2
		echo "${name}: Valid test names: {$(clean_ws ${test_types})}" >&2
		usage
		exit 1
		;;
	esac
}

build_tests() {
	local tests_dir=${1}
	local sysroot=${2}
	local -n _build_tests__tests=${3}

	for test in ${_build_tests__tests[@]}; do
		trap "on_exit 'Done, build ${test} failed.'" EXIT
		check_test ${test}
		test_build_${test} ${tests_dir} ${sysroot}
	done
}

run_tests() {
	local tests_dir=${1}
	local machine_type=${2}
	local ssh_host=${3}
	local -n _run_tests__ssh_opts=${4}
	local -n _run_tests__tests=${5}

	for test in ${_run_tests__tests[@]}; do
		trap "on_exit 'Done, run ${test} failed.'" EXIT
		check_test ${test}
		test_run_${test} ${tests_dir} ${machine_type} ${ssh_host} _run_tests__ssh_opts
	done
}

on_exit() {
	if [[ -d ${tmp_dir} ]]; then
		rm -rf ${tmp_dir}
	fi
}

on_fail() {
	echo "${name}: Step ${current_step}: FAILED." >&2
	on_exit
}


#===============================================================================
# program start
#===============================================================================

sudo="sudo -S"

test_types="
	ltp
	unixbench
"

machine_types="
	qemu
	remote
"

process_opts "${@}"

host_arch=$(get_arch "$(uname -m)")
target_arch=${target_arch:-"${host_arch}"}

tests_dir=${tests_dir:-"$(pwd)/tests"}

if [[ ${usage} ]]; then
	usage
	exit 0
fi

if [[ ! ${op_build} && ! ! ${op_run} ]]; then
	echo "${name}: ERROR: Must supply --build or --run." >&2
	usage
	exit 1
fi

trap on_fail EXIT

tmp_dir="$(mktemp --tmpdir --directory ${name}.XXXX)"

for test in ${test_types[@]}; do
	source ${SCRIPTS_TOP}/test-plugin-${test}.sh
done

if [[ ${op_build} ]]; then
	current_step="build"
	echo "${name}: INFO: Step ${current_step}: start." >&2

	check_opt 'sysroot' ${sysroot}
	check_directory "${sysroot}"

	check_file "${sysroot}/etc/os-release"
	rootfs_type=$(egrep '^ID=' ${sysroot}/etc/os-release)
	rootfs_type=${rootfs_type#ID=}
	echo "${name}: INFO: Rootfs type = '${rootfs_type}'" >&2

	case "${rootfs_type}" in
	alpine | debian)
		;;
	*)
		echo "${name}: ERROR: Unknown rootfs type: '${rootfs_type}'" >&2
		cat ${sysroot}/etc/os-release
		exit 1
		;;
	esac

	build_tests ${tests_dir} ${sysroot} op_build

	echo "${name}: INFO: Step ${current_step}: done." >&2
fi

if [[ ${op_run} ]]; then
	current_step="run"
	echo "${name}: INFO: Step ${current_step}: start." >&2

	check_opt 'machine-type' ${machine_type}

	case "${machine_type}" in
	qemu | remote)
		;;
	*)
		echo "${name}: ERROR: Unknown machine type: '${machine_type}'" >&2
		exit 1
		;;
	esac

	check_opt 'ssh-host' ${ssh_host}
	check_opt 'ssh-opts' ${ssh_opts}

	run_tests ${tests_dir} ${machine_type} ${ssh_host} ssh_opts op_run

	echo "${name}: INFO: Step ${current_step}: done." >&2
fi

trap on_exit EXIT

echo "${name}: INFO: Success: ${tests_dir}" >&2
