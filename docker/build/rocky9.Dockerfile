# Rocky Linux 9 构建环境（glibc 2.34，覆盖 RHEL/CentOS/Rocky/Alma 9 家族）
ARG BASE_IMAGE=rockylinux:9
FROM ${BASE_IMAGE}

RUN set -eux; \
    dnf -y install gcc make perl; \
    dnf clean all; \
    rm -rf /var/cache/dnf

COPY components/nginx/build.sh components/nginx/configure-args.sh /opt/trust-binary/
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
