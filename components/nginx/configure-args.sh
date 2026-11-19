#!/usr/bin/env bash
# 输出 nginx configure 参数，每行一个参数（供 mapfile 读取，避免空格拆分问题）。
#
# 依赖环境变量: PCRE2_VERSION / ZLIB_VERSION / OPENSSL_VERSION
# 参数: $1 = 工作目录（源码解包根目录）
nginx_configure_args() {
    local work="${1:?nginx_configure_args 需要工作目录}"

    local cc_opt="-O2 -fPIC -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2"

    # CentOS 7 自带 gcc 4.8 不支持 -fstack-protector-strong
    if ! printf 'int main(void){return 0;}\n' \
        | gcc -x c -fstack-protector-strong -c -o /dev/null - 2>/dev/null; then
        cc_opt="-O2 -fPIC -fstack-protector -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2"
    fi

    cat <<EOF_ARGS
--prefix=/etc/nginx
--sbin-path=/usr/sbin/nginx
--modules-path=/usr/lib/nginx/modules
--conf-path=/etc/nginx/nginx.conf
--error-log-path=/var/log/nginx/error.log
--http-log-path=/var/log/nginx/access.log
--pid-path=/var/run/nginx.pid
--lock-path=/var/run/nginx.lock
--http-client-body-temp-path=/var/cache/nginx/client_temp
--http-proxy-temp-path=/var/cache/nginx/proxy_temp
--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp
--http-scgi-temp-path=/var/cache/nginx/scgi_temp
--user=nginx
--group=nginx
--with-compat
--with-file-aio
--with-threads
--with-http_addition_module
--with-http_auth_request_module
--with-http_dav_module
--with-http_flv_module
--with-http_gunzip_module
--with-http_gzip_static_module
--with-http_mp4_module
--with-http_random_index_module
--with-http_realip_module
--with-http_secure_link_module
--with-http_slice_module
--with-http_ssl_module
--with-http_stub_status_module
--with-http_sub_module
--with-http_v2_module
--with-mail
--with-mail_ssl_module
--with-stream
--with-stream_realip_module
--with-stream_ssl_module
--with-stream_ssl_preread_module
--with-ld-opt=-Wl,-z,relro -Wl,-z,now
--with-cc-opt=$cc_opt
--with-pcre=$work/pcre2-$PCRE2_VERSION
--with-pcre-opt=-O2 -fPIC
--with-pcre-jit
--with-zlib=$work/zlib-$ZLIB_VERSION
--with-zlib-opt=-O2 -fPIC
--with-openssl=$work/openssl-$OPENSSL_VERSION
--with-openssl-opt=-fPIC no-tests
EOF_ARGS
}
