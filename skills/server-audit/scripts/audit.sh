#!/usr/bin/env bash
# server-audit：只读采集一台或多台 Linux 的安全面，输出 JSON + 人看的摘要。
# 绝不修改目标机：本脚本里没有 apt install / systemctl restart / sed -i / ufw allow。
set -uo pipefail

HOST=""
KEY=""
PORT=""
OUT=""
CONFIG=""
JOBS="4"
SUMMARY=0
SELF_TEST=0

usage() {
  cat <<'USAGE'
用法：
  audit.sh --host root@192.0.2.10 [--key ~/.ssh/id_ed25519] [--port 22] [--out report.json] [--summary]
  audit.sh --config hosts.json --out reports/ [--jobs 4] [--summary]
  audit.sh --self-test          # 用内置样例与桩验证单机/多机解析、防误报与失败传播
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
    --out) [ $# -ge 2 ] || { echo "✗ --out 缺少参数" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --config) [ $# -ge 2 ] || { echo "✗ --config 缺少参数" >&2; exit 2; }; CONFIG="$2"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || { echo "✗ --jobs 缺少参数" >&2; exit 2; }; JOBS="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

# 远端采集：只读命令，输出 KEY=VALUE（显式传参，支持免 --key 走 ~/.ssh/config）
remote_probe() {
  local host="$1" key="$2" port="$3"
  local ssh_opts=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [ -n "$port" ]; then
    ssh_opts+=(-p "$port")
  fi
  if [ -n "$key" ]; then
    key="$(expand_tilde "$key")"
    [ -f "$key" ] || { echo "✗ 找不到 SSH 私钥：$key" >&2; return 2; }
    ssh_opts+=(-i "$key")
  fi

  ssh "${ssh_opts[@]}" "$host" 'bash -s' <<'PROBE'
PATH="$PATH:/usr/sbin:/sbin"
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  echo "PROBE_PRIV=root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
  echo "PROBE_PRIV=sudo"
else
  echo "PROBE_PRIV=unprivileged"
fi

echo "HOSTNAME=$(hostname 2>/dev/null)"
if [ -r /etc/os-release ]; then
  . /etc/os-release 2>/dev/null && echo "OS=${PRETTY_NAME:-}"
fi
echo "KERNEL=$(uname -r 2>/dev/null)"

if command -v apt >/dev/null 2>&1; then
  echo "PKG_SUPPORTED=yes"
  upg=$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)
  if [ -n "$upg" ]; then
    echo "PENDING=$(printf '%s\n' "$upg" | wc -l | tr -d ' ')"
    echo "SECURITY=$(printf '%s\n' "$upg" | grep -ci 'security' || true)"
  else
    echo "PENDING=0"
    echo "SECURITY=0"
  fi
else
  echo "PKG_SUPPORTED=no"
  echo "PENDING=0"
  echo "SECURITY=0"
fi
echo "REBOOT_REQUIRED=$(test -f /var/run/reboot-required && echo yes || echo no)"

if command -v ufw >/dev/null 2>&1; then
  echo "FW_INSTALLED=yes"
  ufw_out=$($SUDO ufw status verbose 2>/dev/null || true)
  if [ -n "$ufw_out" ]; then
    fw_first="$(printf '%s\n' "$ufw_out" | head -1)"
    if printf '%s\n' "$fw_first" | grep -Eiq '^Status:[[:space:]]*active([[:space:]]|$)'; then
      echo "FW_READABLE=yes"
      echo "FW_ACTIVE=yes"
      echo "FW_DEFAULT_IN=$(printf '%s\n' "$ufw_out" | sed -n 's/^Default: \([a-z]*\).*/\1/p' | head -1)"
    elif printf '%s\n' "$fw_first" | grep -Eiq '^Status:[[:space:]]*inactive([[:space:]]|$)'; then
      echo "FW_READABLE=yes"
      echo "FW_ACTIVE=no"
      echo "FW_DEFAULT_IN="
    else
      echo "FW_READABLE=no"
      echo "FW_ACTIVE=unknown"
      echo "FW_DEFAULT_IN="
    fi
  else
    echo "FW_READABLE=no"
    echo "FW_ACTIVE=unknown"
    echo "FW_DEFAULT_IN="
  fi
else
  echo "FW_INSTALLED=no"
  echo "FW_READABLE=no"
  echo "FW_ACTIVE=unknown"
  echo "FW_DEFAULT_IN="
fi

sshd_out=$($SUDO sshd -T 2>/dev/null || true)
if [ -n "$sshd_out" ]; then
  echo "SSHD_READABLE=yes"
  echo "SSHD_PASSWORD=$(printf '%s\n' "$sshd_out" | awk '/^passwordauthentication/{print $2; exit}')"
  echo "SSHD_ROOT=$(printf '%s\n' "$sshd_out" | awk '/^permitrootlogin/{print $2; exit}')"
  echo "SSHD_MAXAUTH=$(printf '%s\n' "$sshd_out" | awk '/^maxauthtries/{print $2; exit}')"
  echo "SSHD_PORT=$(printf '%s\n' "$sshd_out" | awk '/^port /{print $2; exit}')"
else
  echo "SSHD_READABLE=no"
  echo "SSHD_PASSWORD="
  echo "SSHD_ROOT="
  echo "SSHD_MAXAUTH="
  echo "SSHD_PORT="
fi

authkeys=$($SUDO awk '/^ssh-/{c++} END{print c+0}' /root/.ssh/authorized_keys 2>/dev/null || awk '/^ssh-/{c++} END{print c+0}' "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
echo "AUTHKEYS=$authkeys"
echo "FAIL2BAN=$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
echo "UNATTENDED=$(systemctl is-active unattended-upgrades 2>/dev/null || echo inactive)"
echo "AUDITD=$(systemctl is-active auditd 2>/dev/null || echo inactive)"
echo "APPARMOR=$(systemctl is-active apparmor 2>/dev/null || echo inactive)"
echo "UID0=$(awk -F: '$3==0{c++} END{print c+0}' /etc/passwd 2>/dev/null || echo 0)"
echo "SUDO_GROUP=$(getent group sudo 2>/dev/null | cut -d: -f4)"
echo "DOCKER_GROUP=$(getent group docker 2>/dev/null | cut -d: -f4)"
echo "LISTEN_PUBLIC_START"
(ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null) | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/{print $4}' | sort -u | head -40
echo "LISTEN_PUBLIC_END"
echo "DOCKER_PUB_START"
docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | grep '0\.0\.0\.0' || true
echo "DOCKER_PUB_END"
echo "CERT_END"
if command -v openssl >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$(hostname)" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//'
  else
    openssl s_client -connect 127.0.0.1:443 -servername "$(hostname)" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//'
  fi
fi
echo "CERT_END2"
PROBE
}

# 把 KEY=VALUE + 多行块解析成 JSON，并按规则生成 findings
assemble() {
  python3 - "$1" "$2" <<'PY'
import json, sys, datetime, re

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
host = sys.argv[2] or "unknown"

def block(name):
    m = re.search(r"^%s_START$(.*?)^%s_END$" % (name, name), raw, re.S | re.M)
    return [l.strip() for l in (m.group(1) if m else "").splitlines() if l.strip()]

kv = {}
for line in raw.splitlines():
    if "=" in line and not line.startswith(" "):
        k, v = line.split("=", 1)
        if re.fullmatch(r"[A-Z0-9_]+", k):
            kv[k] = v.strip()

listeners = block("LISTEN_PUBLIC")
docker_pub = block("DOCKER_PUB")
cert = ""
m = re.search(r"^CERT_END$", raw, re.M)
if m:
    tail = raw[m.end():].split("CERT_END2")[0].strip()
    cert = tail.splitlines()[0] if tail else ""

def num(v, d=0):
    try:
        return int(str(v).strip())
    except Exception:
        return d

fw_active_raw = kv.get("FW_ACTIVE", "")
fw_readable = kv.get("FW_READABLE", "yes") == "yes" if "FW_READABLE" in kv else True
fw_installed = kv.get("FW_INSTALLED", "yes") == "yes" if "FW_INSTALLED" in kv else True
sshd_readable = kv.get("SSHD_READABLE", "yes") == "yes" if "SSHD_READABLE" in kv else True
pkg_supported = kv.get("PKG_SUPPORTED", "yes") == "yes" if "PKG_SUPPORTED" in kv else True

fw_active = True if fw_active_raw == "yes" else (False if fw_active_raw == "no" else None)

data = {
    "host": host,
    "hostname": kv.get("HOSTNAME", ""),
    "os": kv.get("OS", ""),
    "kernel": kv.get("KERNEL", ""),
    "probe_privilege": kv.get("PROBE_PRIV", "unknown"),
    "collected_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "updates": {
        "supported": pkg_supported,
        "pending": num(kv.get("PENDING")),
        "security": num(kv.get("SECURITY")),
        "reboot_required": kv.get("REBOOT_REQUIRED") == "yes",
    },
    "firewall": {
        "installed": fw_installed,
        "readable": fw_readable,
        "active": fw_active,
        "default_in": kv.get("FW_DEFAULT_IN", ""),
    },
    "sshd": {
        "readable": sshd_readable,
        "password_auth": kv.get("SSHD_PASSWORD", ""),
        "root_login": kv.get("SSHD_ROOT", ""),
        "maxauthtries": num(kv.get("SSHD_MAXAUTH")),
        "port": num(kv.get("SSHD_PORT"), 22),
    },
    "auth_keys": num(kv.get("AUTHKEYS")),
    "agents": {
        "fail2ban": kv.get("FAIL2BAN", ""),
        "unattended_upgrades": kv.get("UNATTENDED", ""),
        "auditd": kv.get("AUDITD", ""),
        "apparmor": kv.get("APPARMOR", ""),
    },
    "accounts": {
        "uid0": num(kv.get("UID0")),
        "sudo_group": kv.get("SUDO_GROUP", ""),
        "docker_group": kv.get("DOCKER_GROUP", ""),
    },
    "listeners_public": listeners,
    "docker_published_public": docker_pub,
    "tls_cert_expiry": cert,
    "unverified": [],
}

unverified = data["unverified"]
if not pkg_supported:
    unverified.append("非 apt 系统：未检查待升级包与安全更新")
if not fw_installed:
    unverified.append("未安装 ufw：需人工核对 iptables/nftables/云安全组")
elif not fw_readable:
    unverified.append("权限不足（需 root 或免密 sudo）：未读取到 ufw 防火墙状态")
if not sshd_readable:
    unverified.append("权限不足（需 root 或免密 sudo）：未读取到 sshd -T 生效配置")

f = []
def add(sev, key, msg, evidence, fix):
    f.append({"severity": sev, "key": key, "issue": msg, "evidence": evidence, "fix": fix})

if pkg_supported and data["updates"]["security"] > 0:
    add("P1", "updates.security", "有安全更新没打（%d 个）" % data["updates"]["security"],
        "apt list --upgradable | grep -ci security = %d" % data["updates"]["security"],
        "挑维护窗口 apt upgrade 后重启")
if pkg_supported and data["updates"]["pending"] > 30:
    add("P0", "updates.pending", "待升级包 %d 个，内核/库补丁可能缺失" % data["updates"]["pending"],
        "apt list --upgradable 行数", "同上一并处理")
if data["updates"]["reboot_required"]:
    add("P1", "reboot", "补丁已装但没重启，未生效", "/var/run/reboot-required 存在", "计划重启")
if fw_installed and fw_readable and fw_active is False:
    add("P0", "firewall", "本机防火墙没开", "ufw status 第一行不是 active", "开 ufw 并默认拒绝入站")
if sshd_readable and data["sshd"]["password_auth"] not in ("no", ""):
    add("P0", "sshd.password", "SSH 允许密码登录",
        "sshd -T passwordauthentication=%s" % data["sshd"]["password_auth"],
        "改 no 并保留密钥通道")
if sshd_readable and data["sshd"]["root_login"] in ("yes",):
    add("P0", "sshd.root", "root 可以用密码直接登录", "permitrootlogin=yes", "改 without-password 或 no")
if sshd_readable and data["sshd"]["maxauthtries"] and data["sshd"]["maxauthtries"] > 4:
    add("P2", "sshd.maxauth", "SSH 重试次数偏大（%d）" % data["sshd"]["maxauthtries"],
        "sshd -T maxauthtries", "调到 3-4")
if data["accounts"]["uid0"] > 1:
    add("P0", "accounts.uid0", "有 %d 个 UID 0 账号" % data["accounts"]["uid0"], "/etc/passwd", "逐个核对来源")
if data["accounts"]["docker_group"]:
    add("P1", "accounts.docker", "这些账号在 docker 组（等价 root）",
        data["accounts"]["docker_group"], "确认都是必要账号")
if data["agents"]["fail2ban"] != "active" and data["sshd"]["password_auth"] not in ("no", ""):
    add("P1", "fail2ban", "密码登录开着又没 fail2ban",
        "systemctl is-active fail2ban", "装 fail2ban 开 sshd jail")
if pkg_supported and data["agents"]["unattended_upgrades"] != "active":
    add("P2", "autoupdate", "没开自动安全更新",
        "systemctl is-active unattended-upgrades", "开启 security 源自动更新")

db_ports = {
    "3306": "MySQL", "5432": "PostgreSQL", "5433": "PostgreSQL", "6379": "Redis",
    "27017": "MongoDB", "9200": "Elasticsearch", "11211": "Memcached",
}
for item in listeners:
    port = item.rsplit(":", 1)[-1]
    if port in db_ports:
        add("P0", "db.public", "%s（%s）监听在所有网卡" % (db_ports[port], port),
            "ss -tln 显示 %s" % item, "改绑 127.0.0.1，或防火墙只放应用机")
for item in docker_pub:
    add("P1", "docker.public", "容器端口发布到 0.0.0.0（绕过 UFW）", item, "改绑 127.0.0.1 或走反代")

data["findings"] = sorted(f, key=lambda x: {"P0": 0, "P1": 1, "P2": 2}[x["severity"]])
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
}

