#!/usr/bin/env bash
# 下载并校验所有上游源码（GPG 验签 + SHA256 锁定），生成供构建使用的源码目录。
#
# 用法:
#   prepare-sources.sh <out_dir> [lockfile] [override_version] [override_component]
#
#   override_component 默认 nginx；例如 OpenSSH:
#   prepare-sources.sh work lock/openssh.lock.json 10.6p2 openssh
#
# 产物:
#   <out_dir>/sources/<tarball>                 已验签的源码包
#   <out_dir>/sources/MANIFEST.sha256           源码包哈希清单
#   <out_dir>/<name>.lock.resolved.json          本次构建实际使用的锁定文件
#   <out_dir>/source-metadata.json              版本/哈希/签名者信息
#
# 安全模型:
#   1. 所有源码必须通过 GPG 验签，且签名者指纹必须与 lockfile 中固定值一致；
#   2. lockfile 中已有 sha256 的组件必须匹配；
#   3. 新版本（尚未锁定）在 GPG 验签通过后记录其 sha256。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT_DIR="${1:?用法: prepare-sources.sh <out_dir> [lockfile] [override_version] [override_component]}"
LOCK_FILE="${2:-$ROOT_DIR/lock/nginx.lock.json}"
TARGET_VERSION="${3:-}"
TARGET_COMPONENT="${4:-nginx}"

[ -n "$TARGET_VERSION" ] && validate_component_version "$TARGET_COMPONENT" "$TARGET_VERSION"

SRC_DIR="$OUT_DIR/sources"
mkdir -p "$SRC_DIR"

require_cmd curl gpg
PYTHON="$(python_cmd)"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
TMP_FILES=()
cleanup() {
    rm -rf "$GNUPGHOME"
    if [ "${#TMP_FILES[@]}" -gt 0 ]; then rm -f "${TMP_FILES[@]}"; fi
}
trap cleanup EXIT

declare -A FETCHED=()
declare -A VER=()
declare -A SHA=()
declare -A FPR=()
declare -A FILE=()
declare -A UPDATE_LOCK=()
declare -a ORDER=()

EXPORT_FILE="$(mktemp "$OUT_DIR/.export.XXXXXX")"
TMP_FILES+=("$EXPORT_FILE")
if [ -n "$TARGET_VERSION" ]; then
    "$PYTHON" "$SCRIPT_DIR/lockfile.py" export "$LOCK_FILE" \
        --override "$TARGET_COMPONENT=$TARGET_VERSION" > "$EXPORT_FILE"
else
    "$PYTHON" "$SCRIPT_DIR/lockfile.py" export "$LOCK_FILE" > "$EXPORT_FILE"
fi
[ -s "$EXPORT_FILE" ] || die "lockfile 导出为空，无法继续"

