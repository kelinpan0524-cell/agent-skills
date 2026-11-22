#!/usr/bin/env bash
# install.sh：把仓库里的技能软链（或复制）到助手的技能目录，改仓库即改本机。
set -uo pipefail

CALLER_PWD="$(pwd -P)"
REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$REPO_DIR" || exit 1

TARGETS=()
MODE="link"   # link | copy
LIST=()
ALL_TARGETS=0

usage() {
  cat <<'USAGE'
用法：
  ./install.sh --list                            列出仓库里的技能
  ./install.sh contract-redact                   只装这一个（软链到默认目录）
  ./install.sh --all                             全装到默认目录（~/.hermes/skills）
  ./install.sh --target ~/.agents/skills --all   装到通用目录（Codex/Claude/Kimi/Cursor）
  ./install.sh --all-targets --all               装到本机已存在的常见助手技能目录
  ./install.sh --copy --all                      复制而不是软链（不支持热改）
USAGE
}

expand_target() {
  local raw="$1"
  case "$raw" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${raw#"~/"}" ;;
    /*) printf '%s\n' "$raw" ;;
    *) printf '%s/%s\n' "$CALLER_PWD" "$raw" ;;
  esac
}

add_targets() {
  local raw="$1"
  local item
  IFS=',' read -ra parts <<< "$raw"
  for item in "${parts[@]}"; do
    [ -n "$item" ] && TARGETS+=("$(expand_target "$item")")
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=("__list__"); shift ;;
    --all) LIST=("__all__"); shift ;;
    --copy) MODE="copy"; shift ;;
    --target)
      [ $# -ge 2 ] || { echo "✗ --target 缺少目录参数" >&2; exit 2; }
      add_targets "$2"; shift 2 ;;
    --all-targets) ALL_TARGETS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数：$1" >&2; usage; exit 2 ;;
    *) LIST+=("$1"); shift ;;
  esac
done

available() {
  local d
  for d in "$REPO_DIR"/skills/*/; do
    [ -f "${d}SKILL.md" ] && basename "$d"
  done
}

if [ "${LIST[0]:-}" = "__list__" ]; then
  python3 - "$REPO_DIR" <<'PY' || exit 1
import json, os, sys
repo = sys.argv[1]
reg_path = os.path.join(repo, "registry.json")
desc_map = {}
if os.path.isfile(reg_path):
    data = json.load(open(reg_path, encoding="utf-8"))
    for item in data.get("skills", []):
        desc_map[item["name"]] = item.get("description", "-")
skills_root = os.path.join(repo, "skills")
names = sorted(
    d for d in os.listdir(skills_root)
    if not d.startswith(".") and os.path.isfile(os.path.join(skills_root, d, "SKILL.md"))
)
print(f"{'技能':<20} {'说明'}")
for n in names:
    tag = "" if n in desc_map else " [未登记到 registry.json]"
    print(f"{n:<20} {desc_map.get(n, '-')}{tag}")
PY
  exit 0
fi

[ ${#LIST[@]} -eq 0 ] && { usage; exit 2; }
if [ "${LIST[0]}" = "__all__" ]; then
  LIST=()
  while IFS= read -r s; do
    [ -n "$s" ] && LIST+=("$s")
  done < <(available)
fi

if [ "$ALL_TARGETS" = "1" ]; then
  for base in "$HOME/.hermes" "$HOME/.agents" "$HOME/.claude" "$HOME/.codex"; do
    if [ -d "$base" ]; then
      TARGETS+=("$base/skills")
    fi
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("$(expand_target "${SKILLS_DIR:-$HOME/.hermes/skills}")")
fi

ts="$(date +%Y%m%d-%H%M%S)"
installed=()
failed=0

for target in "${TARGETS[@]}"; do
  if ! mkdir -p "$target"; then
    echo "✗ 无法创建目标目录：$target" >&2
    failed=1
    continue
  fi
  target_abs="$(cd "$target" 2>/dev/null && pwd -P)" || target_abs=""
  if [ -z "$target_abs" ]; then
    echo "✗ 无法进入目标目录：$target" >&2
    failed=1
    continue
  fi
  backup_root="$(dirname "$target_abs")/.skills-backups/$ts"

  for s in "${LIST[@]}"; do
    src="$REPO_DIR/skills/$s"
    if [ ! -f "$src/SKILL.md" ]; then
      echo "✗ 仓库里没有 $s" >&2
      failed=1
      continue
    fi
    dest="$target_abs/$s"
    if [ -L "$dest" ]; then
      rm -f "$dest" || { echo "✗ 无法移除旧软链：$dest" >&2; failed=1; continue; }
    elif [ -e "$dest" ]; then
      # 备份放到目标技能目录之外，避免助手把 .bak-* 当成损坏技能加载
      if ! mkdir -p "$backup_root" || ! mv "$dest" "$backup_root/$s"; then
        echo "✗ 无法备份原目录：$dest" >&2
        failed=1
        continue
      fi
      echo "  原目录已备份到 $backup_root/$s"
    fi
    if [ "$MODE" = "copy" ]; then
      if cp -R "$src" "$dest"; then
        echo "✓ ${s} → ${dest}（复制）"
        installed+=("$s")
      else
        echo "✗ 复制失败：${s} → ${dest}" >&2
        failed=1
      fi
    else
      if ln -sfn "$src" "$dest"; then
        echo "✓ ${s} → ${dest}（软链）"
        installed+=("$s")
      else
        echo "✗ 软链失败：${s} → ${dest}" >&2
        failed=1
      fi
    fi
  done
done

if [ -f "$REPO_DIR/tests/check_skill.py" ] && [ ${#installed[@]} -gt 0 ]; then
  echo
  echo "校验："
  check_dirs=()
  seen=" "
  for s in "${installed[@]}"; do
    case "$seen" in
      *" $s "*) continue ;;
    esac
    seen="$seen$s "
    check_dirs+=("$REPO_DIR/skills/$s")
  done
  python3 "$REPO_DIR/tests/check_skill.py" "${check_dirs[@]}" || exit 1
fi

[ "$failed" -eq 0 ] || exit 1
