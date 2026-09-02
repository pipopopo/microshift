#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="microshift-bootc"
IMAGE_TAG="v4.22"
VM_NAME="microshift"
VM_MEMORY=8192
VM_VCPUS=4
VM_DISK_SIZE="50G"
REMOTE_USER="${REMOTE_USER:-kenny}"
BUILD_DIR="microshift-build"

usage() {
    echo "Usage: $0 <kvm-host-ip> [--destroy]"
    echo ""
    echo "Deploy a MicroShift 4.22 VM on a remote KVM host."
    echo ""
    echo "Arguments:"
    echo "  kvm-host-ip    IP address of the KVM host"
    echo "  --destroy      Remove existing VM before deploying"
    echo ""
    echo "Prerequisites:"
    echo "  - pull-secret.json in this directory (download from console.redhat.com)"
    echo "  - SSH key-based access to the KVM host"
    echo "  - Registry credentials in ~/.config/containers/auth.json"
    exit 1
}

[[ $# -lt 1 ]] && usage
KVM_HOST="$1"
DESTROY=false
[[ "${2:-}" == "--destroy" ]] && DESTROY=true

ssh_cmd() {
    ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${KVM_HOST}" "$@"
}

echo "==> Targeting KVM host: ${KVM_HOST}"

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
echo "==> Installing podman on ${KVM_HOST}..."
ssh_cmd "command -v podman &>/dev/null || sudo dnf install -y podman"

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
    "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}/config.json" \
    "${SCRIPT_DIR}/pull-secret.json" \
    "${REMOTE_USER}@${KVM_HOST}:~/${BUILD_DIR}/"

# Phase 3: Build the container image
echo "==> Building container image (this takes 5-15 minutes)..."
ssh_cmd "cd ~/${BUILD_DIR} && podman build -t ${IMAGE_NAME}:${IMAGE_TAG} ."

# Copy image to root storage for bootc-image-builder
echo "==> Copying image to root storage..."
ssh_cmd "podman save localhost/${IMAGE_NAME}:${IMAGE_TAG} | sudo podman load"

# Phase 4: Convert to qcow2
echo "==> Building qcow2 disk image (this takes 10-30 minutes)..."
ssh_cmd "rm -rf ~/${BUILD_DIR}/output && mkdir -p ~/${BUILD_DIR}/output && chmod 777 ~/${BUILD_DIR}/output"
ssh_cmd "sudo podman run --rm --privileged \
    -v ~/${BUILD_DIR}/config.json:/config.json:ro \
    -v ~/${BUILD_DIR}/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.json \
    localhost/${IMAGE_NAME}:${IMAGE_TAG}"

# Phase 5: Deploy the VM
echo "==> Deploying VM..."
ssh_cmd "sudo cp ~/${BUILD_DIR}/output/qcow2/disk.qcow2 /var/lib/libvirt/images/${VM_NAME}.qcow2"
ssh_cmd "sudo qemu-img resize /var/lib/libvirt/images/${VM_NAME}.qcow2 ${VM_DISK_SIZE}"

ssh_cmd "sudo virt-install \
    --name ${VM_NAME} \
    --memory ${VM_MEMORY} \
    --vcpus ${VM_VCPUS} \
    --disk /var/lib/libvirt/images/${VM_NAME}.qcow2 \
    --import \
    --os-variant rhel9-unknown \
    --virt-type kvm \
    --graphics none \
    --noautoconsole \
    --network network=default,model=virtio"

# Wait for VM to get an IP
echo "==> Waiting for VM to boot..."
for i in $(seq 1 30); do
    VM_IP=$(ssh_cmd "sudo virsh domifaddr ${VM_NAME} 2>/dev/null" | awk '/ipv4/{print $4}' | cut -d/ -f1)
    [[ -n "${VM_IP}" ]] && break
    sleep 5
done

if [[ -z "${VM_IP:-}" ]]; then
    echo "ERROR: Could not get VM IP after 150 seconds"
    exit 1
fi

echo ""
echo "============================================"
echo "  MicroShift VM deployed successfully"
echo "============================================"
echo ""
echo "  KVM host:    ${KVM_HOST}"
echo "  VM name:     ${VM_NAME}"
echo "  VM IP:       ${VM_IP} (NAT)"
echo "  Credentials: ${REMOTE_USER} / ${REMOTE_USER}"
echo ""
echo "  SSH access:"
echo "    ssh -J ${REMOTE_USER}@${KVM_HOST} ${REMOTE_USER}@${VM_IP}"
echo ""
echo "  API access from Mac (port forward):"
echo "    ssh -L 6443:${VM_IP}:6443 ${REMOTE_USER}@${KVM_HOST}"
echo ""
echo "  HTTP access from Mac (port forward):"
echo "    ssh -L 8080:${VM_IP}:80 ${REMOTE_USER}@${KVM_HOST}"
echo "    curl -H 'Host: <route-host>' http://localhost:8080/"
echo ""
echo "  Setup kubeconfig on the VM:"
echo "    mkdir -p ~/.kube"
echo "    sudo cp /var/lib/microshift/resources/kubeadmin/kubeconfig ~/.kube/config"
echo "    sudo chown \$(whoami):\$(whoami) ~/.kube/config"
