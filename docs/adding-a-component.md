# 新增软件组件指南

以新增 `curl` 为例，说明如何复用本仓库的可信构建流程。

## 1. 固定上游公钥与版本

1. 找到上游官方发布签名方式（`.asc` / `.sig` / 校验和文件）。
2. 从官方渠道获取公钥，核对指纹后保存为 `keys/<component>-<signer>.asc`。
3. 在 `keys/README.md` 补充来源与指纹。
4. 新建 `lock/<component>.lock.json`，结构参考 `lock/nginx.lock.json`：

```json
{
  "schema": 1,
  "updated_at": "2026-11-19T00:00:00Z",
  "components": {
    "curl": {
      "version": "8.x.y",
      "sha256": "<64 hex>",
      "key_file": "keys/curl-<signer>.asc",
      "signer_fingerprint": "<40 hex 或 16 hex>",
      "downloads": [
        {
          "url_template": "https://curl.se/download/curl-{version}.tar.gz",
          "signature_url_template": "https://curl.se/download/curl-{version}.tar.gz.asc",
          "file_name_template": "curl-{version}.tar.gz"
        }
      ]
    }
  }
}
```

> `scripts/prepare-sources.sh` 当前把 lockfile 中的每个组件都视为必需项。若一个 lockfile 含多个组件，
> 它们都会被下载校验；请按组件拆分 lockfile（如 `lock/curl.lock.json`）。

## 2. 构建脚本

新建 `components/curl/`：

- `build.sh`：容器内编译、打包，约定：
  - 输入 `/sources`（只读，已验签源码）、`/build`、`/out`
  - 环境变量：版本号 + `DISTRO`
  - 产出：裸二进制、`.tar.gz`、`*.build-info.json`、`SHA256SUMS`
- `smoke-test.sh`：在目标发行版容器内验证功能（不依赖 curl 等工具时可用 bash `/dev/tcp`）
- `configure-args.sh`（可选）：抽离编译参数

Dockerfile 可将脚本 COPY 到 `/opt/trust-binary/`，并复用现有 `docker/build/*.Dockerfile` 的基础镜像约定。

## 3. Workflow

复制 `.github/workflows/nginx-build.yml` 为 `<component>-build.yml`，修改：

- `env`/组件名、lockfile 路径
- 版本解析逻辑（或使用固定版本 + 手动输入）
- 构建/测试矩阵（按组件的实际支持范围；每个条目包含 `distro` / `arch` / `runner` / `base_image`，
  ARM64 条目使用 `ubuntu-24.04-arm` 或仓库变量 `ARM64_RUNNER` 指定的自托管 runner）
- Release tag 前缀：`<component>-<version>`，避免与 nginx 冲突
- lockfile 回写路径

若多个组件共享同一套脚本，可把公共步骤抽成 composite action 或 reusable workflow。

## 4. 文档

更新：

- `README.md` 的产物矩阵与版本策略表
- `docs/architecture.md` 的组件说明
- Release 说明生成脚本如不通用，新增 `scripts/render-<component>-release-notes.sh`

## 5. 验收清单

- [ ] GPG 验签失败时构建确实失败（可临时改错指纹验证）
- [ ] SHA256 不匹配时构建确实失败
- [ ] 每个目标发行版、每个架构均能启动并完成功能冒烟测试
- [ ] 产物文件名中的架构与容器内 `uname -m` 一致
- [ ] `ldd` 不包含非预期动态依赖
- [ ] Release 资产含二进制、tar 包、build-info、SHA256SUMS
- [ ] 首次锁定新版本后，lockfile 回写逻辑生效
