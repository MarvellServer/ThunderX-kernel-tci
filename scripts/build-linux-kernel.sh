#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/common.sh

targets="
	amd64
	arm64
	arm64_be
	native
	powerpc
	powerpc64le
	ps3
	x86_64
"
ops="
	batch_build
	build
	defconfig
	fresh
	gconfig
	headers
	help
	install
	menuconfig
	oldconfig
	rebuild
	savedefconfig
	xconfig
"

cpus="$(cpu_count)"

usage() {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Builds linux kernel." >&2
	echo "Usage: ${name} [flags] <target> <kernel_src> <op>" >&2
	echo "Option flags:" >&2
	echo "  -b --build-dir     - Build directory. Default: '${build_dir}'." >&2
	echo "  -d --dry-run       - Do not run commands." >&2
	echo "  -h --help          - Show this help and exit." >&2
	echo "  -i --install-dir   - Target install directory. Default: '${install_dir}'." >&2
	echo "  -l --local-version - Default: '${local_version}'." >&2
	echo "  -v --verbose       - Verbose execution." >&2
	echo "Args:" >&2
	echo "  <target>     - Build target {$(clean_ws ${targets})}." >&2
	echo "                 Default: '${target}'." >&2
	echo "  <kernel-src> - Kernel source directory." >&2
	echo "                 Default: '${kernel_src}'." >&2
	echo "  <op>         - Build operation {$(clean_ws ${ops})}." >&2
	echo "                 Default: '${op}'." >&2
	echo "Info:" >&2
	echo "  ${cpus} CPUs available." >&2

	eval "${old_xtrace}"
}

short_opts="b:dhi:l:v"
long_opts="build-dir:,dry-run,help,install-dir:,local-version:,verbose"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

if [ $? != 0 ]; then
	echo "${name}: ERROR: Internal getopt" >&2
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-b | --build-dir)
		build_dir="${2}"
		shift 2
		;;
	-d | --dry-run)
		dry_run=1
		shift
		;;
	-h | --help)
		usage=1
		shift
		;;
	-l | --local-version)
		local_version="${2}"
		shift 2
		;;
	-t | --install-dir)
		install_dir="${2}"
		shift 2
		;;
	-v | --verbose)
		set -x
		verbose=1
		shift
		;;
	--)
		shift
		target=${1}
		kernel_src=${2}
		op=${3}
		if ! shift 3; then
			echo "${name}: ERROR: Missing args:" >&2
			echo "${name}:        <target>='${target}'" >&2
			echo "${name}:        <kernel_src>='${kernel_src}'" >&2
			echo "${name}:        <op>='${op}'" >&2
			usage
			exit 1
		fi
		if [[ -n "${1}" ]]; then
			echo "${name}: ERROR: Got extra args: '${@}'" >&2
			usage
			exit 1
		fi
		break
		;;
	*)
		echo "${name}: ERROR: Internal opts: '${@}'" >&2
		exit 1
		;;
	esac
done

cmd_trace=1

if [[ -z "${build_dir}" ]]; then
	build_dir="$(pwd)/${target}-kernel-build"
fi

if [[ -z "${install_dir}" ]]; then
	#install_dir="/target/${target}"
	install_dir="$(pwd)/${target}-kernel-install"
fi

if [[ -z "${local_version}" ]]; then
	local_version="$(basename "${kernel_src}")"
fi

if [[ -n "${usage}" ]]; then
	usage
	exit 0
fi

check_directory "${kernel_src}" "" "usage"

if test -x "$(command -v ccache)"; then
	ccache="ccache "
else
	echo "${name}: INFO: Please install ccache"
fi

declare -a target_copy

case "${target}" in
amd64)
	echo "${name}: TODO target: '${target}'" >&2
	exit 1
	;;
arm64|arm64_be)
	target_tool_prefix=${target_tool_prefix:="aarch64-linux-gnu-"}
	target_make_options="ARCH=arm64 CROSS_COMPILE='${ccache}${target_tool_prefix}'"
	target_defconfig="defconfig"
	target_copy=(
		vmlinux boot/
		arch/arm64/boot/Image boot/
	)
	;;
native)
	target_make_options="CROSS_COMPILE='${ccache}'"
	target_defconfig="defconfig"
	make_targets="all"
	;;
powerpc)
	target_tool_prefix=${target_tool_prefix:="powerpc-linux-gnu-"}
	target_make_options="ARCH=powerpc CROSS_COMPILE='${ccache}${target_tool_prefix}'"
	target_defconfig="defconfig"
	target_copy=(
		vmlinux boot/
	)
	;;
powerpc64le)
	target_tool_prefix=${target_tool_prefix:="powerpc64le-linux-gnu-"}
	target_make_options="ARCH=powerpc CROSS_COMPILE='${ccache}${target_tool_prefix}'"
	target_defconfig="defconfig"
	target_copy=(
		vmlinux boot/
	)
	;;
