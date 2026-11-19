#!/usr/bin/env bash
# 在构建容器内编译 OpenSSH（静态链接 OpenSSL/zlib，PAM 动态链接）。
#
# 必需环境变量:
#   OPENSSH_VERSION OPENSSL_VERSION ZLIB_VERSION DISTRO
# 固定路径:
#   /sources  已验签的源码包（只读挂载）
#   /build    工作目录
#   /out      产物目录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f /opt/trust-binary/openssh-configure-args.sh ]; then
    # shellcheck source=/dev/null
    source /opt/trust-binary/openssh-configure-args.sh
else
    # shellcheck source=configure-args.sh
    source "$SCRIPT_DIR/configure-args.sh"
fi
if [ -f /opt/trust-binary/cc-hardening-flags.sh ]; then
    # shellcheck source=/dev/null
    source /opt/trust-binary/cc-hardening-flags.sh
else
    # shellcheck source=../../scripts/cc-hardening-flags.sh
    source "$SCRIPT_DIR/../../scripts/cc-hardening-flags.sh"
fi

: "${OPENSSH_VERSION:?缺少 OPENSSH_VERSION}"
: "${OPENSSL_VERSION:?缺少 OPENSSL_VERSION}"
: "${ZLIB_VERSION:?缺少 ZLIB_VERSION}"
: "${DISTRO:=unknown}"

SRC_DIR="${SRC_DIR:-/sources}"
WORK_DIR="${WORK_DIR:-/build}"
OUT_DIR="${OUT_DIR:-/out}"
ARCH="$(uname -m)"

mkdir -p "$OUT_DIR"
BUILD_LOG="$OUT_DIR/build.log"
exec > >(tee -a "$BUILD_LOG") 2>&1

log()   { printf '[openssh-build] %s\n' "$*"; }
stage() { printf '\n[openssh-build] ========== %s ==========\n' "$*"; }
die()   { printf '[openssh-build] ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    trap - ERR
    set +e
    printf '\n[openssh-build] ========== 构建失败 rc=%s ==========\n' "$rc"
    local diag="$OUT_DIR/diagnostics"
    mkdir -p "$diag"
    local f
    for f in "$WORK_DIR"/openssh-*/config.log \
             "$WORK_DIR"/openssl-*/config.log \
             "$WORK_DIR"/zlib-*/configure.log; do
        [ -f "$f" ] || continue
        printf '\n--- %s (tail 120) ---\n' "$f"
        tail -n 120 "$f"
        cp "$f" "$diag/" 2>/dev/null
    done
    sync
    sleep 1
    exit "$rc"
}
trap on_error ERR

if [ -n "${EXPECTED_ARCH:-}" ] && [ "$ARCH" != "$EXPECTED_ARCH" ]; then
    die "架构不匹配：容器为 $ARCH，期望 $EXPECTED_ARCH"
fi

if [ -f /opt/rh/devtoolset-11/enable ]; then
    log "启用 devtoolset-11 工具链"
    set +u
    # shellcheck disable=SC1091
    source /opt/rh/devtoolset-11/enable
    set -u
    export CC=gcc
else
    log "devtoolset-11: 未安装，使用系统 gcc"
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

stage "解包源码"
for tarball in \
    "openssh-${OPENSSH_VERSION}.tar.gz" \
    "openssl-${OPENSSL_VERSION}.tar.gz" \
    "zlib-${ZLIB_VERSION}.tar.gz"; do
    [ -f "$SRC_DIR/$tarball" ] || die "缺少源码包: $SRC_DIR/$tarball"
    tar xzf "$SRC_DIR/$tarball"
done

stage "编译环境"
gcc --version | sed -n '1p'
ldd --version | sed -n '1p'

OPENSSL_INSTALL="$WORK_DIR/openssl-install"
ZLIB_INSTALL="$WORK_DIR/zlib-install"

stage "构建 OpenSSL（静态）"
cd "$WORK_DIR/openssl-${OPENSSL_VERSION}"
# no-dso/no-engine: OpenSSH 不需要 DSO/ENGINE，避免 libcrypto.a 引入 dlclose 依赖
# （Ubuntu 18.04/20.04 的 glibc 把 libdl 独立出来，静态链接容易缺符号）
./config --prefix="$OPENSSL_INSTALL" --libdir=lib no-shared no-tests no-dso no-engine -fPIC
make -j"$(nproc)"
make install_sw
"$OPENSSL_INSTALL/bin/openssl" version

stage "构建 zlib（静态）"
cd "$WORK_DIR/zlib-${ZLIB_VERSION}"
CFLAGS="-O2 -fPIC" ./configure --prefix="$ZLIB_INSTALL" --static
make -j"$(nproc)"
make install

stage "构建 OpenSSH"
cd "$WORK_DIR/openssh-${OPENSSH_VERSION}"
mapfile -t CONFIGURE_ARGS < <(openssh_configure_args "$WORK_DIR" "$DISTRO")
# 旧 glibc 上 libdl/libpthread 是独立共享库；Ubuntu 默认 --as-needed 可能
# 在 libcrypto 之前把 -ldl/-lpthread 丢掉，因此显式关闭 as-needed。
CFLAGS="$(hardening_cflags)" \
LDFLAGS="-Wl,-z,relro -Wl,-z,now" \
LIBS="-Wl,--no-as-needed -ldl -lpthread -Wl,--as-needed" \
    ./configure "${CONFIGURE_ARGS[@]}"
