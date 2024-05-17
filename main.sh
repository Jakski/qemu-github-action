#!/usr/bin/env bash
################################################################################
# Start an ad-hoc virtual machine using QEMU and Cloud Init provisioning disk.
# It will be started as a systemd service on user.
#
# Environment variables:
#   - QEMU_INSTANCE_EXTRA_SIZE - How much to enlarge disk, e.g. 10G
#   - QEMU_INSTANCE_MEMORY - Memory expressed in megabytes
#   - QEMU_INSTANCE_CPU - Virtual CPUs quantity
#   - QEMU_INSTANCE_IMAGE_URL - URL to QCOW2 image
#   - QEMU_INSTANCE_DIR - Directory where instance data will be placed
#   - QEMU_INSTANCE_SSH_PORT - Port number on local machine to forward to remote SSH
#   - QEMU_INSTANCE_SSH_USER - User for SSH and sudo access
#   - QEMU_INSTANCE_NAME - Hostname and systemd service name
#   - QEMU_INSTANCE_SHELL - Path to shell for SSH user
#
# Data directory layout:
#   - cidata.iso - Cloud Init provisioning disk
#   - image.qcow2 - Base image downloaded from URL
#   - rootfs.qcow2 - Copy-on-write disk layer for virtual machine
#   - ssh_config - OpenSSH client configuration with access details
#   - id_ed25519 - Private SSH key
#   - id_ed25519 - Private SSH key
#   - id_ed25519.pub - Public SSH key
#   - pid.txt - PID file left managed by QEMU
#   - console.log - Serial console output
#   - console.socket - Serial console UNIX socket
#   - monitor.socket - QEMU supervisor UNIX socket
#   - meta-data/user-data - Files used to generate Cloud Init provisioning disk
################################################################################

set -eEuo pipefail
shopt -s inherit_errexit nullglob lastpipe

[ -v QEMU_INSTANCE_EXTRA_SIZE ] || declare QEMU_INSTANCE_EXTRA_SIZE
[ -v QEMU_INSTANCE_MEMORY ] || declare QEMU_INSTANCE_MEMORY=1024
[ -v QEMU_INSTANCE_CPU ] || declare QEMU_INSTANCE_CPU=1
[ -v QEMU_INSTANCE_IMAGE_URL ] || declare QEMU_INSTANCE_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
[ -v QEMU_INSTANCE_DIR ] || declare QEMU_INSTANCE_DIR="ci-instance"
[ -v QEMU_INSTANCE_SSH_PORT ] || declare QEMU_INSTANCE_SSH_PORT=8022
[ -v QEMU_INSTANCE_SSH_USER ] || declare QEMU_INSTANCE_SSH_USER="ci-instance"
[ -v QEMU_INSTANCE_NAME ] || declare QEMU_INSTANCE_NAME="ci-instance"
[ -v QEMU_INSTANCE_SHELL ] || declare QEMU_INSTANCE_SHELL="/bin/bash"

on_exit() {
	declare cmd=$BASH_COMMAND exit_code=$? i=0 line=""
	declare -a all_functions=() parts
	if [ "$exit_code" != 0 ] && [ "${HANDLED_ERROR:-}" != 1 ]; then
		printf "%s\n" "Process ${BASHPID} exited with code ${exit_code} in command: ${cmd}" 1>&2
		while true; do
			line=$(caller "$i") || break
			printf "%s\n" "  ${line}" 1>&2
			i=$((i + 1))
		done
		HANDLED_ERROR=1
	fi
	declare -F | mapfile -t all_functions
	for i in "${all_functions[@]}"; do
		if [[ $i =~ declare[[:space:]]-f[[:space:]]on_exit_[^[:space:]]+$ ]]; then
			read -r -a parts <<<"$i"
			"${parts[2]}"
		fi
	done
	exit "$exit_code"
}

on_error() {
	declare cmd=$BASH_COMMAND exit_code=$? i=0 line=""
	printf "%s\n" "Process ${BASHPID} exited with code ${exit_code} in command: ${cmd}" 1>&2
	while true; do
		line=$(caller "$i") || break
		printf "%s\n" "  ${line}" 1>&2
		i=$((i + 1))
	done
	HANDLED_ERROR=1
	exit "$exit_code"
}

install_dependencies() {
	declare -a pkgs=()
	if ! command -v genisoimage >/dev/null; then
		pkgs+=(genisoimage)
	fi
	if ! command -v qemu-system-x86_64 >/dev/null; then
		pkgs+=(qemu-system-x86)
	fi
	if ! command -v qemu-img >/dev/null; then
		pkgs+=(qemu-utils)
	fi
	if ! command -v wget >/dev/null; then
		pkgs+=(wget)
	fi
	if [ "${#pkgs[@]}" != 0 ]; then
		if [ "$UID" != 0 ]; then
			sudo apt-get install -y "${pkgs[@]}"
		else
			apt-get install -y "${pkgs[@]}"
		fi
	fi
	if [ ! -f image.qcow2 ]; then
		printf "%s\n" "Downloading system image"
		wget -q -O image.qcow2 "$QEMU_INSTANCE_IMAGE_URL"
	fi
}

