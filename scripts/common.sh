#!/usr/bin/env bash

clean_ws() {
	local in="$*"

	shopt -s extglob
	in="${in//+( )/ }" in="${in# }" in="${in% }"
	echo -n "$in"
}

check_directory() {
	local src="${1}"
	local msg="${2}"
	local usage="${3}"

	if [[ ! -d "${src}" ]]; then
		echo "${name}: ERROR: Directory not found${msg}: '${src}'" >&2
		[[ -z "${usage}" ]] || usage
		exit 1
	fi
}

check_file() {
	local src="${1}"
	local msg="${2}"
	local usage="${3}"

	if [[ ! -f "${src}" ]]; then
		echo -e "${name}: ERROR: File not found${msg}: '${src}'" >&2
		[[ -z "${usage}" ]] || usage
		exit 1
	fi
}

copy_file() {
	local src="${1}"
	local dest="${2}"

	check_file ${src}
	run_cmd "cp -f ${src} ${dest}"
}

cpu_count() {
	echo "$(getconf _NPROCESSORS_ONLN || echo 1)"
}

get_user_home() {
	local user=${1}
	local result;

	if ! result="$(getent passwd ${user})"; then
		echo "${name}: ERROR: No home for user '${user}'" >&2
		exit 1
	fi
	echo ${result} | cut -d ':' -f 6
}

get_arch() {
	local a=${1}

	case "${a}" in
	arm64|aarch64) echo "arm64" ;;
	amd64|x86_64)  echo "amd64" ;;
	*)
		echo "${name}: ERROR: Bad arch '${a}'" >&2
		exit 1
		;;
	esac
}

run_cmd() {
	local cmd="${*}"

	if [[ -n ${cmd_trace} ]]; then
		echo "==> ${cmd}"
	fi

	if [[ -n "${dry_run}" ]]; then
		true
	else
		eval "${cmd}"
	fi
}

sudo_write() {
	sudo tee "${1}" >/dev/null
}

sudo_append() {
	sudo tee -a "${1}" >/dev/null
}

find_addr() {
	local hosts_file=${1}
	local host_name=${2}
	local addr="$(dig ${host_name} +short)"

	if [[ ! ${addr} ]]; then
		addr="$(egrep "${host_name}" ${hosts_file} | egrep -o '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || :)"

		if [[ ! ${addr} ]]; then
			echo "${name}: ERROR: ${host_name} DNS entry not found." >&2
			exit 1
		fi
	fi
	echo ${addr}
}

my_addr() {
	ip route get 8.8.8.8 | egrep -o 'src [0-9.]*' | cut -f 2 -d ' '
}

sec_to_min() {
	local t=${1}
	echo "scale=2; ${t}/60" | bc -l | sed 's/^\./0./'
}

if [[ -n "${JENKINS_URL}" ]]; then
	export PS4='+$(basename ${BASH_SOURCE}):${LINENO}:'
else
	export PS4='\[\033[0;33m\]+$(basename ${BASH_SOURCE}):${LINENO}: \[\033[0;37m\]'
fi

MODULES_ID=${MODULES_ID:="kernel_modules"}
TARGET_HOSTNAME=${TARGET_HOSTNAME:="tci-tester"}
