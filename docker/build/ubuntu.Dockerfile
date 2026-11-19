# 通用 Ubuntu 构建环境（18.04 / 20.04 / 22.04 / 24.04）
# 用法: docker build -f docker/build/ubuntu.Dockerfile \
#         --build-arg BASE_IMAGE=ubuntu:22.04 -t trust-binary/nginx-build:ubuntu22.04 .
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    if ! apt-get update -qq; then \
        echo "archive.ubuntu.com 不可用，尝试 old-releases.ubuntu.com"; \
        cp /etc/apt/sources.list /tmp/sources.list.archive; \
        sed -i \
            -e 's|http://archive.ubuntu.com|http://old-releases.ubuntu.com|g' \
            -e 's|https://archive.ubuntu.com|https://old-releases.ubuntu.com|g' \
            -e 's|http://security.ubuntu.com|http://old-releases.ubuntu.com|g' \
            -e 's|https://security.ubuntu.com|https://old-releases.ubuntu.com|g' \
            /etc/apt/sources.list; \
        if ! apt-get update -qq; then \
            echo "old-releases 也不可用，恢复默认源"; \
            cp /tmp/sources.list.archive /etc/apt/sources.list; \
            apt-get update -qq; \
        fi; \
    fi; \
    apt-get install -y --no-install-recommends \
        build-essential \
        perl \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/* /tmp/sources.list.archive

COPY components/nginx/build.sh components/nginx/configure-args.sh /opt/trust-binary/
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
