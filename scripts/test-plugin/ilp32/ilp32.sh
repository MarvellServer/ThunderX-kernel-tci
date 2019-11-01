#!/usr/bin/env bash
#
# ILP32 hello world test plug-in.

test_usage_ilp32() {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "  ${BASH_SOURCE##*/} - Build and run ILP32 hello world program." >&2
	eval "${old_xtrace}"
}

test_packages_ilp32() {
	local rootfs_type=${1}
	local target_arch=${2}

	case "${rootfs_type}-${target_arch}" in
	alpine-*)
		;;
	debian-*)
		;;
	*)
		;;
	esac
	echo ""
}

test_setup_ilp32() {
	return
}

test_build_ilp32() {
	local rootfs_type=${1}
	local tests_dir=${2}
	mkdir -p ${tests_dir}
	tests_dir="$(cd ${tests_dir} && pwd)"
	local sysroot="$(cd ${3} && pwd)"
	local kernel_src_dir="$(cd ${4} && pwd)"

	local test_name='ilp32'
	local src_repo=${ilp32_src_repo:-"https://github.com/glevand/ilp32--builder.git"}
	local repo_branch=${ilp32_repo_branch:-"master"}
	local src_dir="${tests_dir}/${test_name}-src"
	local build_dir="${tests_dir}/${test_name}-build"
	#local archive_file="${tests_dir}/${test_name}-archive.tar.gz"
	local results_file="${tests_dir}/${test_name}-results.tar.gz"
	local ilp32_libs_file="${tests_dir}/ilp32-libraries.tar.gz"
	local tool_prefix="/opt/ilp32"

	rm -rf ${build_dir} ${results_file} ${tests_dir}/${test_name}*-archive.tar.gz

	# FIXME: For debug.
	#src_repo="/tci--test/ilp32--builder.git-copy"

	git_checkout_safe ${src_dir} ${src_repo} ${repo_branch}

	mkdir -p ${build_dir}
	pushd ${build_dir}

	# FIXME: For debug.
	#force_toolup="--force"
	#force_builder="--force"
	#force_runner="--force"

	${src_dir}/scripts/build-docker-image.sh \
		--build-top=${build_dir}/toolchain \
		${force_toolup} \
		--toolup

	${src_dir}/scripts/build-docker-image.sh \
		--build-top=${build_dir}/toolchain \
		${force_builder} \
		--builder

	# FIXME: check this...
	if [[ -d ${build_dir}/toolchain ]]; then
		cp -vf --link ${build_dir}/toolchain/ilp32-toolchain-*.tar.gz ${tests_dir}/
		# FIXME: Need this???
		cp -vf --link ${build_dir}/toolchain/ilp32-libraries-*.tar.gz ${tests_dir}/
	fi

	if [[ ${host_arch} == ${target_arch} ]]; then
		${src_dir}/scripts/build-docker-image.sh \
			--build-top=${build_dir}/toolchain \
			${force_runner} \
			--runner
	fi

	HOST_WORK_DIR=${HOST_WORK_DIR} ${src_dir}/scripts/build-test-program.sh \
		--src-top=${src_dir}/tests/hello-world \
		--build-top=${build_dir}/tests/hello-world \
		--prefix=${tool_prefix}

	# FIXME: Need this???
	tar -vczf ${tests_dir}/ilp32-libraries.tar.gz \
		-C ${build_dir}/tests/hello-world/ilp32-libraries ${tool_prefix#/}

	tar -vczf ${tests_dir}//ilp32-hello-world-archive.tar.gz \
		-C ${build_dir}/tests hello-world \
		-C ${src_dir} docker scripts

	HOST_WORK_DIR=${HOST_WORK_DIR} ${src_dir}/scripts/build-test-program.sh \
		--src-top=${src_dir}/tests/vdso-test \
		--build-top=${build_dir}/tests/vdso-test \
		--prefix=${tool_prefix}

	tar -vczf ${tests_dir}/ilp32-vdso-test-archive.tar.gz \
		-C ${build_dir}/tests vdso-test \
		-C ${src_dir} docker scripts

	popd
	echo "${FUNCNAME[0]}: Done, success." >&2
}

ilp32_run_sub_test() {
	local sub_test=${1}

	local archive_file="${tests_dir}/${test_name}-${sub_test}-archive.tar.gz"
	local results_file="${tests_dir}/${test_name}-${sub_test}-results.tar.gz"
	local remote_results_file="/${test_name}-${sub_test}-results.tar.gz"

	rm -rf ${results_file}

	scp ${ssh_opts} ${archive_file} ${ssh_host}:/
	scp ${ssh_opts} ${TEST_TOP}/generic-test.sh ${ssh_host}:/
	ssh ${ssh_opts} ${ssh_host} chmod +x /generic-test.sh
	ssh ${ssh_opts} ${ssh_host} "TEST_NAME=${sub_test} sh -c 'ls -l / && env'"

	set +e
	timeout ${timeout} ssh ${ssh_opts} ${ssh_host} \
		"TEST_NAME=${sub_test} RESULTS_FILE=${remote_results_file} sh -c '/generic-test.sh'"
	result=${?}
	set -e

	if [[ ${result} -eq 124 ]]; then
		echo "${FUNCNAME[0]}: Done, ${test_name}-${sub_test} failed: timeout." >&2
	elif [[ ${result} -ne 0 ]]; then
		echo "${FUNCNAME[0]}: Done, ${test_name}-${sub_test} failed: '${result}'." >&2
	else
		echo "${FUNCNAME[0]}: Done, ${test_name}-${sub_test} success." >&2
	fi

	scp ${ssh_opts} ${ssh_host}:${remote_results_file} ${results_file}
}

test_run_ilp32() {
	local tests_dir="$(cd ${1} && pwd)"
	local machine_type=${2}
	local ssh_host=${3}
	local -n _test_run_ilp32__ssh_opts=${4}
	local ssh_opts="${_test_run_ilp32__ssh_opts}"

	local test_name='ilp32'
	local src_repo=${ilp32_src_repo:-"https://github.com/glevand/ilp32--builder.git"}
	local repo_branch=${ilp32_repo_branch:-"master"}
	local src_dir="${tests_dir}/${test_name}-src"
	local build_dir="${tests_dir}/${test_name}-build"
	local timeout=${ilp32_timeout:-"5m"}

	echo "INSIDE @${BASH_SOURCE[0]}:${FUNCNAME[0]}@"
	echo "ssh_opts = @${ssh_opts}@"

	set -x

	ilp32_run_sub_test "hello-world"
	ilp32_run_sub_test "vdso-test"
}

SCRIPTS_TOP=${SCRIPTS_TOP:-"$(cd "${BASH_SOURCE%/*}/.." && pwd)"}
source ${SCRIPTS_TOP}/lib/util.sh

TEST_TOP=${TEST_TOP:-"$(cd "${BASH_SOURCE%/*}" && pwd)"}
