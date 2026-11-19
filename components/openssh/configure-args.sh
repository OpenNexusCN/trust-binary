#!/usr/bin/env bash
# OpenSSH configure 参数（每行一个），以及发行版相关的 libexecdir。
# 依赖环境变量: OPENSSH_VERSION / OPENSSL_VERSION / ZLIB_VERSION
# 参数: $1 = 工作目录（源码解包根目录），$2 = 发行版标签

openssh_libexecdir() {
    case "${1:-}" in
        centos7|rocky9) echo "/usr/libexec/openssh" ;;
        *)              echo "/usr/lib/openssh" ;;
    esac
}

openssh_configure_args() {
    local work="${1:?openssh_configure_args 需要工作目录}"
    local distro="${2:-unknown}"
    local libexecdir
    libexecdir="$(openssh_libexecdir "$distro")"

    cat <<EOF_ARGS
--prefix=/usr
--sysconfdir=/etc/ssh
--libexecdir=$libexecdir
--with-ssl-dir=$work/openssl-install
--with-zlib=$work/zlib-install
--with-pam
--without-rpath
--with-privsep-user=sshd
--with-privsep-path=/run/sshd
EOF_ARGS
}
