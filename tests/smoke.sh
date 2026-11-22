#!/usr/bin/env bash
# 仓库自检：文档规范 + 注册表对齐 + 脚本语法 + 离线模拟测试 + 安装器行为 + 脱敏卫生
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
tmp_work="$(mktemp -d)" || { echo "✗ 无法创建临时目录" >&2; exit 1; }
[ -n "$tmp_work" ] && [ -d "$tmp_work" ] || { echo "✗ 临时目录不可用" >&2; exit 1; }
trap 'rm -rf "$tmp_work"' EXIT

echo "== 技能文档"
python3 tests/check_skill.py || fail=1

echo
echo "== 注册表对齐 (registry.json)"
python3 - <<'PY' || fail=1
import json, os, sys

reg = json.load(open("registry.json", encoding="utf-8"))
if "$schema" in reg and not os.path.exists(reg["$schema"]):
    print("✗ registry.json 的 $schema 指向不存在的文件:", reg["$schema"])
    sys.exit(1)

reg_names = {item["name"]: item for item in reg.get("skills", [])}
disk_names = sorted(
    d for d in os.listdir("skills")
    if not d.startswith(".") and os.path.isdir(os.path.join("skills", d))
)
missing_reg = sorted(set(disk_names) - set(reg_names))
extra_reg = sorted(set(reg_names) - set(disk_names))
if missing_reg or extra_reg:
    print("✗ registry.json 与 skills/ 目录不一致：", missing_reg, extra_reg)
    sys.exit(1)
for name, item in reg_names.items():
    entry = item.get("entry", "")
    if not os.path.isfile(entry):
        print(f"✗ {name} 的 entry 不存在：{entry}")
        sys.exit(1)
print(f"✓ registry.json 已对齐全部 {len(disk_names)} 个技能")
PY

echo
echo "== 脚本语法"
for f in install.sh tests/smoke.sh skills/*/scripts/*.sh; do
  [ -f "$f" ] || continue
  printf "%-52s" "$f"
  bash -n "$f" && echo "✓" || { echo "✗"; fail=1; }
done

python3 - <<'PY' || fail=1
import glob, re, sys
bad = []
for path in ["install.sh", "tests/smoke.sh"] + sorted(glob.glob("skills/*/scripts/*.sh")):
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]", line):
            bad.append(f"{path}:{i}: {m.group(0)}")
if bad:
    print("✗ 变量紧跟全角中文必须写成 ${var}，否则 set -u 报错：", bad)
    sys.exit(1)
print("✓ 无 $var 紧跟全角字符隐患")
PY

echo
echo "== 内置离线自检 (--self-test)"
for f in skills/*/scripts/*.sh; do
  [ -f "$f" ] || continue
  printf "%-52s" "$(basename "$f") --self-test"
  if ! grep -q -- "--self-test" "$f"; then
    echo "✗ 缺少 --self-test"
    fail=1
    continue
  fi
  st_out="$tmp_work/$(basename "$f").out"
  if bash "$f" --self-test >"$st_out" 2>&1; then
    echo "✓ ($(head -n 1 "$st_out"))"
  else
    echo "✗"
    tail -n 5 "$st_out"
    fail=1
  fi
done

echo
echo "== 安装脚本行为 (install.sh)"
list_out="$tmp_work/list.out"
if bash install.sh --list >"$list_out" 2>&1; then
  list_ok=1
  if grep -q '未登记' "$list_out"; then
    list_ok=0
  fi
  for sdir in skills/*/; do
    sname="$(basename "$sdir")"
    grep -q "^${sname}[[:space:]]" "$list_out" || list_ok=0
  done
  if [ "$list_ok" -eq 1 ]; then
    echo "✓ install.sh --list 覆盖全部技能且无未登记项"
  else
    echo "✗ install.sh --list 输出不完整"
    cat "$list_out"
    fail=1
  fi
else
  echo "✗ install.sh --list 执行失败"
  cat "$list_out"
  fail=1
fi

