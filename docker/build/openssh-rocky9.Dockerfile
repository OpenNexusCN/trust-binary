# OpenSSH 构建环境（Rocky Linux 9）
ARG BASE_IMAGE=rockylinux:9
FROM ${BASE_IMAGE}

RUN set -eux; \
    dnf -y install gcc make perl pam-devel groff; \
    dnf clean all; \
    rm -rf /var/cache/dnf

COPY components/openssh/build.sh components/openssh/configure-args.sh /opt/trust-binary/
COPY components/openssh/configure-args.sh /opt/trust-binary/openssh-configure-args.sh
COPY scripts/cc-hardening-flags.sh /opt/trust-binary/cc-hardening-flags.sh
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
