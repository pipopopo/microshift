# MicroShift 4.22 bootc VM

Deploy MicroShift 4.22 VMs on any KVM host using RHEL image mode (bootc). Includes both a **connected** and a **disconnected** (air-gapped) deployment.

## What's included

- **MicroShift 4.22** with OVN-Kubernetes networking
- **MicroShift OLM** (Operator Lifecycle Manager)
- **MicroShift Observability**
- **MicroShift Multus** (multiple network interfaces for pods)
- Networking/debug tools: tcpdump, iperf3, mtr, nmap-ncat, bind-utils, etc.

### Deployment modes

| Mode | Script | Image type | Description |
|------|--------|------------|-------------|
| Connected | `deploy.sh` | qcow2 | Standard deployment, pulls images at runtime |
| Disconnected | `deploy-disconnected.sh` | ISO | All container images embedded, outbound internet blocked via nftables |

### Component profiles (disconnected)

The disconnected Containerfile can be customized to include only the components you need. This directly affects image size and build time.

| Profile | Components | Images | ISO size | Use case |
|---------|-----------|--------|----------|----------|
| Core | `microshift` | ~9 | ~3 GB | Minimal control plane, smallest footprint |
| Standard | Core + OLM + Multus | ~14 | ~5 GB | Typical edge deployment with operator support |
| Full | Standard + Observability + AI Model Serving | ~34 | ~30 GB | Everything, including AI inference at the edge |

To customize, edit `Containerfile.disconnected`:
- Add or remove packages from the `dnf install` step (e.g. `microshift-olm`, `microshift-multus`, `microshift-ai-model-serving`)
- Add or remove the matching `microshift-*-release-info` packages
- Add or remove the corresponding `embed-images.sh` RUN steps for each release file

Each component has a release info package that provides the image list at `/usr/share/microshift/release/`:

| Component | Package | Release file |
|-----------|---------|-------------|
| Core | `microshift-release-info` | `release-x86_64.json` |
| OLM | `microshift-olm-release-info` | `release-olm-x86_64.json` |
| Multus | `microshift-multus-release-info` | `release-multus-x86_64.json` |
| AI Model Serving | `microshift-ai-model-serving-release-info` | `release-ai-model-serving-x86_64.json` |

## Prerequisites

1. **Pull secret** - Download from https://console.redhat.com/openshift/downloads and save as `pull-secret.json`.
   See `pull-secret.json.example` for the expected format.

2. **Config file** - Copy `config.json.example` to `config.json` and fill in your username, password, and SSH public key.

3. **Registry credentials** - Log in to registry.redhat.io:
   ```
   podman login registry.redhat.io
   ```

4. **SSH access** - Key-based SSH to the target KVM host.

5. **KVM host requirements** - RHEL with active subscription, libvirt, virt-install. The deploy scripts install podman/skopeo if missing.

## Deploy (connected)

```bash
./deploy.sh <kvm-host-ip>
```

To destroy an existing VM and redeploy:

```bash
./deploy.sh <kvm-host-ip> --destroy
```

## Deploy (disconnected / air-gapped)

The disconnected deployment embeds all MicroShift container images into the bootc image at build time using `dir:` transport, then loads them into CRI-O storage on first boot. Outbound internet is blocked via nftables.

```bash
./deploy-disconnected.sh <kvm-host-ip>
```

This takes significantly longer than the connected variant (30-60+ minutes) because all container images are pulled during the build phase. The resulting ISO is ~5 GB.

## Access

The VM runs on a NAT network (libvirt default). Access is via SSH jump through the KVM host.

**SSH to the VM:**
```bash
ssh -J <user>@<kvm-host> <user>@<vm-ip>
```

**Port forward the Kubernetes API:**
```bash
ssh -L 6443:<vm-ip>:6443 <user>@<kvm-host>
```

**Port forward HTTP (for Routes):**
```bash
ssh -L 8080:<vm-ip>:80 <user>@<kvm-host>
curl -H "Host: myapp.microshift.local" http://localhost:8080/
```

## Setup kubeconfig (on the VM)

```bash
mkdir -p ~/.kube
sudo cp /var/lib/microshift/resources/kubeadmin/kubeconfig ~/.kube/config
sudo chown $(whoami):$(whoami) ~/.kube/config
kubectl get nodes
kubectl get pods -A
```

## Build workflow

### Connected

```
podman build (Containerfile)
  -> podman save | sudo podman load
  -> bootc-image-builder --type qcow2
  -> virt-install --import
```

### Disconnected

```
sudo podman build --secret (Containerfile.disconnected)
  -> embed-images.sh pulls all MicroShift images via dir: transport
  -> bootc-image-builder --type iso
  -> virt-install from ISO (anaconda kickstart)
  -> First boot: microshift-copy-images loads images into CRI-O
  -> block-internet.service blocks outbound traffic via nftables
```

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | Connected bootc image |
| `Containerfile.disconnected` | Disconnected bootc image with embedded container images |
| `deploy.sh` | Connected deployment script |
| `deploy-disconnected.sh` | Disconnected deployment script |
| `embed-images.sh` | Build-time script to pull and cache container images via `dir:` transport |
| `config.json.example` | Template for bootc-image-builder user config |
| `pull-secret.json.example` | Template for Red Hat pull secret |

## Networking

MicroShift uses OVN-Kubernetes but does not absorb the host interface into OVS.

```
enp1s0              -> External host traffic only (SSH, DHCP)
br-ex               -> OVS bridge: Service DNAT/SNAT gateway
ovn-k8s-mp0         -> OVS internal port: node <-> pod communication
br-int              -> OVS bridge: internal pod fabric (veth pairs)
```

Where to tcpdump:

```bash
sudo tcpdump -i enp1s0       # External traffic (SSH, DHCP)
sudo tcpdump -i ovn-k8s-mp0  # Pod traffic
sudo tcpdump -i br-ex        # Service gateway traffic
```

## VM specs

| Resource | Value |
|----------|-------|
| vCPUs | 4 |
| RAM | 8 GB |
| Disk | 50 GB |

## Disconnected: re-enable internet

```bash
sudo nft delete table inet disconnected
```

## Day 2 updates

The image supports bootc automatic updates:

```bash
sudo bootc upgrade
```
