FROM registry.redhat.io/openshift4/microshift-bootc-rhel9:v4.22

ARG USHIFT_VER=4.22
RUN dnf config-manager \
        --set-enabled rhocp-${USHIFT_VER}-for-rhel-9-$(uname -m)-rpms \
        --set-enabled fast-datapath-for-rhel-9-$(uname -m)-rpms

RUN dnf install -y \
        bash-completion \
        bind-utils \
        chrony \
        curl \
        ethtool \
        firewalld \
        iperf3 \
        iproute \
        jq \
        lsof \
        mtr \
        NetworkManager-tui \
        nmap-ncat \
        openssh-server \
        pciutils \
        podman \
        rsync \
        sos \
        sysstat \
        tcpdump \
        tmux \
        traceroute \
        usbutils \
        openssh-clients \
        sudo \
        vim-enhanced \
        wget \
        microshift-olm \
        microshift-observability \
        microshift-ai-model-serving \
        microshift-ai-model-serving-release-info \
        microshift-multus && \
    dnf clean all

ARG VM_USER=kenny
RUN useradd -m -G wheel ${VM_USER}
RUN echo "${VM_USER}:${VM_USER}" | chpasswd
RUN mkdir -p /home/${VM_USER}/.ssh

RUN systemctl enable \
        microshift \
        NetworkManager \
        sshd \
        chronyd

RUN systemctl enable microshift-observability

RUN mkdir -p /var/lib/microshift
RUN mkdir -p /var/lib/kubelet
RUN mkdir -p /etc/crio

COPY --chmod=0600 pull-secret.json /var/lib/microshift/pull-secret.json
COPY --chmod=0600 pull-secret.json /etc/crio/openshift-pull-secret
COPY --chmod=0600 pull-secret.json /var/lib/kubelet/pull-secret.json

RUN bootc container lint