target_dir="$tmp_work/client/skills"
mkdir -p "$target_dir/server-audit"
touch "$target_dir/server-audit/old.txt"
if bash install.sh --target "$target_dir" --all >"$tmp_work/install.out" 2>&1; then
  bak_in_target=$(ls -1 "$target_dir" | grep -c '\.bak-' || true)
  if [ "$bak_in_target" -eq 0 ] && [ -L "$target_dir/server-audit" ] && [ -d "$tmp_work/client/.skills-backups" ]; then
    echo "✓ install.sh 软链安装与外部备份（不污染目标技能目录）通过"
  else
    echo "✗ install.sh 目标目录存在残留或备份异常"
    ls -la "$target_dir"
    fail=1
  fi
else
  echo "✗ install.sh --all 失败"
  cat "$tmp_work/install.out"
  fail=1
fi

# 从仓库外相对 --target 与相对 SKILLS_DIR 调用，验证按调用者 cwd 解析
caller_dir="$tmp_work/caller"
mkdir -p "$caller_dir"
repo_abs="$(pwd -P)"
if (cd "$caller_dir" && bash "$repo_abs/install.sh" --target ./rel-skills contract-redact >/dev/null 2>&1) && [ -L "$caller_dir/rel-skills/contract-redact" ]; then
  echo "✓ install.sh 仓库外相对 --target 解析通过"
else
  echo "✗ install.sh 仓库外相对 --target 解析失败"
  fail=1
fi
if (cd "$caller_dir" && SKILLS_DIR=./env-rel-skills bash "$repo_abs/install.sh" contract-redact >/dev/null 2>&1) && [ -L "$caller_dir/env-rel-skills/contract-redact" ]; then
  echo "✓ install.sh 仓库外相对 SKILLS_DIR 解析通过"
else
  echo "✗ install.sh 仓库外相对 SKILLS_DIR 解析失败"
  fail=1
fi

copy_dir="$tmp_work/copy/skills"
if bash install.sh --target "$copy_dir" --copy contract-redact >/dev/null 2>&1 && [ -d "$copy_dir/contract-redact" ] && [ ! -L "$copy_dir/contract-redact" ]; then
  echo "✓ install.sh --copy 模式通过"
else
  echo "✗ install.sh --copy 模式失败"
  fail=1
fi

echo
echo "== 公开仓库脱敏卫生扫描"
python3 - <<'PY' || fail=1
import ipaddress, os, re, sys

skip_dirs = {".git", ".kelin", "__pycache__"}
patterns = [
    (re.compile(r"/Users/[A-Za-z0-9._-]+"), "macOS 本机路径"),
    (re.compile(r"/home/[A-Za-z0-9._-]+"), "Linux 本机路径"),
    (re.compile(r"C:\\Users\\[A-Za-z0-9._-]+"), "Windows 本机路径"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "API 密钥"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "GitHub Token"),
    (re.compile(r"tskey-(?:api|auth)-[A-Za-z0-9]{10,}"), "真实 Tailscale Key"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "私钥头"),
]

# 允许的文档/测试占位网段（RFC 5737 / RFC 6598 / loopback / 0.0.0.0 / 文档示例 10.0.0.x）
allowed_nets = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("0.0.0.0/32"),
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("10.0.0.0/24"),
]
ip_pat = re.compile(r"(?<![.\d])(\d{1,3}(?:\.\d{1,3}){3})(?![.\d])")

hits = []
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fn in files:
        p = os.path.join(root, fn)
        if os.path.normpath(p) in (os.path.normpath("tests/check_skill.py"), os.path.normpath("tests/smoke.sh")):
            continue
        try:
            lines = open(p, encoding="utf-8", errors="ignore").read().splitlines()
        except OSError:
            continue
        for lineno, line in enumerate(lines, 1):
            for pat, label in patterns:
                if pat.search(line):
                    hits.append((p, lineno, label))
            for m in ip_pat.finditer(line):
                try:
                    addr = ipaddress.ip_address(m.group(1))
                except ValueError:
                    continue
                if not any(addr in net for net in allowed_nets):
                    hits.append((p, lineno, "非文档允许段 IPv4"))

if hits:
    for p, lineno, label in hits:
        print(f"✗ {p}:{lineno}: 疑似{label}")
    sys.exit(1)
print("✓ 公开仓库未检出本机路径、密钥、Token 或非占位 IP")
PY

exit "$fail"
