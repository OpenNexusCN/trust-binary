# 通用 Ubuntu 构建环境（18.04 / 20.04 / 22.04 / 24.04）
# 优先使用 Azure 归档镜像（GitHub Runner 位于 Azure），失败回退官方 archive / old-releases。
# 用法: docker build -f docker/build/ubuntu.Dockerfile \
#         --build-arg BASE_IMAGE=ubuntu:22.04 -t trust-binary/nginx-build:ubuntu22.04 .
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    APT_OPTS="-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"; \
    set_sources() { \
        mirror="$1"; \
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do \
            [ -f "$f" ] || continue; \
            sed -i \
                -e "s|http://archive.ubuntu.com|http://${mirror}|g" \
                -e "s|https://archive.ubuntu.com|http://${mirror}|g" \
                -e "s|http://security.ubuntu.com|http://${mirror}|g" \
                -e "s|https://security.ubuntu.com|http://${mirror}|g" \
                -e "s|http://azure.archive.ubuntu.com|http://${mirror}|g" \
                -e "s|https://azure.archive.ubuntu.com|http://${mirror}|g" \
                -e "s|http://old-releases.ubuntu.com|http://${mirror}|g" \
                -e "s|https://old-releases.ubuntu.com|http://${mirror}|g" \
                "$f"; \
        done; \
    }; \
    ok=0; \
    for mirror in azure.archive.ubuntu.com archive.ubuntu.com old-releases.ubuntu.com; do \
        echo "=== apt mirror: ${mirror} ==="; \
        set_sources "$mirror"; \
        if apt-get update -qq $APT_OPTS; then \
            if apt-get install -y --no-install-recommends $APT_OPTS \
                build-essential \
                perl \
                ca-certificates; then \
                ok=1; \
                break; \
            fi; \
        fi; \
        echo "mirror ${mirror} 失败，尝试下一个"; \
    done; \
    [ "$ok" = "1" ]; \
    rm -rf /var/lib/apt/lists/*

COPY components/nginx/build.sh components/nginx/configure-args.sh /opt/trust-binary/
RUN chmod 0755 /opt/trust-binary/*.sh

WORKDIR /build
