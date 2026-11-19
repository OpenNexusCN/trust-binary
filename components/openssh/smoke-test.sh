#!/usr/bin/env bash
# 在目标发行版容器内验证 OpenSSH 产物：
#   解包到 /、创建 sshd 用户、生成临时主机/客户端密钥、启动 sshd，
#   依次验证 ssh 登录、scp/sftp 传输、ssh-agent/ssh-add。
#
# 必需环境变量: OPENSSH_VERSION OPENSSL_VERSION
# 可选环境变量: ARTIFACT_DIR(默认 /artifact)
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/artifact}"
: "${OPENSSH_VERSION:?缺少 OPENSSH_VERSION}"
: "${OPENSSL_VERSION:?缺少 OPENSSL_VERSION}"

PREFIX="$(mktemp -d /tmp/openssh-smoke.XXXXXX)"
CONF="$PREFIX/sshd_config"
SSHD_LOG="$PREFIX/sshd.log"
MARKER="trust-binary-openssh-ok"

SSHD=/usr/sbin/sshd
SSH=/usr/bin/ssh
SCP=/usr/bin/scp
SSH_KEYGEN=/usr/bin/ssh-keygen
SSH_AGENT=/usr/bin/ssh-agent
SSH_ADD=/usr/bin/ssh-add

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    echo "--- ssh -V ---" >&2
    [ -x "$SSH" ] && "$SSH" -V >&2 2>&1 || true
    echo "--- sshd -t ---" >&2
    [ -f "$CONF" ] && "$SSHD" -t -f "$CONF" >&2 2>&1 || true
    echo "--- sshd.log ---" >&2
    cat "$SSHD_LOG" 2>/dev/null >&2 || true
    echo "--- ldd sshd ---" >&2
    cat "$PREFIX/ldd.txt" 2>/dev/null >&2 || true
    exit 1
}

cleanup() {
    if [ -f "$PREFIX/sshd.pid" ]; then
        kill "$(cat "$PREFIX/sshd.pid")" 2>/dev/null || true
    fi
    if [ -n "${SSH_AGENT_PID:-}" ]; then
        "$SSH_AGENT" -k >/dev/null 2>&1 || true
    fi
    rm -rf "$PREFIX"
}
trap cleanup EXIT

TARBALL="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "openssh-*-$(uname -m).tar.gz" -print -quit)"
[ -n "$TARBALL" ] || fail "在 $ARTIFACT_DIR 未找到 OpenSSH 产物 tar.gz"
echo "测试对象: $TARBALL"

echo "=== 1. 安装产物到 / ==="
tar -C / -xzf "$TARBALL" || fail "解包失败: $TARBALL"
[ -x "$SSHD" ] || fail "缺少 $SSHD"
SSHD_SESSION="$(find /usr -type f -name sshd-session -print -quit)"
SSHD_AUTH="$(find /usr -type f -name sshd-auth -print -quit)"
SFTP_SERVER="$(find /usr -type f -name sftp-server -print -quit)"
[ -n "$SSHD_SESSION" ] || fail "缺少 sshd-session"
[ -n "$SSHD_AUTH" ] || fail "缺少 sshd-auth"
[ -n "$SFTP_SERVER" ] || fail "缺少 sftp-server"
LIBEXECDIR="$(dirname "$SSHD_SESSION")"

echo "=== 2. 版本与依赖检查 ==="
SSH_V="$("$SSH" -V 2>&1)"
printf '%s\n' "$SSH_V"
[[ "$SSH_V" == *"OpenSSH_${OPENSSH_VERSION}"* ]] || fail "OpenSSH 版本不符（期望 $OPENSSH_VERSION）"
[[ "$SSH_V" == *"OpenSSL ${OPENSSL_VERSION}"* ]] || fail "OpenSSL 版本不符（期望 $OPENSSL_VERSION）"
if ! ldd "$SSHD" > "$PREFIX/ldd.txt" 2>&1; then
    fail "ldd 执行失败"
fi
if grep -Eq 'libcrypto|libssl|libz\.so' "$PREFIX/ldd.txt"; then
    fail "sshd 未静态链接 OpenSSL/zlib"
fi
if grep -q 'not found' "$PREFIX/ldd.txt"; then
    fail "sshd 存在无法解析的动态库"
fi
echo "依赖检查通过（OpenSSL/zlib 静态）"

echo "=== 3. 准备 sshd 运行环境 ==="
if ! id -u sshd >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        getent group sshd >/dev/null 2>&1 || groupadd -r sshd 2>/dev/null || true
        useradd -r -g sshd -s /bin/false -M sshd 2>/dev/null \
            || useradd -r -s /bin/false -M sshd 2>/dev/null || true
    fi
fi
if ! id -u sshd >/dev/null 2>&1; then
    # 极简镜像缺少 useradd 时直接写入 passwd/group（容器内一次性使用）
    echo 'sshd:x:74:74:sshd privsep:/var/empty:/bin/false' >> /etc/passwd
    grep -q '^sshd:' /etc/group || echo 'sshd:x:74:' >> /etc/group
