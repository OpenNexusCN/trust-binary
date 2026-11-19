#!/usr/bin/env bash
# 端到端测试 prepare-sources.sh 的信任逻辑（仅 Linux/macOS，CI 中执行）：
#   1. 合法签名 + 正确 SHA256 -> 成功
#   2. 签名有效但 SHA256 不符 -> 失败
#   3. 源码被篡改（签名失效） -> 失败
#
# 使用临时生成的测试密钥，不依赖任何真实上游私钥。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
PYTHON="$(python_cmd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/trust-binary-verify.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
if [ "${KEEP_TEST_WORK:-}" = "1" ]; then
    echo "保留测试目录: $WORK" >&2
else
    trap cleanup EXIT
fi

export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

echo "=== 生成测试签名密钥 ==="
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Trust Binary Test <test@example.invalid>" rsa2048 sign 0
FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "FAIL: 无法获取测试密钥指纹" >&2; exit 1; }
gpg --batch --quiet --armor --export "$FPR" > "$WORK/test-signer.asc"

create_component() {
    local name="$1" version="$2" file="$3" sig_suffix="$4"
    local payload="$WORK/payload-$name"
    mkdir -p "$payload"
    printf '%s %s\n' "$name" "$version" > "$payload/README.txt"
    tar -C "$payload" -czf "$WORK/$file" README.txt
    gpg --batch --quiet --yes --armor --detach-sign \
        --output "$WORK/$file$sig_suffix" "$WORK/$file"
}

echo "=== 构造四个组件（签名 + 哈希） ==="
create_component nginx 1.2.3 nginx-1.2.3.tar.gz .asc
create_component openssl 3.5.9 openssl-3.5.9.tar.gz .asc
create_component pcre2 10.49 pcre2-10.49.tar.gz .sig
create_component zlib 1.4 zlib-1.4.tar.gz .asc

"$PYTHON" - "$WORK" "$FPR" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
fpr = sys.argv[2]
base = work.as_uri().rstrip("/")
specs = [
    ("nginx", "1.2.3", ".asc"),
    ("openssl", "3.5.9", ".asc"),
    ("pcre2", "10.49", ".sig"),
    ("zlib", "1.4", ".asc"),
]

components = {}
for name, version, suffix in specs:
    file_name = f"{name}-{version}.tar.gz"
    path = work / file_name
    template = file_name.replace(version, "{version}")
    components[name] = {
        "version": version,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "key_file": str(work / "test-signer.asc"),
        "signer_fingerprint": fpr,
        "downloads": [
            {
                "url_template": f"{base}/{template}",
                "signature_url_template": f"{base}/{template}{suffix}",
                "file_name_template": template,
            }
        ],
    }

lock = {
    "schema": 1,
    "updated_at": "2026-01-01T00:00:00Z",
    "components": components,
}
(work / "nginx.lock.json").write_text(json.dumps(lock, indent=2), encoding="utf-8")
PY

echo "=== 1. 合法流程应成功 ==="
PREPARE_LOG="$WORK/prepare-ok.log"
if ! bash "$ROOT_DIR/scripts/prepare-sources.sh" "$WORK/out" "$WORK/nginx.lock.json" 1.2.3 \
    > "$PREPARE_LOG" 2>&1; then
    echo "FAIL: 合法流程失败" >&2
    cat "$PREPARE_LOG" >&2
    exit 1
fi
[ -f "$WORK/out/sources/nginx-1.2.3.tar.gz" ] || { echo "FAIL: 缺少 nginx 源码" >&2; exit 1; }
[ -f "$WORK/out/nginx.lock.resolved.json" ] || { echo "FAIL: 缺少 resolved lock" >&2; exit 1; }
grep -q "验签与 SHA256 校验通过" "$PREPARE_LOG" || { echo "FAIL: 未执行哈希校验" >&2; exit 1; }
echo "PASS: 合法源码通过校验"

echo "=== 2. SHA256 不符应失败 ==="
"$PYTHON" - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
lock = json.loads((work / "nginx.lock.json").read_text(encoding="utf-8"))
lock["components"]["nginx"]["sha256"] = "f" * 64
(work / "lock-badsha.json").write_text(json.dumps(lock, indent=2), encoding="utf-8")
PY
if bash "$ROOT_DIR/scripts/prepare-sources.sh" "$WORK/out-badsha" "$WORK/lock-badsha.json" 1.2.3 \
    > "$WORK/prepare-badsha.log" 2>&1; then
    echo "FAIL: SHA256 不符仍被接受" >&2
    exit 1
fi
grep -q "SHA256 不匹配" "$WORK/prepare-badsha.log" || { echo "FAIL: 失败原因不是 SHA256" >&2; exit 1; }
echo "PASS: SHA256 不符被拒绝"

echo "=== 3. 源码篡改应失败 ==="
printf 'tampered' >> "$WORK/zlib-1.4.tar.gz"
if bash "$ROOT_DIR/scripts/prepare-sources.sh" "$WORK/out-tampered" "$WORK/nginx.lock.json" 1.2.3 \
    > "$WORK/prepare-tampered.log" 2>&1; then
    echo "FAIL: 篡改源码仍被接受" >&2
    exit 1
fi
grep -q "GPG 验签失败" "$WORK/prepare-tampered.log" || { echo "FAIL: 失败原因不是 GPG 验签" >&2; exit 1; }
echo "PASS: 篡改源码被拒绝"

echo "ALL VERIFY-SOURCES TESTS PASSED"
