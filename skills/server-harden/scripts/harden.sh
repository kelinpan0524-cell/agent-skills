#!/usr/bin/env bash
# harden.sh：按项执行加固；SSH 改动先核查可用公钥、加锁防重入，再挂 5 分钟自动回滚定时器。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT_NAME="$(basename "$0")"
HOST=""
KEY=""
PORT=""
ACTION=""
YES=0
SELF_TEST=0

usage() {
  cat <<'USAGE'
用法：
  harden.sh --host root@192.0.2.10 [--key ~/.ssh/id] [--port 22] --check
  harden.sh --host root@192.0.2.10 [--key ~/.ssh/id] --apply fail2ban|autoupdate|sshd-guard [--yes]
  harden.sh --host root@192.0.2.10 [--key ~/.ssh/id] --cancel-rollback
  harden.sh --self-test
说明：sshd-guard 会先检查目标机已有 SSH 公钥，再挂 5 分钟自动还原，成功登录后用 --cancel-rollback 取消。
USAGE
}

expand_tilde() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#"~/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || { echo "✗ --host 缺少参数" >&2; exit 2; }; HOST="$2"; shift 2 ;;
    --key) [ $# -ge 2 ] || { echo "✗ --key 缺少参数" >&2; exit 2; }; KEY="$2"; shift 2 ;;
    --port) [ $# -ge 2 ] || { echo "✗ --port 缺少参数" >&2; exit 2; }; PORT="$2"; shift 2 ;;
    --apply) [ $# -ge 2 ] || { echo "✗ --apply 缺少动作名" >&2; exit 2; }; ACTION="$2"; shift 2 ;;
    --check) ACTION="check"; shift ;;
    --cancel-rollback) ACTION="cancel"; shift ;;
    --yes) YES=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

sshx_script() {
  local opts=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [ -n "$PORT" ]; then
    opts+=(-p "$PORT")
  fi
  if [ -n "$KEY" ]; then
    local k
    k="$(expand_tilde "$KEY")"
    [ -f "$k" ] || { echo "✗ 找不到 SSH 私钥：$k" >&2; return 2; }
    opts+=(-i "$k")
  fi
  ssh "${opts[@]}" "$HOST" 'bash -s'
}

# 远端共享单元状态查询函数（兼容 systemd v255 对不存在单元 is-active 返回 4 的情况）
REMOTE_UNIT_STATE_FN='
unit_state() {
  local u="$1" out load="" active="" line
  out=$(systemctl show -p LoadState -p ActiveState "$u" 2>/dev/null) || return 2
  while IFS= read -r line; do
    case "$line" in
      LoadState=*) load="${line#LoadState=}" ;;
      ActiveState=*) active="${line#ActiveState=}" ;;
    esac
  done <<< "$out"
  [ -n "$load" ] && [ -n "$active" ] || return 2
  if [ "$load" = "not-found" ]; then
    echo "absent"
    return 0
  fi
  case "$active" in
    inactive|failed) echo "stopped"; return 0 ;;
    active|activating|reloading|deactivating) echo "running"; return 0 ;;
    *) return 2 ;;
  esac
}
'