summarize() {
  python3 - "$1" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1], encoding="utf-8"))
if "error" in d:
    print(f"== {d['host']}: ERROR ({d['error']})")
    raise SystemExit(0)
c = collections.Counter(x["severity"] for x in d.get("findings", []))
fw = "开" if d["firewall"]["active"] is True else ("关" if d["firewall"]["active"] is False else "未查/未知")
print("== %s (%s | 采集身份: %s)" % (d["hostname"] or d["host"], d["os"] or "未知系统", d.get("probe_privilege", "未知")))
print("   待升级 %d（安全 %d）| 防火墙 %s | SSH 密码登录 %s | 公开监听 %d 个" % (
    d["updates"]["pending"], d["updates"]["security"], fw,
    d["sshd"]["password_auth"] or "未知", len(d["listeners_public"])))
print("   P0 %d / P1 %d / P2 %d" % (c["P0"], c["P1"], c["P2"]))
if d.get("unverified"):
    print("   未验证: " + "；".join(d["unverified"]))
for x in d["findings"][:5]:
    print("   [%s] %s — %s" % (x["severity"], x["issue"], x["fix"]))
PY
}

run_one() {
  local host="$1" key="$2" port="$3" target="$4"
  local tmp target_dir
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir" 2>/dev/null || { echo "✗ 无法创建报告目录：$target_dir" >&2; return 1; }
  tmp="$(mktemp)" || return 1
  if ! remote_probe "$host" "$key" "$port" > "$tmp" 2>/dev/null; then
    python3 -c 'import json,sys; print(json.dumps({"host":sys.argv[1],"error":"ssh 采集失败（网络、端口或权限）"}, ensure_ascii=False, indent=2))' "$host" > "$target" 2>/dev/null || true
    echo "✗ $host 采集失败" >&2
    rm -f "$tmp"
    return 1
  fi
  local assembled
  if ! assembled="$(assemble "$tmp" "$host")"; then
    echo "✗ $host 报告解析失败" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  if ! printf '%s\n' "$assembled" > "$target"; then
    echo "✗ $host 报告写入失败：$target" >&2
    return 1
  fi
  [ "$SUMMARY" = "1" ] && { summarize "$target" || return 1; }
  echo "✓ $host → $target" >&2
}

