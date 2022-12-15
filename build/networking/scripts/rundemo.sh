#!/bin/bash
#Copyright (C) 2021-2022 Intel Corporation
#SPDX-License-Identifier: Apache-2.0

stty -echoctl # hide ctrl-c

usage() {
    echo ""
    echo "Usage:"
    echo "rundemo.sh: -s|--scripts-dir --deps-install-dir --nr-install-dir --sde-install-dir -w|--workdir -h|--help"
    echo ""
    echo "  --deps-install-dir: Networking-recipe dependencies install path. [Default: ${workdir}/networking-recipe/deps_install"
    echo "  -h|--help: Displays help"
    echo "  --nr-install-dir: Networking-recipe install path. [Default: ${workdir}/networking-recipe/install"
    echo "  --p4c-install-dir: P4C install path. [Default: ${workdir}/p4c/install"
    echo "  -s|--scripts-dir: Directory path where all utility scripts copied.  [Default: ${workdir}/scripts]"
    echo "  --sde-install-dir: P4 SDE install path. [Default: ${workdir}/p4-sde/install"
    echo "  -w|--workdir: Working directory"
    echo ""
}

# Parse command-line options.
SHORTOPTS=:h,s:,w:
LONGOPTS=help,deps-install-dir:,nr-install-dir:,p4c-install-dir:,sde-install-dir:,scripts-dir:,workdir:

GETOPTS=$(getopt -o ${SHORTOPTS} --long ${LONGOPTS} -- "$@")
eval set -- "${GETOPTS}"

# Set defaults.
WORKING_DIR=/root
SCRIPTS_DIR="${WORKING_DIR}"/scripts
DEPS_INSTALL_DIR="${WORKING_DIR}"/networking-recipe/deps_install
P4C_INSTALL_DIR="${WORKING_DIR}"/p4c/install
SDE_INSTALL_DIR="${WORKING_DIR}"/p4-sde/install
NR_INSTALL_DIR="${WORKING_DIR}"/networking-recipe/install

# Process command-line options.
while true ; do
    case "${1}" in
    --deps-install-dir)
        DEPS_INSTALL_DIR="${2}"
        shift 2 ;;
    -h|--help)
        usage
        exit 1 ;;
    --nr-install-dir)
        NR_INSTALL_DIR="${2}"
        shift 2 ;;
    --p4c-install-dir)
        P4C_INSTALL_DIR="${2}"
        shift 2 ;;
    --sde-install-dir)
        SDE_INSTALL_DIR="${2}"
        shift 2 ;;
    -s|--scripts-dir)
        SCRIPTS_DIR="${2}"
        shift 2 ;;
    -w|--workdir)
        WORKING_DIR="${2}"
        shift 2 ;;
    --)
        shift
        break ;;
    *)
        echo "Internal error!"
        exit 1 ;;
    esac
done

# Exit function
exit_function()
{
    echo "Exiting cleanly"
    pushd /root || exit
    rm -f network-config-v1.yaml meta-data user-data
    pkill qemu
    rm -rf /tmp/vhost-user-*
    rm -f vm1.qcow2 vm2.qcow2
    popd || exit
    exit
}

# Display argument data after parsing commandline arguments
echo ""
echo "WORKING_DIR: ${WORKING_DIR}"
echo "SCRIPTS_DIR: ${SCRIPTS_DIR}"
echo "DEPS_INSTALL_DIR: ${DEPS_INSTALL_DIR}"
echo "P4C_INSTALL_DIR: ${P4C_INSTALL_DIR}"
echo "SDE_INSTALL_DIR: ${SDE_INSTALL_DIR}"
echo "NR_INSTALL_DIR: ${NR_INSTALL_DIR}"
echo ""

echo ""
echo "Cleaning from previous run"
echo ""

pkill qemu
rm -rf /tmp/vhost-user-*
killall ovsdb-server
killall ovs-vswitchd
killall infrap4d


echo ""
echo "Setting hugepages up and starting networking-recipe processes"
echo ""

unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY

pushd "${WORKING_DIR}" || exit
# shellcheck source=/dev/null
. "${SCRIPTS_DIR}"/initialize_env.sh --sde-install-dir="${SDE_INSTALL_DIR}" \
      --nr-install-dir="${NR_INSTALL_DIR}" --deps-install-dir="${DEPS_INSTALL_DIR}" \
      --p4c-install-dir="${P4C_INSTALL_DIR}"

. "${SCRIPTS_DIR}"/set_hugepages.sh

