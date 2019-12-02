#!/usr/bin/env bash

clean_ws() {
	local in="$*"

	shopt -s extglob
	in="${in//+( )/ }" in="${in# }" in="${in% }"
	echo -n "$in"
}

substring_has() {
	local string=${1}
	local substring=${2}

	[ -z "${string##*${substring}*}" ];
}

substring_begins() {
	local string=${1}
	local substring=${2}

	[ -z "${string##${substring}*}" ];
}

substring_ends() {
	local string=${1}
	local substring=${2}

	[ -z "${string##*${substring}}" ];
}

strip_current() {
	local path=${1}

	if [[ ! ${CURRENT_WORK_DIR} ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad CURRENT_WORK_DIR" >&2
		exit 1
	fi

	if ! substring_begins ${path} ${CURRENT_WORK_DIR}; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad path: '${path}'" >&2
		exit 1
	fi

	echo "${path#${CURRENT_WORK_DIR}}"
}

to_host() {
	local path=${1}

	if [[ ! ${HOST_WORK_DIR} ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad HOST_WORK_DIR" >&2
		exit 1
	fi

	echo "${HOST_WORK_DIR}$(strip_current ${path})"
}

sec_to_min() {
	local sec=${1}
	local min="$((sec / 60))"
	local frac="$(((sec * 100) / 60))"
	local len=${#frac}

	if [[ ${len} -eq 1 ]]; then
		frac="0${frac}"
	elif [[ ${len} -gt 2 ]]; then
		frac=${frac:(-2)}
	fi
	echo "${min}.${frac}"
}

sec_to_min_bc() {
	local sec=${1}
	echo "scale=2; ${sec}/60" | bc -l | sed 's/^\./0./'
}

directory_size_bytes() {
	local dir=${1}

	local size="$(du -sb ${dir})"
	echo ${size%%[[:space:]]*}
}

directory_size_human() {
	local dir=${1}

	local size
	size="$(du -sh ${dir})"
	echo ${size%%[[:space:]]*}
}

check_directory() {
	local src="${1}"
	local msg="${2}"
	local usage="${3}"

	if [[ ! -d "${src}" ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Directory not found${msg}: '${src}'" >&2
		[[ -z "${usage}" ]] || usage
		exit 1
	fi
}

check_file() {
	local src="${1}"
	local msg="${2}"
	local usage="${3}"

	if [[ ! -f "${src}" ]]; then
		echo -e "${script_name}: ERROR: File not found${msg}: '${src}'" >&2
		[[ -z "${usage}" ]] || usage
		exit 1
	fi
}

check_opt() {
	option=${1}
	shift
	value=${@}

	if [[ ! ${value} ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Must provide --${option} option." >&2
		usage
		exit 1
	fi
}

relative_path_2() {
	local base="${1}"
	local target="${2}"
	local root="${3}"

	base="${base##${root}}"
	base="${base%%/}"
	base=${base%/*}
	target="${target%%/}"

	local back=""
	while :; do
		set +x
		echo "target: ${target}" >&2
		echo "base:   ${base}" >&2
		echo "back:   ${back}" >&2
		set -x
		if [[ "${base}" == "/" || ! ${base} ]]; then
			break
		fi
		back+="../"
		if [[ "${target}" == ${base}/* ]]; then
			break
		fi
		base=${base%/*}
	done

	echo "${back}${target##${base}/}"
}

relative_path() {
	local base="${1}"
	local target="${2}"
	local root="${3}"

	base="${base##${root}}"
	base="${base%%/}"
	base=${base%/*}
	target="${target%%/}"

	local back=""
	while :; do
		#echo "target: ${target}" >&2
		#echo "base:   ${base}" >&2
		#echo "back:   ${back}" >&2
		if [[ "${base}" == "/" || "${target}" == ${base}/* ]]; then
			break
		fi
		back+="../"
		base=${base%/*}
	done

	echo "${back}${target##${base}/}"
}

copy_file() {
	local src="${1}"
	local dest="${2}"

	check_file ${src}
	cp -f ${src} ${dest}
}

cpu_count() {
	echo "$(getconf _NPROCESSORS_ONLN || echo 1)"
}

get_user_home() {
	local user=${1}
	local result;

	if ! result="$(getent passwd ${user})"; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): No home for user '${user}'" >&2
		exit 1
	fi
	echo ${result} | cut -d ':' -f 6
}

get_arch() {
	local a=${1}

	case "${a}" in
	arm64|aarch64)			echo "arm64" ;;
	amd64|x86_64)			echo "amd64" ;;
	ppc|powerpc|ppc32|powerpc32)	echo "ppc32" ;;
	ppc64|powerpc64)		echo "ppc64" ;;
	ppc64le|powerpc64le)		echo "ppc64le" ;;
	*)
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad arch '${a}'" >&2
		exit 1
		;;
	esac
}

get_triple() {
	local a=${1}

	case "${a}" in
	amd64)		echo "x86_64-linux-gnu" ;;
	arm64)		echo "aarch64-linux-gnu" ;;
	ppc32)		echo "powerpc-linux-gnu" ;;
	ppc64)		echo "powerpc64-linux-gnu" ;;
	ppc64le)	echo "powerpc64le-linux-gnu" ;;
	*)
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad arch '${a}'" >&2
		exit 1
		;;
	esac
}

kernel_arch() {
	local a=${1}

	case "${a}" in
	amd64)		echo "x86_64" ;;
	arm64*)		echo "arm64" ;;
	ppc*)		echo "powerpc" ;;
	*)
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad arch '${a}'" >&2
		exit 1
		;;
	esac
}

sudo_write() {
	sudo tee "${1}" >/dev/null
}

sudo_append() {
	sudo tee -a "${1}" >/dev/null
}

is_ip_addr() {
	local host=${1}
	local regex_ip="[[:digit:]]{1,3}\.[[:digit:]]{1,3}{3}"

	[[ "${host}" =~ ${regex_ip} ]]
}

find_addr() {
	local -n _find_addr__addr=${1}
	local hosts_file=${2}
	local host=${3}

	_find_addr__addr=""

	if is_ip_addr ${host}; then
		_find_addr__addr=${host}
		return
	fi

	if [[ ! -x "$(command -v dig)" ]]; then
		echo "${script_name}: WARNING: Please install dig (dnsutils)." >&2
	else
		_find_addr__addr="$(dig ${host} +short)"
	fi

	if [[ ! ${_find_addr__addr} ]]; then
		_find_addr__addr="$(egrep -m 1 "${host}[[:space:]]*$" ${hosts_file} \
			| egrep -o '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || :)"

		if [[ ! ${_find_addr__addr} ]]; then
			echo "${script_name}: ERROR (${FUNCNAME[0]}): '${host}' DNS entry not found." >&2
			exit 1
		fi
	fi
}

my_addr() {
	ip route get 8.8.8.8 | egrep -o 'src [0-9.]*' | cut -f 2 -d ' '
}

wait_pid() {
	local pid="${1}"
	local timeout_sec=${2}
	timeout_sec=${timeout_sec:-300}

	echo "${script_name}: INFO: Waiting ${timeout_sec}s for pid ${pid}." >&2

	let count=1
	while kill -0 ${pid} &> /dev/null; do
		let count=count+5
		if [[ count -gt ${timeout_sec} ]]; then
			echo "${script_name}: ERROR (${FUNCNAME[0]}): wait_pid failed for pid ${pid}." >&2
			exit -1
		fi
		sleep 5s
	done
}

git_get_repo_name() {
	local repo=${1}

	if [[ "${repo: -1}" == "/" ]]; then
		repo=${repo:0:-1}
	fi

	local repo_name="${repo##*/}"

	if [[ "${repo_name:0:1}" == "." ]]; then
		repo_name="${repo%/.*}"
		repo_name="${repo_name##*/}"
		echo "${repo_name}"
		return
	fi

	repo_name="${repo_name%.*}"

	if [[ -z "${repo_name}" ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad repo: '${repo}'" >&2
		exit 1
	fi

	echo "${repo_name}"
}

git_set_remote() {
	local dir=${1}
	local repo=${2}
	local remote

	remote="$(git -C ${dir} remote -v | egrep 'origin' | cut -f2 | cut -d ' ' -f1)"

	if [[ ${?} -ne 0 ]]; then
		echo "${script_name}: ERROR (${FUNCNAME[0]}): Bad git repo ${dir}." >&2
		exit 1
	fi

	if [[ ${remote} != ${repo} ]]; then
		echo "${script_name}: INFO: Switching git remote ${remote} => ${repo}." >&2
		git -C ${dir} remote set-url origin ${repo}
		git -C ${dir} remote -v
	fi
}

git_checkout_force() {
	local dir=${1}
	local repo=${2}
	local branch=${3:-'master'}

	if [[ ! -d "${dir}" ]]; then
		mkdir -p "${dir}/.."
		git clone "${repo}" "${dir}"
	fi

	git_set_remote "${dir}" "${repo}"
	git -C "${dir}" remote update -p
	git -C "${dir}" checkout --force "${branch}"
	git -C "${dir}" pull "${repo}" "${branch}"
	git -C "${dir}" status
}

git_checkout_safe() {
	local dir=${1}
	local repo=${2}
	local branch=${3:-'master'}

	if [[ -e "${dir}" ]]; then
		if [[ ! -e "${dir}/.git/config" ]]; then
			mv "${dir}" "${dir}.backup-$(date +%Y.%m.%d-%H.%M.%S)"
		elif ! git -C "${dir}" status --porcelain; then
			echo "${script_name}: INFO: Local changes: ${dir}." >&2
			cp -a --link "${dir}" "${dir}.backup-$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	fi

	git_checkout_force "${dir}" "${repo}" "${branch}"
}

run_shellcheck() {
	local file=${1}

	shellcheck=${shellcheck:-"shellcheck"}

	if ! test -x "$(command -v "${shellcheck}")"; then
		echo "${script_name}: ERROR: Please install '${shellcheck}'." >&2
		exit 1
	fi

	${shellcheck} "${file}"
}

if [[ ${PS4} == '+ ' ]]; then
	if [[ ${JENKINS_URL} ]]; then
		export PS4='+ [${STAGE_NAME}] \${BASH_SOURCE##*/}:\${LINENO}: '
	else
		export PS4='\[\033[0;33m\]+ ${BASH_SOURCE##*/}:${LINENO}:(${FUNCNAME[0]:-"?"}): \[\033[0;37m\]'
	fi
fi