while IFS='|' read -r name version sha fpr key_file url sig_url file_name; do
    # 防御 Windows/Git Bash 场景下可能残留的行尾 \r
    name="${name%$'\r'}"
    version="${version%$'\r'}"
    sha="${sha%$'\r'}"
    fpr="${fpr%$'\r'}"
    key_file="${key_file%$'\r'}"
    url="${url%$'\r'}"
    sig_url="${sig_url%$'\r'}"
    file_name="${file_name%$'\r'}"
    [ -n "${name:-}" ] || continue

    if [ -z "${VER[$name]:-}" ]; then
        key_path="$key_file"
        case "$key_path" in
            /*|[A-Za-z]:[\\/]*|\\\\*) ;;
            *) key_path="$ROOT_DIR/$key_path" ;;
        esac
        # Git Bash 本地运行时，把 Windows 绝对路径转成 POSIX 路径
        if command -v cygpath >/dev/null 2>&1; then
            key_path="$(cygpath -u "$key_path")"
        fi
        [ -f "$key_path" ] || die "缺少公钥文件: $key_path"
        log "导入 $name 的签名公钥: $key_path"
        gpg --batch --quiet --import "$key_path"
        VER[$name]="$version"
        SHA[$name]="$sha"
        FPR[$name]="$fpr"
        FILE[$name]="$file_name"
        ORDER+=("$name")
    fi

    if [ -n "${FETCHED[$name]:-}" ]; then
        continue
    fi

    log "下载 $name $version: $url"
    tmp_tar="$(mktemp "$OUT_DIR/.download.XXXXXX")"
    tmp_sig="$(mktemp "$OUT_DIR/.download.XXXXXX.sig")"
    tmp_status="$(mktemp "$OUT_DIR/.download.XXXXXX.status")"
    TMP_FILES+=("$tmp_tar" "$tmp_sig" "$tmp_status")

    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
        -A "trust-binary/1.0" -o "$tmp_tar" "$url"; then
        warn "下载失败，尝试下一个源: $url"
        continue
    fi
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
        -A "trust-binary/1.0" -o "$tmp_sig" "$sig_url"; then
        warn "签名下载失败，尝试下一个源: $sig_url"
        continue
    fi

    if ! gpg --batch --status-fd 1 --verify "$tmp_sig" "$tmp_tar" >"$tmp_status" 2>/dev/null; then
        warn "GPG 验签失败，拒绝该产物: $url"
        continue
    fi

    validsig="$(awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}' "$tmp_status")"
    if [ -z "$validsig" ]; then
        warn "GPG 状态输出缺少 VALIDSIG，拒绝该产物: $url"
        continue
    fi

    fpr_upper="$(printf '%s' "$fpr" | tr '[:lower:]' '[:upper:]')"
    validsig_upper="$(printf '%s' "$validsig" | tr '[:lower:]' '[:upper:]')"
    if [ "${#fpr_upper}" -eq 40 ]; then
        [ "$validsig_upper" = "$fpr_upper" ] || {
            warn "签名者指纹不匹配（期望 $fpr_upper，实际 $validsig_upper），拒绝该产物: $url"
            continue
        }
    else
        [[ "$validsig_upper" == *"$fpr_upper" ]] || {
            warn "签名者密钥 ID 不匹配（期望 ...$fpr_upper，实际 $validsig_upper），拒绝该产物: $url"
            continue
        }
    fi

    actual_sha="$(sha256_file "$tmp_tar")"
    if [ -n "$sha" ]; then
        if [ "$actual_sha" != "$sha" ]; then
            die "SHA256 不匹配: $name $version
  期望: $sha
  实际: $actual_sha
  来源: $url"
        fi
        log "✓ $name $version 验签与 SHA256 校验通过"
    else
        log "✓ $name $version GPG 验签通过（未锁定，记录 sha256=$actual_sha）"
        SHA[$name]="$actual_sha"
        UPDATE_LOCK[$name]=1
    fi

    mv "$tmp_tar" "$SRC_DIR/$file_name"
    FETCHED[$name]=1
done < "$EXPORT_FILE"

for name in "${ORDER[@]}"; do
    if [ -z "${FETCHED[$name]:-}" ]; then
        die "组件 $name ${VER[$name]} 没有可用的已验签下载源（请检查网络或 lockfile 配置）"
    fi
done

# 生成实际使用的 lockfile：对本次新获取/未锁定的组件回写版本与哈希
LOCK_NAME="$(basename "$LOCK_FILE" .json)"
RESOLVED_LOCK="$OUT_DIR/${LOCK_NAME}.resolved.json"
LOCKED_VERSION="$("$PYTHON" "$SCRIPT_DIR/lockfile.py" get "$LOCK_FILE" "$TARGET_COMPONENT" version)"
if [ -n "$TARGET_VERSION" ] && [ "$TARGET_VERSION" != "$LOCKED_VERSION" ]; then
    log "更新 $TARGET_COMPONENT 版本: $LOCKED_VERSION -> $TARGET_VERSION"
fi
cp "$LOCK_FILE" "$RESOLVED_LOCK"
for name in "${ORDER[@]}"; do
    if [ -n "${UPDATE_LOCK[$name]:-}" ]; then
        log "回写 lockfile: $name ${VER[$name]}"
        "$PYTHON" "$SCRIPT_DIR/lockfile.py" set "$RESOLVED_LOCK" \
            --component "$name" \
            --version "${VER[$name]}" \
            --sha256 "${SHA[$name]}" \
            --out "$RESOLVED_LOCK"
    fi
done

# 哈希清单（供构建产物附带与人工复核）
: > "$SRC_DIR/MANIFEST.sha256"
for name in "${ORDER[@]}"; do
    printf '%s  %s\n' "${SHA[$name]}" "${FILE[$name]}" >> "$SRC_DIR/MANIFEST.sha256"
done

# 结构化元数据
: > "$OUT_DIR/.components.tsv"
for name in "${ORDER[@]}"; do
    printf '%s|%s|%s|%s|%s\n' \
        "$name" "${VER[$name]}" "${SHA[$name]}" "${FPR[$name]}" "${FILE[$name]}" \
        >> "$OUT_DIR/.components.tsv"
done
"$PYTHON" - "$OUT_DIR/.components.tsv" "$OUT_DIR/source-metadata.json" <<'PY'
import datetime
import json
import sys
from pathlib import Path

tsv_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
components = {}
for line in tsv_path.read_text(encoding="utf-8").splitlines():
    name, version, sha256, fingerprint, file_name = line.split("|")
    components[name] = {
        "version": version,
        "sha256": sha256,
        "signer_fingerprint": fingerprint,
        "file_name": file_name,
    }
metadata = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "components": components,
}
out_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
rm -f "$OUT_DIR/.components.tsv"

log "源码准备完成: $SRC_DIR"
"$PYTHON" "$SCRIPT_DIR/lockfile.py" summary "$RESOLVED_LOCK"
