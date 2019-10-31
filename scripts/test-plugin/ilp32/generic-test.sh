TEST_NAME=${TEST_NAME:-"${1}"}

export PS4='+ ilp32-${TEST_NAME}:${LINENO}: '
set -ex

test_home="/ilp32-${TEST_NAME}"
mkdir -p ${test_home}
cd ${test_home}

results_dir=${test_home}/results
mkdir -p ${results_dir}

log_file=${results_dir}/test.log
rm -f ${log_file}

date | tee -a ${log_file}
echo '-----------------------------' | tee -a ${log_file}
printenv | tee -a ${log_file}
uname -a | tee -a ${log_file}

tar -C ${test_home} -xf /ilp32-${TEST_NAME}-archive.tar.gz

echo '-----------------------------' | tee -a ${log_file}
echo 'ilp32-libraries info' | tee -a ${log_file}
cat ${test_home}/${TEST_NAME}/ilp32-libraries/opt/ilp32/info.txt | tee -a ${log_file}
echo '-----------------------------' | tee -a ${log_file}
find . -type f | tee -a ${log_file}
echo '-----------------------------' | tee -a ${log_file}

rootfs_type=$(egrep '^ID=' /etc/os-release)
rootfs_type=${rootfs_type#ID=}

mkdir -p /opt/ilp32/
cp -av ${test_home}/${TEST_NAME}/ilp32-libraries/opt/ilp32/* /opt/ilp32/

LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64-static || :
LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32-static || :

file /opt/ilp32/lib64/ld-2.30.so || :
/opt/ilp32/lib64/ld-2.30.so --help || :
/opt/ilp32/lib64/ld-2.30.so --list ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64 || :
LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--lp64 || :

file /opt/ilp32/libilp32/ld-2.30.so || :
/opt/ilp32/libilp32/ld-2.30.so --help || :
/opt/ilp32/libilp32/ld-2.30.so --list ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32 || :
LD_SHOW_AUXV=1 ${test_home}/${TEST_NAME}/${TEST_NAME}--ilp32 || :

tar -czvf ${HOME}/ilp32-results.tar.gz ${results_dir}
