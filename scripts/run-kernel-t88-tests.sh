#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/common.sh
source ${SCRIPTS_TOP}/ipmi.sh
source ${SCRIPTS_TOP}/relay.sh

usage () {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Run Linux kernel tests on ThunderX T88." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -h --help           - Show this help and exit." >&2
	echo "  -i --initrd         - Initrd image. Default: '${initrd}'." >&2
	echo "  -k --kernel         - Kernel image. Default: '${kernel}'." >&2
	echo "  -n --no-known-hosts - Do not setup known_hosts file. Default: '${no_known_hosts}'." >&2
	echo "  -o --out-file       - stdout, stderr redirection file. Default: '${out_file}'." >&2
	echo "  -s --systemd-debug  - Run systemd with debug options. Default: '${systemd_debug}'." >&2
	echo "  -v --verbose        - Verbose execution." >&2
	echo "  --bmc-host          - Remote BMC host or address. Default: '${bmc_host}'." >&2
	echo "  --relay-triple      - File name or 'server:port:token'. Default: '${relay_triple}'." >&2
	echo "  --result-file       - Result file. Default: '${result_file}'." >&2
	echo "  --ssh-login-key     - SSH login private key file. Default: '${ssh_login_key}'." >&2
	echo "  --tftp-triple       - tftp triple.  File name or 'user:server:root'. Default: '${tftp_triple}'." >&2
	eval "${old_xtrace}"
}

short_opts="hi:k:no:sv"
long_opts="help,initrd:,kernel:,no-known-hosts,out-file:,result-file:,\
systemd-debug,verbose,bmc-host:,relay-triple:,result-file:,ssh-login-key:,tftp-triple:"

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
	-o | --out-file)
		out_file="${2}"
		shift 2
		;;
	-r | --result-file)
		result_file="${2}"
		shift 2
		;;
	-s | --systemd-debug)
		systemd_debug=1
		shift
		;;
	-v | --verbose)
		set -x
		verbose=1
		shift
		;;
	--bmc-host)
		bmc_host="${2}"
		shift 2
		;;
	--relay-triple)
		relay_triple="${2}"
		shift 2
		;;
	--ssh-login-key)
		ssh_login_key="${2}"
		shift 2
		;;
	--tftp-triple)
		tftp_triple="${2}"
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

cmd_trace=1
host_arch=$(get_arch "$(uname -m)")
start_extra_args=""

if [[ -z "${out_file}" ]]; then
	out_file="t88.out"
fi

if [[ -z "${result_file}" ]]; then
	result_file="t88-result.txt"
fi

if [[ -f "${relay_triple}" ]]; then
	relay_triple=$(cat ${relay_triple})
	echo "${name}: INFO: Relay triple: '${relay_triple}'" >&2
fi

if [[ ! ${relay_token} ]]; then
	relay_triple="$(relay_make_random_triple ${relay_server} ${relay_port})"
fi

relay_split_triple ${relay_triple} relay_server relay_port relay_token

relay_addr=$(find_addr /etc/hosts ${relay_server})

old_xtrace="$(shopt -po xtrace || :)"
set +o xtrace
echo "${name}: INFO: Relay triple: '${relay_triple}'" >&2
echo "triple: ${relay_triple}"
echo " server: ${relay_server}"
echo " port:   ${relay_port}"
echo " token:  ${relay_token}"
echo " addr:   ${relay_addr}"
eval "${old_xtrace}"

if [[ -z "${bmc_host}" ]]; then
	bmc_host="t88-bmc"
	echo "${name}: INFO: BMC host: '${bmc_host}'" >&2
fi

if [[ ${usage} ]]; then
	usage
	exit 0
fi

if [[ ! ${relay_triple} ]]; then
	echo "${name}: ERROR: Must provide --relay-triple option." >&2
	usage
	exit 1
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

if [[ ! ${ssh_login_key} ]]; then
	echo "${name}: ERROR: Must provide --ssh-login-key option." >&2
	usage
	exit 1
