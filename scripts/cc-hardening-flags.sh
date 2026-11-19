#!/usr/bin/env bash
# 输出编译器加固参数（供各组件 build.sh 复用）。
# shellcheck shell=bash

hardening_cflags() {
    local stack_flag="-fstack-protector-strong"
    # 老 gcc（如 CentOS 7 系统 gcc 4.8）不支持 -fstack-protector-strong
    if ! printf 'int main(void){return 0;}\n' \
        | gcc -x c -fstack-protector-strong -c -o /dev/null - 2>/dev/null; then
        stack_flag="-fstack-protector"
    fi

    # Ubuntu 24.04 GCC 13 默认 _FORTIFY_SOURCE=3；用普通 -D 让默认值让路，
    # 探测失败则直接采用发行版默认值。
    local fortify_flag="-D_FORTIFY_SOURCE=2"
    if ! printf 'int main(void){return 0;}\n' \
        | gcc -x c -O2 -Werror "$fortify_flag" -c -o /dev/null - 2>/dev/null; then
        fortify_flag=""
    fi

    printf '%s %s %s' "-O2 -fPIC -Wformat -Werror=format-security" "$stack_flag" "$fortify_flag"
}
