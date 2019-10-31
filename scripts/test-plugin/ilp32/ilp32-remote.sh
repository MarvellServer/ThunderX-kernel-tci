export PS4='+ ilp32-test-script:${LINENO}: '

set -ex

mkdir -p /ilp32-test
tar -C /ilp32-test -xf /ilp32-archive.tar.gz
cd /ilp32-test
ls -l

service docker start

/ilp32-test/???/scripts/build-docker-image.sh -f --runner

mkdir -p ./results

printenv | tee ./results/printenv.log

tar -czvf ${HOME}/ilp32-results.tar.gz  ./results