fi

check_file "${ssh_login_key}"

if [[ ${systemd_debug} ]]; then
	start_extra_args+=' --systemd-debug'
fi

if [[ ${no_known_hosts} ]]; then
	tftp_upload_extra="--no-known-hosts"
fi

on_exit() {
	local result=${1}
	local sol_pid

	set +e

	if [[ -n "${sol_pid_file}" ]]; then
		sol_pid=$(cat ${sol_pid_file})
		rm -f ${sol_pid_file}
	fi

	if [[ -f ${test_kernel} ]]; then
		rm -f ${test_kernel}
	fi

	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo '*** on_exit ***'
	echo "*** result      = @${result}@" >&2
	echo "*** sol_pid_fil = @${sol_pid_file}@" >&2
	echo "*** sol_pid     = @${sol_pid}@" >&2
	echo "*** ipmi_args   = @${ipmi_args}@" >&2
	eval "${old_xtrace}"

	kill -0 ${sol_pid}

	if [[ -n "${sol_pid}" ]]; then
		sudo kill ${sol_pid} || :
	fi

	if [[ -n "${ipmi_args}" ]]; then
		ipmitool ${ipmi_args} -I lanplus sol deactivate || :
		ipmitool ${ipmi_args} -I lanplus chassis power off || :
	fi

	wait ${sol_pid}
	echo "${name}: ${result}" >&2
}

trap "on_exit 'Done, failed.'" EXIT

${SCRIPTS_TOP}/set-relay-triple.sh \
	--kernel=${kernel} \
	--relay-triple="${relay_addr}:${relay_port}:${relay_token}" \
	--verbose

test_kernel=${kernel}.${relay_token}

${SCRIPTS_TOP}/tftp-upload.sh --kernel=${test_kernel} --initrd=${initrd} \
	--tftp-triple=${tftp_triple} ${tftp_upload_extra} --verbose

old_xtrace="$(shopt -po xtrace || :)"
set +o xtrace
if [[ -z "${JENKINS_URL}" ]]; then
	check_file 't88-bmc-creds' ': Need credentials file [user:passwd]'
	t88_bmc_cred_USR="$(cat t88-bmc-creds | cut -d ':' -f 1)"
	t88_bmc_cred_PSW="$(cat t88-bmc-creds | cut -d ':' -f 2)"
fi
export IPMITOOL_PASSWORD="${t88_bmc_cred_PSW}"
eval "${old_xtrace}"

ipmi_args="-H ${bmc_host} -U ${t88_bmc_cred_USR} -E"

ipmitool ${ipmi_args} chassis status > ${out_file}
echo '-----' >> ${out_file}

# FIXME: Need this?
#ipmitool ${ipmi_args} -I lanplus sol deactivate || :

sol_pid_file="$(mktemp --tmpdir tci-sol-pid.XXXX)"

(echo "${BASHPID}" > ${sol_pid_file}; exec sleep 24h) | ipmitool ${ipmi_args} -I lanplus sol activate 1>>"${out_file}" &

echo "sol_pid=$(cat ${sol_pid_file})" >&2

ipmi_power_off "${ipmi_args}"
sleep 5s
ipmi_power_on "${ipmi_args}"

relay_get "240" "${relay_addr}:${relay_port}:${relay_token}" remote_addr

echo "${name}: remote_addr = '${remote_addr}'" >&2

remote_host="root@${remote_addr}"

# The remote host address could come from DHCP, so don't use known_hosts.
ssh_no_check="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh ${ssh_no_check} -i ${ssh_login_key} ${remote_host} \
	'find /lib/modules -type f | egrep nicvf.ko'

ssh ${ssh_no_check} -i ${ssh_login_key} ${remote_host} \
	'poweroff &'

echo "${name}: Waiting for shutdown at ${remote_addr}..." >&2

ipmi_wait_power_state "${ipmi_args}" 'off'

trap - EXIT

on_exit 'Done, success.' ${sol_pid_file} "${ipmi_args}"