fi
id -u sshd >/dev/null 2>&1 || fail "创建 sshd 用户失败"
install -d -m 0755 /run/sshd

"$SSH_KEYGEN" -t ed25519 -N '' -f "$PREFIX/host_ed25519" >/dev/null 2>&1 || fail "生成主机密钥失败"
"$SSH_KEYGEN" -t ed25519 -N '' -f "$PREFIX/client_ed25519" >/dev/null 2>&1 || fail "生成客户端密钥失败"
install -d -m 0700 /root/.ssh
install -m 0600 "$PREFIX/client_ed25519.pub" /root/.ssh/authorized_keys

cat > "$CONF" <<EOF_CONF
Port 2222
ListenAddress 127.0.0.1
HostKey $PREFIX/host_ed25519
PidFile $PREFIX/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
AllowUsers root
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,ecdh-sha2-nistp256,diffie-hellman-group14-sha256
HostKeyAlgorithms ssh-ed25519
Subsystem sftp $LIBEXECDIR/sftp-server
EOF_CONF

echo "=== 4. sshd -t ==="
TEST_OUT="$("$SSHD" -t -f "$CONF" 2>&1)" || {
    printf '%s\n' "$TEST_OUT"
    fail "sshd -t 失败"
}
printf '%s\n' "$TEST_OUT"

echo "=== 5. 启动 sshd ==="
"$SSHD" -f "$CONF" -E "$SSHD_LOG" || fail "sshd 启动失败"
for _ in $(seq 1 50); do
    [ -s "$PREFIX/sshd.pid" ] && break
    sleep 0.1
done
[ -s "$PREFIX/sshd.pid" ] || fail "sshd 未生成 pid 文件"

SSH_OPTS=(
    -F /dev/null
    -p 2222
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$PREFIX/known_hosts"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o KexAlgorithms=curve25519-sha256
    -o HostKeyAlgorithms=ssh-ed25519
    -o LogLevel=ERROR
)

retry_ssh() {
    local out=""
    for _ in $(seq 1 15); do
        if out="$("$@" 2>"$PREFIX/ssh.err")"; then
            printf '%s' "$out"
            return 0
        fi
        sleep 0.2
    done
    cat "$PREFIX/ssh.err" >&2 || true
    return 1
}

echo "=== 6. SSH 登录测试 ==="
OUT="$(retry_ssh "$SSH" "${SSH_OPTS[@]}" -i "$PREFIX/client_ed25519" root@127.0.0.1 "echo $MARKER")" \
    || fail "ssh 登录失败"
[[ "$OUT" == *"$MARKER"* ]] || fail "ssh 返回内容不符: $OUT"

echo "=== 7. scp / sftp-server 测试 ==="
printf 'scp-%s\n' "$MARKER" > "$PREFIX/local.txt"
"$SCP" -q -P 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile="$PREFIX/known_hosts" \
    -o BatchMode=yes -o KexAlgorithms=curve25519-sha256 \
    -o HostKeyAlgorithms=ssh-ed25519 -o LogLevel=ERROR \
    -i "$PREFIX/client_ed25519" \
    "$PREFIX/local.txt" root@127.0.0.1:"$PREFIX/remote.txt" || fail "scp 上传失败"
REMOTE="$(retry_ssh "$SSH" "${SSH_OPTS[@]}" -i "$PREFIX/client_ed25519" root@127.0.0.1 "cat '$PREFIX/remote.txt'")" \
    || fail "读取 scp 目标文件失败"
[[ "$REMOTE" == *"$MARKER"* ]] || fail "scp 文件内容不符"

echo "=== 8. ssh-agent / ssh-add 测试 ==="
eval "$("$SSH_AGENT" -s -a "$PREFIX/agent.sock")" >/dev/null
"$SSH_ADD" -q "$PREFIX/client_ed25519" >/dev/null 2>&1 || fail "ssh-add 失败"
SSH_ADD_LIST="$("$SSH_ADD" -l)" || fail "ssh-add -l 失败"
grep -q 'ED25519' <<< "$SSH_ADD_LIST" || fail "ssh-add 未列出密钥"
AGENT_OUT="$(retry_ssh "$SSH" "${SSH_OPTS[@]}" -o IdentityAgent="$PREFIX/agent.sock" \
    root@127.0.0.1 "echo agent-$MARKER")" || fail "通过 ssh-agent 登录失败"
[[ "$AGENT_OUT" == *"agent-$MARKER"* ]] || fail "ssh-agent 登录返回内容不符"
"$SSH_AGENT" -k >/dev/null 2>&1 || true

echo "=== 9. 停止 sshd ==="
kill "$(cat "$PREFIX/sshd.pid")" 2>/dev/null || true
for _ in $(seq 1 50); do
    [ ! -s "$PREFIX/sshd.pid" ] && break
    sleep 0.1
done

echo "PASS: OpenSSH $OPENSSH_VERSION (OpenSSL $OPENSSL_VERSION) 在 $(uname -m) 上冒烟测试全部通过"
