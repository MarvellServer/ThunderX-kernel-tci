# UnixBench test plug-in.

unixbench_repo=${unixbench_repo:-"https://github.com/kdlucas/byte-unixbench.git"}
unixbench_branch=${unixbench_branch:-"master"}

setup_tests_unixbench_alpine() {
	local rootfs=${1}

	enter_chroot ${rootfs} "
		set -e
		apk add make perl
		apk info | sort
	"
}

setup_tests_unixbench_debian() {
	local rootfs=${1}

	enter_chroot ${rootfs} "
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get -y install make libperl-dev
	"
}

test_build_unixbench() {
	local tests_dir=${1}
	local sysroot=${2}

	local test_name='unixbench'
	local src_repo=${unixbench_src_repo:-"https://github.com/kdlucas/byte-unixbench.git"}
	local repo_branch=${unixbench_repo_branch:-"master"}
	local src_dir="${tests_dir}/${test_name}-src"
	local build_dir="${tests_dir}/${test_name}-build"
	local archive_file="${tests_dir}/${test_name}.tar.gz"
	local results_file="${tests_dir}/${test_name}-results.tar.gz"

	check_directory "${sysroot}"
	rm -rf ${build_dir} ${archive_file}

	if [[ ! -d "${src_dir}" ]]; then
		git clone ${src_repo} "${src_dir}"
	fi

	(cd ${src_dir} && git remote update &&
		git checkout --force ${repo_branch})

	mkdir -p ${build_dir}
	rsync -av --delete --exclude='.git' ${src_dir}/ ${build_dir}/

	pushd ${build_dir}/UnixBench

	if [[ "${host_arch}" != "${target_arch}" ]]; then
		cross_build=1
		case "${target_arch}" in
		amd64)
			# FIXME:
			echo "${FUNCNAME[0]}: ERROR: No amd64 support yet." >&2
			make_opts='x86_64-linux-gnu-gcc ???'
			exit 1
			;;
		arm64)
			make_opts='CC=aarch64-linux-gnu-gcc'
			;;
		esac
	fi

	export SYSROOT="${sysroot}"
	export CPPFLAGS="-I${SYSROOT}/usr/include -I${SYSROOT}/include -I${SYSROOT}"
	export LDFLAGS="-L${SYSROOT}/usr/lib -L${SYSROOT}/lib"

	make ${make_opts} UB_GCC_OPTIONS='-O3 -ffast-math'

	cd ${build_dir}
	tar -czf ${archive_file} UnixBench

	popd
}

test_run_unixbench() {
	local tests_dir=${1}
	local machine_type=${2}
	local ssh_host=${3}
	local -n _test_run_unixbench__ssh_opts=${4}

	local test_name='unixbench'
	local archive_file="${tests_dir}/${test_name}.tar.gz"
	local results_file="${tests_dir}/${test_name}-results.tar.gz"

	echo "INSIDE @${BASH_SOURCE[0]}:${FUNCNAME[0]}@"
	echo "ssh_opts = @${_test_run_unixbench__ssh_opts}@"

	set -x
	rm -rf ${results_file}

	scp ${ssh_opts} ${archive_file} ${ssh_host}:unixbench.tar.gz

	ssh ${ssh_opts} ${ssh_host} 'sh -s' <<'EOF'
export PS4='+unixbench-test-script:${LINENO}: '
set -ex

cat /proc/partitions
printenv

rootfs_type=$(egrep '^ID=' /etc/os-release)
rootfs_type=${rootfs_type#ID=}

mkdir -p unixbench-test
tar -C unixbench-test -xf unixbench.tar.gz
cd ./unixbench-test/UnixBench

set +e
./Run
result=${?}
set -e

tar -czvf ${HOME}/unixbench-results.tar.gz  ./results
EOF

	scp ${ssh_opts} ${ssh_host}:unixbench-results.tar.gz ${results_file}
}