if [ "$SELF_TEST" = "1" ]; then
  bash -n "$0" || exit 1
  tmp_dir="$(mktemp -d)" || exit 1
  trap 'rm -rf "$tmp_dir"' EXIT

  # 0) 验证带空格 ~/ 路径展开
  t_exp="$(expand_tilde "~/.ssh/example key")"
  [ "$t_exp" = "$HOME/.ssh/example key" ] || { echo "✗ expand_tilde 错误：$t_exp" >&2; exit 1; }

  # 1) 真实穿过 remote_probe 脚本（桩 PATH：ufw Status: inactive 与 Status: active）
  mkdir -p "$tmp_dir/probe_bin" "$tmp_dir/fake_home/.ssh" "$tmp_dir/bin" "$tmp_dir/reports"
  printf '' > "$tmp_dir/fake_home/.ssh/authorized_keys"
  cat > "$tmp_dir/probe_bin/id" <<'P'
#!/usr/bin/env bash
echo 0
P
  cat > "$tmp_dir/probe_bin/hostname" <<'P'
#!/usr/bin/env bash
echo demo-probe-host
P
  cat > "$tmp_dir/probe_bin/uname" <<'P'
#!/usr/bin/env bash
echo 6.6.0-mock
P
  cat > "$tmp_dir/probe_bin/ufw" <<'P'
