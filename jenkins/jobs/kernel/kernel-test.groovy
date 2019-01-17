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
String dockerCredsExtra = ""

pipeline {
    parameters {
        booleanParam(name: 'DOCKER_PURGE',
            defaultValue: false,
            description: 'Remove existing tci builder image and rebuild.')
        string(name: 'KERNEL_CONFIG_URL',
            defaultValue: '',
            description: 'URL of an alternate kernel config.')
        booleanParam(name: 'KERNEL_DEBUG',
            defaultValue: false,
            description: 'Run kernel with debug flags.')
        string(name: 'KERNEL_GIT_BRANCH',
            defaultValue: 'master',
            description: 'Branch or tag of KERNEL_GIT_URL.')
        string(name: 'KERNEL_GIT_URL',
            defaultValue: 'https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git',
            description: 'URL of a Linux kernel git repository.')
        string(name: 'NODE_ARCH',
            defaultValue: 'amd64',
            description: 'Jenkins node architecture to build on.')
        booleanParam(name: 'RUN_QEMU_TESTS',
            defaultValue: true,
            description: 'Run kernel tests in QEMU emulator.')
        booleanParam(name: 'RUN_T88_TESTS',
            defaultValue: false,
            description: 'Run kernel tests on T88 machine.')
        string(name: 'TARGET_ARCH',
            defaultValue: 'arm64', // FIXME: Need to setup amd64.
            description: 'Target architecture to build for.')
        booleanParam(name: 'USE_BOOTSTRAP_CACHE',
            defaultValue: true,
            description: 'Use cached bootstrap directory.')
        booleanParam(name: 'USE_IMAGE_CACHE',
            defaultValue: false,
            description: 'Use cached disk images.')
        booleanParam(name: 'USE_KERNEL_CACHE',
            defaultValue: false,
            description: 'Use cached kernel build.')
    }

    options {
        // Timeout if no node available.
        timeout(time: 90, unit: 'MINUTES')
        //timestamps()
        buildDiscarder(logRotator(daysToKeepStr: '30', numToKeepStr: '10'))
    }

    environment {
        dockerTag = sh(
            returnStdout: true,
            script: './docker/builder/build-builder.sh --tag').trim()
        dockerRunExtra= sh(
            returnStdout: true,
            script: "if [ ! \${TCI_JENKINS} ]; then echo -n '-v ${env.file_cache}:${env.file_cache}'; else echo -n ' '; fi")
        file_cache = "${WORKSPACE}/../${JOB_BASE_NAME}-cache"
        image_name = "${params.TARGET_ARCH}-debian-buster"
        kernel_build_dir = "${params.TARGET_ARCH}-kernel-build"
        kernel_install_dir = "${params.TARGET_ARCH}-kernel-install"
        kernel_src_dir = sh(
            returnStdout: true,
            script: "echo '${params.KERNEL_GIT_URL}' | sed 's|://|-|; s|/|-|g'").trim()
        qemu_out = "qemu-console.txt"
    }

    agent { label 'master' }

    stages {

        stage('build-container') {
            steps {
                echo "${STAGE_NAME}: dockerTag=@${env.dockerTag}@"

                tci_print_debug_info('tci-jenkins')
                tci_print_result_header()

                sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

tag=${env.dockerTag}
docker images \${tag%:*}

[[ "${params.DOCKER_PURGE}" != 'true' ]] || build_args=' --purge'

./docker/builder/build-builder.sh \${build_args}

""")
            }
            post { /* build-container */
                cleanup {
                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                }
            }
        }

        stage('setup') {
            steps {
                clean_disk_image_build()
                tci_setup_file_cache()
                tci_setup_jenkins_creds()
                //tci_setup_known_hosts()
            }
        }

        stage('parallel-build') {
            failFast false
            parallel {
                stage('bootstrap-disk-image') {
                    steps {
                        tci_print_debug_info('tci-jenkins')
                        tci_print_result_header()

                        echo "${STAGE_NAME}: params.USE_BOOTSTRAP_CACHE=${params.USE_BOOTSTRAP_CACHE}"

                        script { // TODO: Convert to declarative pipeline docker.
                            echo "${STAGE_NAME}: 1 cacheFoundBootstrap=${cacheFoundBootstrap}"
                            cacheFoundBootstrap = fileCache.get(env.file_cache,
                                'bootstrap', env.image_name + '.rootfs',
                                params.USE_BOOTSTRAP_CACHE)

                            echo "${STAGE_NAME}: 2 cacheFoundBootstrap=${cacheFoundBootstrap}"

                            if (cacheFoundBootstrap) {
                                currentBuild.result = 'SUCCESS'
                                echo "${STAGE_NAME}: Using cached files."
                                return
                            }

                            docker.image(env.dockerTag).inside("\
                                --privileged \
                                ${dockerCredsExtra} \
                                ${env.dockerRunExtra} \
                            ") { c ->
                                tci_print_debug_info('tci-builder')
                                sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
scripts/build-debian-rootfs.sh \
    --arch=${params.TARGET_ARCH} \
    --verbose \
    --bootstrap

# Save bootstrap for cacheing later.
sudo rsync -a --delete ${env.image_name}.rootfs/ ${env.image_name}.bootstrap/
""")
                            }
                            // FIXME: For test only.
                            //fileCache.put(env.file_cache, 'bootstrap',
                            //    env.image_name + '.rootfs', '**stamp info**')
                        }
                    }
                    post { /* bootstrap-disk-image */
                        success {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt",
                                fingerprint: true)
                        }
                        cleanup {
                            echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                       }
                    }
                }
                stage('build-kernel') {
                    steps {
                        dir(env.kernel_src_dir) {
                            checkout scm: [
                                $class: 'GitSCM',
                                branches: [[name: params.KERNEL_GIT_BRANCH]],
                                //branches: [[name: 'refs/tags/3.6.1]],
                                userRemoteConfigs: [[url: params.KERNEL_GIT_URL]],
                                //userRemoteConfigs: [[url: params.KERNEL_GIT_URL, name: 'origin']],
                            ]
                            sh("git show -q")
                        }

                        script { // TODO: Convert to declarative pipeline docker.
                            docker.image(env.dockerTag).inside("\
                                --privileged \
                                ${dockerCredsExtra} \
                                ${env.dockerRunExtra} \
                            ") { c ->
                                tci_print_result_header()

                                cacheFoundKernel = fileCache.get(env.file_cache,
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
    --build-dir=\${build_dir} --install-dir=\${install_dir} \
    ${params.TARGET_ARCH} \${src_dir} defconfig

if [[ -n "${params.KERNEL_CONFIG_URL}" ]]; then
    curl --silent --show-error --location ${params.KERNEL_CONFIG_URL} \
        > \${build_dir}/.config
else
    \${scripts_dir}/set-config-opts.sh --verbose \${scripts_dir}/tx2-fixup.spec \
        ./arm64-kernel-build/.config
fi


\${scripts_dir}/build-linux-kernel.sh \
    --build-dir=\${build_dir} --install-dir=\${install_dir} \
    ${params.TARGET_ARCH} \${src_dir} fresh

rm -rf \${build_dir}
""")
                            }
                        }
                    }
                    post { /* build-kernel */
                        success {
                            archiveArtifacts(
                                artifacts: "${STAGE_NAME}-result.txt",
                                fingerprint: true)
                        }
                        cleanup {
                            echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                        }
                    }
                }
            }
            post { /* parallel-build */
                failure {
                    clean_disk_image_build()
                }
                cleanup {
                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                }
            }
        }

        stage('build-disk-image') {
            steps {
                script { // TODO: Convert to declarative pipeline docker.
                    docker.image(env.dockerTag).inside("\
                        --privileged \
                        ${dockerCredsExtra} \
                        ${env.dockerRunExtra} \
                    ") { c ->
                        tci_print_result_header()

                        if (fileCache.get(env.file_cache,
                            'image', env.image_name + '.initrd',
                            params.USE_IMAGE_CACHE) == true
                            && fileCache.get(env.file_cache,
                                'image', env.image_name + '.manifest',
                                params.USE_IMAGE_CACHE) == true
                            && fileCache.get(env.file_cache,
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

scripts/build-debian-rootfs.sh \
    --arch=${params.TARGET_ARCH} \
    --kernel-modules=\${modules_dir} \
    --verbose \
    --rootfs-setup \
    --make-image
""")
                    }
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
                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                }
            }
        }
        stage('parallel-test') {
            failFast false
            parallel {

                stage('t88-tests') {
                    when {
                        expression { return params.RUN_T88_TESTS }
                    }
                    stages {

                        stage('run-t88-tests') {
                             environment {
                                t88_bmc_cred = credentials('t88_bmc_cred')
                                t88_out = "t88-console.txt"
                            }

                            options {
                                timeout(time: 20, unit: 'MINUTES')
                            }

                            steps {
                                echo "${STAGE_NAME}: start"
                                script { // TODO: Convert to declarative pipeline docker.
                                    docker.image(env.dockerTag).inside("\
                                        --privileged \
                                        ${dockerCredsExtra} \
                                        ${env.dockerRunExtra} \
                                    ") { c ->
                                        sshagent (credentials: ['tftp-server-login-key']) {
                                            sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

echo "--------"
printenv
echo "--------"

ls -l /tmp | :
ls -l \$(dirname \${SSH_AUTH_SOCK}) | :
ls -l \${SSH_AUTH_SOCK} | :
ssh-add -l | :
ps aux | :

scripts/run-kernel-t88-tests.sh \
    --kernel=${env.kernel_install_dir}/boot/Image \
    --initrd=${env.image_name}.initrd \
    --ssh-login-key=${env.image_name}.login-key \
    --out-file=${env.t88_out} \
    --result-file=${STAGE_NAME}-result.txt \
    --verbose
""")
                                        }
                                    }
                                }
                            }
                            post { /* run-t88-tests */
                                success {
                                    script {
                                            if (readFile("${env.t88_out}").contains('reboot: Power down')) {
                                                echo "${STAGE_NAME}: FOUND 'reboot' message."
                                            } else {
                                                echo "${STAGE_NAME}: DID NOT FIND 'reboot' message."
                                                currentBuild.result = 'FAILURE'
                                            }
                                    }
                                }
                                cleanup {
                                    archiveArtifacts(
                                        artifacts: "${STAGE_NAME}-result.txt, ${env.t88_out}",
                                        fingerprint: true)
                                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                                }
                            }
                        }
                    }
                }

                stage('run-qemu-tests') {
                    when {
                        expression { return params.RUN_QEMU_TESTS == true }
                    }

                    options {
                        timeout(time: 20, unit: 'MINUTES')
                    }

                    steps {
                        script { // TODO: Convert to declarative pipeline docker.
                            docker.image(env.dockerTag).inside("\
                                --privileged \
                                ${dockerCredsExtra} \
                                ${env.dockerRunExtra} \
                            ") { c ->
                                tci_print_debug_info('tci-builder')
                                sh("""#!/bin/bash -ex
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'

scripts/run-kernel-qemu-tests.sh \
    --arch=${params.TARGET_ARCH} \
    --kernel=${env.kernel_install_dir}/boot/Image \
    --initrd=${env.image_name}.initrd \
    --ssh-login-key=${env.image_name}.login-key \
    --out-file=${env.qemu_out} \
    --result-file=${STAGE_NAME}-result.txt \
    --verbose
""")
                            }
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
                            echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                        }
                    }
                }
            }
            post { /* parallel-test */
                success {
                    script {
                        /* Update file cache on test success. */
                        if (!cacheFoundBootstrap) {
                            sh("""#!/bin/bash -ex
sudo rm -rf ${env.image_name}.rootfs
mv ${env.image_name}.bootstrap ${env.image_name}.rootfs
""")
                            fileCache.put(env.file_cache, 'bootstrap',
                                env.image_name + '.rootfs', '**stamp info**')
                        } else {
                            echo "${STAGE_NAME}: cache-put: Bootstrap already cached."
                        }
                        if (!cacheFoundKernel) {
                            fileCache.put(env.file_cache, 'kernel',
                                env.kernel_install_dir, '**stamp info**')
                        } else {
                            echo "${STAGE_NAME}: cache-put: Kernel already cached."
                        }
                        if (!cacheFoundImage) {
                            fileCache.put(env.file_cache, 'image',
                                    env.image_name + '.initrd', '**stamp info**')
                            fileCache.put(env.file_cache, 'image',
                                env.image_name + '.login-key', '**stamp info**')
                            fileCache.put(env.file_cache, 'image',
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
                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                    clean_disk_image_build()
                 }
            }
        }
    }
}

void clean_disk_image_build() {
    echo "cleaning disk-image"
    sh("sudo rm -rf *.rootfs *.bootstrap")
}

void tci_setup_file_cache() {
    sh("""#!/bin/bash -ex
mkdir -p ${env.file_cache}
""")
}

void tci_setup_jenkins_creds() {
    // Copy current container creds to host accessible store.

    sh("""#!/bin/bash -ex
creds="/var/tci-store/jenkins_creds"

sudo mkdir -p \${creds}
sudo chown \$(id --user --real --name): \${creds}
sudo cp -avf /etc/group /etc/passwd /etc/shadow /etc/sudoers.d \${creds}
""")

    dockerCredsExtra=" \
        -v ${TCI_HOST_STORE}/jenkins_creds/group:/etc/group:ro \
        -v ${TCI_HOST_STORE}/jenkins_creds/passwd:/etc/passwd:ro \
        -v ${TCI_HOST_STORE}/jenkins_creds/shadow:/etc/shadow:ro \
        -v ${TCI_HOST_STORE}/jenkins_creds/sudoers.d:/etc/sudoers.d:ro \
    "

}

void tci_setup_known_hosts() {
    sh("""#!/bin/bash -ex
        if ! ssh-keygen -F ${env.tftp_server_addr} &> /dev/null; then
            mkdir -p ~/.ssh
            ssh-keyscan ${env.tftp_server_addr} >> ~/.ssh/known_hosts
        fi
""")
}

void tci_print_debug_info(String image) {
    sh("""#!/bin/bash -ex
echo '${STAGE_NAME}: In ${image}:'
whoami
id
sudo true
""")
}

void tci_print_result_header() {
    sh("""#!/bin/bash -ex

echo "node=${NODE_NAME}" > ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
echo "printenv" >> ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
printenv        >> ${STAGE_NAME}-result.txt
echo "--------" >> ${STAGE_NAME}-result.txt
""")
}

