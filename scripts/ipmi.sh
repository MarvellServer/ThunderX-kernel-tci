#!/usr/bin/env bash

# ipmi library routines.

ipmi_get_power_status() {
	local ipmi_args="${1}"

	#echo "*** ipmi_args = @${ipmi_args} @" >&2
	local msg="$(ipmitool ${ipmi_args} power status)"

	case ${msg: -3} in
	' on')
		echo 'on'
		;;
	'off')
		echo 'off'
		;;
	*)
		echo "${name}: ERROR: Bad ipmi message '${msg}'" >&2
		exit 1
		;;
	esac
}

ipmi_wait_power_state() {
	local ipmi_args="${1}"
	local state="${2}"

	#echo "*** ipmi_args = @${ipmi_args} @" >&2

	while [[ $(ipmi_get_power_status "${ipmi_args}") != "${state}" ]]; do
		let count=count+5
		if [[ count -gt 60 ]]; then
			echo "${name}: ipmi_wait_power_state '${state}' ${ipmi_args} failed."
			exit -1
		fi
		sleep 5s
	done
}

ipmi_set_power_state() {
	local ipmi_args="${1}"
	local state="${2}"

	#echo "*** ipmi_args = @${ipmi_args} @" >&2

	ipmitool ${ipmi_args} power ${state}
	ipmi_wait_power_state "${ipmi_args}" "${state}"
}

ipmi_power_on() {
	local ipmi_args="${1}"

	#echo "*** ipmi_args = @${ipmi_args} @" >&2
	ipmi_set_power_state "${ipmi_args}" 'on'
}

ipmi_power_off() {
	local ipmi_args="${1}"

	#echo "*** ipmi_args = @${ipmi_args} @" >&2
	ipmi_set_power_state "${ipmi_args}"  'off'
}
