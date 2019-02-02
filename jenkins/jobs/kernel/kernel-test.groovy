#!groovy
// Runs tests on a Linux kernel git repository.
//
// The `jenkins` user must be in the `docker` user group.
// Requires nodes with labels: `amd64`, `arm64`, `docker`.

script {
    library identifier: "thunderx-ci@master", retriever: legacySCM(scm)
}

boolean cacheFoundBootstrap = false
boolean cacheFoundKernel = false
boolean cacheFoundImage = false

pipeline {
    parameters {
        booleanParam(name: 'DOCKER_PURGE',
            defaultValue: false,
            description: 'Remove existing tci builder image and rebuild.')
        string(name: 'KERNEL_CONFIG_URL',
            defaultValue: '',
            description: 'URL of an alternate kernel config.')
        string(name: 'KERNEL_GIT_BRANCH',
            defaultValue: 'master',
            description: 'Branch or tag of KERNEL_GIT_URL.')
        string(name: 'KERNEL_GIT_URL',
            defaultValue: 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git',
            description: 'URL of a Linux kernel git repository.')
        choice(name: 'NODE_ARCH',
            choices: "amd64\narm64",
            description: 'Jenkins node architecture to build on.')
        choice(name: 'ROOTFS_TYPE',
               choices: "debian\nalpine",
               description: 'Rootfs type to build.')
        booleanParam(name: 'RUN_QEMU_TESTS',
            defaultValue: true,
            description: 'Run kernel tests in QEMU emulator.')
        booleanParam(name: 'RUN_REMOTE_TESTS',
            defaultValue: false,
            description: 'Run kernel tests on remote test machine.')
        booleanParam(name: 'SYSTEMD_DEBUG',
            defaultValue: false,
            description: 'Run kernel with systemd debug flags.')
        choice(name: 'TARGET_ARCH',
            choices: "arm64\namd64\nppc64le",
            description: 'Target architecture to build for.')
        booleanParam(name: 'USE_BOOTSTRAP_CACHE',
            defaultValue: true,
            description: '[debugging] Use cached rootfs bootstrap image.')
        booleanParam(name: 'USE_IMAGE_CACHE',
            defaultValue: false,
            description: '[debugging] Use cached rootfs disk image.')
        booleanParam(name: 'USE_KERNEL_CACHE',
            defaultValue: false,
            description: '[debugging] Use cached kernel build.')
        choice(name: 'AGENT',
               choices: "master\nlab2\nsaber25\ntci2\ntci3",
               description: '[debugging] Which Jenkins agent to use.')
        choice(name: 'TEST_MACHINE',
               choices: "gbt2s18\ngbt2s19\nsaber25\nt88",
               description: 'Remote machine to run tests on.')
        string(name: 'PIPELINE_BRANCH',
               defaultValue: 'master',
               description: 'Branch to use for fetching the pipeline jobs')
    }

    options {
        // Timeout if no node available.
        timeout(time: 90, unit: 'MINUTES')
        //timestamps()
        buildDiscarder(logRotator(daysToKeepStr: '30', numToKeepStr: '10'))
    }

    environment {
        String tciStorePath = sh(
            returnStdout: true,
            script: "set -x; \
if [ \${TCI_STORE} ]; then \
    echo -n \${TCI_STORE}; \
else \
    echo -n /run/tci-store/\${USER}; \
fi")
        jenkinsCredsPath = "${env.tciStorePath}/jenkins_creds"
        String dockerCredsExtra = "-v ${env.jenkinsCredsPath}/group:/etc/group:ro \
        -v ${env.jenkinsCredsPath}/passwd:/etc/passwd:ro \
        -v ${env.jenkinsCredsPath}/shadow:/etc/shadow:ro \
        -v ${env.jenkinsCredsPath}/sudoers.d:/etc/sudoers.d:ro"
        String fileCachePath = "${env.WORKSPACE}/../${env.JOB_BASE_NAME}--file-cache"
        String dockerFileCacheExtra = sh(
            returnStdout: true,
            script: "set -x; \
if [ \${TCI_JENKINS} ]; then \
    echo -n ' '; \
else \
    echo -n '-v ${env.fileCachePath}:${env.fileCachePath}'; \
fi")
        String dockerSshExtra = sh(
            returnStdout: true,
            script: "set -x; \
if [ \${TCI_JENKINS} ]; then \
    echo -n ' '; \
else \
    user=\$(id --user --real --name); \
    echo -n '-v /home/\${user}/.ssh:/home/\${user}/.ssh'; \
fi")
        String dockerTag = sh(
            returnStdout: true,
            script: './docker/builder/build-builder.sh --tag').trim()
        String image_name = "${params.TARGET_ARCH}-${params.ROOTFS_TYPE}"
        String kernel_build_dir = "${params.TARGET_ARCH}-kernel-build"
        String kernel_install_dir = "${params.TARGET_ARCH}-kernel-install"
        String kernel_src_dir = sh(
            returnStdout: true,
            script: "set -x; \
echo '${params.KERNEL_GIT_URL}' | sed 's|://|-|; s|/|-|g'").trim()
        String qemu_out = "qemu-console.txt"
        String remote_out = "${params.TEST_MACHINE}-console.txt"
        String tests_dir = 'tests'
    }

    agent { label "${params.AGENT}" }

    stages {

        stage('setup') {
            steps { /* setup */
                clean_disk_image_build()
                tci_setup_file_cache()
                tci_setup_jenkins_creds()
            }
        }

        stage('build-builder') {
            steps { /* build-builder */
                echo "${STAGE_NAME}: dockerTag=@${env.dockerTag}@"

                tci_print_debug_info("${STAGE_NAME}")
                tci_print_result_header()

                sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

tag=${env.dockerTag}
docker images \${tag%:*}

[[ "${params.DOCKER_PURGE}" != 'true' ]] || build_args=' --purge'

./docker/builder/build-builder.sh \${build_args}

""")
            }
            post { /* build-builder */
                cleanup {
                    echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                }
            }
        }

        stage('parallel-build') {
            failFast false
            parallel { /* parallel-build */
                stage('bootstrap-disk-image') {

                    agent { /* bootstrap-disk-image */
                        docker {
                            image "${env.dockerTag}"
                            args "--network host \
                                --privileged \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                            "
                            reuseNode true
                        }
                    }

                    steps { /* bootstrap-disk-image */
                        tci_print_debug_info("${STAGE_NAME}")
                        tci_print_result_header()

                        echo "${STAGE_NAME}: params.USE_BOOTSTRAP_CACHE=${params.USE_BOOTSTRAP_CACHE}"

                        script { // TODO: Convert this to declarative pipeline.
                            echo "${STAGE_NAME}: 1 cacheFoundBootstrap=${cacheFoundBootstrap}"
                            cacheFoundBootstrap = fileCache.get(env.fileCachePath,
                                'bootstrap', env.image_name + '.rootfs',
                                params.USE_BOOTSTRAP_CACHE)

                            echo "${STAGE_NAME}: 2 cacheFoundBootstrap=${cacheFoundBootstrap}"

                            if (cacheFoundBootstrap) {
                                currentBuild.result = 'SUCCESS'
                                echo "${STAGE_NAME}: Using cached files."
                                return
                            }

                            echo "${STAGE_NAME}: dockerCredsExtra = @${env.dockerCredsExtra}@"

                            sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

# for debug
id
whoami
#cat /etc/group || :
#ls -l /etc/sudoers || :
#ls -l /etc/sudoers.d || :
#cat /etc/sudoers || :
sudo -S true

scripts/build-rootfs.sh \
    --arch=${params.TARGET_ARCH} \
    --kernel-modules=\${modules_dir} \
    --build-dir=\$(pwd) \
    --image-name=${env.image_name} \
    --rootfs-type=${params.ROOTFS_TYPE} \
    --bootstrap \
    --verbose

# Save bootstrap for cacheing later.
sudo rsync -a --delete ${env.image_name}.rootfs/ ${env.image_name}.bootstrap/
""")
                        }
                    }

                    post { /* bootstrap-disk-image */
                        success {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt",
                                fingerprint: true)
                        }
                        cleanup {
                            echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                        }
                    }
                }

                stage('build-kernel') {
                    agent { /* build-kernel */
                        docker {
                            image "${env.dockerTag}"
                            args "--network host \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                            "
                            reuseNode true
                        }
                    }

                    steps { /* build-kernel */
                        tci_print_debug_info("${STAGE_NAME}")
                        tci_print_result_header()

                        dir(env.kernel_src_dir) {
                            checkout scm: [
                                $class: 'GitSCM',
                                branches: [[name: params.KERNEL_GIT_BRANCH]],
                                 userRemoteConfigs: [[url: params.KERNEL_GIT_URL]],
                            ]
                            sh("git show -q")
                        }
 
                        script { // TODO: Convert this to declarative pipeline.

                            cacheFoundKernel = fileCache.get(env.fileCachePath,
                                    'kernel', env.kernel_install_dir,
                                    params.USE_KERNEL_CACHE)

                            if (cacheFoundKernel) {
                                currentBuild.result = 'SUCCESS'
                                echo "${STAGE_NAME}: Using cached files."
                                return
                            }

                            sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
scripts_dir="scripts"

src_dir="\$(pwd)/${env.kernel_src_dir}"
build_dir="\$(pwd)/${env.kernel_build_dir}"
install_dir="\$(pwd)/${env.kernel_install_dir}"

rm -rf \${build_dir} "\${install_dir}"

\${scripts_dir}/build-linux-kernel.sh \
    --build-dir=\${build_dir} \
    --install-dir=\${install_dir} \
    ${params.TARGET_ARCH} \${src_dir} defconfig

if [[ -n "${params.KERNEL_CONFIG_URL}" ]]; then
    curl --silent --show-error --location ${params.KERNEL_CONFIG_URL} \
        > \${build_dir}/.config
else
    \${scripts_dir}/set-config-opts.sh \
        --verbose \
        \${scripts_dir}/tx2-fixup.spec \${build_dir}/.config
fi

\${scripts_dir}/build-linux-kernel.sh \
    --build-dir=\${build_dir} \
    --install-dir=\${install_dir} \
    ${params.TARGET_ARCH} \${src_dir} fresh

rm -rf \${build_dir}
""")
                        }
                    }

                    post { /* build-kernel */
                        success {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt",
                                fingerprint: true)
                        }
                        cleanup {
                            echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                        }
                    }
                }
            }

            post { /* parallel-build */
                failure {
                    clean_disk_image_build()
                }
                cleanup {
                    echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                }
            }
        }

        stage('build-disk-image') {
            agent { /* build-disk-image */
                docker {
                    image "${env.dockerTag}"
                            args "--network host \
                                --privileged \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                            "
                    reuseNode true
                }
            }

            steps { /* build-disk-image */
                tci_print_debug_info("${STAGE_NAME}")
                tci_print_result_header()
                script { // TODO: Convert this to declarative pipeline.
                    if (fileCache.get(env.fileCachePath,
                        'image', env.image_name + '.initrd',
                        params.USE_IMAGE_CACHE) == true
                        && fileCache.get(env.fileCachePath,
                            'image', env.image_name + '.manifest',
                            params.USE_IMAGE_CACHE) == true
                        && fileCache.get(env.fileCachePath,
                            'image', env.image_name + '.login-key',
                            params.USE_IMAGE_CACHE) == true) {
                        cacheFoundImage = true
                        echo "${STAGE_NAME}: Using cached files."
                        currentBuild.result = 'SUCCESS'
                        return
                    }

                    sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

modules_dir="\$(find ${env.kernel_install_dir}/lib/modules/* -maxdepth 0 -type d)"

scripts/build-rootfs.sh \
    --arch=${params.TARGET_ARCH} \
    --kernel-modules=\${modules_dir} \
    --build-dir=\$(pwd) \
    --image-name=${env.image_name} \
    --rootfs-type=${params.ROOTFS_TYPE} \
    --rootfs-setup \
    --make-image \
    --verbose
""")
                }
            }

            post { /* build-disk-image */
                success {
                    archiveArtifacts(
                        artifacts: "${STAGE_NAME}-result.txt, ${env.image_name}.manifest",
                        fingerprint: true)
                }
                failure {
                    clean_disk_image_build()
                    echo "${STAGE_NAME}: ${currentBuild.currentResult}"
                }
                cleanup {
                    echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                }
            }
        }

        stage('build-tests') {
            agent { /* build-tests */
                docker {
                    image "${env.dockerTag}"
                            args "--network host \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                            "
                    reuseNode true
                }
            }

            steps { /* build-tests */
                tci_print_debug_info("${STAGE_NAME}")
                tci_print_result_header()

                sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

rootfs_dir=${env.WORKSPACE}/${env.image_name}.rootfs

scripts/test-runner.sh \
    --arch=${params.TARGET_ARCH} \
    --tests-dir=${env.WORKSPACE}/${env.tests_dir} \
    --verbose \
    --build \
    --sysroot=\${rootfs_dir}
""")
            }

            post { /* build-tests */
                cleanup {
                    echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                    archiveArtifacts(
                        artifacts: "${STAGE_NAME}-result.txt",
                        fingerprint: true)
                }
            }
        }

        stage('parallel-test') {
            failFast false
            parallel { /* parallel-test */

                    stage('run-remote-tests') {
                    when { /* run-remote-tests */
                        expression { return params.RUN_REMOTE_TESTS }
                    }

                    agent { /* run-remote-tests */
                        docker {
                            image "${env.dockerTag}"
                            args "--network host \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                                ${env.dockerSshExtra} \
                            "
                             reuseNode true
                        }
                    }

                    environment { /* run-remote-tests */
                        TCI_BMC_CREDS = credentials("${params.TEST_MACHINE}_bmc_creds")
                    }

                    options { /* run-remote-tests */
                        timeout(time: 20, unit: 'MINUTES')
                    }

                    steps { /* run-remote-tests */
                        echo "${STAGE_NAME}: start"
                        tci_print_debug_info("${STAGE_NAME}")
                        tci_print_result_header()

                        script { // TODO: Convert this to declarative pipeline.
                            sshagent (credentials: ['tci-tftp-login-key']) {
                                 sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

echo "--------"
printenv | sort
ssh-add -l || :
echo "--------"

if [[ ${params.SYSTEMD_DEBUG} ]]; then
    extra_args="--systemd-debug"
fi

scripts/run-kernel-remote-tests.sh \
    --test-machine=${params.TEST_MACHINE} \
    --kernel=${env.kernel_install_dir}/boot/Image \
    --initrd=${env.image_name}.initrd \
    --ssh-login-key=${env.image_name}.login-key \
    --out-file=${env.remote_out} \
    --result-file=${STAGE_NAME}-result.txt \
    \${extra_args} \
    --verbose
""")
                            }
                        }
                    }

                    post { /* run-remote-tests */
                        success {
                            script {
                                    if (readFile("${env.remote_out}").contains('reboot: Power down')) {
                                        echo "${STAGE_NAME}: FOUND 'reboot' message."
                                    } else {
                                        echo "${STAGE_NAME}: DID NOT FIND 'reboot' message."
                                        currentBuild.result = 'FAILURE'
                                    }
                            }
                        }
                        cleanup {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt, ${env.remote_out}",
                                fingerprint: true)
                            echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                        }
                    }
                }

            stage('run-qemu-tests') {
                    when { /* run-qemu-tests */
                        expression { return params.RUN_QEMU_TESTS == true }
                    }

                    agent { /* run-qemu-tests */
                        docker {
                            image "${env.dockerTag}"
                            args "--network host \
                                ${env.dockerCredsExtra} \
                                ${env.dockerFileCacheExtra} \
                            "
                            reuseNode true
                        }
                    }

                    options { /* run-qemu-tests */
                        timeout(time: 20, unit: 'MINUTES')
                    }

                    steps { /* run-qemu-tests */
                        tci_print_debug_info("${STAGE_NAME}")
                        tci_print_result_header()

                        script { // TODO: Convert this to declarative pipeline.

                            sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

if [[ ${params.SYSTEMD_DEBUG} ]]; then
    extra_args="--systemd-debug"
fi

scripts/run-kernel-qemu-tests.sh \
    --arch=${params.TARGET_ARCH} \
    --kernel=${env.kernel_install_dir}/boot/Image \
    --initrd=${env.image_name}.initrd \
    --ssh-login-key=${env.image_name}.login-key \
    --tests-dir=??? \
    --out-file=${env.qemu_out} \
    --result-file=${STAGE_NAME}-result.txt \
    \${extra_args} \
    --verbose
""")
                        }
                    }

                    post { /* run-qemu-tests */
                        success {
                            script {
                                    if (readFile("${env.qemu_out}").contains('reboot: Power down')) {
                                        echo "${STAGE_NAME}: FOUND 'reboot' message."
                                    } else {
                                        echo "${STAGE_NAME}: DID NOT FIND 'reboot' message."
                                        currentBuild.result = 'FAILURE'
                                    }
                            }
                        }
                        cleanup {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt, ${env.qemu_out}",
                                fingerprint: true)
                            echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                        }
                    }
                }
            }

            post { /*parallel-test */
                success {
                    script {
                        /* Update file cache on test success. */
                        if (!cacheFoundBootstrap) {
                            sh("""#!/bin/bash -ex
sudo rm -rf ${env.image_name}.rootfs
mv ${env.image_name}.bootstrap ${env.image_name}.rootfs
""")
                            fileCache.put(env.fileCachePath, 'bootstrap',
                                env.image_name + '.rootfs', '**stamp info**')
                        } else {
                            echo "${STAGE_NAME}: cache-put: Bootstrap already cached."
                        }
                        if (!cacheFoundKernel) {
                            fileCache.put(env.fileCachePath, 'kernel',
                                env.kernel_install_dir, '**stamp info**')
                        } else {
                            echo "${STAGE_NAME}: cache-put: Kernel already cached."
                        }
                        if (!cacheFoundImage) {
                            fileCache.put(env.fileCachePath, 'image',
                                    env.image_name + '.initrd', '**stamp info**')
                            fileCache.put(env.fileCachePath, 'image',
                                env.image_name + '.login-key', '**stamp info**')
                            fileCache.put(env.fileCachePath, 'image',
                                env.image_name + '.manifest', '**stamp info**')
                        } else {
                            echo "${STAGE_NAME}: cache-put: Image already cached."
                        }
                    }
                }
                failure {
                    echo "${STAGE_NAME}: TODO: failure"
                }
                cleanup {
                    echo "${STAGE_NAME}: cleanup: ${currentBuild.currentResult} -> ${currentBuild.result}"
                    clean_disk_image_build()
                }
            }
        }
    }
}

void tci_setup_jenkins_creds() {
    sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

sudo rm -rf ${env.jenkinsCredsPath}
sudo mkdir -p ${env.jenkinsCredsPath}
sudo chown \$(id --user --real --name): ${env.jenkinsCredsPath}/
sudo cp -avf /etc/group ${env.jenkinsCredsPath}/
sudo cp -avf /etc/passwd ${env.jenkinsCredsPath}/
sudo cp -avf /etc/shadow  ${env.jenkinsCredsPath}/
sudo cp -avf /etc/sudoers.d ${env.jenkinsCredsPath}/
""")
}

void tci_print_debug_info(String image) {
    sh("""#!/bin/bash -ex
echo '${STAGE_NAME}: In ${image}:'
whoami
id
""")
}

void tci_print_result_header() {
    sh("""#!/bin/bash -ex

echo "node=${NODE_NAME}" > ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
echo "printenv" >> ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
printenv | sort >> ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
""")
}

void clean_disk_image_build() {
    echo "cleaning disk-image"
    sh("sudo rm -rf *.rootfs *.bootstrap")
}

void tci_setup_file_cache() {
    sh("""#!/bin/bash -ex
mkdir -p ${env.fileCachePath}
""")
}