. "${SCRIPTS_DIR}"/setup_nr_cfg_files.sh --nr-install-dir="${NR_INSTALL_DIR}" \
      --sde-install-dir="${SDE_INSTALL_DIR}"

. "${SCRIPTS_DIR}"/run_infrap4d.sh --nr-install-dir="${NR_INSTALL_DIR}"
popd || exit

echo ""
echo "Creating TAP ports"
echo ""

pushd "${WORKING_DIR}" || exit
# Wait for networking-recipe processes to start gRPC server and open ports for clients to connect.
sleep 1

gnmi-ctl set "device:virtual-device,name:net_vhost0,host-name:host1,\
    device-type:VIRTIO_NET,queues:1,socket-path:/tmp/vhost-user-0,\
    port-type:LINK"
gnmi-ctl set "device:virtual-device,name:net_vhost1,host-name:host2,\
    device-type:VIRTIO_NET,queues:1,socket-path:/tmp/vhost-user-1,\
    port-type:LINK"
popd || exit

echo ""
echo "Generating dependent files from P4C and pipeline builder"
echo ""

export OUTPUT_DIR="${WORKING_DIR}"/examples/simple_l3/
p4c --arch psa --target dpdk --output "${OUTPUT_DIR}"/pipe --p4runtime-files \
    "${OUTPUT_DIR}"/p4Info.txt --bf-rt-schema "${OUTPUT_DIR}"/bf-rt.json \
    --context "${OUTPUT_DIR}"/pipe/context.json "${OUTPUT_DIR}"/simple_l3.p4

pushd "${WORKING_DIR}"/examples/simple_l3 || exit
tdi_pipeline_builder --p4c_conf_file=simple_l3.conf \
    --bf_pipeline_config_binary_file=simple_l3.pb.bin
popd || exit

echo ""
echo "Starting VM1_TAP_DEV"
echo ""

pushd "${WORKING_DIR}" || exit
    #-object memory-backend-file,id=mem,size=1024M,mem-path=/hugetlbfs1,share=on \
kvm -smp 1 -m 256M \
    -boot c -cpu host --enable-kvm -nographic \
    -name VM1_TAP_DEV \
    -hda ./vm1.qcow2 \
    -drive file=seed1.img,id=seed,if=none,format=raw,index=1 \
    -device virtio-blk,drive=seed \
    -object memory-backend-file,id=mem,size=256M,mem-path=/mnt/huge,share=on \
    -numa node,memdev=mem \
    -mem-prealloc \
    -chardev socket,id=char1,path=/tmp/vhost-user-0 \
    -netdev type=vhost-user,id=netdev0,chardev=char1,vhostforce \
    -device virtio-net-pci,mac=52:54:00:34:12:aa,netdev=netdev0 \
    -serial telnet::6551,server,nowait &

sleep 5
echo ""
echo "Waiting 10 seconds before starting second VM"
echo ""
for i in {1..10}
do
    sleep 1
    echo -n "."
    if [ "$(( i % 30 ))" == "0" ]
    then
        echo ""
    fi
done
echo ""
echo "Starting VM2_TAP_DEV"
echo ""

kvm -smp 1 -m 256M \
    -boot c -cpu host --enable-kvm -nographic \
    -name VM2_TAP_DEV \
    -hda ./vm2.qcow2 \
    -drive file=seed2.img,id=seed,if=none,format=raw,index=1 \
    -device virtio-blk,drive=seed \
    -object memory-backend-file,id=mem,size=256M,mem-path=/mnt/huge,share=on \
    -numa node,memdev=mem \
    -mem-prealloc \
    -chardev socket,id=char2,path=/tmp/vhost-user-1 \
    -netdev type=vhost-user,id=netdev1,chardev=char2,vhostforce \
    -device virtio-net-pci,mac=52:54:00:34:12:bb,netdev=netdev1 \
    -serial telnet::6552,server,nowait &
popd || exit

echo ""
echo "Programming P4-OVS pipelines"
echo ""

p4rt-ctl set-pipe br0 "${WORKING_DIR}"/examples/simple_l3/simple_l3.pb.bin \
    "${WORKING_DIR}"/examples/simple_l3/p4Info.txt
p4rt-ctl add-entry br0 ingress.ipv4_host \
    "hdr.ipv4.dst_addr=1.1.1.1,action=ingress.send(0)"
p4rt-ctl add-entry br0 ingress.ipv4_host \
    "hdr.ipv4.dst_addr=2.2.2.2,action=ingress.send(1)"
