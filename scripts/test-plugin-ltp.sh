# LTP test plug-in.

setup_tests_ltp_alpine() {
	local rootfs=${1}

	enter_chroot ${rootfs} "
		set -e
		apk add libaio-dev
		apk add numactl-dev --repository http://dl-3.alpinelinux.org/alpine/edge/main/ --allow-untrusted
		apk info | sort
	"
}

setup_tests_ltp_debian() {
	local rootfs=${1}

	enter_chroot ${rootfs} "
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get -y install libaio-dev libnuma-dev
	"
}

test_build_ltp() {
	local tests_dir=${1}
	local sysroot=${2}

	local test_name='ltp'
	local src_repo=${ltp_src_repo:-"https://github.com/linux-test-project/ltp.git"}
	local repo_branch=${ltp_repo_branch:-"master"}
	local src_dir="${tests_dir}/${test_name}-src"
	local build_dir="${tests_dir}/${test_name}-build"
	local archive_file="${tests_dir}/${test_name}.tar.gz"
	local results_file="${tests_dir}/${test_name}-results.tar.gz"

	check_directory "${sysroot}"
	rm -rf ${build_dir} ${archive_file} ${results_file}

	if [[ ! -d "${src_dir}" ]]; then
		git clone ${src_repo} "${src_dir}"
	fi

	(cd ${src_dir} && git remote update &&
		git checkout --force ${repo_branch})

	mkdir -p ${build_dir}
	rsync -av --delete --exclude='.git' ${src_dir}/ ${build_dir}/

	pushd ${build_dir}

	if [[ "${host_arch}" != "${target_arch}" ]]; then
		cross_build=1
		case "${target_arch}" in
		amd64)
			# FIXME:
			echo "${FUNCNAME[0]}: ERROR: No amd64 support yet." >&2
			configure_opts='--host=x86_64-linux-gnu ???'
			exit 1
			;;
		arm64)
			configure_opts='--host=aarch64-linux-gnu'
			;;
		esac
	fi

	export SYSROOT="${sysroot}"
	export CPPFLAGS="-I${SYSROOT}/usr/include -I${SYSROOT}/include -I${SYSROOT}"
	export LDFLAGS="-L${SYSROOT}/usr/lib -L${SYSROOT}/lib"
	export DESTDIR="${build_dir}/install"
	export SKIP_IDCHECK=1

	make autotools
	./configure \
		SYSROOT="${sysroot}" \
		CPPFLAGS="-I${SYSROOT}/usr/include -I${SYSROOT}/include -I${SYSROOT}" \
		LDFLAGS="-L${SYSROOT}/usr/lib -L${SYSROOT}/lib" \
		DESTDIR="${build_dir}/install" \
		${configure_opts}
	make
	make DESTDIR="${build_dir}/install" install
	tar -C ${DESTDIR} -czf ${archive_file} .

	popd
}

test_run_ltp() {
	local tests_dir=${1}
	local machine_type=${2}
	local ssh_host=${3}
	local -n _test_run_unixbench__ssh_opts=${4}

	local test_name='ltp'
	local archive_file="${tests_dir}/${test_name}.tar.gz"
	local results_file="${tests_dir}/${test_name}-results.tar.gz"

	echo "INSIDE @${BASH_SOURCE[0]}:${FUNCNAME[0]}@"
	echo "ssh_opts = @${_test_run_unixbench__ssh_opts}@"

	set -x
	rm -rf ${results_file}

	case "${machine_type}" in
	qemu)
		LTP_RUN_OPTS='-b /dev/vda -z /dev/vdb'
		;;
	remote)
		;;
	esac

	#echo "${FUNCNAME[0]}: tests_dir    = @${tests_dir}@"
	#echo "${FUNCNAME[0]}: machine_type = @${machine_type}@"
	#echo "${FUNCNAME[0]}: ssh_host     = @${ssh_host}@"
	#echo "${FUNCNAME[0]}: ssh_opts     = @${ssh_opts}@"
	echo "${FUNCNAME[0]}: archive_file  = @${archive_file}@"
	echo "${FUNCNAME[0]}: LTP_RUN_OPTS  = @${LTP_RUN_OPTS}@"

	scp ${ssh_opts} ${archive_file} ${ssh_host}:ltp.tar.gz

	ssh ${ssh_opts} ${ssh_host} LTP_RUN_OPTS="'${LTP_RUN_OPTS}'" 'sh -s' <<'EOF'
export PS4='+ltp-test-script:${LINENO}: '
set -ex

cat /proc/partitions
printenv

rootfs_type=$(egrep '^ID=' /etc/os-release)
rootfs_type=${rootfs_type#ID=}

## Exclude sshd from oom-killer.
#sshd_pid=$(systemctl show --value -p MainPID ssh)
#if [[ ${sshd_pid} -eq 0 ]]; then
#	exit 1
#fi
#echo -17 > /proc/${sshd_pid}/oom_adj

mkdir -p ltp-test
tar -C ltp-test -xf ltp.tar.gz
cd ./ltp-test/opt/ltp

echo -e "oom01\noom02\noom03\noom04\noom05" > skip-tests
cat skip-tests

cat ./Version

set +e
ls -l ./bin/ltp-pan
ldd ./bin/ltp-pan

./runltp -S skip-tests ${LTP_RUN_OPTS}

result=${?}
set -e

tar -czvf ${HOME}/ltp-results.tar.gz ./output ./results
EOF

	scp ${ssh_opts} ${ssh_host}:ltp-results.tar.gz ${results_file}
}
