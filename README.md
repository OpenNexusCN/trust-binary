# trust-binary

面向生产升级场景的**可信 Linux 二进制构建仓库**：紧跟上游稳定版，源码强制 GPG 验签 + SHA256 锁定，
在 GitHub Actions 中按发行版原生构建，并在目标发行版容器内完成冒烟测试后自动发布 Release。

当前组件：**nginx**（静态链接 OpenSSL / PCRE2 / zlib，仅依赖系统 glibc）。
后续可扩展其他软件，见 [docs/adding-a-component.md](docs/adding-a-component.md)。

## 产物矩阵（nginx）

| 产物标签 | 架构 | 构建基线 | 适用系统 |
|----------|------|----------|----------|
| `ubuntu18.04` | x86_64 / aarch64 | glibc 2.27 / gcc 7.5 | Ubuntu 18.04+（同架构） |
| `ubuntu20.04` | x86_64 / aarch64 | glibc 2.31 | Ubuntu 20.04+ |
| `ubuntu22.04` | x86_64 / aarch64 | glibc 2.35 | Ubuntu 22.04+ |
| `ubuntu24.04` | x86_64 / aarch64 | glibc 2.39 | Ubuntu 24.04+ |
| `centos7` | x86_64 | glibc 2.17 / devtoolset-11 | CentOS / RHEL 7+，也可运行于 Ubuntu 18.04+ |
| `rocky9` | x86_64 | glibc 2.34 | RHEL / CentOS / Rocky / Alma 9 家族 |

约定：**优先使用与目标系统一致或更老的发行版产物**，并严格匹配 CPU 架构。
例如 Ubuntu 20.04 x86_64 使用 `ubuntu18.04` 或 `ubuntu20.04` 产物均可；RHEL 9 使用 `rocky9` 产物；
ARM64 服务器使用对应的 `aarch64` 产物。

ARM64（Ubuntu 18.04–24.04）在 GitHub 原生 ARM runner（`ubuntu-24.04-arm`）上构建；
若仓库套餐不支持，可设置仓库变量 `ARM64_RUNNER` 指向自托管 ARM runner 的标签。

## 工作流

`.github/workflows/nginx-build.yml` 每天 03:00 UTC（北京时间 11:00）自动执行：

1. **解析版本**：从 nginx.org 读取最新 stable 版本；也可手动指定 `nginx_version`。
2. **校验源码**：下载 nginx / OpenSSL / PCRE2 / zlib，逐个 GPG 验签（签名者指纹固定）并核对 SHA256。
3. **矩阵构建**：10 个任务分别原生编译（6 个 x86_64 发行版 + 4 个 aarch64 Ubuntu）。
4. **冒烟测试**：在对应发行版、对应架构的容器中启动 nginx，验证 HTTP、HTTPS（由 nginx 自身作为 TLS 客户端回环）、
   stream TCP 转发、reload / quit，并检查动态依赖只有 glibc 家族。
5. **发布 Release**：上传二进制、tar 包、构建信息、SHA256SUMS 和源码哈希；自动回写 lockfile。
6. **可选来源证明**：仓库变量 `ENABLE_ATTESTATION=true` 时生成 Sigstore 构建来源证明。

若该版本已发布则自动跳过；手动触发时可用 `force=true` 强制重建。

## 首次使用（GitHub 仓库设置）

1. 推送本仓库到 GitHub，确认默认分支为 `main`。
2. **Settings → Actions → General → Workflow permissions**：选择 *Read and write permissions*
   （Release 创建与 lockfile 回写需要 `contents: write`）。
3. ARM64：GitHub 原生 `ubuntu-24.04-arm` runner 对 public 仓库免费、private 仓库按套餐提供；
   若不可用，设置仓库变量 `ARM64_RUNNER` 为自托管 ARM runner 的标签。
4. 可选：设置仓库变量 `ENABLE_ATTESTATION=true` 开启 Sigstore 构建来源证明。
5. Actions → `nginx-build` → Run workflow 验证首次构建。

## 手动触发

网页：Actions → `nginx-build` → Run workflow，填写版本（留空 = 自动最新稳定版）。

命令行：

```bash
# 自动解析最新稳定版
gh workflow run nginx-build.yml

# 指定版本
gh workflow run nginx-build.yml -f nginx_version=1.30.7

# 强制重建已发布版本
gh workflow run nginx-build.yml -f nginx_version=1.30.7 -f force=true
```

版本解析失败时（例如 nginx.org 不可达）工作流会明确报错，此时手动填写 `nginx_version` 即可。

## 产物与安装

每个发行版/架构的 Release 资产包含（`<arch>` 为 `x86_64` 或 `aarch64`）：

