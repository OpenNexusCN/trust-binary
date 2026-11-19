#!/usr/bin/env bash
# 本地复现 GitHub Actions 构建（要求 Linux + Docker）。
#
# 用法:
#   build-local.sh [nginx_version]
#
# 产物输出到 dist/。注意：本地构建同样执行 GPG 验签与 SHA256 校验。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$ROOT_DIR"

require_cmd docker curl gpg
PYTHON="$(python_cmd)"

VERSION="${1:-}"
if [ -n "$VERSION" ]; then
    validate_version "$VERSION"
else
    VERSION="$(bash scripts/resolve-nginx-version.sh)"
fi

log "准备源码（nginx $VERSION）"
bash scripts/prepare-sources.sh "$ROOT_DIR/work" "$ROOT_DIR/lock/nginx.lock.json" "$VERSION"

RESOLVED_LOCK="$ROOT_DIR/work/nginx.lock.resolved.json"
OPENSSL_VER="$("$PYTHON" scripts/lockfile.py get "$RESOLVED_LOCK" openssl version)"
PCRE2_VER="$("$PYTHON" scripts/lockfile.py get "$RESOLVED_LOCK" pcre2 version)"
ZLIB_VER="$("$PYTHON" scripts/lockfile.py get "$RESOLVED_LOCK" zlib version)"

DISTROS=(ubuntu18.04 ubuntu20.04 ubuntu22.04 ubuntu24.04 centos7 rocky9)
if [ "$(uname -m)" = "aarch64" ]; then
    # CentOS 7 / Rocky 9 的官方多架构镜像不含 aarch64（CentOS 7），本机为 ARM 时只构建 Ubuntu
    DISTROS=(ubuntu18.04 ubuntu20.04 ubuntu22.04 ubuntu24.04)
fi
declare -A BASE_IMAGES=(
    [ubuntu18.04]="ubuntu:18.04"
    [ubuntu20.04]="ubuntu:20.04"
    [ubuntu22.04]="ubuntu:22.04"
    [ubuntu24.04]="ubuntu:24.04"
    [centos7]="centos:7"
    [rocky9]="rockylinux:9"
)
declare -A DOCKERFILES=(
    [ubuntu18.04]="docker/build/ubuntu.Dockerfile"
    [ubuntu20.04]="docker/build/ubuntu.Dockerfile"
    [ubuntu22.04]="docker/build/ubuntu.Dockerfile"
    [ubuntu24.04]="docker/build/ubuntu.Dockerfile"
    [centos7]="docker/build/centos7.Dockerfile"
    [rocky9]="docker/build/rocky9.Dockerfile"
)

mkdir -p "$ROOT_DIR/dist"

for distro in "${DISTROS[@]}"; do
    log "构建 $distro"
    docker build \
        -f "${DOCKERFILES[$distro]}" \
        --build-arg BASE_IMAGE="${BASE_IMAGES[$distro]}" \
        -t "trust-binary/nginx-build:$distro" \
        "$ROOT_DIR"
    docker run --rm --network none \
        -v "$ROOT_DIR/work/sources:/sources:ro" \
        -v "$ROOT_DIR/dist:/out" \
        -e NGINX_VERSION="$VERSION" \
        -e OPENSSL_VERSION="$OPENSSL_VER" \
        -e PCRE2_VERSION="$PCRE2_VER" \
        -e ZLIB_VERSION="$ZLIB_VER" \
        -e DISTRO="$distro" \
        -e EXPECTED_ARCH="$(uname -m)" \
        "trust-binary/nginx-build:$distro" \
        bash /opt/trust-binary/build.sh
done

log "完成，产物位于 $ROOT_DIR/dist"
ls -l "$ROOT_DIR/dist"