preflight() {
  echo "== 预检 $HOST"
  sshx_script <<'REMOTE' || {
PATH="$PATH:/usr/sbin:/sbin"
echo "主机: $(hostname)"
echo "内核: $(uname -r)"
echo "sshd: $(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2; exit}')/$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2; exit}')"
ak_root=$(awk '/^ssh-/{c++} END{print c+0}' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
ak_self=0
if [ "$HOME" != "/root" ]; then
  ak_self=$(awk '/^ssh-/{c++} END{print c+0}' "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
fi
echo "公钥数: root=$ak_root 当前用户=$ak_self"
echo "fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
echo "自动更新: $(systemctl is-active unattended-upgrades 2>/dev/null || echo inactive)"
REMOTE
    echo "✗ 连不上或没权限，先修连接再加固" >&2
    return 1
  }
}

do_check() {
  preflight || return 1
  echo
  echo "将要做的（一次只做一项）："
  echo "  fail2ban   装 fail2ban + sshd jail        回滚: apt purge fail2ban"
  echo "  autoupdate 只开 security 源自动更新        回滚: 改回 20auto-upgrades"
  echo "  sshd-guard 核查公钥后禁密码/禁 root 直登   回滚: 5 分钟自动还原"
  echo
  echo "SSH 加固前请确认：另开一个终端登录着，且你有云控制台的救援入口。"
}

do_fail2ban() {
  sshx_script <<'REMOTE' || return 1
set -e
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
printf "[sshd]\nenabled = true\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n" > /etc/fail2ban/jail.d/sshd.local
systemctl enable --now fail2ban
sleep 1
fail2ban-client status sshd
REMOTE
  echo "验证：fail2ban-client status sshd 里有 Currently banned 计数"
}

do_autoupdate() {
  sshx_script <<'REMOTE' || return 1
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl restart unattended-upgrades
systemctl is-active unattended-upgrades
REMOTE
  echo "验证：systemctl is-active unattended-upgrades → active；不改自动重启（要开另说）"
}

do_sshd_guard() {
  if [ "$YES" != "1" ]; then
    echo "这会改 SSH 配置。确认后有 5 分钟自动还原兜底；再加 --yes 才执行。" >&2
    return 3
  fi

  echo "== 核查目标机可用公钥"
  local key_count
  key_count=$(sshx_script <<'REMOTE'
c1=$(awk '/^ssh-/{c++} END{print c+0}' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
c2=0
if [ "$HOME" != "/root" ]; then
  c2=$(awk '/^ssh-/{c++} END{print c+0}' "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
fi
echo $((c1 + c2))
REMOTE
  ) || return 1
  if [ "${key_count:-0}" -lt 1 ]; then
    echo "✗ 未检测到任何 ssh- 公钥（/root/.ssh/authorized_keys 与 ~/.ssh/authorized_keys 均为空），已中止以防锁死" >&2
    return 1
  fi

  echo "== 加锁检查状态、备份、挂 5 分钟自动回滚并更新 SSH 配置"
  {
    printf '%s\n' "$REMOTE_UNIT_STATE_FN"
    cat <<'REMOTE'
set -u
PATH="$PATH:/usr/sbin:/sbin"
umask 077

SSH_DIR="${HARDEN_SSH_DIR:-/etc/ssh}"
RUN_DIR="${HARDEN_RUN_DIR:-/run}"
LOCK_WAIT="${HARDEN_LOCK_WAIT:-30}"
LOCKDIR="$RUN_DIR/sshd-harden.lockdir"
META="$RUN_DIR/sshd-rollback.meta"
CONF_DIR="$SSH_DIR/sshd_config.d"
CONF_FILE="$CONF_DIR/01-hardening.conf"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "✗ 目标机正在执行 SSH 加固或取消回滚，请稍后再试" >&2
  exit 1
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

# 防止未完成事务期间重复加固覆盖原基线备份（区分 absent/stopped 与 running/query-error）
t_st=$(unit_state sshd-rollback.timer) || { echo "✗ 无法查询 sshd-rollback.timer 状态，已中止" >&2; exit 1; }
s_st=$(unit_state sshd-rollback.service) || { echo "✗ 无法查询 sshd-rollback.service 状态，已中止" >&2; exit 1; }
if [ -e "$META" ] || [ "$t_st" = "running" ] || [ "$s_st" = "running" ]; then
  echo "✗ 目标机已有未完成的 SSH 回滚事务（timer=${t_st}, service=${s_st}），已保留原备份并拒绝覆盖；请先验证后执行 --cancel-rollback 或等自动还原完成" >&2
  exit 1
fi

mkdir -p "$CONF_DIR" "$RUN_DIR" || exit 1
bak=$(mktemp "$SSH_DIR/.01-hardening.bak.XXXXXX") || exit 1
chmod 600 "$bak" || { rm -f "$bak"; exit 1; }
if [ -f "$CONF_FILE" ]; then
  existed=1
  cp -f "$CONF_FILE" "$bak" || { rm -f "$bak"; exit 1; }
else
  existed=0
fi
printf 'EXISTED=%s\nBAK=%s\n' "$existed" "$bak" > "$META" || { rm -f "$bak"; exit 1; }
chmod 600 "$META"

rollback_now() {
  local need_reload="$1"
  if [ "$existed" = "1" ]; then
    [ -f "$bak" ] && cp -f "$bak" "$CONF_FILE" || {
      echo "✗ 立即回滚还原原配置失败，保留备份：${bak}" >&2
      return 1
    }
  else
    rm -f "$CONF_FILE" || {
      echo "✗ 立即回滚删除临时配置失败，保留备份：${bak}" >&2
      return 1
    }
  fi
  if ! sshd -t; then
    echo "✗ 立即回滚后 sshd -t 仍未通过，保留备份：${bak}" >&2
    return 1
  fi
  if [ "$need_reload" = "1" ]; then
    if ! (systemctl reload ssh 2>/dev/null || systemctl reload sshd); then
      echo "✗ 立即回滚重载 ssh 失败，保留备份：${bak}" >&2
      return 1
    fi
  fi
  local cur_t
  cur_t=$(unit_state sshd-rollback.timer) || { echo "✗ 立即回滚后查询定时器状态失败，保留备份：${bak}" >&2; return 1; }
  if [ "$cur_t" = "running" ]; then
    systemctl stop sshd-rollback.timer || { echo "✗ 立即回滚停止定时器失败，保留备份：${bak}" >&2; return 1; }
  fi
  systemctl reset-failed sshd-rollback.service >/dev/null 2>&1 || true
  rm -f "$bak" "$META"
}

if ! systemd-run --on-active=5min --unit=sshd-rollback /bin/sh -c "
  PATH=\$PATH:/usr/sbin:/sbin
  i=0
  got_lock=0
  while [ \$i -lt '$LOCK_WAIT' ]; do
    if mkdir '$LOCKDIR' 2>/dev/null; then
      got_lock=1
      break
    fi
    sleep 1
    i=\$((i+1))
  done
  if [ \"\$got_lock\" -ne 1 ]; then
    echo '✗ 无法获取回滚锁 ${LOCKDIR}，中止本次回滚并保留备份' >&2
    exit 1
  fi
  trap \"rmdir '$LOCKDIR' 2>/dev/null || true\" EXIT
  if [ '$existed' = '1' ]; then
    cp -f '$bak' '$CONF_FILE' || exit 1
  else
    rm -f '$CONF_FILE' || exit 1
  fi
  sshd -t || exit 1
  (systemctl reload ssh 2>/dev/null || systemctl reload sshd) || exit 1
  rm -f '$bak' '$META'"; then
  echo "✗ 挂载 5 分钟回滚定时器失败，已中止并清理" >&2
  rm -f "$bak" "$META"
  exit 1
fi

printf "PermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes\nMaxAuthTries 3\nLoginGraceTime 30\nX11Forwarding no\nAllowAgentForwarding no\n" > "$CONF_FILE"
if ! sshd -t; then
  echo "✗ 配置语法不过，未 reload；正在还原原配置" >&2
  rollback_now 0 || exit 1
  exit 1
fi

if ! (systemctl reload ssh 2>/dev/null || systemctl reload sshd); then
  echo "✗ ssh reload 失败，正在还原原配置" >&2
  rollback_now 1 || exit 1
  exit 1
fi

pw=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2; exit}')
rl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2; exit}')
echo "生效值: PasswordAuthentication=$pw PermitRootLogin=$rl"
if [ "$pw" != "no" ]; then
  echo "⚠ 警告：PasswordAuthentication 仍为 ${pw}（可能被 00-*.conf 或 50-cloud-init.conf 覆盖），请检查："
  grep -rn -i "PasswordAuthentication" "$SSH_DIR/sshd_config" "$CONF_DIR/" 2>/dev/null || true
fi
REMOTE
  } | sshx_script || return 1

  local cancel_cmd="bash \"$SCRIPT_DIR/$SCRIPT_NAME\" --host \"$HOST\""
  [ -n "$KEY" ] && cancel_cmd="$cancel_cmd --key \"$KEY\""
  [ -n "$PORT" ] && cancel_cmd="$cancel_cmd --port \"$PORT\""
  cancel_cmd="$cancel_cmd --cancel-rollback"

  echo "== 已 reload。现在必须用同用户同钥匙新开一个终端 ssh 一次。"
  echo "   成功 → 执行：$cancel_cmd"
  echo "   失败 → 什么都别做，5 分钟后自动还原"
}

do_cancel() {
  if ! {
    printf '%s\n' "$REMOTE_UNIT_STATE_FN"
    cat <<'REMOTE'
set -u
RUN_DIR="${HARDEN_RUN_DIR:-/run}"
LOCKDIR="$RUN_DIR/sshd-harden.lockdir"
META="$RUN_DIR/sshd-rollback.meta"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "✗ 目标机正在执行另一项 SSH 加固或回滚，请稍后再试" >&2
  exit 1
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

for u in sshd-rollback.timer sshd-rollback.service; do
  st=$(unit_state "$u") || {
    echo "✗ 查询 ${u} 状态失败，保留备份" >&2
    exit 1
  }
  if [ "$st" = "running" ]; then
    systemctl stop "$u" || {
      echo "✗ 停止 ${u} 失败，保留备份" >&2
      exit 1
    }
  fi
  st_after=$(unit_state "$u") || {
    echo "✗ 停止后复查 ${u} 状态失败，保留备份" >&2
    exit 1
  }
  if [ "$st_after" = "running" ]; then
    echo "✗ ${u} 仍在运行，保留备份" >&2
    exit 1
  fi
done

systemctl reset-failed sshd-rollback.service >/dev/null 2>&1 || true
if [ -f "$META" ]; then
  . "$META"
  rm -f "${BAK:-}" "$META"
fi
systemctl list-timers --all | awk '/sshd-rollback/{c++} END{print c+0}'
REMOTE
  } | sshx_script; then
    echo "✗ 取消回滚失败：未删除远端保护备份，请排查后重试" >&2
    return 1
  fi
  echo "回滚定时器已取消并清理保护备份（上面的 0 表示已无残留）"
}

if [ "$SELF_TEST" = "1" ]; then
  bash -n "$0" || exit 1
  "$0" --help >/dev/null || exit 1
  t_exp="$(expand_tilde "~/.ssh/example key")"
  [ "$t_exp" = "$HOME/.ssh/example key" ] || { echo "✗ expand_tilde 错误：$t_exp" >&2; exit 1; }
  "$0" --check >/dev/null 2>&1
  [ "$?" -eq 2 ] || { echo "✗ 缺少 --host 应返回 2" >&2; exit 1; }
  "$0" --host root@192.0.2.10 --apply sshd-guard >/dev/null 2>&1
  [ "$?" -eq 3 ] || { echo "✗ sshd-guard 缺少 --yes 应返回 3" >&2; exit 1; }

  tmp_dir="$(mktemp -d)" || exit 1
  trap 'rm -rf "$tmp_dir"' EXIT
  fake_key="$tmp_dir/test key"
  touch "$fake_key"

  mkdir -p "$tmp_dir/bin" "$tmp_dir/remote_bin" "$tmp_dir/etc_ssh/sshd_config.d" "$tmp_dir/run" "$tmp_dir/userhome/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey test@local\n' > "$tmp_dir/userhome/.ssh/authorized_keys"
  printf '# baseline sshd\n' > "$tmp_dir/etc_ssh/sshd_config.d/01-hardening.conf"
  printf 'PasswordAuthentication no\n' > "$tmp_dir/etc_ssh/sshd_config"

  # 远端 mock 工具链：systemctl (读 state 文件模拟 not-found / active / error)、systemd-run (记录回调命令)、sshd、cp(可注入77)
  cat > "$tmp_dir/remote_bin/systemctl" <<'SC'
#!/usr/bin/env bash
case "${1:-}" in
  show)
    u="${@: -1}"
    if [ "${MOCK_SYS_ERR:-0}" = "1" ]; then exit 4; fi
    if [ -f "$MOCK_STATE_DIR/$u" ]; then
      cat "$MOCK_STATE_DIR/$u"
    else
      printf 'LoadState=not-found\nActiveState=inactive\n'
    fi
    ;;
  stop)
    u="${@: -1}"
    if [ "${MOCK_STOP_FAIL:-0}" != "0" ]; then exit "$MOCK_STOP_FAIL"; fi
    printf 'LoadState=loaded\nActiveState=inactive\n' > "$MOCK_STATE_DIR/$u"
    ;;
  list-timers) exit 0 ;;
  *) exit 0 ;;
