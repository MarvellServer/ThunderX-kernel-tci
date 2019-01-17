#!/usr/bin/env bash

# TCI relay client library routines.

relay_double_to_server() {
	echo ${1} | cut -d ':' -f 1
}

relay_double_to_port() {
	echo ${1} | cut -d ':' -f 2
}

relay_test_triple() {
	[[ ${1} =~ .:[[:digit:]]{3,5}:. ]]
}

relay_verify_triple() {
	local triple=${1}

	if ! relay_test_triple ${triple}; then
		echo "${name}: ERROR: Bad triple: '${triple}'" >&2
		exit 1
	fi
}

relay_make_random_triple() {
	local server=${1}
	local port=${2}

	: ${server:=${TCI_RELAY_SERVER}}
	: ${port:=${TCI_RELAY_PORT}}

	echo "${server}:${port}:$(cat /proc/sys/kernel/random/uuid)"
}

relay_triple_to_server() {
	local triple=${1}

	relay_verify_triple ${triple}
	echo ${triple} | cut -d ':' -f 1
}

relay_triple_to_port() {
	local triple=${1}

	relay_verify_triple ${triple}
	echo ${triple} | cut -d ':' -f 2
}

relay_triple_to_token() {
	local triple=${1}

	relay_verify_triple ${triple}
	echo ${triple} | cut -d ':' -f 3
}

relay_split_triple() {
	local triple=${1}
	local -n _ph1_server=${2}
	local -n _ph1_port=${3}
	local -n _ph1_token=${4}

	relay_verify_triple ${triple}

	_ph1_server="$(echo ${triple} | cut -d ':' -f 1)"
	_ph1_port="$(echo ${triple} | cut -d ':' -f 2)"
	_ph1_token="$(echo ${triple} | cut -d ':' -f 3)"
}

relay_split_reply() {
	local reply=${1}
	local -n _ph2_cmd=${2}
	local -n _ph2_data=${3}

	_ph2_cmd="$(echo ${reply} | cut -d ':' -f 1)"
	_ph2_data="$(echo ${reply} | cut -d ':' -f 2)"
}

relay_get() {
	local timeout=${1}
	local triple=${2}
	local -n _ph3_remote_addr=${3}

	local server
	local port
	local token
	relay_split_triple ${triple} server port token

	echo "${name}: relay client: Waiting ${timeout}s for msg at ${server}:${port}..." >&2

	SECONDS=0
	local reply_msg
	local reply_result

	#timeout="3s" # FIXME: For debug.
	set +e
	reply_msg="$(echo -n "GET:${token}" | netcat -w${timeout} ${server} ${port})"
	reply_result=${?}
	set -e

	local boot_time="$(sec_to_min ${SECONDS})"

	echo "${name}: reply_result='${reply_result}'" >&2
	echo "${name}: reply_msg='${reply_msg}'" >&2

	if [[ ${reply_result} -eq 124 || ! ${reply_msg} ]]; then
		echo "${name}: relay_get failed: timed out ${timeout}" >&2
		return 1
	fi

	if [[ ${reply_result} -ne 0 ]]; then
		echo "${name}: relay_get failed: command failed: ${reply_result}" >&2
		return ${reply_result}
	fi

	if [[ ${reply_result} -ne 0 ]]; then
		echo "${name}: relay_get failed: command failed: ${reply_result}" >&2
		return ${reply_result}
	fi

	echo "${name}: reply_msg='${reply_msg}'" >&2
	local cmd
	relay_split_reply ${reply_msg} cmd _ph3_remote_addr

	if [[ "${cmd}" != 'OK-' ]]; then
		echo "${name}: relay_get failed: ${reply_msg}" >&2
		_ph3_remote_addr="server-error"
		return 1
	fi

	echo "${name}: Received msg from '${_ph3_remote_addr}" >&2
	echo "${name}: ${_ph3_remote_addr} boot time = ${boot_time} min" >&2
}

TCI_RELAY_SERVER=${TCI_RELAY_SERVER:="tci-relay"}
TCI_RELAY_PORT=${TCI_RELAY_PORT:="9600"}
