#!/usr/bin/env bash
# 在构建容器内编译 nginx（静态链接 OpenSSL/PCRE2/zlib，仅依赖 glibc）。
#
# 必需环境变量:
#   NGINX_VERSION OPENSSL_VERSION PCRE2_VERSION ZLIB_VERSION DISTRO
# 固定路径:
#   /sources  已验签的源码包（只读挂载）
#   /build    工作目录
#   /out      产物目录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 镜像内路径优先，其次同目录（本地直接运行脚本时）
if [ -f /opt/trust-binary/configure-args.sh ]; then
    # shellcheck source=/dev/null
    source /opt/trust-binary/configure-args.sh
else
    # shellcheck source=configure-args.sh
    source "$SCRIPT_DIR/configure-args.sh"
fi

: "${NGINX_VERSION:?缺少 NGINX_VERSION}"
: "${OPENSSL_VERSION:?缺少 OPENSSL_VERSION}"
: "${PCRE2_VERSION:?缺少 PCRE2_VERSION}"
: "${ZLIB_VERSION:?缺少 ZLIB_VERSION}"
: "${DISTRO:=unknown}"

SRC_DIR="${SRC_DIR:-/sources}"
WORK_DIR="${WORK_DIR:-/build}"
OUT_DIR="${OUT_DIR:-/out}"
ARCH="$(uname -m)"

log() { printf '[build] %s\n' "$*" >&2; }
die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }
if [ -n "${EXPECTED_ARCH:-}" ] && [ "$ARCH" != "$EXPECTED_ARCH" ]; then
    die "架构不匹配：容器为 $ARCH，期望 $EXPECTED_ARCH（产物命名与真实架构必须一致）"
fi

# CentOS 7 优先使用 devtoolset-11（glibc 保持 2.17，兼容老系统）
if [ -f /opt/rh/devtoolset-11/enable ]; then
    log "启用 devtoolset-11 工具链"
    set +u
    # shellcheck disable=SC1091
    source /opt/rh/devtoolset-11/enable
    set -u
    export CC=gcc
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

log "解包源码"
for tarball in \
    "nginx-${NGINX_VERSION}.tar.gz" \
    "openssl-${OPENSSL_VERSION}.tar.gz" \
    "pcre2-${PCRE2_VERSION}.tar.gz" \
    "zlib-${ZLIB_VERSION}.tar.gz"; do
    [ -f "$SRC_DIR/$tarball" ] || die "缺少源码包: $SRC_DIR/$tarball"
    tar xzf "$SRC_DIR/$tarball"
done

log "编译环境"
gcc --version | head -n 1 >&2
ldd --version | head -n 1 >&2

log "configure"
mapfile -t CONFIGURE_ARGS < <(nginx_configure_args "$WORK_DIR")
cd "$WORK_DIR/nginx-${NGINX_VERSION}"
./configure "${CONFIGURE_ARGS[@]}"

log "make -j$(nproc)"
make -j"$(nproc)"

[ -x objs/nginx ] || die "编译失败：objs/nginx 不存在"

log "收集构建信息"
COMPILER="$(gcc --version | head -n 1)"
LIBC="$(ldd --version | head -n 1)"
OS_PRETTY="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
NGINX_V="$("./objs/nginx" -V 2>&1 || true)"
LDD_OUT="$(ldd ./objs/nginx 2>&1 || true)"

BIN_NAME="nginx-${NGINX_VERSION}-${DISTRO}-${ARCH}"
OUT_BIN="$OUT_DIR/$BIN_NAME"
install -m 0755 objs/nginx "$OUT_BIN"

cat > "$OUT_DIR/$BIN_NAME.build-info.json" <<EOF_JSON
{
  "component": "nginx",
  "version": "${NGINX_VERSION}",
  "distro": "${DISTRO}",
  "arch": "${ARCH}",
  "os_pretty_name": "${OS_PRETTY}",
  "compiler": "${COMPILER}",
  "libc": "${LIBC}",
  "dependencies": {
    "openssl": "${OPENSSL_VERSION}",
    "pcre2": "${PCRE2_VERSION}",
    "zlib": "${ZLIB_VERSION}"
  },
  "configure_args": [
$(printf '    "%s",\n' "${CONFIGURE_ARGS[@]}" | sed '$ s/,$//')
  ]
}
EOF_JSON

log "打包可分发产物"
STAGE="$OUT_DIR/stage/nginx-${NGINX_VERSION}-${DISTRO}-${ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/conf"
install -m 0755 objs/nginx "$STAGE/bin/nginx"
cp -a conf/. "$STAGE/conf/"
printf '%s\n' "$NGINX_V" > "$STAGE/nginx-V.txt"
printf '%s\n' "$LDD_OUT" > "$STAGE/ldd.txt"
cp "$OUT_DIR/$BIN_NAME.build-info.json" "$STAGE/BUILD_INFO.json"
cp "$SRC_DIR/MANIFEST.sha256" "$STAGE/SOURCE_MANIFEST.sha256"

cat > "$STAGE/INSTALL.txt" <<EOF_INSTALL
nginx ${NGINX_VERSION} (${DISTRO}/${ARCH})
========================================
本二进制静态链接 OpenSSL ${OPENSSL_VERSION} / PCRE2 ${PCRE2_VERSION} / zlib ${ZLIB_VERSION}，
仅依赖系统 glibc 家族运行库。安装路径与发行版官方 nginx 包保持一致。

安装步骤（root）:
  id nginx >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin nginx
  install -d /etc/nginx /var/cache/nginx /var/log/nginx
  install -m 0755 bin/nginx /usr/sbin/nginx
  cp -a conf/. /etc/nginx/
  nginx -t

校验:
  在发布资产目录（解压前）执行: sha256sum -c SHA256SUMS
  ./bin/nginx -V

卸载/升级:
  直接用新版本二进制覆盖 /usr/sbin/nginx，然后执行 nginx -t && nginx -s reload
EOF_INSTALL

tar -C "$OUT_DIR/stage" -czf "$OUT_DIR/${BIN_NAME}.tar.gz" "nginx-${NGINX_VERSION}-${DISTRO}-${ARCH}"
rm -rf "$OUT_DIR/stage"

(
    cd "$OUT_DIR"
    sha256sum "$BIN_NAME" "${BIN_NAME}.tar.gz" "$BIN_NAME.build-info.json" > SHA256SUMS
)

log "产物:"
ls -l "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS" >&2
