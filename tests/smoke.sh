#!/usr/bin/env bash
# 仓库自检：所有技能的文档规范 + 脚本语法
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
echo "== 技能文档"
python3 tests/check_skill.py $(ls -d skills/*/ | sed 's:/$::') || fail=1
echo
echo "== 脚本语法"
for f in skills/*/scripts/*.sh; do
  [ -f "$f" ] || continue
  printf "%-52s" "$f"
  bash -n "$f" && echo "✓" || { echo "✗"; fail=1; }
done
echo
echo "== 内置样例"
for f in skills/*/scripts/*.sh; do
  grep -q -- "--self-test" "$f" 2>/dev/null || continue
  printf "%-52s" "$(basename "$f") --self-test"
  bash "$f" --self-test >/tmp/st.out 2>&1 && echo "✓" || { echo "✗"; tail -3 /tmp/st.out; fail=1; }
done
exit $fail