#!/usr/bin/env bash
if [ "${MOCK_UFW_STATE:-inactive}" = "active" ]; then
  printf 'Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing)\n'
else
  printf 'Status: inactive\n'
fi
P
  cat > "$tmp_dir/probe_bin/sshd" <<'P'
#!/usr/bin/env bash
printf 'passwordauthentication yes\npermitrootlogin yes\nmaxauthtries 6\nport 22\n'
P
  cat > "$tmp_dir/probe_bin/systemctl" <<'P'
#!/usr/bin/env bash
echo inactive
P
  cat > "$tmp_dir/probe_bin/getent" <<'P'
#!/usr/bin/env bash
echo deploy
P
  cat > "$tmp_dir/probe_bin/ss" <<'P'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:5432 0.0.0.0:*\n'
P
  cat > "$tmp_dir/probe_bin/docker" <<'P'
#!/usr/bin/env bash
printf 'demo-api|0.0.0.0:8080->80/tcp\n'
P
  chmod +x "$tmp_dir/probe_bin/"*

  # ssh 桩：直接把 remote_probe 发送的 <<'PROBE' 在隔离 mock_bin 环境中执行，验证真实采集逻辑
  cat > "$tmp_dir/bin/ssh" <<STUB
#!/usr/bin/env bash
env PATH="$tmp_dir/probe_bin:/usr/bin:/bin" HOME="$tmp_dir/fake_home" MOCK_UFW_STATE="\${MOCK_UFW_STATE:-inactive}" bash -s
STUB
  chmod +x "$tmp_dir/bin/ssh"

  # 1a) 真实穿过 remote_probe 验证 Status: inactive -> firewall.active == False，且无 apt 不误报
  probe_inact="$tmp_dir/probe_inact.txt"
  PATH="$tmp_dir/bin:$PATH" MOCK_UFW_STATE=inactive remote_probe "root@192.0.2.10" "" "" > "$probe_inact" || {
    echo "✗ remote_probe inactive 桩失败" >&2; exit 1;
  }
  grep -qx 'FW_ACTIVE=no' "$probe_inact" || { echo "✗ Status: inactive 未判为 FW_ACTIVE=no" >&2; cat "$probe_inact" >&2; exit 1; }
  grep -qx 'AUTHKEYS=0' "$probe_inact" || { echo "✗ AUTHKEYS 空文件应为 0" >&2; exit 1; }

  # 1b) 真实穿过 remote_probe 验证 Status: active -> FW_ACTIVE=yes
  probe_act="$tmp_dir/probe_act.txt"
  PATH="$tmp_dir/bin:$PATH" MOCK_UFW_STATE=active remote_probe "root@192.0.2.10" "" "" > "$probe_act" || {
    echo "✗ remote_probe active 桩失败" >&2; exit 1;
  }
  grep -qx 'FW_ACTIVE=yes' "$probe_act" || { echo "✗ Status: active 未判为 FW_ACTIVE=yes" >&2; exit 1; }

  # 构造碰撞 label: web / web / web_2 / WEB（覆盖大小写不敏感卷碰撞），经过真实 --config 路径
  cfg="$tmp_dir/hosts.json"
  cat > "$cfg" <<'CFG'
{
  "hosts": [
    {"host": "root@192.0.2.10", "label": "web"},
    {"host": "root@192.0.2.11", "label": "web"},
    {"host": "root@192.0.2.12", "label": "web_2"},
    {"host": "root@192.0.2.13", "label": "WEB"}
  ]
}
CFG
  PATH="$tmp_dir/bin:$PATH" MOCK_UFW_STATE=inactive "$0" --config "$cfg" --out "$tmp_dir/reports" --jobs 2 >/dev/null 2>&1 || {
    echo "✗ --config 并发调度测试失败" >&2; exit 1;
  }

  # 验证无特权+非 apt 不误报 firewall P0
  sample_unpriv="$tmp_dir/unpriv.txt"
  cat > "$sample_unpriv" <<'SAMPLE'