make -j"$(nproc)"

stage "安装到暂存目录"
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
make install-nosysconf DESTDIR="$STAGE"

LIBEXECDIR="$(openssh_libexecdir "$DISTRO")"
SSH_BIN="$STAGE/usr/bin/ssh"
SSHD_BIN="$STAGE/usr/sbin/sshd"
[ -x "$SSH_BIN" ]  || die "缺少 ssh: $SSH_BIN"
[ -x "$SSHD_BIN" ] || die "缺少 sshd: $SSHD_BIN"
for helper in sshd-session sshd-auth ssh-keysign ssh-pkcs11-helper ssh-sk-helper sftp-server; do
    [ -x "$STAGE$LIBEXECDIR/$helper" ] || die "缺少 $LIBEXECDIR/$helper"
done

stage "校验产物"
SSH_V="$("$SSH_BIN" -V 2>&1 || true)"
printf '%s\n' "$SSH_V"
[[ "$SSH_V" == *"OpenSSH_${OPENSSH_VERSION}"* ]] || die "OpenSSH 版本不符（期望 $OPENSSH_VERSION）"
[[ "$SSH_V" == *"OpenSSL ${OPENSSL_VERSION}"* ]] || die "OpenSSL 版本不符（期望 $OPENSSL_VERSION）"

LDD_OUT="$(ldd "$SSHD_BIN" 2>&1 || true)"
printf '%s\n' "$LDD_OUT"
if grep -Eq 'libcrypto|libssl|libz\.so' <<< "$LDD_OUT"; then
    die "sshd 未静态链接 OpenSSL/zlib"
fi
if grep -q 'not found' <<< "$LDD_OUT"; then
    die "sshd 存在无法解析的动态库"
fi

COMPILER="$(gcc --version | sed -n '1p')"
LIBC="$(ldd --version | sed -n '1p')"
OS_PRETTY="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
BIN_NAME="openssh-${OPENSSH_VERSION}-${DISTRO}-${ARCH}"

stage "打包可分发产物"
DOCDIR="$STAGE/usr/share/doc/trust-binary/openssh"
mkdir -p "$DOCDIR"

cat > "$OUT_DIR/$BIN_NAME.build-info.json" <<EOF_JSON
{
  "component": "openssh",
  "version": "${OPENSSH_VERSION}",
  "distro": "${DISTRO}",
  "arch": "${ARCH}",
  "os_pretty_name": "${OS_PRETTY}",
  "compiler": "${COMPILER}",
  "libc": "${LIBC}",
  "libexecdir": "${LIBEXECDIR}",
  "dependencies": {
    "openssl": "${OPENSSL_VERSION}",
    "zlib": "${ZLIB_VERSION}"
  },
  "static_dependencies": ["openssl", "zlib"],
  "pam": true,
  "configure_args": [
$(printf '    "%s",\n' "${CONFIGURE_ARGS[@]}" | sed '$ s/,$//')
  ]
}
EOF_JSON
cp "$OUT_DIR/$BIN_NAME.build-info.json" "$DOCDIR/BUILD_INFO.json"
cp "$SRC_DIR/MANIFEST.sha256" "$DOCDIR/SOURCE_MANIFEST.sha256"
printf '%s\n' "$SSH_V" > "$DOCDIR/ssh-V.txt"
printf '%s\n' "$LDD_OUT" > "$DOCDIR/ldd-sshd.txt"

cat > "$DOCDIR/INSTALL.txt" <<EOF_INSTALL
OpenSSH ${OPENSSH_VERSION} (${DISTRO}/${ARCH})
==============================================
静态链接 OpenSSL ${OPENSSL_VERSION} / zlib ${ZLIB_VERSION}；PAM 动态链接。
安装路径与发行版 openssh 包一致；libexecdir=${LIBEXECDIR}。

升级前请保留一个已登录的 root 会话，并备份现有二进制:
  cp -a /usr/sbin/sshd /usr/sbin/sshd.bak.$(date +%F)
  cp -a ${LIBEXECDIR} ${LIBEXECDIR}.bak.$(date +%F)

安装（root）:
  tar -C / -xzf openssh-${OPENSSH_VERSION}-${DISTRO}-${ARCH}.tar.gz   # 解压出 usr/
  id sshd >/dev/null 2>&1 || useradd -r -s /bin/false -M sshd
  install -d -m 0755 /run/sshd
  ssh-keygen -A
  sshd -t
  systemctl restart sshd    # Debian/Ubuntu 也可用 service ssh restart

重要:
  - sshd、sshd-session、sshd-auth 必须来自同一版本，成对替换；
  - 不要覆盖 /etc/ssh 下现有配置和主机密钥；
  - 需要使用发行版现有 PAM 配置（/etc/pam.d/sshd）；
  - SELinux 环境如启用，替换后执行 restorecon -Rv /usr/sbin/sshd ${LIBEXECDIR}。
EOF_INSTALL

tar -C "$STAGE" -czf "$OUT_DIR/${BIN_NAME}.tar.gz" usr
rm -rf "$STAGE"

(
    cd "$OUT_DIR"
    sha256sum "${BIN_NAME}.tar.gz" "${BIN_NAME}.build-info.json" > SHA256SUMS
)

stage "完成"
ls -l "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