create_cloud_init_data() {
	declare -a public_key
	declare private_key_file
	rm -f id_ed25519 id_ed25519.pub
	ssh-keygen -q -t ed25519 -f id_ed25519 -N "" -C "Automatically generated key"
	private_key_file=$(realpath id_ed25519)
	printf "%s" "\
Host ${QEMU_INSTANCE_NAME}
	HostName 127.0.0.1
	User ${QEMU_INSTANCE_SSH_USER}
	Port ${QEMU_INSTANCE_SSH_PORT}
	StrictHostKeyChecking no
	LogLevel ERROR
	UserKnownHostsFile /dev/null
	IdentityFile ${private_key_file}
	IdentitiesOnly yes
" >ssh_config
	mapfile -d "" public_key <id_ed25519.pub
	printf "%s" "\
instance-id: ${QEMU_INSTANCE_NAME}
local-hostname: ${QEMU_INSTANCE_NAME}
" >meta-data
	printf "%s" "\
#cloud-config
users:
  - name: ${QEMU_INSTANCE_SSH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '*'
    shell: ${QEMU_INSTANCE_SHELL}
    ssh_authorized_keys:
      - ${public_key[0]}
packages:
  - sudo
  - bash
" >user-data
	genisoimage -quiet -output cidata.iso -volid cidata -joliet -rock user-data meta-data
}

run_instance() {
	printf "%s\n" "Creating copy-on-write instance image"
	if systemctl --user list-unit-files "${QEMU_INSTANCE_NAME}.service" >/dev/null; then
		printf "%s\n" "Removing previously running instance"
		if systemctl --user -q is-active "${QEMU_INSTANCE_NAME}.service"; then
			# When using KVM systemd throws:
			#   Failed to kill unit ci-instance.service: Access denied
			# but process gets terminated anyway.
			systemctl --user kill --signal KILL "${QEMU_INSTANCE_NAME}.service" &>/dev/null || true
		fi
		while systemctl --user -q is-active "${QEMU_INSTANCE_NAME}.service"; do
			printf "%s\n" "Waiting for previously started instance to terminate"
			sleep 0.5
		done
		systemctl --user reset-failed "${QEMU_INSTANCE_NAME}.service" &>/dev/null || true
	fi
	rm -f rootfs.qcow2
	qemu-img create -q -f qcow2 -b image.qcow2 -F qcow2 rootfs.qcow2
	if [ -v QEMU_INSTANCE_EXTRA_SIZE ]; then
		qemu-img resize -q rootfs.qcow2 "+${QEMU_INSTANCE_EXTRA_SIZE}"
	fi
	printf "%s\n" "Starting instance"
	systemd-run \
		--user \
		--unit "$QEMU_INSTANCE_NAME" \
		--same-dir \
		-- \
		qemu-system-x86_64 \
		-cpu max \
		-m "$QEMU_INSTANCE_MEMORY" \
		-smp "$QEMU_INSTANCE_CPU" \
		-netdev user,id=user0,hostfwd=tcp:127.0.0.1:"$QEMU_INSTANCE_SSH_PORT"-:22 \
		-device virtio-net-pci,netdev=user0 \
		-device virtio-rng-pci \
		-drive file=rootfs.qcow2,format=qcow2,id=disk0,if=none,index=0 \
		-device virtio-blk-pci,drive=disk0,bootindex=1 \
		-drive file=cidata.iso,format=raw,if=virtio \
		-monitor unix:monitor.socket,server=on,wait=off \
		-chardev socket,id=char0,path=console.socket,logfile=console.log,server=on,wait=off \
		-serial chardev:char0 \
		-nographic \
		-pidfile pid.txt
}

wait_for_ssh() {
	printf "%s\n" "Waiting for SSH"
	while ! timeout 1 ssh -F ssh_config "$QEMU_INSTANCE_NAME" echo -n 2>&1; do
		sleep 1
	done
}

main() {
	mkdir -vp "$QEMU_INSTANCE_DIR"
	mkdir -vp ~/.ssh
	chmod -c 700 ~/.ssh
	pushd "$QEMU_INSTANCE_DIR" >/dev/null
	install_dependencies
	create_cloud_init_data
	run_instance
	wait_for_ssh
	popd >/dev/null
}

trap on_exit EXIT
trap on_error ERR
main "$@"
