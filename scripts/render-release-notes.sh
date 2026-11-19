#!/usr/bin/env bash
# 生成 GitHub Release 说明。
# 用法: render-release-notes.sh <version> <artifacts_dir> <out_file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
PYTHON="$(python_cmd)"

VERSION="${1:?用法: render-release-notes.sh <version> <artifacts_dir> <out_file>}"
ARTIFACTS_DIR="${2:?缺少 artifacts 目录}"
OUT_FILE="${3:?缺少输出文件}"

[ -d "$ARTIFACTS_DIR" ] || { echo "artifacts 目录不存在: $ARTIFACTS_DIR" >&2; exit 1; }
METADATA="$ARTIFACTS_DIR/sources/source-metadata.json"
[ -f "$METADATA" ] || { echo "缺少 source-metadata.json: $METADATA" >&2; exit 1; }

{
    echo "## nginx ${VERSION} 静态编译产物"
    echo
    echo "OpenSSL / PCRE2 / zlib 已静态链接，产物仅依赖系统 glibc。"
    echo "每个产物均在对应发行版容器中完成启动、HTTP/HTTPS/stream 转发与 reload 冒烟测试。"
    echo
    echo "### 产物矩阵"
    echo
    echo "| 发行版-架构 | 产物 |"
    echo "|-------------|------|"
    for dir in "$ARTIFACTS_DIR"/nginx-*/; do
        [ -d "$dir" ] || continue
        tarball="$(find "$dir" -maxdepth 1 -name '*.tar.gz' -printf '%f\n' | head -n 1)"
        [ -n "$tarball" ] || continue
        distro="$(basename "$dir")"
        distro="${distro#nginx-${VERSION}-}"
        echo "| ${distro} | \`${tarball}\` |"
    done
    echo
    echo "### 上游源码"
    echo
    PYTHONIOENCODING=utf-8 "$PYTHON" - "$METADATA" <<'PY'
import json
import sys

metadata = json.load(open(sys.argv[1], encoding="utf-8"))
print("| 组件 | 版本 | SHA256 |")
print("|------|------|--------|")
for name, comp in metadata["components"].items():
    print(f"| {name} | {comp['version']} | `{comp['sha256']}` |")
PY
    echo
    echo "### 安装"
    echo
    echo '```bash'
    echo "tar xzf nginx-${VERSION}-<发行版>-x86_64.tar.gz"
    echo "sudo useradd -r -s /usr/sbin/nologin nginx 2>/dev/null || true"
    echo "sudo install -d /etc/nginx /var/cache/nginx /var/log/nginx"
    echo "sudo install -m 0755 nginx-${VERSION}-<发行版>-x86_64/bin/nginx /usr/sbin/nginx"
    echo "sudo cp -a nginx-${VERSION}-<发行版>-x86_64/conf/. /etc/nginx/"
    echo "sudo nginx -t && sudo nginx"
    echo '```'
    echo
    echo "### 校验"
    echo
    echo '```bash'
    echo "sha256sum -c SHA256SUMS"
    echo "gpg --verify  # 源码验签信息见构建日志与 source-metadata.json"
    echo '```'
} > "$OUT_FILE"

cat "$OUT_FILE"
