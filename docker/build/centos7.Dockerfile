# CentOS 7 构建环境（glibc 2.17 基线，兼容最老的 RHEL/CentOS 7）
# CentOS 7 已 EOL，官方 vault.centos.org 对部分网络返回 403，默认使用 Rackspace 的官方镜像；
# 国内构建可覆盖: --build-arg CENTOS_VAULT_BASE=https://mirrors.aliyun.com/centos-vault
# 可选镜像: https://mirrors.tuna.tsinghua.edu.cn/centos-vault
#           https://mirrors.aliyun.com/centos-vault
#           https://mirrors.cloud.tencent.com/centos-vault
ARG BASE_IMAGE=centos:7
ARG CENTOS_VAULT_BASE=https://mirror.rackspace.com/centos-vault
FROM ${BASE_IMAGE}

# 全局 ARG 需要在本阶段重新声明后才能被 RUN 使用
ARG CENTOS_VAULT_BASE

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
        'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7' \
        'enabled=1' \
        > /etc/yum.repos.d/CentOS-SCLo-rh.repo; \
    yum -y install gcc gcc-c++ make perl; \
    yum -y install devtoolset-11-gcc devtoolset-11-gcc-c++ \
        || echo "devtoolset-11 不可用，回退到系统 gcc 4.8"; \
    yum clean all; \
    rm -rf /var/cache/yum

COPY components/nginx/build.sh components/nginx/configure-args.sh /opt/trust-binary/
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
