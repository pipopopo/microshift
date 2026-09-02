#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="microshift-bootc-disconnected"
IMAGE_TAG="v4.22"
VM_NAME="microshift-disconnected"
VM_MEMORY=8192
VM_VCPUS=4
VM_DISK_SIZE="50G"
REMOTE_USER="${REMOTE_USER:-kenny}"
BUILD_DIR="microshift-build-disconnected"

usage() {
    echo "Usage: $0 <kvm-host-ip> [--destroy]"
    echo ""
    echo "Deploy a disconnected MicroShift 4.22 VM on a remote KVM host."
    echo "All container images are embedded in the ISO; outbound internet"
    echo "is blocked on the VM via nftables."
    echo ""
    echo "Arguments:"
    echo "  kvm-host-ip    IP address of the KVM host"
    echo "  --destroy      Remove existing VM before deploying"
    echo ""
    echo "Prerequisites:"
    echo "  - pull-secret.json in this directory (download from console.redhat.com)"
    echo "  - SSH key-based access to the KVM host"
    echo "  - Registry credentials in ~/.config/containers/auth.json"
    echo ""
    echo "NOTE: Build takes significantly longer than the connected variant"
    echo "because all MicroShift container images are pulled during build."
    exit 1
}

[[ $# -lt 1 ]] && usage
KVM_HOST="$1"
DESTROY=false
[[ "${2:-}" == "--destroy" ]] && DESTROY=true

ssh_cmd() {
    ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${KVM_HOST}" "$@"
}

echo "==> Targeting KVM host: ${KVM_HOST} (DISCONNECTED build)"

# Validate prerequisites
if [[ ! -f "${SCRIPT_DIR}/pull-secret.json" ]]; then
    echo "ERROR: pull-secret.json not found in ${SCRIPT_DIR}"
    echo "Download from: https://console.redhat.com/openshift/downloads"
    exit 1
fi

if [[ ! -f "${HOME}/.config/containers/auth.json" ]]; then
    echo "ERROR: ~/.config/containers/auth.json not found"
    echo "Run: podman login registry.redhat.io"
    exit 1
fi

# Destroy existing VM if requested
if $DESTROY; then
    echo "==> Destroying existing VM '${VM_NAME}'..."
    ssh_cmd "sudo virsh destroy ${VM_NAME} 2>/dev/null; sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null" || true
fi

# Phase 1: Prepare the remote server
echo "==> Installing podman + skopeo on ${KVM_HOST}..."
ssh_cmd "command -v podman &>/dev/null || sudo dnf install -y podman"
ssh_cmd "command -v skopeo &>/dev/null || sudo dnf install -y skopeo"

echo "==> Copying registry credentials..."
scp -o StrictHostKeyChecking=no "${HOME}/.config/containers/auth.json" "${REMOTE_USER}@${KVM_HOST}:~/auth.json"
ssh_cmd "mkdir -p ~/.config/containers && mv ~/auth.json ~/.config/containers/auth.json && chmod 600 ~/.config/containers/auth.json"
ssh_cmd "sudo mkdir -p /root/.config/containers && sudo cp ~/.config/containers/auth.json /root/.config/containers/auth.json"

echo "==> Activating libvirt default network..."
ssh_cmd "sudo virsh net-start default 2>/dev/null; sudo virsh net-autostart default 2>/dev/null" || true

# Phase 2: Prepare build context
echo "==> Uploading build context..."
ssh_cmd "mkdir -p ~/${BUILD_DIR}"
scp -o StrictHostKeyChecking=no \
    "${SCRIPT_DIR}/Containerfile.disconnected" \
    "${SCRIPT_DIR}/config.json" \
    "${SCRIPT_DIR}/embed-images.sh" \
    "${SCRIPT_DIR}/pull-secret.json" \
    "${REMOTE_USER}@${KVM_HOST}:~/${BUILD_DIR}/"

ssh_cmd "cp ~/${BUILD_DIR}/Containerfile.disconnected ~/${BUILD_DIR}/Containerfile"

# Phase 3: Build the container image directly into root storage.
# Uses sudo to avoid the rootless save/load step which needs ~3x the
# image size in temp space (the embedded images total ~50GB).
echo "==> Building disconnected container image (this takes 30-60+ minutes)..."
echo "    All MicroShift container images will be pulled and cached."
ssh_cmd "cd ~/${BUILD_DIR} && sudo podman build --network=host --security-opt label=type:unconfined_t --secret id=pullsecret,src=~/${BUILD_DIR}/pull-secret.json -t ${IMAGE_NAME}:${IMAGE_TAG} ."

# Phase 4: Build ISO with bootc-image-builder
echo "==> Building ISO image (this takes 10-30 minutes)..."
ssh_cmd "rm -rf ~/${BUILD_DIR}/output && mkdir -p ~/${BUILD_DIR}/output && chmod 777 ~/${BUILD_DIR}/output"
ssh_cmd "sudo podman run --rm --privileged \
    -v ~/${BUILD_DIR}/config.json:/config.json:ro \
    -v ~/${BUILD_DIR}/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type iso \
    --config /config.json \
    localhost/${IMAGE_NAME}:${IMAGE_TAG}"

# Phase 5: Deploy the VM from ISO
echo "==> Creating VM disk..."
ssh_cmd "sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.qcow2 ${VM_DISK_SIZE}"

ISO_PATH=$(ssh_cmd "find ~/${BUILD_DIR}/output -name '*.iso' | head -1")
if [[ -z "${ISO_PATH}" ]]; then
    echo "ERROR: No ISO found in build output"
    exit 1
fi

echo "==> Copying ISO to libvirt images..."
ssh_cmd "sudo cp ${ISO_PATH} /var/lib/libvirt/images/${VM_NAME}.iso"

echo "==> Installing VM from ISO..."
ssh_cmd "sudo virt-install \
    --name ${VM_NAME} \
    --memory ${VM_MEMORY} \
    --vcpus ${VM_VCPUS} \
    --disk /var/lib/libvirt/images/${VM_NAME}.qcow2 \
    --disk /var/lib/libvirt/images/${VM_NAME}.iso,device=cdrom \
    --boot cdrom,hd \
    --os-variant rhel9-unknown \
    --virt-type kvm \
    --graphics vnc \
    --noautoconsole \
    --network network=default,model=virtio"

# Wait for installation to complete — the kickstart has "reboot --eject"
# so the VM reboots after install. Wait for it to come back up with an IP.
echo "==> Waiting for ISO installation and first boot..."
INSTALL_DONE=false
for i in $(seq 1 180); do
    STATE=$(ssh_cmd "sudo virsh domstate ${VM_NAME} 2>/dev/null" || echo "unknown")
    if [[ "${STATE}" == "shut off" ]]; then
        echo "  VM shut off after install"
        INSTALL_DONE=true
        break
    fi
    # Check if the VM rebooted into the installed OS (SSH available)
    VM_IP_TMP=$(ssh_cmd "sudo virsh domifaddr ${VM_NAME} 2>/dev/null" | awk '/ipv4/{print $4}' | cut -d/ -f1)
    if [[ -n "${VM_IP_TMP}" ]]; then
        if ssh_cmd "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 ${REMOTE_USER}@${VM_IP_TMP} true" 2>/dev/null; then
            echo "  VM booted into installed OS"
            INSTALL_DONE=true
            break
        fi
    fi
    sleep 10
done

# Ensure ISO is detached so VM won't boot from it again
echo "==> Ejecting ISO..."
ssh_cmd "sudo virsh destroy ${VM_NAME} 2>/dev/null" || true
ssh_cmd "sudo virsh detach-disk ${VM_NAME} sda --config 2>/dev/null" || true
ssh_cmd "sudo rm -f /var/lib/libvirt/images/${VM_NAME}.iso"
echo "==> Starting VM from disk..."
ssh_cmd "sudo virsh start ${VM_NAME}"

# Wait for VM to get an IP
echo "==> Waiting for VM to boot..."
VM_IP=""
for i in $(seq 1 30); do
    VM_IP=$(ssh_cmd "sudo virsh domifaddr ${VM_NAME} 2>/dev/null" | awk '/ipv4/{print $4}' | cut -d/ -f1)
    [[ -n "${VM_IP}" ]] && break
    sleep 5
done

if [[ -z "${VM_IP:-}" ]]; then
    echo "ERROR: Could not get VM IP after 150 seconds"
    exit 1
fi

# Phase 6: Verify disconnected state
echo "==> Waiting for VM SSH to become available..."
for i in $(seq 1 24); do
    if ssh_cmd "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${REMOTE_USER}@${VM_IP} true" 2>/dev/null; then
        break
    fi
    sleep 5
done

echo "==> Verifying disconnected state..."
INTERNET_BLOCKED=$(ssh_cmd "ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${VM_IP} 'curl -s --connect-timeout 5 https://registry.redhat.io/ >/dev/null 2>&1 && echo CONNECTED || echo DISCONNECTED'" 2>/dev/null || echo "UNKNOWN")
NFTABLES_ACTIVE=$(ssh_cmd "ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${VM_IP} 'sudo nft list table inet disconnected >/dev/null 2>&1 && echo ACTIVE || echo INACTIVE'" 2>/dev/null || echo "UNKNOWN")
BLOCK_SVC=$(ssh_cmd "ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${VM_IP} 'systemctl show block-internet.service -p Result --value'" 2>/dev/null || echo "UNKNOWN")

echo ""
echo "============================================"
echo "  MicroShift Disconnected VM deployed"
echo "============================================"
echo ""
echo "  KVM host:           ${KVM_HOST}"
echo "  VM name:            ${VM_NAME}"
echo "  VM IP:              ${VM_IP} (NAT)"
echo "  Credentials:        ${REMOTE_USER} / ${REMOTE_USER}"
echo ""
echo "  Disconnected state:"
echo "    Internet:         ${INTERNET_BLOCKED}"
echo "    nftables rules:   ${NFTABLES_ACTIVE}"
echo "    block-internet:   ${BLOCK_SVC}"
echo ""
echo "  SSH access:"
echo "    ssh -J ${REMOTE_USER}@${KVM_HOST} ${REMOTE_USER}@${VM_IP}"
echo ""
echo "  Verify MicroShift started without internet:"
echo "    ssh -J ${REMOTE_USER}@${KVM_HOST} ${REMOTE_USER}@${VM_IP}"
echo "    sudo systemctl status microshift"
echo "    sudo crictl images   # should show all pre-embedded images"
echo "    kubectl get pods -A  # all pods should be Running"
echo ""
echo "  Re-enable internet (if needed):"
echo "    sudo nft delete table inet disconnected"
echo ""
