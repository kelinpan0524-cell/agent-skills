#!/usr/bin/env bash
# install.sh：把仓库里的技能软链到助手的技能目录，改仓库即改本机。
set -uo pipefail
cd "$(dirname "$0")"

TARGET="${SKILLS_DIR:-$HOME/.hermes/skills}"
MODE="link"   # link | copy
LIST=()

usage() {
  cat <<'USAGE'
用法：
  ./install.sh --list                    列出仓库里的技能
  ./install.sh contract-redact           只装这一个（软链）
  ./install.sh --all                     全装
  ./install.sh --copy --all              复制而不是软链（不支持热改）
  ./install.sh --target ~/.claude/skills --all
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=("__list__"); shift ;;
    --all) LIST=("__all__"); shift ;;
    --copy) MODE="copy"; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数：$1" >&2; usage; exit 2 ;;
    *) LIST+=("$1"); shift ;;
  esac
done

available() { ls -1 skills | grep -v '^\.'; }

if [ "${LIST[0]:-}" = "__list__" ]; then
  printf "%-20s %s\n" "技能" "说明"
  available | while read -r s; do
    desc=$(python3 - "$s" <<'PY'
import json, sys
r = json.load(open("registry.json", encoding="utf-8"))
for item in r["skills"]:
    if item["name"] == sys.argv[1]:
        print(item["description"]); break
else:
    print("-")
PY
)
    printf "%-20s %s\n" "$s" "$desc"
  done
  exit 0
fi

[ ${#LIST[@]} -eq 0 ] && { usage; exit 2; }
[ "${LIST[0]}" = "__all__" ] && LIST=($(available))

mkdir -p "$TARGET"
for s in "${LIST[@]}"; do
  [ -f "skills/$s/SKILL.md" ] || { echo "✗ 仓库里没有 $s" >&2; continue; }
  dest="$TARGET/$s"
  if [ -L "$dest" ]; then rm -f "$dest"; elif [ -e "$dest" ]; then
    backup="$dest.bak-$(date +%Y%m%d-%H%M%S)"; mv "$dest" "$backup"; echo "  原目录已备份为 $(basename "$backup")"
  fi
  if [ "$MODE" = "copy" ]; then cp -R "skills/$s" "$dest"; echo "✓ $s → ${dest}（复制）"
  else ln -s "$PWD/skills/$s" "$dest"; echo "✓ $s → ${dest}（软链）"; fi
done

echo
echo "校验："
python3 tests/check_skill.py $(for s in "${LIST[@]}"; do echo "skills/$s"; done) 2>/dev/null | tail -2