PROBE_PRIV=unprivileged
HOSTNAME=alpine-box
OS=Alpine Linux
KERNEL=6.6.0
PKG_SUPPORTED=no
PENDING=0
SECURITY=0
REBOOT_REQUIRED=no
FW_INSTALLED=yes
FW_READABLE=no
FW_ACTIVE=unknown
SSHD_READABLE=no
AUTHKEYS=1
FAIL2BAN=inactive
UNATTENDED=inactive
UID0=1
LISTEN_PUBLIC_START
LISTEN_PUBLIC_END
DOCKER_PUB_START
DOCKER_PUB_END
CERT_END
CERT_END2
SAMPLE
  json_unpriv="$tmp_dir/unpriv.json"
  assemble "$sample_unpriv" "ops@198.51.100.20" > "$json_unpriv" || exit 1

  python3 - "$tmp_dir/reports" "$json_unpriv" <<'PY' || exit 1
import json, os, sys
rdir, unpriv_file = sys.argv[1], sys.argv[2]
files = sorted(f for f in os.listdir(rdir) if f.endswith(".json"))
assert len(files) == 4, f"期望 4 份独立报告（含 web/WEB 大小写去重），实际: {files}"
assert len({f.lower() for f in files}) == 4, f"大小写折叠后仍有文件名碰撞: {files}"
seen_hosts = set()
for f in files:
    d = json.load(open(os.path.join(rdir, f), encoding="utf-8"))
    seen_hosts.add(d["host"])
    assert d["firewall"]["active"] is False
    assert any(x["key"] == "firewall" for x in d["findings"])
    assert any(x["key"] == "db.public" for x in d["findings"])
