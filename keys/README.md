# 上游签名公钥

本目录保存构建流水线信任根所需的官方公钥。**这些文件的内容与指纹一旦变更，必须经过人工审查**。

| 组件 | 公钥文件 | 指纹（主密钥） | 用途 | 来源 |
|------|----------|----------------|------|------|
| nginx | `nginx-pluknet.asc` | `D6786CE303D9A9022998DC6CC8464D549AF75C0A` | 校验 `nginx-*.tar.gz.asc` | https://nginx.org/en/pgp_keys.html |
| OpenSSL | `openssl-release.asc` | `B146647E45A7B33947AB226B2A2C87D161692D40` | 校验 `openssl-*.tar.gz.asc` | keys.openpgp.org（UID: `OpenSSL <openssl@openssl.org>`） |
| PCRE2 | `pcre2-nicholas-wilson.asc` | `A95536204A3BB489715231282A98E77EB6F24CA8` | 校验 `pcre2-*.tar.gz.sig` | keys.openpgp.org（UID: `Nicholas Wilson <nicholas@nicholaswilson.me.uk>`） |
| zlib | `zlib-mark-adler.asc` | `5ED46A6721D365587791E2AA783FCD8E58BCAFBA` | 校验 `zlib-*.tar.gz.asc` | keys.openpgp.org（UID: `Mark Adler <madler@alumni.caltech.edu>`） |
| OpenSSH | `openssh-damien-miller.asc` | `7168B983815A5EEF59A4ADFD2A3F414E736060BA` | 校验 `openssh-*.tar.gz.asc` | keyserver.ubuntu.com（UID: `Damien Miller <djm@mindrot.org>`；OpenSSH 8.7 起启用的发布签名密钥） |

说明：

- 本流水线采用 **指纹固定（TOFU + 人工审核）** 模式：公钥文件随仓库提交，构建时导入临时 GNUPGHOME，
  并由 `lock/nginx.lock.json` 中 `signer_fingerprint` 字段强制校验实际签名者。
- OpenSSL 与 PCRE2 的实际签名者是其签名子密钥；`lock/nginx.lock.json` 记录的是**实际签名密钥**的指纹：
  - OpenSSL 签名子密钥：`C46ED3F2CBEFDA1FDAADA44264ED7B1DCCE71CB2`
  - PCRE2 签名子密钥：`BACF71F10404D5761C09D392021DE40BFB63B406`
- 若上游更换签名密钥，构建会**失败并明确报错**（fail-closed）。此时需人工核对新密钥来源，更新本目录与 lockfile。
- 本地复核命令：

```bash
export GNUPGHOME="$(mktemp -d)"
gpg --import keys/*.asc
gpg --verify nginx-1.30.7.tar.gz.asc nginx-1.30.7.tar.gz
gpg --verify openssl-3.5.9.tar.gz.asc openssl-3.5.9.tar.gz
gpg --verify pcre2-10.49.tar.gz.sig pcre2-10.49.tar.gz
gpg --verify zlib-1.4.tar.gz.asc zlib-1.4.tar.gz
```
