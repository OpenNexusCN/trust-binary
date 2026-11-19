# OpenSSH 构建环境（CentOS 7，glibc 2.17 基线）
# SCLo 公钥指纹: C4DBD535B1FBBA14F8BA64A84EB84E71F2EE9D55
ARG BASE_IMAGE=centos:7
ARG CENTOS_VAULT_BASE=https://mirror.rackspace.com/centos-vault
FROM ${BASE_IMAGE}

ARG CENTOS_VAULT_BASE

COPY docker/keys/RPM-GPG-KEY-CentOS-SIG-SCLo /opt/trust-binary/RPM-GPG-KEY-CentOS-SIG-SCLo

RUN set -eux; \
    sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|' \
        -e "s|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=${CENTOS_VAULT_BASE}/7.9.2009|" \
        -e "s|^#baseurl=https://mirror.centos.org/centos/\$releasever|baseurl=${CENTOS_VAULT_BASE}/7.9.2009|" \
        /etc/yum.repos.d/CentOS-Base.repo; \
    printf '%s\n' \
        '[centos-sclo-rh]' \
        'name=CentOS-7 - SCLo rh' \
        "baseurl=${CENTOS_VAULT_BASE}/7.9.2009/sclo/x86_64/rh/" \
        'gpgcheck=1' \
        'gpgkey=file:///opt/trust-binary/RPM-GPG-KEY-CentOS-SIG-SCLo' \
        'enabled=1' \
        > /etc/yum.repos.d/CentOS-SCLo-rh.repo; \
    yum -y install gcc gcc-c++ make perl perl-core pam-devel groff; \
    yum -y install devtoolset-11-gcc devtoolset-11-gcc-c++; \
    test -x /opt/rh/devtoolset-11/root/usr/bin/gcc; \
    yum clean all; \
    rm -rf /var/cache/yum

COPY components/openssh/build.sh components/openssh/configure-args.sh /opt/trust-binary/
COPY components/openssh/configure-args.sh /opt/trust-binary/openssh-configure-args.sh
COPY scripts/cc-hardening-flags.sh /opt/trust-binary/cc-hardening-flags.sh
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