assert seen_hosts == {"root@192.0.2.10", "root@192.0.2.11", "root@192.0.2.12", "root@192.0.2.13"}, seen_hosts

d2 = json.load(open(unpriv_file, encoding="utf-8"))
assert d2["firewall"]["active"] is None
assert not any(f["key"] == "firewall" for f in d2["findings"])
assert len(d2["unverified"]) >= 3
PY

  # 不可写 --out 路径必须返回非零（不能误打印成功）
  mkdir -p "$tmp_dir/readonly_dir"
  PATH="$tmp_dir/bin:$PATH" "$0" --host root@192.0.2.10 --out "$tmp_dir/readonly_dir" >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "✗ --out 不可写（是目录）仍退出 0" >&2; exit 1; }

  summarize "$tmp_dir/reports/web.json" >/dev/null || exit 1
  echo "self-test OK：真实 remote_probe UFW 判定、--config 大小写去重、不可写退出、防误报全部通过"
  exit 0
fi

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "✗ 找不到配置文件：$CONFIG" >&2; exit 2; }
  out_dir="${OUT:-reports}"
  mkdir -p "$out_dir" || { echo "✗ 无法创建输出目录：$out_dir" >&2; exit 1; }

  # 用 Python ThreadPoolExecutor 并发调度本脚本单机模式（兼容 macOS Bash 3.2，零 eval）
  SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  python3 - "$CONFIG" "$out_dir" "$JOBS" "$SUMMARY" "$SCRIPT_PATH" <<'PY' || exit 1