ps3)
	target_tool_prefix=${target_tool_prefix:="powerpc-linux-gnu-"}
	target_make_options="ARCH=powerpc CROSS_COMPILE='${ccache}${target_tool_prefix}'"
	target_defconfig="ps3_defconfig"
	target_copy=(
		vmlinux boot/
		arch/powerpc/boot/dtbImage.ps3.bin boot/linux
	)
	target_copy_opt=(
		arch/powerpc/boot/otheros.bld boot/
	)
	;;
x86_64)
	target_tool_prefix=${target_tool_prefix:="powerpc64le-linux-gnu-"}
	target_make_options="ARCH=powerpc CROSS_COMPILE='${ccache}${target_tool_prefix}'"
	target_defconfig="x86_64_defconfig"
	target_copy=(
		vmlinux boot/
	)
	;;
*)
	echo "${name}: ERROR: Unknown target: '${target}'" >&2
	usage
	exit 1
	;;
esac

if [[ -n "${verbose}" ]]; then
	make_options_extra="V=1"
fi

make_options="-j${cpus} ${target_make_options} INSTALL_MOD_PATH='${install_dir}' INSTALL_PATH='${install_dir}/boot' INSTALLKERNEL=non-existent-file O='${build_dir}' ${make_options_extra}"
start_time="$(date)"
SECONDS=0

export CCACHE_DIR=${CCACHE_DIR:="${build_dir}.ccache"}

run_cmd "mkdir -p ${build_dir}"
run_cmd "mkdir -p ${CCACHE_DIR}"

cd ${kernel_src}

on_exit() {
	result=${?}
	end_time="$(date)"

	set +x

	echo ""
	echo "${name}: Done:          result=${result}"
	echo "${name}: target:        ${target}"
	echo "${name}: op:            ${op}"
	echo "${name}: kernel_src:    ${kernel_src}"
	echo "${name}: build_dir:     ${build_dir}"
	echo "${name}: install_dir:   ${install_dir}"
	echo "${name}: local_version: ${local_version}"
	echo "${name}: make_options:  ${make_options}"
	echo "${name}: start_time:    ${start_time}"
	echo "${name}: end_time:      ${end_time}"
	echo "${name}: duration:      ${SECONDS} seconds"
}

trap on_exit EXIT

while true ; do
	case "${op}" in
	batch_build|build)
		run_cmd "make ${make_options} savedefconfig"
		run_cmd "make ${make_options} ${make_targets}"
		if [[ "${op}" == "batch_build" ]]; then
			break
		fi
		op="install"
		;;
	defconfig)
		if [[ -n ${target_defconfig} ]]; then
			run_cmd "make ${make_options} ${target_defconfig}"
		else
			run_cmd "make ${make_options} defconfig"
		fi
		run_cmd "make ${make_options} savedefconfig"
		break
		;;
	fresh)
		run_cmd "cp ${build_dir}/.config /tmp/config.tmp"
		run_cmd "rm -rf ${build_dir}/{*,.*} &>/dev/null || :"
		run_cmd "make ${make_options} mrproper"
		run_cmd "make ${make_options} defconfig"
		run_cmd "cp /tmp/config.tmp ${build_dir}/.config"
		run_cmd "make ${make_options} oldconfig"
		op="build"
		;;
	headers)
		run_cmd "make ${make_options} mrproper"
		run_cmd "make ${make_options} defconfig"
		run_cmd "make ${make_options} prepare"
		break
		;;
	install)
		run_cmd mkdir -p "${install_dir}/boot" "${install_dir}/lib/modules"
		run_cmd "cp ${build_dir}/{defconfig,System.map,vmlinux} ${install_dir}/boot/"
		run_cmd "cp ${build_dir}/.config ${install_dir}/boot/config"
		run_cmd "${target_tool_prefix}strip -s -R .comment ${build_dir}/vmlinux -o ${install_dir}/boot/vmlinux.strip"

		if [[ -z ${target_copy} ]]; then
			run_cmd "make ${make_options} install"
		else
			for ((i = 0; i <= ${#target_copy[@]} - 1; i+=2)); do
				run_cmd "cp --no-dereference ${build_dir}/${target_copy[i]} ${install_dir}/${target_copy[i+1]}"
			done
		fi
		if [[ -n ${target_copy_opt} ]]; then
			for ((i = 0; i <= ${#target_copy_opt[@]} - 1; i+=2)); do
				if [[ -f ${target_copy_opt[i]} ]]; then
					run_cmd "cp --no-dereference ${build_dir}/${target_copy_opt[i]} ${install_dir}/${target_copy_opt[i+1]}"
				fi
			done
		fi
		run_cmd "make ${make_options} modules_install"
		break
		;;
	rebuild)
		run_cmd "make ${make_options} clean"
		op="build"
		;;
	savedefconfig)
		run_cmd "make ${make_options} savedefconfig"
		break
		;;
	gconfig|menuconfig|oldconfig|olddefconfig|xconfig)
		run_cmd "make ${make_options} ${op}"
		run_cmd "make ${make_options} savedefconfig"
		break
		;;
	*)
		echo "${name}: INFO: Unknown op: '${op}'" >&2
		run_cmd "make ${make_options} ${op}"
		break
		;;
	esac
done