esac
SC
  cat > "$tmp_dir/remote_bin/systemd-run" <<'SR'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    /bin/sh) shift; shift; printf '%s\n' "$1" > "$MOCK_ROLLBACK_CMD_FILE"; break ;;
    *) shift ;;
  esac
done
printf 'LoadState=loaded\nActiveState=active\n' > "$MOCK_STATE_DIR/sshd-rollback.timer"
exit 0
SR
  cat > "$tmp_dir/remote_bin/sshd" <<'SD'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit "${MOCK_SSHD_T_FAIL:-0}" ;;
  -T) printf 'passwordauthentication no\npermitrootlogin prohibit-password\n' ;;
esac
SD
  cat > "$tmp_dir/remote_bin/cp" <<'CP'
#!/usr/bin/env bash
if [ "${MOCK_CP_FAIL:-0}" != "0" ] && [[ "${@: -1}" == *"01-hardening.conf" ]]; then
  exit "$MOCK_CP_FAIL"
fi
/bin/cp "$@"
CP
  cat > "$tmp_dir/remote_bin/mkdir" <<'MK'
#!/usr/bin/env bash
if [ "${MOCK_LOCK_FAIL:-0}" = "1" ] && [[ "$*" == *"sshd-harden.lockdir"* ]]; then
  exit 1
