#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/common.sh

usage () {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Upload files to tftp server." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -h --help           - Show this help and exit." >&2
	echo "  -i --initrd         - Initrd image. Default: '${initrd}'." >&2
	echo "  -k --kernel         - Kernel image. Default: '${kernel}'." >&2
	echo "  -n --no-known-hosts - Do not setup known_hosts file. Default: '${no_known_hosts}'." >&2
	echo "  -t --tftp-triple    - tftp triple.  File name or 'user:server:root'. Default: '${tftp_triple}'." >&2
	echo "  -v --verbose        - Verbose execution." >&2
	eval "${old_xtrace}"
}

short_opts="hi:k:nt:v"
long_opts="help,initrd:,kernel:,no-known-hosts,tftp-triple:,verbose"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

if [ $? != 0 ]; then
	echo "${name}: ERROR: Internal getopt" >&2
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-h | --help)
		usage=1
		shift
		;;
	-i | --initrd)
		initrd="${2}"
		shift 2
		;;
	-k | --kernel)
		kernel="${2}"
		shift 2
		;;
	-n | --no-known-hosts)
		no_known_hosts=1
		shift
		;;
	--tftp-triple)
		tftp_triple="${2}"
		shift 2
		;;
	-v | --verbose)
		set -x
		verbose=1
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

tftp_kernel="tci-kernel"
tftp_initrd="tci-initrd"

if [[ -f "${tftp_triple}" ]]; then
	tftp_triple=$(cat ${tftp_triple})
	echo "${name}: INFO: tftp triple: '${tftp_triple}'" >&2
fi

if [[ -z "${tftp_triple}" ]]; then
	tftp_triple="tci-jenkins:tci-tftp:/var/tftproot"
	echo "${name}: INFO: tftp triple: '${tftp_triple}'" >&2
fi

if [[ ${usage} ]]; then
	usage
	exit 0
fi

if [[ ! ${kernel} ]]; then
	echo "${name}: ERROR: Must provide --kernel option." >&2
	usage
	exit 1
fi

check_file "${kernel}"

if [[ ! ${initrd} ]]; then
	echo "${name}: ERROR: Must provide --initrd option." >&2
	usage
	exit 1
fi

check_file "${initrd}"

on_exit() {
	local result=${1}

	echo "${name}: ${result}" >&2
}

trap "on_exit 'Done, failed.'" EXIT

setup_known_hosts() {
	local host=${1}

	if ! ssh-keygen -F ${host} &> /dev/null; then
		mkdir -p ~/.ssh
		ssh-keyscan ${host} >> ~/.ssh/known_hosts
	fi
}

tftp_user="$(echo ${tftp_triple} | cut -d ':' -f 1)"
tftp_server="$(echo ${tftp_triple} | cut -d ':' -f 2)"
tftp_root="$(echo ${tftp_triple} | cut -d ':' -f 3)"

if [[ ${no_known_hosts} ]]; then
	ssh_no_check="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
	setup_known_hosts ${tftp_server}
fi

[[ ${verbose} ]] && ssh ${ssh_no_check} ${tftp_user}@${tftp_server} ls -lh ${tftp_root}
scp ${ssh_no_check} ${initrd} ${tftp_user}@${tftp_server}:${tftp_root}/${tftp_initrd}
scp ${ssh_no_check} ${kernel} ${tftp_user}@${tftp_server}:${tftp_root}/${tftp_kernel}
[[ ${verbose} ]] && ssh ${ssh_no_check} ${tftp_user}@${tftp_server} ls -lh ${tftp_root}

trap - EXIT

on_exit 'Done, success.'
