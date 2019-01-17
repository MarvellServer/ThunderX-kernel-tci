#!/usr/bin/env bash

set -e

name="$(basename $0)"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/common.sh

DOCKER_TOP=${DOCKER_TOP:="$( cd "${SCRIPTS_TOP}/../docker" && pwd )"}
DOCKER_TAG=${DOCKER_TAG:="$("${DOCKER_TOP}/builder/build-builder.sh" --tag)"}

usage () {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Runs a tci container.  If no command is provided, runs an interactive container." >&2
	echo "Usage: ${name} [flags] -- [command] [args]" >&2
	echo "Option flags:" >&2
	echo "  -a --docker-args    - Args for docker run. Default: '${docker_args}'" >&2
	echo "  -d --dry-run        - Do not run build commands." >&2
	echo "  -h --help           - Show this help and exit." >&2
	echo "  -n --container-name - Container name. Default: '${container_name}'." >&2
	echo "  -s --no-sudoers     - Do not setup sudoers." >&2
	echo "  -t --tag            - Print Docker tag to stdout and exit." >&2
	echo "  -v --verbose        - Verbose execution." >&2
	echo "Args:" >&2
	echo "  command             - Default: '${user_cmd}'" >&2
	echo "Environment:" >&2
	echo "  DOCKER_TAG          - Default: '${DOCKER_TAG}'" >&2
	echo "Examples:" >&2
	echo "  ${name} -v" >&2
	eval "${old_xtrace}"
}

short_opts="a:dhn:stv"
long_opts="docker-args:,dry-run,help,container-name:,no-sudoers,tag,verbose"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

if [ $? != 0 ]; then
	echo "${name}: ERROR: Internal getopt" >&2
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-a | --docker-args)
		docker_args="${2}"
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
	-n | --container-name)
		container_name="${2}"
		shift 2
		;;
	-s | --no-sudoers)
		no_sudoers=1
		shift
		;;
	-t | --tag)
		tag=1
		shift
		;;
	-v | --verbose)
		set -x
		verbose=1
		shift
		;;
	--)
		shift
		user_cmd="${@}"
		break
		;;
	*)
		echo "${name}: ERROR: Internal opts: '${@}'" >&2
		exit 1
		;;
	esac
done

cmd_trace=1
docker_extra_args=""

if [[ -z "${container_name}" ]]; then
	container_name="tci"
fi

if [[ -z "${user_cmd}" ]]; then
	user_cmd="/bin/bash"
fi

if [[ -n "${usage}" ]]; then
	usage
	exit 0
fi

if [[ -n "${tag}" ]]; then
	show_tag
	exit 0
fi

if [[ $(echo "${docker_args}" | egrep ' -w ') ]]; then
	docker_extra_args+=" -v $(pwd):/work -w /work"
fi

relay_server="tci-relay"
tftp_server="tci-tftp"
bmc_host="t88-bmc"


relay_addr=$(find_addr /etc/hosts ${relay_server})

if [[ ${relay_addr} ]]; then
	docker_extra_args+=" --add-host='${relay_server}:${relay_addr}'"
else
	echo "${name}: WARNING: '${relay_server}' address not found." >&2
fi

tftp_addr=$(find_addr /etc/hosts ${tftp_server})

if [[ ${tftp_addr} ]]; then
	docker_extra_args+=" --add-host='${tftp_server}:${tftp_addr}'"
else
	echo "${name}: WARNING: '${tftp_server}' address not found." >&2
fi

bmc_addr=$(find_addr /etc/hosts ${bmc_host})

if [[ ${bmc_addr} ]]; then
	docker_extra_args+=" --add-host='${bmc_host}:${bmc_addr}'"
else
	echo "${name}: WARNING: '${bmc_host}' address not found." >&2
fi

if [[ ! ${no_sudoers} ]]; then
	docker_extra_args+=" \
	-u $(id --user --real):$(id --group --real) \
	-v /etc/group:/etc/group:ro \
	-v /etc/passwd:/etc/passwd:ro \
	-v /etc/shadow:/etc/shadow:ro \
	-v /etc/sudoers.d:/etc/sudoers.d:ro"
fi

run_cmd "docker run \
	--name ${container_name} \
	--hostname ${container_name} \
	--rm \
	 -it \
	--privileged \
	${docker_extra_args} \
	${docker_args} \
	${DOCKER_TAG} \
	${user_cmd}"
