#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""技能自检：frontmatter、篇幅、相对链接、跨目录路径与路径卫生。

用法：
  python3 tests/check_skill.py [技能目录 ...]
默认检查 skills/ 下所有技能目录。
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILLS_ROOT = os.path.join(ROOT, "skills")

MAX_SKILL_LINES = 200
MAX_DESCRIPTION = 200
REQUIRED_KEYS = ("name", "description", "version", "author", "license", "platforms")


def default_targets() -> list[str]:
    if not os.path.isdir(SKILLS_ROOT):
        return []
    return [
        os.path.join(SKILLS_ROOT, d)
        for d in sorted(os.listdir(SKILLS_ROOT))
        if not d.startswith(".") and os.path.isdir(os.path.join(SKILLS_ROOT, d))
    ]


def parse_frontmatter(text: str):
    if not text.startswith("---"):
        raise ValueError("文件必须以 --- 开头（第 0 字节）")
    match = re.search(r"\n---\s*\n", text[3:])
    if not match:
        raise ValueError("frontmatter 没有闭合的 ---")
    block = text[3:match.start() + 3]
    data = {}
    for raw in block.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        if line.startswith("  ") or line.startswith("- "):
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if not key:
            continue
        if value.startswith("[") and value.endswith("]"):
            data[key] = [v.strip() for v in value[1:-1].split(",") if v.strip()]
        else:
            data[key] = value.strip('"').strip("'")
    return data, text[match.start() + 3:]


def check_skill(skill_dir: str) -> list[str]:
    problems: list[str] = []
    path = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(path):
        return ["缺少 SKILL.md：%s" % path]

    text = open(path, encoding="utf-8").read()
    try:
        fm, body = parse_frontmatter(text)
    except ValueError as exc:
        return ["frontmatter 有问题：%s" % exc]

    for key in REQUIRED_KEYS:
        if key not in fm:
            problems.append("frontmatter 缺字段：%s" % key)

    name = fm.get("name", "")
    if name != os.path.basename(os.path.normpath(skill_dir)):
        problems.append("name（%s）与目录名不一致" % name)

    desc = fm.get("description", "")
    if not desc:
        problems.append("description 不能为空")
    elif len(desc) > MAX_DESCRIPTION:
        problems.append("description 超过 %d 字（现在 %d）" % (MAX_DESCRIPTION, len(desc)))
    if desc and not desc.endswith("。"):
        problems.append("description 建议以句号结尾")

    lines = text.splitlines()
    if len(lines) > MAX_SKILL_LINES:
        problems.append("SKILL.md 有 %d 行，超过 %d 行（该拆到 references/）" % (len(lines), MAX_SKILL_LINES))

    # 相对链接必须在（覆盖 .md、样例 json 等）
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", body):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        if not os.path.exists(os.path.join(skill_dir, target)):
            problems.append("链接指向的文件不存在：%s" % target)

    # 代码块内不允许裸写 scripts/ 或 ./scripts/（跨目录调用会找不到脚本，须写 "$SKILL_DIR/scripts/..."）
    md_files = [("SKILL.md", body)]
    ref_dir = os.path.join(skill_dir, "references")
    if os.path.isdir(ref_dir):
        for fn in sorted(os.listdir(ref_dir)):
            if fn.endswith(".md"):
                md_files.append((f"references/{fn}", open(os.path.join(ref_dir, fn), encoding="utf-8").read()))

    for rel_name, md_text in md_files:
        in_fence = False
        for idx, line in enumerate(md_text.splitlines(), 1):
            if line.strip().startswith("```"):
                in_fence = not in_fence
                continue
            if not in_fence:
                continue
            for m in re.finditer(r"[^\s\"'`()=;]*scripts/[A-Za-z0-9._-]+", line):
                tok = m.group(0)
                if not tok.startswith(("$SKILL_DIR/scripts/", "${SKILL_DIR}/scripts/")):
                    problems.append(
                        "%s:%d 代码块含相对 scripts/ 路径 (%s)，请改写为 \"$SKILL_DIR/scripts/...\"" % (rel_name, idx, tok)
                    )

    # 必须有 references/ 且非空（渐进式披露）
    if not os.path.isdir(ref_dir) or not any(f.endswith(".md") for f in os.listdir(ref_dir)):
        problems.append("缺少 references/ 目录或其中没有 .md（渐进式披露要求）")

    # 路径卫生：不许本机绝对路径
    for bad in ("/Users/", "/home/", "C:\\Users"):
        if bad in text:
            problems.append("出现本机绝对路径：%s" % bad)

    return problems


def main(argv):
    targets = argv[1:] or default_targets()
    failed = 0
    for target in targets:
        problems = check_skill(os.path.abspath(target))
        label = os.path.basename(os.path.normpath(target))
        if problems:
            failed += 1
            print("✗ %s" % label)
            for problem in problems:
                print("   - %s" % problem)
        else:
            print("✓ %s：frontmatter 完整、篇幅达标、链接与跨目录写法合规" % label)
    print("\n结果：%s" % ("全部通过" if not failed else "%d 个技能不合格" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
