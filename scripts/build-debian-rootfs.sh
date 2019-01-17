#!/usr/bin/env bash

set -e

name="$(basename $0)"

SCRIPTS_TOP=${SCRIPTS_TOP:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

source ${SCRIPTS_TOP}/common.sh

clean_qemu_static() {
	local chroot=${1}

	if [[ ${cross_build} ]]; then
		run_cmd "sudo rm -f ${chroot}${qemu_static}"
	fi
}

copy_qemu_static() {
	local chroot=${1}

	if [[ ${cross_build} ]]; then
		run_cmd "sudo cp -f ${qemu_static} ${chroot}${qemu_static}"
	fi
}

cleanup_chroot () {
	local chroot=${1}

	clean_qemu_static ${chroot}
}

enter_chroot() {
	local chroot=${1}
	shift

	copy_qemu_static ${chroot}

	run_cmd "sudo LANG=C.UTF-8 chroot ${chroot} /bin/bash -x <<EOF
${@}
EOF"
	cleanup_chroot ${chroot}
}

make_rootfs() {
	local rootfs=${1}
	local release=${2}
	local mirror=${3}

	if [[ ${cross_build} ]]; then
		debootstrap_extra="--foreign --arch ${target_arch}"
	fi

	sudo true
	run_cmd "sudo debootstrap ${debootstrap_extra} --no-check-gpg \
		${release} ${rootfs} ${mirror}"

	sudo true
	if [[ ${cross_build} ]]; then
		enter_chroot ${rootfs} "/debootstrap/debootstrap --second-stage"
	fi

	sudo true
	run_cmd "sudo sed --in-place 's/$/ non-free contrib/' \
		${rootfs}/etc/apt/sources.list"

	enter_chroot ${rootfs} "
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get -y install openssh-server netcat-openbsd tcpdump \
			pciutils strace firmware-qlogic firmware-bnx2x
	"

	run_cmd "sudo chown $(id --user --real --name): ${rootfs}"
}

setup_initrd_boot() {
	local rootfs=${1}

	run_cmd "sudo ln -sf 'lib/systemd/systemd' '${rootfs}/init'"
	run_cmd "sudo cp -a '${rootfs}/etc/os-release' '${rootfs}/etc/initrd-release'"
}

setup_autologin() {
	local rootfs=${1}

	run_cmd "sudo sed --in-place 's/root:x:0:0/root::0:0/' \
		${rootfs}/etc/passwd"

	# TODO: Shadow setup???

	run_cmd "sudo sed --in-place \
		's|-/sbin/agetty -o|-/sbin/agetty --autologin root -o|' \
		${rootfs}/lib/systemd/system/serial-getty@.service"

	run_cmd "sudo sed --in-place \
		's|-/sbin/agetty -o|-/sbin/agetty --autologin root -o|' \
		${rootfs}/lib/systemd/system/getty@.service"
}

setup_network() {
	local rootfs=${1}

	run_cmd "echo '${TARGET_HOSTNAME}' | sudo_write '${rootfs}/etc/hostname'"

	run_cmd "sudo_append '${rootfs}/etc/network/interfaces' <<EOF
allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug enP2p1s0v0
iface enP2p1s0v0 inet dhcp

allow-hotplug enP2p1s0f1
iface enP2p1s0f1 inet dhcp
EOF"


# TODO: Need this, or from dhcp???
	run_cmd "sudo_append '${rootfs}/etc/resolv.conf' <<EOF
nameserver 4.2.2.4
nameserver 4.2.2.2
nameserver 8.8.8.8
EOF"
}

setup_sshd() {
	local rootfs=${1}
	local srv_key=${2}

	sshd_config() {
		local key=${1}
		local value=${2}
		
		run_cmd "sudo sed --in-place 's/^${key}.*$//' \
			${rootfs}/etc/ssh/sshd_config"
		run_cmd "echo '${key} ${value}' | sudo_append '${rootfs}/etc/ssh/sshd_config'"
	}

	sshd_config "PermitRootLogin" "yes"
	sshd_config "UseDNS" "no"
	sshd_config "PermitEmptyPasswords" "yes"

	if [[ ! -f "${rootfs}/etc/ssh/ssh_host_rsa_key" ]]; then
		echo "${name}: ERROR: Not found: ${rootfs}/etc/ssh/ssh_host_rsa_key" >&2
		exit 1
	fi

	run_cmd "sudo cp -f ${rootfs}/etc/ssh/ssh_host_rsa_key ${srv_key}"
	echo "${name}: USER=@$(id --user --real --name)@" >&2
	#printenv
	run_cmd "sudo chown $(id --user --real --name): ${srv_key}"

}

setup_ssh_keys() {
	local rootfs=${1}
	local key=${2}

	run_cmd "sudo mkdir -p -m0700 '${rootfs}/root/.ssh'"

	run_cmd "ssh-keygen -q -f "${key}" -N ''"
	run_cmd "cat '${key}.pub' | sudo_append '${rootfs}/root/.ssh/authorized_keys'"

	for key in ${HOME}/.ssh/id_*.pub; do
		[[ -f "${key}" ]] || continue
		run_cmd "cat '${key}' | sudo_append '${rootfs}/root/.ssh/authorized_keys'"
		local found=1
	done
}

setup_modules_copy() {
	local rootfs=${1}
	local src=${2}
	local dest="${rootfs}/lib/modules/$(basename ${src})"

	if [[ ${verbose} ]]; then
		local extra='-v'
	fi

	run_cmd "sudo mkdir -p ${dest}"
	run_cmd "sudo rsync -av --delete ${extra} ${src}/ ${dest}/"
}

setup_modules_virtio() {
	local rootfs=${1}

	run_cmd "sudo mkdir -p '${rootfs}/usr/lib/modules'"
	run_cmd "echo '${MODULES_ID} /usr/lib/modules 9p trans=virtio,version=9p2000.L 0 0' \
		| sudo_append '${rootfs}/etc/fstab'"
}

setup_relay_client() {
	local rootfs=${1}

	local last_target="last-boot.target"
	local tci_service="tci-relay-client.service"
	local tci_script="/bin/tci-relay-client.sh"

	run_cmd "sudo_write '${rootfs}/etc/systemd/system/${last_target}' <<EOF
[Unit]
Description=Last Boot Target
Requires=multi-user.target
After=multi-user.target
AllowIsolate=yes
EOF"

	run_cmd "sudo_write '${rootfs}/etc/systemd/system/${tci_service}' <<EOF
[Unit]
Description=TCI Relay Client Service
Requires=network-online.target last-boot.target
After=network-online.target last-boot.target

[Service]
Type=simple
StandardOutput=journal+console
StandardError=journal+console
ExecStart=${tci_script}

[Install]
WantedBy=${last_target}
EOF"

	run_cmd "sudo_write '${rootfs}${tci_script}' <<EOF
#!/usr/bin/env bash
set -x
echo ''
echo 'TCI Relay Client: start'
echo '----------'
date
uname -a
cat /etc/os-release
systemctl status networking.service
ip a
cat /proc/cmdline
echo '----------'
echo ''

my_addr() {
	ip route get 8.8.8.8 | egrep -o 'src [0-9.]*' | cut -f 2 -d ' '
}

triple=\"\\\$(cat /proc/cmdline | egrep --only-matching 'tci_relay_triple=[^ ]*' | cut -d '=' -f 2)\"

if [[ ! \\\${triple} ]]; then
	echo \"TCI Relay Client: ERROR: Triple not found: '\\\$(cat /proc/cmdline)'.\"
	exit 2
fi

ip_test=\"\\\$(my_addr)\"

if [[ ! \\\${ip_test} ]]; then
	echo \"TCI Relay Client: WARNING: No IP address found.\"
	dhclient -v
	ip a
	ip_test=\"\\\$(my_addr)\"
fi

server=\"\\\$(echo \\\${triple} | cut -d ':' -f 1)\"
port=\"\\\$(echo \\\${triple} | cut -d ':' -f 2)\"
token=\"\\\$(echo \\\${triple} | cut -d ':' -f 3)\"

count=0
while [[ \\\${count} -lt 240 ]]; do
	msg=\"PUT:\\\${token}:\\\$(my_addr)\"
	reply=\\\$(echo -n \\\${msg} | nc -w10 \\\${server} \\\${port})
	if [[ \\\${reply} == 'QED' || \\\${reply} == 'UPD' ]]; then
		break
	fi
	let count=count+10
	sleep 10s
done

echo 'TCI Relay Client: end'
EOF"

	run_cmd "sudo chmod u+x '${rootfs}${tci_script}'"

	enter_chroot ${rootfs} "
		systemctl set-default ${last_target}
		systemctl enable ${tci_service}
	"
}

apt_cleanup() {
	local rootfs=${1}

	enter_chroot ${rootfs} "
		export DEBIAN_FRONTEND=noninteractive
		apt-get -y autoremove
		rm -rf /var/lib/apt/lists/*
	"
}

delete_rootfs() {
	local rootfs=${1}

	run_cmd "sudo rm -rf ${rootfs}"
}

clean_make_disk_img() {
	local mnt=${1}

	run_cmd "sudo umount ${mnt} || :"
}

on_exit() {
	local rootfs=${1}
	local mnt=${2}

	echo "${name}: Step ${current_step}: FAILED." >&2

	cleanup_chroot ${rootfs}
	
	if [[ -d "${mnt}" ]]; then
		clean_make_disk_img "${mnt}"
		rm -rf "${mnt}"
	fi

	if [[ ! ${keep_rootfs} ]]; then
		delete_rootfs ${rootfs}
	fi
}

make_disk_img() {
	local rootfs=${1}
	local img=${2}
	local mnt=${3}

	tmp_img="$(mktemp --tmpdir tci-XXXX.img)" # FIXME: need to add this to on_exit

	run_cmd "dd if=/dev/zero of=${tmp_img} bs=1M count=1536"
	run_cmd "mkfs.ext4 ${tmp_img}"

	run_cmd "mkdir -p ${mnt}"

	run_cmd "sudo mount  ${tmp_img} ${mnt}"
	run_cmd "sudo cp -a ${rootfs}/* ${mnt}"

	run_cmd "sudo umount ${mnt} || :"
	run_cmd "cp ${tmp_img} ${img}"
	run_cmd "rm -f  ${tmp_img}"
}

make_initrd() {
	local rootfs=${1}
	local rd=${2}

	run_cmd "(cd ${rootfs} && sudo find . | sudo cpio --create --format='newc' --owner=root:root | gzip) > ${rd}"
}

make_manifest() {
	local rootfs=${1}
	local man=${2}

	run_cmd "(cd ${rootfs} && sudo find . -type f -ls | sort) > ${man}"
}

usage() {
	local old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${name} - Builds a minimal debian disk image." >&2
	echo "Usage: ${name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -a --arch              - Target architecture. Default: '${target_arch}'." >&2
	echo "  -b --build-dir         - Build directory. Default: '${build_dir}'." >&2
	echo "  -h --help              - Show this help and exit." >&2
	echo "  -i --output-disk-image - Output a binary disk image file '${disk_img}'." >&2
	echo "  -k --keep-rootfs       - Keep temporary rootfs directory. Default: ${keep_rootfs}" >&2
	echo "  -m --kernel-modules    - Kernel modules to install. Default: '${kernel_modules}'." >&2
	echo "  -n --image-name        - Output image basename. Default: '${rootfs_dir}', '${initrd}', '${disk_img}'." >&2
	echo "  -v --verbose           - Verbose execution." >&2
	echo "  -y --type              - Image type {$(clean_ws ${image_type})}. Default: '${image_type}'." >&2
	echo "Option steps:" >&2
	echo "  -1 --bootstrap    - Run debootstrap step (implies --keep-rootfs). Default: '${step_bootstrap}'." >&2
	echo "  -2 --rootfs-setup - Run rootfs setup step (implies --keep-rootfs). Default: '${step_rootfs_setup}'." >&2
	echo "  -3 --make-image   - Run make image step. Default: '${step_make_image}'." >&2
	eval "${old_xtrace}"
}

short_opts="a:b:hikm:n:vy:123"
long_opts="arch:,build-dir:,help,output-disk-image,keep-rootfs,\
image-name:,kernel-modules:,verbose,type:,\
bootstrap,rootfs-setup,make-image"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${name}" -- "$@")

if [ $? != 0 ]; then
	echo "${name}: ERROR: Internal getopt" >&2
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-a | --arch)
		target_arch=$(get_arch "${2}")
		shift 2
		;;
	-b | --build-dir)
		build_dir="${2}"
		shift 2
		;;
	-h | --help)
		usage=1
		shift
		;;
	-i | --output-disk-image)
		output_disk_image=1
		shift
		;;
	-k | --keep-rootfs)
		keep_rootfs=1
		shift
		;;
	-m | --kernel-modules)
		kernel_modules="${2}"
		shift 2
		;;
	-n | --image-name)
		image_name="${2}"
		shift 2
		;;
	-v | --verbose)
		set -x
		verbose=1
		shift
		;;
	-y | --type)
		image_type="${2}"
		shift 2
		;;
	-1 | --bootstrap)
		step_bootstrap=1
		keep_rootfs=1
		shift
		;;
	-2 | --rootfs-setup)
		step_rootfs_setup=1
		keep_rootfs=1
		shift
		;;
	-3 | --make-image)
		step_make_image=1
		shift
		;;
	--)
		shift
		break
		;;
	*)
		echo "${name}: ERROR: Internal opts: '${@}'" >&2
		exit 1
		;;
	esac
done

cmd_trace=1
os_release="buster"
os_mirror="http://ftp.us.debian.org/debian"

if [[ -z "${image_type}" ]]; then
	image_type="qemu"
fi

if [[ -z "${build_dir}" ]]; then
	build_dir="$(pwd)"
fi

host_arch=$(get_arch "$(uname -m)")

if [[ -z "${target_arch}" ]]; then
	target_arch="${host_arch}"
fi

if [[ -z "${image_name}" ]]; then
	image_name="${target_arch}-debian-${os_release}"
fi

if [[ -n "${kernel_modules}" ]]; then
	if [[ ! -d "${kernel_modules}" ]]; then
		echo "${name}: ERROR: <kernel-modules> directory not found: '${kernel_modules}'" >&2
		usage
		exit 1
	fi
	if [[ "$(basename $(cd ${kernel_modules}/.. && pwd))" != "modules" ]]; then
		echo "${name}: ERROR: No kernel modules found in '${kernel_modules}'" >&2
		usage
		exit 1
	fi
fi


rootfs_dir="${build_dir}/${image_name}.rootfs"
disk_img="${build_dir}/${image_name}.img"
initrd="${build_dir}/${image_name}.initrd"
manifest="${build_dir}/${image_name}.manifest"

srv_key="${build_dir}/${image_name}.srv-key"
#ssh_hosts="${build_dir}/${image_name}.knownhosts"
login_key="${build_dir}/${image_name}.login-key"

step_code="${step_bootstrap}-${step_rootfs_setup}-${step_make_image}"
case "${step_code}" in
1--|1-1-|1-1-1|-1-|-1-1|--1)
	#echo "${name}: Steps OK" >&2
	;;
--)
	step_bootstrap=1
	step_rootfs_setup=1
	step_make_image=1
	;;
1--1)
	echo "${name}: ERROR: Bad flags: 'bootstrap + make_image'." >&2
	usage
	exit 1
	;;
*)
	echo "${name}: ERROR: Internal bad step_code: '${step_code}'." >&2
	exit 1
	;;
esac

if [[ "${image_type}" != "qemu" ]]; then
	echo "${name}: ERROR: Unsupported image type '${image_type}'" >&2
	usage
	exit 1
fi

if [[ -n "${usage}" ]]; then
	usage
	exit 0
fi

if [[ "${host_arch}" != "${target_arch}" ]]; then
	cross_build=1

	case "${target_arch}" in
		amd64) qemu_static="/usr/bin/qemu-x86_64-static" ;;
		arm64) qemu_static="/usr/bin/qemu-aarch64-static" ;;
	esac

	if ! test -x "$(command -v ${qemu_static})"; then
		echo "${name}: ERROR: Please install QEMU user emulation '${qemu_static}'." >&2
		exit 1
	fi
	
	# FIXME: Check for binfmt support: systemctl status systemd-binfmt.service???
fi

sudo true

run_cmd "sudo rm -rf ${login_key} ${disk_img} ${initrd} ${manifest}"
cleanup_chroot ${rootfs_dir}

trap "on_exit ${rootfs_dir} -" EXIT

if [[ ${step_bootstrap} ]]; then
	current_step="bootstrap"
	echo "${name}: Step ${current_step}: start." >&2
	delete_rootfs ${rootfs_dir}
	make_rootfs ${rootfs_dir} ${os_release} ${os_mirror}
	echo "${name}: Step ${current_step}: done." >&2
fi

if [[ ${step_rootfs_setup} ]]; then
	current_step="rootfs_setup"
	echo "${name}: Step ${current_step}: start." >&2
	setup_initrd_boot ${rootfs_dir}
	setup_autologin ${rootfs_dir}
	setup_network ${rootfs_dir}
	setup_sshd ${rootfs_dir} ${srv_key}
	setup_ssh_keys ${rootfs_dir} ${login_key}
	if [[ -n "${kernel_modules}" ]]; then
		setup_modules_copy ${rootfs_dir} ${kernel_modules}
	else
		setup_modules_virtio ${rootfs_dir}
	fi
	setup_relay_client ${rootfs_dir}

	apt_cleanup ${rootfs_dir}
	echo "${name}: Step ${current_step}: done." >&2
fi

if [[ ${step_make_image} ]]; then
	current_step="make_image"
	echo "${name}: Step ${current_step}: start." >&2

	if [[ ${output_disk_image} ]]; then
		tmp_mnt="$(mktemp --directory --tmpdir tci-XXXX.mnt)"
		trap "on_exit ${rootfs_dir} ${tmp_mnt}" EXIT
		make_disk_img ${rootfs_dir} ${disk_img} ${tmp_mnt}
		trap "on_exit ${rootfs_dir} -" EXIT
		clean_make_disk_img "${tmp_mnt}"
	fi

	make_initrd ${rootfs_dir} ${initrd}
	make_manifest ${rootfs_dir} ${manifest}

	rm -rf ${tmp_mnt}
	echo "${name}: Step ${current_step}: done." >&2
fi

trap - EXIT

if [[ ! ${keep_rootfs} ]]; then
	delete_rootfs ${rootfs_dir}
fi

echo "${name}: Success: ${image_name}" >&2
