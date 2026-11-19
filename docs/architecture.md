# 架构设计

## 目标

1. **紧跟上游**：始终构建 nginx 最新 stable 版本，无需人工追版本。
2. **可信**：源码签名可验证、哈希可锁定、构建过程可在公开 CI 中审计。
3. **可直接升级**：产物与发行版官方包路径一致，静态链接第三方库，避免系统 OpenSSL 版本差异导致故障。
4. **多发行版**：Ubuntu 18–24 必须支持，CentOS/RHEL 7+ 与 RHEL 9 家族尽力覆盖。
5. **可扩展**：同一套流程可复用于其他软件。

## 总体流程

```
workflow_dispatch / schedule(每日)
        │
        ▼
┌───────────────────┐
│ resolve           │  解析 nginx stable 版本（可手动覆盖）
│                   │  已发布则提前结束
└─────────┬─────────┘
          ▼
┌───────────────────┐
│ prepare-sources   │  下载 nginx/OpenSSL/PCRE2/zlib
│                   │  ├─ GPG 验签（指纹固定）
│                   │  ├─ SHA256 校验（lockfile）
│                   │  └─ 生成 resolved lock + metadata
└─────────┬─────────┘
          ▼  upload artifact（已验签源码）
┌───────────────────┐   10 个并行矩阵任务（x86_64 6 个 + aarch64 4 个）
│ build matrix      │   ubuntu18.04/20.04/22.04/24.04（双架构）
│                   │   centos7 / rocky9（x86_64）
│                   │   docker build 工具链 → docker run 编译
└─────────┬─────────┘
          ▼
┌───────────────────┐   在对应发行版、对应架构的基础镜像中运行
│ smoke test matrix │   nginx -V / ldd / nginx -t / 启动
│                   │   HTTP + HTTPS(nginx 自身作客户端) + stream + reload/quit
└─────────┬─────────┘
          ▼
┌───────────────────┐
│ release           │  汇总资产 + SHA256SUMS + 说明
│                   │  gh release create/upload
│                   │  回写 lockfile（尽力而为）
└───────────────────┘
```

## 关键决策

### 1. 每发行版原生构建（而非单一基线）

用户选择：Ubuntu 18/20/22/24 + CentOS 7 + Rocky 9 各自构建；其中 Ubuntu 覆盖 x86_64 与 aarch64。

- 兼容性最确定：产物在目标发行版原生编译、原生测试。
- 避免 glibc 符号版本、发行版补丁、工具链差异带来的隐性不兼容。
- 代价：Release 资产更多，升级时需选择匹配发行版与架构的产物（README 提供选择规则）。
- ARM64 使用 GitHub 原生 ARM runner（`ubuntu-24.04-arm`）原生编译，而不是 QEMU 模拟，
  避免模拟器导致的编译超时与潜在行为差异。

CentOS 7 产物基于 glibc 2.17，理论可在所有更新的 glibc 发行版运行，可作为“通用兜底”产物；
但正式支持矩阵仍以“对应发行版”为准。

### 2. 第三方库静态链接

nginx 编译时内嵌 OpenSSL / PCRE2 / zlib：

- 不受目标机 OpenSSL 版本、发行版安全策略（如 Ubuntu 22.04 的 OpenSSL 3.0）影响；
- 升级 nginx 即升级其 TLS 栈，行为可预测；
- 产物 `ldd` 仅剩 glibc 家族（libc、libpthread、libdl）。

OpenSSL 选择 3.5 LTS（支持到 2030），在安全更新周期与稳定性之间取平衡。
nginx 1.30.7 已包含 OpenSSL 4.0 兼容代码，但 3.5 LTS 仍是生产首选。

### 3. 构建镜像与运行时分离

- **构建镜像**（`docker/build/*.Dockerfile`）：安装编译器、perl 等工具链。
- **不安装** curl/wget：构建容器不需要联网，源码由宿主机校验后以只读卷挂载；
  编译阶段以 `--network none` 运行，强制断网。
- **测试**直接使用各发行版官方基础镜像，验证的是“用户机器上的真实运行环境”。

### 4. 源码安全模型（fail-closed）

信任根：`keys/*.asc` + `lock/nginx.lock.json` 中的 `signer_fingerprint`。

校验顺序：

1. 导入固定公钥到临时 `GNUPGHOME`；
2. 下载 tarball 与签名；
3. GPG 验签，提取 `VALIDSIG` 指纹，必须与 lockfile 完全一致；
4. 若 lockfile 有该版本 SHA256，则必须完全一致；
5. 新 nginx 版本（未锁定）在验签通过后记录 SHA256 并写入 resolved lock。