fi
/bin/mkdir "$@"
MK
  chmod +x "$tmp_dir/remote_bin/"*

  mkdir -p "$tmp_dir/state"
  cat > "$tmp_dir/bin/ssh" <<STUB
#!/usr/bin/env bash
if [ "\${STUB_FAIL:-0}" != "0" ]; then exit "\${STUB_FAIL}"; fi
env PATH="$tmp_dir/remote_bin:/usr/bin:/bin" \
  HOME="$tmp_dir/userhome" \
  HARDEN_SSH_DIR="$tmp_dir/etc_ssh" \
  HARDEN_RUN_DIR="$tmp_dir/run" \
  HARDEN_LOCK_WAIT=1 \
  MOCK_STATE_DIR="$tmp_dir/state" \
  MOCK_ROLLBACK_CMD_FILE="$tmp_dir/rollback_cmd.sh" \
  MOCK_SYS_ERR="\${MOCK_SYS_ERR:-0}" \
  MOCK_STOP_FAIL="\${MOCK_STOP_FAIL:-0}" \
  MOCK_SSHD_T_FAIL="\${MOCK_SSHD_T_FAIL:-0}" \
  MOCK_CP_FAIL="\${MOCK_CP_FAIL:-0}" \
  bash -s
STUB
  chmod +x "$tmp_dir/bin/ssh"

  # 1) systemd v255 初次加固（单元不存在 LoadState=not-found）：必须成功并留好元文件与原配置备份
  PATH="$tmp_dir/bin:$PATH" "$0" --host root@192.0.2.10 --key "$fake_key" --apply sshd-guard --yes >/dev/null || {
    echo "✗ 首次加固（not-found 单元）失败" >&2; exit 1;
  }
  [ -f "$tmp_dir/run/sshd-rollback.meta" ] || { echo "✗ 未生成 meta" >&2; exit 1; }
  . "$tmp_dir/run/sshd-rollback.meta"
  [ -f "$BAK" ] && grep -q 'baseline sshd' "$BAK" || { echo "✗ 原配置备份缺失" >&2; exit 1; }

  # 2) 未取消前重复加固：必须被拒绝，且原基线备份不被覆盖
  PATH="$tmp_dir/bin:$PATH" "$0" --host root@192.0.2.10 --key "$fake_key" --apply sshd-guard --yes >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "✗ 重复加固未被拒绝" >&2; exit 1; }
  grep -q 'baseline sshd' "$BAK" || { echo "✗ 重复加固破坏了原备份" >&2; exit 1; }

  # 3) 取消回滚在 stop=77 或 show 查询失败=4 时：必须退出非零且保留备份与元文件
  PATH="$tmp_dir/bin:$PATH" MOCK_STOP_FAIL=77 "$0" --host root@192.0.2.10 --key "$fake_key" --cancel-rollback >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ -f "$BAK" ] && [ -f "$tmp_dir/run/sshd-rollback.meta" ] || {
    echo "✗ stop=77 时仍清理了备份或返回 0" >&2; exit 1;
  }
  PATH="$tmp_dir/bin:$PATH" MOCK_SYS_ERR=1 "$0" --host root@192.0.2.10 --key "$fake_key" --cancel-rollback >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ -f "$BAK" ] || { echo "✗ 查询失败时仍清理了备份" >&2; exit 1; }

  # 4) 定时回滚拿不到锁（MOCK_LOCK_FAIL=1）：必须非零退出、不删他人的锁、不删备份
  /bin/mkdir "$tmp_dir/run/sshd-harden.lockdir"
  PATH="$tmp_dir/remote_bin:/usr/bin:/bin" MOCK_LOCK_FAIL=1 /bin/sh -c "$(cat "$tmp_dir/rollback_cmd.sh")" >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ -d "$tmp_dir/run/sshd-harden.lockdir" ] && [ -f "$BAK" ] || {
    echo "✗ 定时回滚无锁时越权执行或删掉了他人的锁/备份" >&2; exit 1;
  }
  rmdir "$tmp_dir/run/sshd-harden.lockdir"

  # 5) 定时回滚恢复 cp=77 失败：必须非零退出且保留备份与元文件
  PATH="$tmp_dir/remote_bin:/usr/bin:/bin" MOCK_CP_FAIL=77 /bin/sh -c "$(cat "$tmp_dir/rollback_cmd.sh")" >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ -f "$BAK" ] && [ -f "$tmp_dir/run/sshd-rollback.meta" ] || {
    echo "✗ 定时回滚 cp=77 失败却清理了备份" >&2; exit 1;
  }

  # 6) 正常取消回滚（stop 成功 + 单元已 stopped）：应退出 0 且清理备份与元文件
  PATH="$tmp_dir/bin:$PATH" "$0" --host root@192.0.2.10 --key "$fake_key" --cancel-rollback >/dev/null || {
    echo "✗ 正常 --cancel-rollback 失败" >&2; exit 1;
  }
  [ ! -f "$BAK" ] && [ ! -f "$tmp_dir/run/sshd-rollback.meta" ] || {
    echo "✗ 正常取消后备份/元文件未清理" >&2; exit 1;
  }

  # 7) 立即回滚场景：sshd -t 失败 + 恢复 cp=77 失败 -> 必须退出非零且保留备份
  PATH="$tmp_dir/bin:$PATH" MOCK_SSHD_T_FAIL=1 MOCK_CP_FAIL=77 "$0" --host root@192.0.2.10 --key "$fake_key" --apply sshd-guard --yes >/dev/null 2>&1
  [ "$?" -ne 0 ] && [ -f "$tmp_dir/run/sshd-rollback.meta" ] || {
    echo "✗ 立即回滚 cp 失败后未保留备份" >&2; exit 1;
  }

  echo "self-test OK：真实远端脚本回放（systemd not-found/防重入/无锁不回滚/cp=77保备份/取消传播）全过"
  exit 0
fi

[ -z "$HOST" ] && { usage; exit 2; }
case "$ACTION" in
  check) do_check ;;
  fail2ban) do_fail2ban ;;
  autoupdate) do_autoupdate ;;
  sshd-guard) do_sshd_guard ;;
  cancel) do_cancel ;;
  *) usage; exit 2 ;;
esac