- `nginx-<version>-<distro>-<arch>`：裸二进制，可直接替换 `/usr/sbin/nginx`
- `nginx-<version>-<distro>-<arch>.tar.gz`：二进制 + 默认配置 + 构建信息 + 源码哈希 + 安装说明
- `nginx-<version>-<distro>-<arch>.build-info.json`：编译器、libc、依赖版本、configure 参数
- `SHA256SUMS`：全部发布资产的校验和

```bash
tar xzf nginx-1.30.7-ubuntu22.04-<arch>.tar.gz
cd nginx-1.30.7-ubuntu22.04-<arch>

sudo useradd -r -s /usr/sbin/nologin nginx 2>/dev/null || true
sudo install -d /etc/nginx /var/cache/nginx /var/log/nginx
sudo install -m 0755 bin/nginx /usr/sbin/nginx
sudo cp -a conf/. /etc/nginx/
sudo nginx -t
sudo nginx
```

升级时覆盖 `/usr/sbin/nginx` 后执行 `nginx -t && nginx -s reload`。

## 版本策略

| 组件 | 策略 | 当前锁定 |
|------|------|----------|
| nginx | 每次构建自动解析最新 **stable**（偶数次版本号）；可手动覆盖 | 1.30.7 |
| OpenSSL | 锁定 LTS 系列，人工升级（安全更新优先） | 3.5.9 LTS |
| PCRE2 | 锁定，人工升级 | 10.49 |
| zlib | 锁定，人工升级 | 1.4 |

所有版本与 SHA256 记录在 [lock/nginx.lock.json](lock/nginx.lock.json)。依赖升级属于安全决策，采用人工评审：

1. 在 lockfile 中更新组件 `version`，并清空该组件的 `sha256`；
2. 运行 `make prepare`，脚本会下载、GPG 验签，并把新哈希写入 `work/nginx.lock.resolved.json`；
3. 用该文件覆盖 `lock/nginx.lock.json`，提交并发起构建。

> 不自动追新依赖，避免上游未经测试的变更直接进入生产二进制；nginx 本体则保持自动追新。

## 可信校验链

```
上游官方签名
   │  GPG（公钥与指纹固定于 keys/ 与 lockfile）
   ▼
源码 tarball ── SHA256 锁定（lockfile）
   │
   ▼
GitHub Actions 构建（构建日志公开可审计）
   │
   ├─ SHA256SUMS（Release 资产）
   └─ 可选 Sigstore 来源证明（ENABLE_ATTESTATION=true）
```

- 公钥来源与指纹见 [keys/README.md](keys/README.md)。
- 签名者指纹不匹配、SHA256 不匹配、GPG 验签失败都会**直接失败**，不会产出二进制。
- CI 中的 `tests/verify-sources-test.sh` 会用临时密钥端到端验证上述成功/失败路径，防止校验逻辑回归。
- 详细设计见 [docs/architecture.md](docs/architecture.md)。

## 目录结构

```
.
├── .github/workflows/       # CI：nginx-build（构建/测试/发布）、lint
├── components/nginx/        # 组件构建脚本、configure 参数、冒烟测试
├── docker/build/            # 各发行版构建环境 Dockerfile
├── keys/                    # 上游签名公钥（固定指纹）
├── lock/nginx.lock.json     # 版本 + SHA256 + 签名者指纹
├── scripts/                 # 版本解析、源码校验、lockfile 工具、本地构建
└── docs/                    # 架构说明、新增组件指南
```

## 本地构建（可选）

要求 Linux + Docker：

```bash
make prepare                      # 下载并校验源码到 work/
bash scripts/build-local.sh       # 构建本机架构对应的全部发行版
bash scripts/build-local.sh 1.30.6  # 指定版本
```

本地脚本遵循本机架构：x86_64 主机构建全部 6 个发行版；aarch64 主机只构建 4 个 Ubuntu。
本机没有 Docker 时，推荐直接使用 GitHub Actions（本项目即按此设计）。

## 当前限制

- ARM64 仅覆盖 Ubuntu 18.04–24.04；CentOS 7 / Rocky 9 暂仅提供 x86_64。
- ARM64 构建依赖 GitHub 原生 ARM runner 或自托管 ARM runner（见 `ARM64_RUNNER` 变量）。
- 未启用 HTTP/3（`--with-http_v3_module`）。OpenSSL 3.5 已提供 QUIC 能力，可作为后续增强项。
- 未捆绑第三方动态模块；`--with-compat` 已开启，但第三方模块需与相同 configure 参数自行编译。
- 仅支持 glibc 系统，不提供 musl 全静态产物。

## 新增软件

参见 [docs/adding-a-component.md](docs/adding-a-component.md)。
