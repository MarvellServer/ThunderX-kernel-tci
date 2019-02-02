#!/usr/bin/env bash

set -e

name="$(basename ${0})"

SCRIPTS_TOP=${SCRIPTS_TOP:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/lib-common.sh
source ${SCRIPTS_TOP}/lib-ipmi.sh
source ${SCRIPTS_TOP}/lib-relay.sh

usage () {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Run Linux kernel tests on remote machine via PXE boot, IPMI and ssh." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -h --help           - Show this help and exit." >&2
	echo "  -i --initrd         - Initrd image. Default: '${initrd}'." >&2
	echo "  -k --kernel         - Kernel image. Default: '${kernel}'." >&2
	echo "  -m --test-machine   - Test machine name. Default: '${test_machine}'." >&2
	echo "  -n --no-known-hosts - Do not setup known_hosts file. Default: '${no_known_hosts}'." >&2
	echo "  -o --out-file       - stdout, stderr redirection file. Default: '${out_file}'." >&2
	echo "  -s --systemd-debug  - Run systemd with debug options. Default: '${systemd_debug}'." >&2
	echo "  -v --verbose        - Verbose execution." >&2
	echo "  --bmc-host          - Test machine BMC hostname or address. Default: '${bmc_host}'." >&2
	echo "  --relay-server      - Relay server host[:port]. Default: '${relay_server}'." >&2
	echo "  --result-file       - Result file. Default: '${result_file}'." >&2
	echo "  --ssh-login-key     - SSH login private key file. Default: '${ssh_login_key}'." >&2
	echo "  --tftp-triple       - tftp triple.  File name or 'user:server:root'. Default: '${tftp_triple}'." >&2
	echo "  --test-script          - Test script file. Default: '${test_script}'." >&2
	eval "${old_xtrace}"
}

short_opts="hi:k:m:no:sv"

long_opts="help,initrd:,kernel:,test-machine:,no-known-hosts,out-file:,\
result-file:,systemd-debug,verbose,bmc-host:,relay-server:,result-file:,\
ssh-login-key:,tftp-triple:,test-script:"

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
	-m | --test-machine)
		test_machine="${2}"
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
	--relay-server)
		relay_server="${2}"
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
	--test-script)
		test_script="${2}"
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

test_machine=${test_machine:-"t88"}

host_arch=$(get_arch "$(uname -m)")
start_extra_args=""
out_file=${out_file:-"${test_machine}.out"}
result_file=${result_file:-"${test_machine}-result.txt"}

relay_triple=$(relay_init_triple ${relay_server})
relay_token=$(relay_triple_to_token ${relay_triple})

if [[ ! ${bmc_host} ]]; then
	bmc_host="${test_machine}-bmc"
	echo "${name}: INFO: BMC host: '${bmc_host}'" >&2
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

if [[ ! ${ssh_login_key} ]]; then
	echo "${name}: ERROR: Must provide --ssh-login-key option." >&2
	usage
	exit 1
fi

check_file "${ssh_login_key}"

if [[ ${no_known_hosts} ]]; then
	tftp_upload_extra="--no-known-hosts"
fi

if [[ ${test_script} ]]; then
	check_file "${test_script}"
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

	${SCRIPTS_TOP}/checkin.sh ${checkout_token}

	echo "${name}: ${result}" >&2
}

trap "on_exit 'Done, failed.'" EXIT

tmp_kernel=${kernel}.tmp
test_kernel=${kernel}.${relay_token}

if [[ ! ${systemd_debug} ]]; then
	tmp_kernel=${kernel}
else
	tmp_kernel=${kernel}.tmp

	${SCRIPTS_TOP}/set-systemd-debug.sh \
		--in-file=${kernel} \
		--out-file=${tmp_kernel} \
		--verbose
fi

${SCRIPTS_TOP}/set-relay-triple.sh \
	--relay-triple="${relay_triple}" \
	--kernel=${tmp_kernel} \
	--out-file=${test_kernel} \
	--verbose

if [[ "${tmp_kernel}" != ${kernel} ]]; then
	rm -f ${tmp_kernel}
