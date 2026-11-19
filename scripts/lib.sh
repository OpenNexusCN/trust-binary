#!/usr/bin/env bash
# 公共 Shell 辅助函数。所有脚本通过 `source lib.sh` 使用。
# shellcheck shell=bash

set -euo pipefail

log()  { printf '[trust-binary] %s\n' "$*" >&2; }
warn() { printf '[trust-binary] WARN: %s\n' "$*" >&2; }
die()  { printf '[trust-binary] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
    done
}

# 返回可用的 Python 3 命令名（CI 为 python3，部分本地环境为 python）
python_cmd() {
    if command -v python3 >/dev/null 2>&1; then
        echo python3
    elif command -v python >/dev/null 2>&1; then
        echo python
    else
        die "缺少 Python 3"
    fi
}

# 计算文件 SHA256（GNU coreutils 或 BSD shasum 均可）
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "缺少 sha256sum / shasum"
    fi
}

# 简单的版本校验：X.Y.Z
validate_version() {
    [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "非法版本号: '${1:-}'（期望 X.Y.Z）"
}
