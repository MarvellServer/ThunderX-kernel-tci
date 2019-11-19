#!/usr/bin/env sh
#
# generic test driver

on_exit() {
	local result=${1}

	tar -czvf ${RESULTS_FILE} ${results_dir}

	echo "ilp32-${TEST_NAME}: Done: ${result}" >&2
}

script_name="${0##*/}"
TEST_NAME=${TEST_NAME:-"${1}"}

export PS4='+ ilp32-${TEST_NAME}: '
set -x

trap "on_exit 'failed.'" EXIT
set -e

test_home="/ilp32-${TEST_NAME}"
mkdir -p ${test_home}
cd ${test_home}

results_dir=${test_home}/results
mkdir -p ${results_dir}

log_file=${results_dir}/test.log
rm -f ${log_file}

rootfs_type=$(egrep '^ID=' /etc/os-release)
rootfs_type=${rootfs_type#ID=}

{
	echo '-----------------------------'
	echo -n 'date: '
	date
	echo -n 'uname: '
	uname -a
	echo "test name: ${TEST_NAME}"
	echo "rootfs_type: ${rootfs_type}"
	echo '-----------------------------'
	echo 'os-release:'
	cat /etc/os-release
	echo '-----------------------------'
	echo 'env:'
	env
	echo '-----------------------------'
	echo 'set:'
	set
} 2>&1 | tee -a ${log_file}

tar -C ${test_home} -xf /ilp32-${TEST_NAME}-archive.tar.gz
mkdir -p /opt/ilp32/
cp -a ${test_home}/${TEST_NAME}/ilp32-libraries/opt/ilp32/* /opt/ilp32/

{
	echo '-----------------------------'
	echo 'ilp32-libraries info:'
	cat ${test_home}/${TEST_NAME}/ilp32-libraries/opt/ilp32/info.txt
	echo '-----------------------------'
	echo 'manifest:'
	find . -type f -exec ls -l {} \;
	echo '-----------------------------'
} 2>&1 | tee -a ${log_file}

run_test_progs() {
	set +e
	{
		echo 'test results:'

		LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64-static
		LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32-static

		echo '-----------------------------'
		echo "strace (${TEST_NAME}--ilp32-static):"
		strace ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32-static
		echo '-----------------------------'

		ls -l /opt/ilp32/lib64/ld-2.30.so
		file /opt/ilp32/lib64/ld-2.30.so
		#/opt/ilp32/lib64/ld-2.30.so --list ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64
		LD_TRACE_LOADED_OBJECTS=1 LD_VERBOSE=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64
		LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64
		LD_DEBUG=libs ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64

		ls -l /opt/ilp32/libilp32/ld-2.30.so
		file /opt/ilp32/libilp32/ld-2.30.so
		#/opt/ilp32/libilp32/ld-2.30.so --list ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32
		LD_TRACE_LOADED_OBJECTS=1 LD_VERBOSE=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32
		LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32
		LD_DEBUG=libs ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32

		echo '-----------------------------'
		echo "strace (${TEST_NAME}--ilp32):"
		strace ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32
		echo '-----------------------------'

	} 2>&1 | tee -a ${log_file}

	result=${?}
	set -e
}


ulimit -s
run_test_progs

ulimit -s unlimited
ulimit -s
run_test_progs



if grep "Segmentation fault" ${log_file}; then
	echo "ilp32-${TEST_NAME}: ERROR: Segmentation fault detected." >&2
	exit 1
fi

trap "on_exit 'Success.'" EXIT
exit 0