import concurrent.futures, json, os, re, subprocess, sys

cfg_path, out_dir, jobs_raw, summary_flag, script_path = sys.argv[1:6]
jobs = max(1, min(16, int(jobs_raw)))
cfg = json.load(open(cfg_path, encoding="utf-8"))
hosts = cfg.get("hosts") or []
if not hosts:
    raise SystemExit("✗ 配置文件里 hosts 为空")

used_files_lower = set()
tasks = []
for idx, item in enumerate(hosts, 1):
    h = (item.get("host") or "").strip()
    if not h:
        raise SystemExit(f"✗ hosts[{idx-1}] 缺少 host 字段")
    key = os.path.expanduser((item.get("key") or "").strip())
    port = str(item.get("port") or "").strip()
    base = re.sub(r"[^A-Za-z0-9._-]", "_", item.get("label") or h)
    fname = f"{base}.json"
    suffix = 2
    while fname.lower() in used_files_lower:
        fname = f"{base}_{suffix}.json"
        suffix += 1
    used_files_lower.add(fname.lower())
    out_file = os.path.join(out_dir, fname)
    cmd = ["bash", script_path, "--host", h, "--out", out_file]
    if key:
        cmd.extend(["--key", key])
    if port:
        cmd.extend(["--port", port])
    tasks.append((h, out_file, cmd))

failures = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(tasks))) as pool:
    futs = {pool.submit(subprocess.run, cmd, capture_output=True, text=True): (h, out_file) for h, out_file, cmd in tasks}
    for fut in concurrent.futures.as_completed(futs):
        h, out_file = futs[fut]
        res = fut.result()
        if res.stderr.strip():
            print(res.stderr.strip(), file=sys.stderr)
        if res.returncode != 0:
            failures += 1

print("\n== 多机汇总")
for h, out_file, _ in tasks:
    try:
        d = json.load(open(out_file, encoding="utf-8"))
    except Exception:
        print(f"- {h}: 读取报告失败 ({out_file})")
        failures += 1
        continue
    if d.get("host") != h:
        print(f"- {h}: 报告主机不匹配（文件内为 {d.get('host')}）")
        failures += 1
        continue
    if "error" in d:
        print(f"- {h}: 失败 — {d['error']}")
        continue
    counts = {"P0": 0, "P1": 0, "P2": 0}
    for x in d.get("findings", []):
        counts[x["severity"]] = counts.get(x["severity"], 0) + 1
    print(f"- {h} ({d.get('hostname') or '-'}): P0={counts['P0']} P1={counts['P1']} P2={counts['P2']} → {out_file}")
    if summary_flag == "1":
        for x in d.get("findings", [])[:3]:
            print(f"    [{x['severity']}] {x['issue']}")

if failures:
    sys.exit(1)
PY
elif [ -n "$HOST" ]; then
  if [ -n "$OUT" ]; then
    run_one "$HOST" "$KEY" "$PORT" "$OUT"
  else
    tmp_probe="$(mktemp)" || exit 1
    tmp_json="$(mktemp)" || { rm -f "$tmp_probe"; exit 1; }
    trap 'rm -f "$tmp_probe" "$tmp_json"' EXIT
    remote_probe "$HOST" "$KEY" "$PORT" > "$tmp_probe" || exit 1
    assemble "$tmp_probe" "$HOST" > "$tmp_json" || exit 1
    if [ "$SUMMARY" = "1" ]; then
      summarize "$tmp_json" || exit 1
    else
      cat "$tmp_json"
    fi
  fi
else
  usage
  exit 2
fi
