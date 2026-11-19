#!/usr/bin/env bash
# 生成 OpenSSH GitHub Release 说明。
# 用法: render-openssh-release-notes.sh <version> <artifacts_dir> <out_file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
PYTHON="$(python_cmd)"

VERSION="${1:?用法: render-openssh-release-notes.sh <version> <artifacts_dir> <out_file>}"
ARTIFACTS_DIR="${2:?缺少 artifacts 目录}"
OUT_FILE="${3:?缺少输出文件}"

[ -d "$ARTIFACTS_DIR" ] || { echo "artifacts 目录不存在: $ARTIFACTS_DIR" >&2; exit 1; }
METADATA="$ARTIFACTS_DIR/sources/source-metadata.json"
[ -f "$METADATA" ] || { echo "缺少 source-metadata.json: $METADATA" >&2; exit 1; }

{
    echo "## OpenSSH ${VERSION} 构建产物"
    echo
    echo "OpenSSL / zlib 已静态链接；PAM 使用目标发行版的动态库。"
    echo "每个产物均在对应发行版容器中完成 sshd 启动、SSH 登录、scp/sftp 和 ssh-agent 冒烟测试。"
    echo "产物包含 \`sshd\`、\`sshd-session\`、\`sshd-auth\` 及完整客户端工具，必须整包替换。"
    echo
    echo "### 产物矩阵"
    echo
    echo "| 发行版-架构 | 产物 |"
    echo "|-------------|------|"
    for dir in "$ARTIFACTS_DIR"/openssh-*/; do
        [ -d "$dir" ] || continue
        tarball="$(find "$dir" -maxdepth 1 -name '*.tar.gz' -print -quit)"
        [ -n "$tarball" ] || continue
        tarball="$(basename "$tarball")"
        label="$(basename "$dir")"
        label="${label#openssh-${VERSION}-}"
        echo "| ${label} | \`${tarball}\` |"
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
    echo "# 升级前保留一个已登录的 root 会话，并备份现有二进制"
    echo "tar -C / -xzf openssh-${VERSION}-<发行版>-<架构>.tar.gz"
    echo "id sshd >/dev/null 2>&1 || useradd -r -s /bin/false -M sshd"
    echo "install -d -m 0755 /run/sshd"
    echo "ssh-keygen -A"
    echo "sshd -t && systemctl restart sshd"
    echo '```'
    echo
    echo "注意：\`sshd\`、\`sshd-session\`、\`sshd-auth\` 必须来自同一版本；不要覆盖 \`/etc/ssh\` 下现有配置。"
    echo
    echo "### 校验"
    echo
    echo '```bash'
    echo "sha256sum -c SHA256SUMS"
    echo "ssh -V   # 应显示 OpenSSH_${VERSION} 与对应 OpenSSL 版本"
    echo '```'
} > "$OUT_FILE"

cat "$OUT_FILE"
