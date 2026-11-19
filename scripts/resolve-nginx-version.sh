#!/usr/bin/env bash
# 解析 nginx 最新稳定版（stable 分支，偶数次版本号）。
#
# 用法:
#   resolve-nginx-version.sh [version]
#   INPUT_VERSION=1.30.7 resolve-nginx-version.sh
#
# 优先级：显式参数 > 环境变量 INPUT_VERSION > 从 nginx.org 自动解析。
# 自动解析失败时以非 0 退出，并提示用户手动填写版本号。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INPUT="${1:-${INPUT_VERSION:-}}"

if [ -n "$INPUT" ]; then
    validate_version "$INPUT"
    echo "$INPUT"
    exit 0
fi

require_cmd curl

UA="trust-binary/1.0 (+https://github.com/OpenNexusCN/trust-binary)"
PAGE_URL="https://nginx.org/en/download.html"
LIST_URL="https://nginx.org/download/"
LATEST=""

PAGE="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
    -A "$UA" "$PAGE_URL" 2>/dev/null || true)"

if [ -n "$PAGE" ] && printf '%s' "$PAGE" | grep -qi 'stable version'; then
    # 页面同时包含 stable / mainline / legacy 版本；stable 分支为偶数次版本号。
    LATEST="$(printf '%s' "$PAGE" \
        | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+' \
        | sed 's/^nginx-//' \
        | sort -u \
        | awk -F. '$2 % 2 == 0' \
        | sort -V \
        | tail -n 1)"
fi

if [ -z "$LATEST" ]; then
    log "download.html 解析失败，回退到 $LIST_URL 目录列表"
    LIST="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        -A "$UA" "$LIST_URL" 2>/dev/null || true)"
    LATEST="$(printf '%s' "$LIST" \
        | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed 's/^nginx-//; s/\.tar\.gz$//' \
        | sort -u \
        | awk -F. '$2 % 2 == 0' \
        | sort -V \
        | tail -n 1)"
fi

if [ -z "$LATEST" ]; then
    die "无法从 nginx.org 确定最新稳定版。请手动指定版本，例如：
  GitHub Actions: workflow_dispatch 输入 nginx_version=1.30.7
  本地:           resolve-nginx-version.sh 1.30.7"
fi

validate_version "$LATEST"
log "从上游解析到 nginx 最新稳定版: $LATEST"
echo "$LATEST"