任何一步失败都不会生成构建产物。镜像下载地址可回退（openssl.org → GitHub Releases），
但**校验值不会随下载源改变**。

已知限制：首次锁定新版本时依赖 GPG 建立信任（TOFU）；指纹由人工核对上游页面后提交。
公钥变更必须走代码评审。

### 5. 每日自动检查 + 幂等发布

- 定时任务解析 stable 版本；若 GitHub Release `nginx-<version>` 已存在则跳过。
- 成功发布后回写 lockfile（带 `[skip ci]`），使仓库状态与已发布产物一致。
- 手动 `force=true` 可重建并覆盖已有 Release 资产。

### 6. 关键编译参数

沿用参考脚本的发行版包路径，便于替换官方包：

```
--prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf
--pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock
--http-*-temp-path=/var/cache/nginx/*
--user=nginx --group=nginx
```

模块集合：http_ssl、http_v2、realip、stub_status、gzip_static、slice、auth_request、dav、
flv、mp4、gunzip、random_index、secure_link、sub、addition、mail(+ssl)、stream(+realip/ssl/ssl_preread)、
pcre-jit、file-aio、threads、compat。

安全与优化参数：

```
-O2 -fPIC -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2
-Wl,-z,relro -Wl,-z,now
```

CentOS 7 若回退到 gcc 4.8，会自动把 `-fstack-protector-strong` 降级为 `-fstack-protector`
（4.8 不支持前者）；正常路径使用 devtoolset-11。

## 冒烟测试覆盖

在目标发行版容器中（无网络、无额外工具）：

| 用例 | 方式 |
|------|------|
| 版本/模块 | `nginx -V` 检查 nginx 版本、OpenSSL 版本、stream/http_v2/ssl 模块 |
| 动态依赖 | `ldd` 确保无 libssl/libcrypto/libpcre2/libz |
| 配置校验 | `nginx -t`（含 SSL 证书加载、stream 配置） |
| HTTP | bash `/dev/tcp` 直接发请求，断言 200 + 内容 |
| HTTPS | nginx 作为 TLS 客户端回环代理到自身 TLS server，验证 OpenSSL 双向可用 |
| Stream | TCP 代理到 HTTP server 并断言内容 |
| 生命周期 | `nginx -s reload` 后再次请求；`nginx -s quit` 后进程退出 |

不依赖 curl/openssl 命令，避免老发行版的基础镜像缺少工具或软件源失效。

## 失败模式与排查

| 现象 | 原因 | 处理 |
|------|------|------|
| resolve 失败 | nginx.org 不可达/页面结构变化 | 手动输入 `nginx_version` |
| GPG 验签失败 | 上游换签名密钥、镜像篡改、网络劫持 | 人工核对上游公钥页面，更新 keys/ 与指纹 |
| SHA256 不匹配 | lockfile 与实际源码不一致 | 检查版本是否匹配；确认后重新锁定 |
| Docker Hub 拉取失败 | 匿名限流 | 自动回退 `mirror.gcr.io` |
| ubuntu:18.04 apt 失败 | 官方归档/网络异常 | Dockerfile 自动在 archive 与 old-releases 之间回退 |
| centos7 yum 失败 | vault.centos.org 不可达/403 | 默认使用 Rackspace centos-vault 镜像；可用 `CENTOS_VAULT_BASE` 切换清华/阿里/腾讯镜像 |
| lockfile 回写失败 | 分支保护 | Release 已成功；回写步骤允许失败并记录日志 |
| 22.04+ 产物跑在 18.04 | glibc 版本不满足 | 使用 `ubuntu18.04` 或 `centos7` 产物 |
| ARM 任务无法启动 | 套餐不含 GitHub ARM runner | 设置仓库变量 `ARM64_RUNNER` 指向自托管 ARM runner 标签 |
| x86 产物跑在 ARM | 架构不匹配 | 使用对应的 `aarch64` 产物 |

## 后续扩展

- **更多架构组合**：为 Rocky 9 / RHEL 9 增加 aarch64（`rockylinux:9` 支持多架构），
  CentOS 7 无官方 aarch64 镜像，可考虑 AlmaLinux 8 替代。
- **HTTP/3**：增加 `--with-http_v3_module`（OpenSSL 3.5 支持 QUIC），并补充 UDP 冒烟测试。
- **更多软件**：见 [adding-a-component.md](adding-a-component.md)。
- **依赖自动检查**：可增加定时任务检测 OpenSSL LTS / PCRE2 / zlib 新版本并开 Issue，仍由人工评审合并。
