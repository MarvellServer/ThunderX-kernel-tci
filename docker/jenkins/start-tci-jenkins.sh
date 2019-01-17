#!/bin/bash

set -ex

name="$(basename $0)"

docker_name=${1}
docker_name=${docker_name:="tci-jenkins"}

if [ -f /.dockerenv ]; then
	echo "${name}: ERROR: Startup script for tci-jenkins container." >&2
	exit 1
fi

find_addr() {
	local hosts_file=${1}
	local host_name=${2}
	local addr="$(dig ${host_name} +short)"

	if [[ ! ${addr} ]]; then
		addr="$(egrep "${host_name}" ${hosts_file} | egrep -o '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || :)"

		if [[ ! ${addr} ]]; then
			echo "${name}: ERROR: ${host_name} DNS entry not found." >&2
			exit 1
		fi
	fi
	echo ${addr}
}

if [ -f "/etc/tci/tci-jenkins.conf" ]; then
	source "/etc/tci/tci-jenkins.conf"
elif [ -f "/var/lib/tci/tci-jenkins.conf" ]; then
	source "/var/lib/tci/tci-jenkins.conf"
fi

TCI_RELAY=${TCI_RELAY:="tci-relay"}
TCI_TICKET=${TCI_TICKET:="tci-ticket"}
TCI_TFTP=${TCI_HOSTS:="tci-tftp"}

tci_store="/var/tci-store/${docker_name}"

docker rm -f ${docker_name} &> /dev/null || :
rm -rf ${tci_store}

mkdir -p ${tci_store}
cp -avf /etc/hosts ${tci_store}/

relay_addr=$(find_addr /etc/hosts ${TCI_RELAY})
#ticket_addr=$(find_addr /etc/hosts ${TCI_TICKET})
tftp_addr=$(find_addr /etc/hosts ${TCI_TFTP})
t88_bmc_addr=$(find_addr /etc/hosts t88_bmc)

exec docker run --init --rm \
	--name ${docker_name} \
	-p 8080:8080 \
	--env "TCI_HOST_STORE=${tci_store}" \
	-v ${tci_store}:/var/tci-store \
	-v jenkins_home:/var/jenkins_home \
	-v /var/run/docker.sock:/var/run/docker.sock \
	--add-host=tci-relay:${relay_addr} \
	--add-host=tci-tftp:${tftp_addr} \
	--add-host=t88-bmc:${t88_bmc_addr} \
	tci-jenkins:1
