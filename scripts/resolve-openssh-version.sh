#!/usr/bin/env bash
# 解析 OpenSSH 最新 portable 版本（形如 10.6p2）。
#
# 用法:
#   resolve-openssh-version.sh [version]
#   INPUT_VERSION=10.6p2 resolve-openssh-version.sh
#
# 优先级：显式参数 > 环境变量 INPUT_VERSION > OpenBSD 官方目录 > GitHub tags。
# 解析失败时以非 0 退出，并提示手动填写版本。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INPUT="${1:-${INPUT_VERSION:-}}"
OPENSSH_VERSION_RE='^[0-9]+\.[0-9]+(p[0-9]+)?$'

if [ -n "$INPUT" ]; then
    [[ "$INPUT" =~ $OPENSSH_VERSION_RE ]] || die "非法 OpenSSH 版本: '$INPUT'（期望 X.YpZ，如 10.6p2）"
    echo "$INPUT"
    exit 0
fi

require_cmd curl

UA="trust-binary/1.0 (+https://github.com/OpenNexusCN/trust-binary)"
LATEST=""

for base in \
    "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/" \
    "https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/"; do
    LIST="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        -A "$UA" "$base" 2>/dev/null || true)"
    LATEST="$(printf '%s' "$LIST" \
        | grep -oE 'openssh-[0-9]+\.[0-9]+(p[0-9]+)?\.tar\.gz' \
        | sed 's/^openssh-//; s/\.tar\.gz$//' \
        | sort -uV \
        | tail -n 1)"
    [ -n "$LATEST" ] && break
done

if [ -z "$LATEST" ]; then
    log "OpenBSD 目录不可用，回退到 GitHub tags"
    TAGS="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        -A "$UA" "https://api.github.com/repos/openssh/openssh-portable/tags?per_page=100" 2>/dev/null || true)"
    LATEST="$(printf '%s' "$TAGS" \
        | grep -oE 'V_[0-9]+_[0-9]+_P[0-9]+' \
        | sed -E 's/^V_([0-9]+)_([0-9]+)_P([0-9]+)$/\1.\2p\3/' \
        | sort -uV \
        | tail -n 1)"
fi

if [ -z "$LATEST" ]; then
    die "无法确定 OpenSSH 最新版本。请手动指定，例如：
  GitHub Actions: workflow_dispatch 输入 openssh_version=10.6p2
  本地:           resolve-openssh-version.sh 10.6p2"
fi

[[ "$LATEST" =~ $OPENSSH_VERSION_RE ]] || die "解析出的版本不合法: '$LATEST'"
log "从上游解析到 OpenSSH 最新版本: $LATEST"
echo "$LATEST"
