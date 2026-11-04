#!/usr/bin/env python3
"""KPLBoard 仓库卫生检查。

本地和 CI 跑同一份逻辑，避免两边行为不一致：

    python3 scripts/check-repo.py            # 全部检查
    python3 scripts/check-repo.py --fix-hint # 只列出问题，不做任何修改

检查项：
  1. 构建产物 / 本机文件有没有被误提交
  2. 签名材料有没有被误提交
  3. 所有 .json / .plist / .entitlements 能否解析
  4. Xcode 工程的 pbxproj 引用的 Swift 文件是否都还在

退出码：0 全部通过，1 有问题。
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 构建产物 / 本机路径：出现即视为违规
ARTIFACT_PATTERNS = [
    r"(^|/)build/",
    r"\.xcarchive$",
    r"\.app/",
    r"\.dmg$",
    r"\.ipa$",
    r"\.hap$",
    r"DerivedData/",
    r"oh_modules/",
    r"\.hvigor/",
    r"xcuserdata/",
    r"\.DS_Store$",
    r"\.build-mc2/",
    r"\.tmpcheck/",
    r"local\.properties$",
]

# 签名材料：绝对不能入库
SIGNING_PATTERNS = [
    r"\.(p12|cer|p7b|csr)$",
    r"(^|/)signing/",
]

XCODE_PROJECTS = [
    ("iOS", "iOS/KPLBoard-iOS.xcodeproj/project.pbxproj"),
    ("MacOS", "MacOS/KPLBoard-MacOS.xcodeproj/project.pbxproj"),
]


def tracked_files() -> list[str]:
    """git 索引里的全部文件（相对仓库根目录）。"""
    out = subprocess.run(
        ["git", "ls-files"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def check_patterns(files: list[str], patterns: list[str], title: str, hint: str) -> list[str]:
    bad = [f for f in files if any(re.search(p, f) for p in patterns)]
    if bad:
        print(f"[FAIL] {title}：{len(bad)} 个文件不该入库")
        for f in bad[:20]:
            print(f"         {f}")
        if len(bad) > 20:
            print(f"         …… 还有 {len(bad) - 20} 个")
        print(f"         提示：{hint}")
    else:
        print(f"[OK]   {title}")
    return bad


def check_formats() -> list[str]:
    """校验 JSON / plist / entitlements 能否解析。"""
    problems: list[str] = []
    counts = {"json": 0, "plist": 0}
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, REPO_ROOT)
            if name.endswith(".json"):
                counts["json"] += 1
                try:
                    with open(path, encoding="utf-8") as fh:
                        import json

                        json.load(fh)
                except Exception as exc:  # noqa: BLE001 - 报出具体原因即可
                    problems.append(f"{rel}: {exc}")
            elif name.endswith((".plist", ".entitlements")):
                counts["plist"] += 1
                try:
                    with open(path, "rb") as fh:
                        plistlib.load(fh)
                except Exception as exc:  # noqa: BLE001
                    problems.append(f"{rel}: {exc}")
    if problems:
        print(f"[FAIL] 文件格式：{len(problems)} 个文件解析失败")
        for p in problems[:20]:
            print(f"         {p}")
    else:
        print(f"[OK]   文件格式：JSON {counts['json']} 个、plist {counts['plist']} 个均可解析")
    return problems


def check_xcode_references() -> list[str]:
    """pbxproj 引用的 Swift 文件必须在对应工程目录下存在。"""
    problems: list[str] = []
    for name, proj_rel in XCODE_PROJECTS:
        proj = os.path.join(REPO_ROOT, proj_rel)
        if not os.path.exists(proj):
            print(f"[FAIL] {name}：找不到工程文件 {proj_rel}")
            problems.append(proj_rel)
            continue
        with open(proj, encoding="utf-8") as fh:
            text = fh.read()
        # 只认以大写字母开头的文件名，跳过 sourcecode.swift 这类类型字面量
        referenced = {m for m in re.findall(r"([A-Z][A-Za-z0-9_]*\.swift)", text)}

        found: set[str] = set()
        root = os.path.join(REPO_ROOT, name)
        for _dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ("build", ".git")]
            found.update(filenames)

        missing = sorted(referenced - found)
        if missing:
            print(f"[FAIL] {name}：pbxproj 引用了 {len(missing)} 个不存在的文件")
            for m in missing[:10]:
                print(f"         {name}/{m}")
            problems += missing
        else:
            print(f"[OK]   {name}：pbxproj 引用的 {len(referenced)} 个 Swift 文件都在")
    return problems


def main() -> int:
    if not os.path.isdir(os.path.join(REPO_ROOT, ".git")):
        print(f"[FAIL] 这里不是 git 仓库：{REPO_ROOT}")
        return 1

    print(f"仓库：{REPO_ROOT}")
    files = tracked_files()
    print(f"受版本控制的文件：{len(files)} 个\n")

    problems: list[str] = []
    problems += check_patterns(
        files,
        ARTIFACT_PATTERNS,
        "构建产物 / 本机文件",
        "构建产物由 build 脚本重新生成，不要入库；见各平台的 .gitignore。",
    )
    problems += check_patterns(
        files,
        SIGNING_PATTERNS,
        "签名材料",
        "证书 / profile 只在本机保留，用 Xcode 或 DevEco 重新签名。",
    )
    problems += check_formats()
    problems += check_xcode_references()

    print()
    if problems:
        print(f"结果：{len(problems)} 项问题")
        return 1
    print("结果：全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
