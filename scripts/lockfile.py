#!/usr/bin/env python3
"""lock/nginx.lock.json 的读写辅助工具。

子命令：
  export <lock> [--nginx-version V]   导出下载清单（每行一个下载源，'|' 分隔）
  get <lock> <component> <field>      读取字段
  set <lock> --component C [--version V] [--sha256 S] --out PATH
                                      更新组件版本/哈希并写出新 lockfile
  summary <lock>                      输出人类可读摘要

设计意图：Shell 负责下载与 GPG 验签，Python 只负责结构化数据的稳定读写。
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path

COMPONENT_ORDER = ("openssh", "nginx", "openssl", "pcre2", "zlib")
FIELD_SEP = "|"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FPR_RE = re.compile(r"^[0-9A-Fa-f]{16}$|^[0-9A-Fa-f]{40}$")
# nginx 版本固定为 X.Y.Z；其他组件允许 X.Y / X.Y.Z / X.YpN
# （如 zlib 1.4、PCRE2 10.49、OpenSSH 10.6p2）
NGINX_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
COMPONENT_VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+)+(p[0-9]+)?$")


def validate_component_version(name: str, version: str) -> None:
    pattern = NGINX_VERSION_RE if name == "nginx" else COMPONENT_VERSION_RE
    if not pattern.match(version):
        sys.exit(f"[lockfile] 非法版本号: {name}={version!r}")


def load_lock(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        sys.exit(f"[lockfile] lockfile 不存在: {path}")
    except json.JSONDecodeError as exc:
        sys.exit(f"[lockfile] lockfile 不是合法 JSON: {path}: {exc}")
    if data.get("schema") != 1:
        sys.exit(f"[lockfile] 不支持的 schema: {data.get('schema')!r}")
    if "components" not in data:
        sys.exit("[lockfile] lockfile 缺少 components 字段")
    return data


def save_lock(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    tmp.replace(path)


def ordered_components(data: dict) -> list[tuple[str, dict]]:
    comps = data["components"]
    ordered = [(name, comps[name]) for name in COMPONENT_ORDER if name in comps]
    # 兼容未来新增组件：按文件中出现顺序追加未知组件
    ordered += [(name, comp) for name, comp in comps.items() if name not in COMPONENT_ORDER]
    return ordered


def validate_component(name: str, comp: dict) -> None:
    for field in ("version", "key_file", "signer_fingerprint", "downloads"):
        if field not in comp:
            sys.exit(f"[lockfile] 组件 {name} 缺少字段: {field}")
    if not FPR_RE.match(comp["signer_fingerprint"]):
        sys.exit(f"[lockfile] 组件 {name} 的 signer_fingerprint 非法: {comp['signer_fingerprint']!r}")
    sha = comp.get("sha256", "")
    if sha and not SHA256_RE.match(sha):
        sys.exit(f"[lockfile] 组件 {name} 的 sha256 非法: {sha!r}")
    if not comp["downloads"]:
        sys.exit(f"[lockfile] 组件 {name} 未配置下载源")
    for dl in comp["downloads"]:
        for field in ("url_template", "signature_url_template", "file_name_template"):
            if field not in dl:
                sys.exit(f"[lockfile] 组件 {name} 的下载源缺少字段: {field}")


def render(template: str, version: str) -> str:
    return template.replace("{version}", version)


def cmd_export(args: argparse.Namespace) -> int:
    data = load_lock(Path(args.lock))
    overrides: dict[str, str] = {}
    if args.nginx_version:
        validate_component_version("nginx", args.nginx_version)
        overrides["nginx"] = args.nginx_version
    for item in args.override:
        name, sep, version = item.partition("=")
        if not sep or not name or not version:
            sys.exit(f"[lockfile] --override 参数格式应为 NAME=VERSION: {item!r}")
        find_component(data, name)
        validate_component_version(name, version)
        overrides[name] = version

    for name, comp in ordered_components(data):
        validate_component(name, comp)
        version = comp["version"]
        sha = comp.get("sha256", "")
        if name in overrides and overrides[name] != version:
            # 新版本尚未锁定：签名验证通过后再计算哈希
            version = overrides[name]
            sha = ""
        for dl in comp["downloads"]:
            url = render(dl["url_template"], version)
            sig_url = render(dl["signature_url_template"], version)
            file_name = render(dl["file_name_template"], version)
            row = [
                name,
                version,
                sha,
                comp["signer_fingerprint"],
                comp["key_file"],
                url,
                sig_url,
                file_name,
            ]
            print(FIELD_SEP.join(row))
    return 0


def find_component(data: dict, name: str) -> dict:
    comps = data["components"]
    if name not in comps:
        sys.exit(f"[lockfile] 未知组件: {name}（可用: {', '.join(comps)}）")
    return comps[name]


def cmd_get(args: argparse.Namespace) -> int:
    data = load_lock(Path(args.lock))
    comp = find_component(data, args.component)
    if args.field not in comp:
        sys.exit(f"[lockfile] 组件 {args.component} 没有字段 {args.field}")
    value = comp[args.field]
    if isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(value)
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    data = load_lock(Path(args.lock))
    comp = find_component(data, args.component)
    if args.version is not None:
        validate_component_version(args.component, args.version)
        comp["version"] = args.version
    if args.sha256 is not None:
        if not SHA256_RE.match(args.sha256):
            sys.exit(f"[lockfile] 非法 sha256: {args.sha256!r}")
        comp["sha256"] = args.sha256
    data["updated_at"] = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    save_lock(data, Path(args.out))
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    data = load_lock(Path(args.lock))
    print(f"lockfile: {args.lock}")
    print(f"updated_at: {data.get('updated_at', 'unknown')}")
    for name, comp in ordered_components(data):
        print(f"- {name}: {comp['version']} sha256={comp.get('sha256', '<unpinned>')}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="trust-binary lockfile helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_export = sub.add_parser("export", help="导出下载清单")
    p_export.add_argument("lock")
    p_export.add_argument("--nginx-version", default="", help="覆盖 nginx 版本（兼容旧用法）")
    p_export.add_argument(
        "--override",
        action="append",
        default=[],
        metavar="NAME=VERSION",
        help="覆盖任意组件版本（新版本 sha256 留空），可重复",
    )
    p_export.set_defaults(func=cmd_export)

    p_get = sub.add_parser("get", help="读取字段")
    p_get.add_argument("lock")
    p_get.add_argument("component")
    p_get.add_argument("field")
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="更新组件版本/哈希")
    p_set.add_argument("lock")
    p_set.add_argument("--component", required=True)
    p_set.add_argument("--version")
    p_set.add_argument("--sha256")
    p_set.add_argument("--out", required=True)
    p_set.set_defaults(func=cmd_set)

    p_summary = sub.add_parser("summary", help="打印摘要")
    p_summary.add_argument("lock")
    p_summary.set_defaults(func=cmd_summary)

    return parser


def main(argv: list[str]) -> int:
    # 统一输出为 \n，避免 Windows 的 \r\n 污染 Shell 解析
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(newline="\n")
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
