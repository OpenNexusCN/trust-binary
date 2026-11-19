# 构建镜像使用的发行版公钥

| 文件 | 用途 | 指纹 | 来源 |
|------|------|------|------|
| `RPM-GPG-KEY-CentOS-SIG-SCLo` | 校验 CentOS 7 SCLo 仓库（devtoolset-11） | `C4DBD535B1FBBA14F8BA64A84EB84E71F2EE9D55` | https://www.centos.org/keys/RPM-GPG-KEY-CentOS-SIG-SCLo |

说明：CentOS 7 的 SCLo 软件包由 **CentOS SoftwareCollections SIG** 密钥签名，
与 CentOS 7 主发行版密钥不同。缺少该公钥时 `yum install devtoolset-11-gcc` 会因 GPG 校验失败，
并可能被静默回退到系统 gcc 4.8。