fi

checkout_token=$(${SCRIPTS_TOP}/checkout.sh -v ${test_machine} 1200) # 20 min.

${SCRIPTS_TOP}/tftp-upload.sh --kernel=${test_kernel} --initrd=${initrd} \
	--ssh-login-key=${ssh_login_key} --tftp-triple=${tftp_triple} \
	--tftp-dest="${test_machine}" ${tftp_upload_extra} --verbose

# ===== secrets section ========================================================
old_xtrace="$(shopt -po xtrace || :)"
set +o xtrace
if [[ ! ${TCI_BMC_CREDS_USR} || ! ${TCI_BMC_CREDS_PSW} ]]; then
	echo "${name}: Using creds file ${test_machine}-bmc-creds" >&2
	check_file "${test_machine}-bmc-creds" ': Need environment variables or credentials file [user:passwd]'
	TCI_BMC_CREDS_USR="$(cat ${test_machine}-bmc-creds | cut -d ':' -f 1)"
	TCI_BMC_CREDS_PSW="$(cat ${test_machine}-bmc-creds | cut -d ':' -f 2)"
fi
if [[ ! ${TCI_BMC_CREDS_USR}  ]]; then
	echo "${name}: ERROR: No TCI_BMC_CREDS_USR defined." >&2
	exit 1
fi
if [[ ! ${TCI_BMC_CREDS_PSW}  ]]; then
	echo "${name}: ERROR: No TCI_BMC_CREDS_PSW defined." >&2
	exit 1
fi
export IPMITOOL_PASSWORD="${TCI_BMC_CREDS_PSW}"
eval "${old_xtrace}"
# ==============================================================================

ping -c 1 -n ${bmc_host}
ipmi_args="-H ${bmc_host} -U ${TCI_BMC_CREDS_USR} -E"

ipmitool ${ipmi_args} chassis status > ${out_file}
echo '-----' >> ${out_file}

ipmitool ${ipmi_args} -I lanplus sol deactivate && result=1

if [[ ${result} ]]; then
	# wait for ipmitool to disconnect.
	sleep 5s
fi

sol_pid_file="$(mktemp --tmpdir tci-sol-pid.XXXX)"

(echo "${BASHPID}" > ${sol_pid_file}; exec sleep 24h) | ipmitool ${ipmi_args} -I lanplus sol activate &>>"${out_file}" &

sol_pid=$(cat ${sol_pid_file})
echo "sol_pid=${sol_pid}" >&2

sleep 5s
if ! kill -0 ${sol_pid} &> /dev/null; then
	echo "${name}: ERROR: ipmitool sol seems to have quit early." >&2
	exit 1
fi

ipmi_power_off "${ipmi_args}"
sleep 5s
ipmi_power_on "${ipmi_args}"

relay_get "420" "${relay_triple}" remote_addr

echo "${name}: remote_addr = '${remote_addr}'" >&2

remote_host="root@${remote_addr}"

# The remote host address could come from DHCP, so don't use known_hosts.
ssh_no_check="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [[ ${test_script} ]]; then
	source "${test_script}"
else
	set +e
	count=0
	timeout=300
	while [[ ${count} -lt ${timeout} ]]; do
		ping -c 1 -n ${remote_addr} || :
		if ssh ${ssh_no_check} -i ${ssh_login_key} ${remote_host} \
			'find /lib/modules -type f | egrep nicvf.ko'
			then break
		fi
		let count=count+10
		sleep 10s
	done
	set -e
	if [[ ${count} -ge ${timeout} ]]; then
		echo "${name}: ERROR: ssh to remote host '${remote_addr}' failed." >&2
		exit 1
	fi
fi

ssh ${ssh_no_check} -i ${ssh_login_key} ${remote_host} \
	'poweroff &'

echo "${name}: Waiting for shutdown at ${remote_addr}..." >&2

ipmi_wait_power_state "${ipmi_args}" 'off' 120

trap - EXIT

on_exit 'Done, success.' ${sol_pid_file} "${ipmi_args}"
