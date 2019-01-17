#!groovy
// Test install of Fedora.


script {
    library identifier: "thunderx-ci@master", retriever: legacySCM(scm)
}

pipeline {
    parameters {
        string(name: 'FEDORA_KICKSTART_URL',
            defaultValue: '',
            description: 'URL of an alternate Anaconda kickstart file.')
        booleanParam(name: 'FORCE', 
            defaultValue: false,
            description: 'Force tests to run.')
        string(name: 'FEDORA_INITRD_URL',
            defaultValue: 'https://dl.fedoraproject.org/pub/fedora/linux/development/29/Server/aarch64/os/images/pxeboot/initrd.img',
            description: 'URL of Fedora Anaconda initrd.')
        //string(name: 'FEDORA_ISO_URL', // TODO: Add iso support.
        //    defaultValue: 'https://dl.fedoraproject.org/pub/fedora/linux/development/29/Server/aarch64/iso/Fedora-Server-netinst-aarch64-29-???.iso',
        //    description: 'URL of Fedora Anaconda CD-ROM iso.')
        string(name: 'FEDORA_KERNEL_URL',
            defaultValue: 'https://dl.fedoraproject.org/pub/fedora/linux/development/29/Server/aarch64/os/images/pxeboot/vmlinuz',
            description: 'URL of Fedora Anaconda kernel.')
        booleanParam(name: 'RUN_QEMU_TESTS',
            defaultValue: true,
            description: 'Run kernel tests in QEMU emulator.')
        booleanParam(name: 'RUN_T88_TESTS',
            defaultValue: false,
            description: 'Run kernel tests on T88 machine.')
        string(name: 'TARGET_ARCH',
            defaultValue: 'arm64', // FIXME: Need to setup amd64.
            description: 'Target architecture to build for.')
    }

    options {
        // Timeout if no node available.
        timeout(time: 90, unit: 'MINUTES')
        //timestamps()
        buildDiscarder(logRotator(daysToKeepStr: '10', numToKeepStr: '5'))
    }

    environment {
        builder_dockerfile = 'docker/builder/Dockerfile.builder'
        builder_docker_from = "debian:buster"  // FIXME: Setup from for arm64...
        jenkins_creds = "/var/tci-store/jenkins_creds"
        qemu_out = "qemu-console.txt"
        tftp_initrd = 'tci-initrd'
        tftp_kickstart = 'tci-kickstart'
        tftp_kernel = 'tci-kernel'
        tftp_root= '/var/tftproot/t88'
        tftp_server = '10.7.15.107'
    }

    agent {
        //label "${params.NODE_ARCH} && docker"
        label 'master'
    }

    stages {

        stage('parallel-setup') {
            failFast false
            parallel {

            stage('setup') {
                steps {
                tci_setup_known_hosts()

                    sh("""#!/bin/bash
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
set -ex

# Copy jenkins creds to tci-store.
sudo mkdir -p ${env.jenkins_creds}
sudo chown \$(id --user --real --name): ${env.jenkins_creds}
sudo cp -avf /etc/group /etc/passwd /etc/shadow /etc/sudoers.d \
    ${env.jenkins_creds}

# Setup builder dockerfile.
cp -f docker/builder/Dockerfile.builder docker/builder/Dockerfile.tmp

# FIXME: Should just need for docker older than 17.05.
if [[ 1 == 1 ]]; then
    sed --in-place "s|ARG DOCKER_FROM||" docker/builder/Dockerfile.tmp
    sed --in-place "s|.{DOCKER_FROM}|${env.builder_docker_from}|" docker/builder/Dockerfile.tmp
    #cat docker/builder/Dockerfile.tmp
fi

""")
            }
        }

                stage('download-files') {
                    steps {
                        echo "${STAGE_NAME}: start"
                        tci_print_debug_info('tci-jenkins')

                        copyArtifacts(
                            projectName: "${JOB_NAME}",
                            selector: lastCompleted(),
                            fingerprintArtifacts: true,
                            optional: true,
                        )

                        sh("""#!/bin/bash
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
set -ex

rm -f ${env.tftp_initrd} ${env.tftp_kickstart} ${env.tftp_kernel}

if [[ -n "${params.FEDORA_KICKSTART_URL}" ]]; then
    curl --silent --show-error --location ${params.FEDORA_KICKSTART_URL} > ${env.tftp_kickstart}
else
    cp jenkins/jobs/distro/f29/f29-qemu.ks ${env.tftp_kickstart}
fi
curl --silent --show-error --location ${params.FEDORA_INITRD_URL} > ${env.tftp_initrd}
curl --silent --show-error --location ${params.FEDORA_KERNEL_URL} > ${env.tftp_kernel}

if [[ -f md5sum.txt ]]; then
    last="\$(cat md5sum.txt)"
fi

current=\$(md5sum ${env.tftp_initrd} ${env.tftp_kernel})

set +x
echo '------'
echo "last    = \n\${last}"
echo "current = \n\${current}"
ls -l ${env.tftp_initrd} ${env.tftp_kernel}
echo '------'
set -x

if [[ "${params.FORCE}" == 'true' || -z "\${last}" \
    || "\${current}" != "\${last}" ]]; then
    echo "${STAGE_NAME}: Need test."
    echo "\${current}" > md5sum.txt
    echo "yes" > need-test
else
    echo "${STAGE_NAME}: No change."
    echo "no" > need-test
fi

""")
                    }
                    post { /* download-files */
                        success {
                            archiveArtifacts(
                                artifacts: "md5sum.txt",
                                fingerprint: true
                            )
                        }
                        cleanup {
                            echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                        }
                    }
                }
            }
        }

        stage('parallel-test') {
            failFast false
            parallel {

                stage('t88-tests') {
                    when {
                        expression { return params.RUN_T88_TESTS == true \
                            && readFile('need-test').contains('yes')  }
                    }
                    stages {

                        stage('upload-files') {
                            steps {
                                echo "${STAGE_NAME}: start"
                                tci_upload_tftp_files('tftp-server-login-key',
                                    env.tftp_server, env.tftp_root,
                                    env.tftp_initrd + ' ' + env.tftp_kernel + ' '
                                        + env.tftp_kickstart)
                            }
                        }

                        stage('run-t88-tests') {
                            environment { 
                                t88_bmc_cred = credentials('t88_bmc_cred')
                                t88_out = "t88-console.txt"
                            }

                            options {
                                timeout(time: 90, unit: 'MINUTES')
                            }

                            agent {
                                dockerfile {
                                    dir 'docker/builder'
                                    filename 'Dockerfile.tmp'
                                    reuseNode true
                                    additionalBuildArgs " \
                                        --build-arg DOCKER_FROM=${env.builder_docker_from} \
                                        --network=host"
                                    // FIXME: This expansion doesn't seem to work.
                                    //args "--privileged \
                                    //        -v ${env.jenkins_creds}/group:/etc/group:ro \
                                    //        -v ${env.jenkins_creds}/passwd:/etc/passwd:ro \
                                    //        -v ${env.jenkins_creds}/shadow:/etc/shadow:ro \
                                    //        -v ${env.jenkins_creds}/sudoers.d:/etc/sudoers.d:ro"
                                    args "--privileged \
                                            -v /var/tci-store/jenkins_creds/group:/etc/group:ro \
                                            -v /var/tci-store/jenkins_creds/passwd:/etc/passwd:ro \
                                            -v /var/tci-store/jenkins_creds/shadow:/etc/shadow:ro \
                                            -v /var/tci-store/jenkins_creds/sudoers.d:/etc/sudoers.d:ro"
                                }
                            }

                            steps {
                                echo "${STAGE_NAME}: start"
                                tci_print_debug_info('tci-builder')
                                tci_print_result_header()

                                sh("""#!/bin/bash
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
set -ex

# FIXME: todo

exit 0

""")
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
                                    echo "${STAGE_NAME}: done: ${currentBuild.currentResult}"
                                }
                            }
                        }
                    }
                }

                stage('run-qemu-tests') {
                    when {
                        expression { return params.RUN_QEMU_TESTS == true \
                            && readFile('need-test').contains('yes')  }
                    }

                    options {
                        timeout(time: 90, unit: 'MINUTES')
                    }

                    agent {
                        dockerfile {
                            dir 'docker/builder'
                            filename 'Dockerfile.tmp'
                            reuseNode true
                            additionalBuildArgs " \
                                --build-arg DOCKER_FROM=${env.builder_docker_from} \
                                --network=host"
                            // FIXME: This expansion doesn't seem to work.
                            //args "--privileged \
                            //        -v ${env.jenkins_creds}/group:/etc/group:ro \
                            //        -v ${env.jenkins_creds}/passwd:/etc/passwd:ro \
                            //        -v ${env.jenkins_creds}/shadow:/etc/shadow:ro \
                            //        -v ${env.jenkins_creds}/sudoers.d:/etc/sudoers.d:ro"
                            args "--privileged \
                                    -v /var/tci-store/jenkins_creds/group:/etc/group:ro \
                                    -v /var/tci-store/jenkins_creds/passwd:/etc/passwd:ro \
                                    -v /var/tci-store/jenkins_creds/shadow:/etc/shadow:ro \
                                    -v /var/tci-store/jenkins_creds/sudoers.d:/etc/sudoers.d:ro"
                        }
                    }

                    steps {
                        echo "${STAGE_NAME}: start"
                        tci_print_debug_info('tci-builder')
                        tci_print_result_header()

                        sh("""#!/bin/bash
export PS4='+\$(basename \${BASH_SOURCE}):\${LINENO}:'
set -ex

rm -f ${env.qemu_out}
touch ${env.qemu_out}

rm -f fedora.hda
qemu-img create -f qcow2 fedora.hda 20G

rm -f test-login-key
ssh-keygen -q -f test-login-key -N ''

scripts/run-fedora-qemu-tests.sh  \
    --arch=${params.TARGET_ARCH} \
    --initrd=${env.tftp_initrd} \
    --kernel=${env.tftp_kernel} \
    --kickstart=${env.tftp_kickstart} \
    --out-file=${env.qemu_out} \
    --hda=fedora.hda \
    --ssh-key=test-login-key \
    --verbose

""")
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
        }
    }
}

// TCI common routines.

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

void tci_setup_known_hosts() {
    sh("""#!/bin/bash -ex
        if ! ssh-keygen -F ${env.tftp_server} &> /dev/null; then
            mkdir -p ~/.ssh
            ssh-keyscan ${env.tftp_server} >> ~/.ssh/known_hosts
        fi
""")
}

void tci_upload_tftp_files(String keyId, String server, String root, String files) {
    echo 'upload_tftp_files: key   = @' + keyId + '@'
    echo 'upload_tftp_files: root  = @' + root + '@'
    echo 'upload_tftp_files: files = @' + files + '@'

    sshagent (credentials: [keyId]) {
        sh("""#!/bin/bash -ex

ssh ${server} ls -lh ${root}
for f in "${files}"; do
    scp \${f} ${server}:${root}/\${f}
done
ssh ${server} ls -lh ${root}
""")
    }
}
