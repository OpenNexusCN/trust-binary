#!/usr/bin/env bash
# 在目标发行版容器内验证 nginx 二进制可直接运行。
# 不依赖 curl/openssl 命令：HTTP 使用 bash /dev/tcp，TLS 由 nginx 自身作为客户端回环验证。
#
# 必需环境变量: NGINX_VERSION OPENSSL_VERSION
# 可选环境变量: ARTIFACT_DIR(默认 /artifact) CERT_DIR(默认 /certs)
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/artifact}"
CERT_DIR="${CERT_DIR:-/certs}"
: "${NGINX_VERSION:?缺少 NGINX_VERSION}"
: "${OPENSSL_VERSION:?缺少 OPENSSL_VERSION}"

MARKER="trust-binary-smoke-test-ok"
PREFIX="$(mktemp -d /tmp/nginx-smoke.XXXXXX)"
CONF="$PREFIX/nginx.conf"
BIN=""

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    echo "--- nginx -V ---" >&2
    if [ -n "$BIN" ]; then
        "$BIN" -V 2>&1 | sed 's/^/  /' >&2 || true
    fi
    echo "--- error.log ---" >&2
    cat "$PREFIX/logs/error.log" 2>/dev/null >&2 || true
    echo "--- ldd ---" >&2
    cat "$PREFIX/ldd.txt" 2>/dev/null >&2 || true
    exit 1
}

cleanup() {
    if [ -n "$BIN" ] && [ -f "$PREFIX/nginx.pid" ]; then
        "$BIN" -p "$PREFIX" -c "$CONF" -s quit >/dev/null 2>&1 || true
    fi
    rm -rf "$PREFIX"
}
trap cleanup EXIT

BIN_SRC="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "nginx-*-$(uname -m)" -print -quit)"
[ -n "$BIN_SRC" ] || fail "在 $ARTIFACT_DIR 未找到 nginx 二进制"

# upload/download-artifact 不保留可执行位，而 /artifact 通常只读挂载；
# 复制到可写目录后再设置执行位。
BIN="$PREFIX/nginx"
install -m 0755 "$BIN_SRC" "$BIN" || fail "复制二进制失败: $BIN_SRC"
echo "测试对象: $BIN_SRC"

mkdir -p "$PREFIX/logs" "$PREFIX/html"
mkdir -p "$PREFIX/temp/client_temp" "$PREFIX/temp/proxy_temp" \
         "$PREFIX/temp/fastcgi_temp" "$PREFIX/temp/uwsgi_temp" "$PREFIX/temp/scgi_temp"
printf '%s\n' "$MARKER" > "$PREFIX/html/health.txt"
chmod 0755 "$PREFIX" "$PREFIX/logs" "$PREFIX/html"
chmod 0644 "$PREFIX/html/health.txt"
chmod -R 0777 "$PREFIX/temp"

echo "=== 1. 版本与编译特性 ==="
"$BIN" -V > "$PREFIX/nginx-V.txt" 2>&1 || fail "nginx -V 执行失败"
grep -q "nginx/$NGINX_VERSION" "$PREFIX/nginx-V.txt" || fail "版本不符（期望 $NGINX_VERSION）"
grep -q "OpenSSL $OPENSSL_VERSION" "$PREFIX/nginx-V.txt" || fail "内嵌 OpenSSL 版本不符（期望 $OPENSSL_VERSION）"
grep -q -- '--with-stream' "$PREFIX/nginx-V.txt" || fail "缺少 stream 模块"
grep -q -- '--with-http_v2_module' "$PREFIX/nginx-V.txt" || fail "缺少 http_v2 模块"
grep -q -- '--with-http_ssl_module' "$PREFIX/nginx-V.txt" || fail "缺少 http_ssl 模块"

echo "=== 2. 运行时依赖检查 ==="
if ! ldd "$BIN" > "$PREFIX/ldd.txt" 2>&1; then
    fail "ldd 执行失败（二进制可能无法在当前系统加载）"
fi
if grep -Eq 'libssl|libcrypto|libpcre2|libz\.so' "$PREFIX/ldd.txt"; then
    fail "存在未静态链接的依赖（libssl/libcrypto/libpcre2/libz）"
fi
if grep -q 'not found' "$PREFIX/ldd.txt"; then
    fail "存在无法解析的动态库"
fi
echo "ldd 检查通过（仅依赖 glibc 家族）"

[ -f "$CERT_DIR/test.crt" ] && [ -f "$CERT_DIR/test.key" ] \
    || fail "缺少测试证书: $CERT_DIR/test.crt / test.key"

echo "=== 3. 生成配置并 nginx -t ==="
cat > "$CONF" <<EOF_CONF
user nobody;
worker_processes 1;
pid $PREFIX/nginx.pid;
error_log $PREFIX/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $PREFIX/temp/client_temp;
    proxy_temp_path $PREFIX/temp/proxy_temp;
    fastcgi_temp_path $PREFIX/temp/fastcgi_temp;
    uwsgi_temp_path $PREFIX/temp/uwsgi_temp;
    scgi_temp_path $PREFIX/temp/scgi_temp;

    server {
        listen 127.0.0.1:18080;
        server_name localhost;
        location / { root $PREFIX/html; }
    }

    server {
        listen 127.0.0.1:18443 ssl;
        ssl_certificate $CERT_DIR/test.crt;
        ssl_certificate_key $CERT_DIR/test.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / { root $PREFIX/html; }
    }

    # 用 nginx 自身作为 TLS 客户端，验证 OpenSSL 双向可用
    server {
        listen 127.0.0.1:18082;
        location / {
            proxy_pass https://127.0.0.1:18443;
            proxy_ssl_verify off;
            proxy_ssl_protocols TLSv1.2 TLSv1.3;
        }
    }
}
stream {
    server {
        listen 127.0.0.1:18081;
        proxy_pass 127.0.0.1:18080;
    }
}
EOF_CONF

TEST_OUT="$("$BIN" -t -p "$PREFIX" -c "$CONF" 2>&1)" || {
    printf '%s\n' "$TEST_OUT"
    fail "nginx -t 失败"
}
printf '%s\n' "$TEST_OUT"

echo "=== 4. 启动并做端到端请求 ==="
"$BIN" -p "$PREFIX" -c "$CONF" || fail "nginx 启动失败"
for _ in $(seq 1 50); do
    [ -s "$PREFIX/nginx.pid" ] && break
    sleep 0.1
done
[ -s "$PREFIX/nginx.pid" ] || fail "nginx 未生成 pid 文件"

TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout 15)
fi

http_get() {
    local port="$1" path="$2" rc
    exec 3<>"/dev/tcp/127.0.0.1/${port}" || return 1
    printf 'GET %s HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$path" >&3
    if [ "${#TIMEOUT_CMD[@]}" -gt 0 ]; then
        "${TIMEOUT_CMD[@]}" cat <&3
    else
        cat <&3
    fi
    rc=$?
    exec 3<&- 3>&- 2>/dev/null || true
    return "$rc"
}

assert_ok() {
    local label="$1" port="$2" response
    if ! response="$(http_get "$port" /health.txt)"; then
        fail "$label: 请求 127.0.0.1:$port 失败"
    fi
    grep -q '200 OK' <<< "$response" || fail "$label: 未返回 200"
    grep -q "$MARKER" <<< "$response" || fail "$label: 响应内容不符"
    echo "  ✓ $label (127.0.0.1:$port)"
}

assert_ok "HTTP" 18080
assert_ok "HTTPS via proxy (TLS 握手)" 18082
assert_ok "Stream TCP 转发" 18081

echo "=== 5. reload / quit ==="
"$BIN" -p "$PREFIX" -c "$CONF" -s reload || fail "reload 失败"
sleep 0.5
assert_ok "reload 后 HTTP" 18080

"$BIN" -p "$PREFIX" -c "$CONF" -s quit || fail "quit 失败"
for _ in $(seq 1 50); do
    [ ! -s "$PREFIX/nginx.pid" ] && break
    sleep 0.1
done
[ ! -s "$PREFIX/nginx.pid" ] || fail "nginx 未在 quit 后退出"

echo "PASS: nginx $NGINX_VERSION (OpenSSL $OPENSSL_VERSION) 在 $(uname -m) 上冒烟测试全部通过"
