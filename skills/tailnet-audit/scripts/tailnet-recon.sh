#!/usr/bin/env bash
# tailnet-recon.sh：Tailscale 拓扑、并发可达性矩阵、ACL 快照（只读）
set -uo pipefail

PORTS="22"
SSH_TARGET=""
SSH_KEY=""
SSH_PORT=""
OUT=""
TIMEOUT="2"
JOBS="16"
INCLUDE_OFFLINE=0
JSON_OUT=0
SELF_TEST=0

usage() {
  cat <<'USAGE'
用法：
  tailnet-recon.sh status [--json]
  tailnet-recon.sh matrix [--ports 22,445,5433] [--timeout 2] [--jobs 16] [--include-offline] [--json]
  tailnet-recon.sh from --ssh user@host [--key ~/.ssh/id] [--ssh-port 22] [--ports 22,445] [--timeout 2] [--jobs 16] [--include-offline] [--json]
  tailnet-recon.sh acl [--out acl.json]          # 需要 TS_API_KEY
  tailnet-recon.sh --self-test                    # 离线回放 + 本地回环并发探测自检
USAGE
}

expand_tilde() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#"~/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
  cmd="status"
else
  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    --self-test) SELF_TEST=1; cmd="self-test"; shift ;;
    status|matrix|from|acl) shift ;;
    *) echo "未知命令：$cmd" >&2; usage; exit 2 ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --ports) [ $# -ge 2 ] || { echo "✗ --ports 缺少参数" >&2; exit 2; }; PORTS="$2"; shift 2 ;;
    --ssh) [ $# -ge 2 ] || { echo "✗ --ssh 缺少参数" >&2; exit 2; }; SSH_TARGET="$2"; shift 2 ;;
    --key) [ $# -ge 2 ] || { echo "✗ --key 缺少参数" >&2; exit 2; }; SSH_KEY="$2"; shift 2 ;;
    --ssh-port) [ $# -ge 2 ] || { echo "✗ --ssh-port 缺少参数" >&2; exit 2; }; SSH_PORT="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { echo "✗ --out 缺少参数" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || { echo "✗ --timeout 缺少参数" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || { echo "✗ --jobs 缺少参数" >&2; exit 2; }; JOBS="$2"; shift 2 ;;
    --include-offline) INCLUDE_OFFLINE=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --self-test) SELF_TEST=1; cmd="self-test"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

normalize_probe_opts() {
  local norm
  norm=$(python3 - "$PORTS" "$TIMEOUT" "$JOBS" <<'PY'
import math, sys
ports_raw, timeout_raw, jobs_raw = sys.argv[1:4]
ports = []
for tok in ports_raw.split(","):
    t = tok.strip()
    if not t:
        continue
    if not t.isdigit():
        raise SystemExit(f"✗ 非法端口：{t}")
    p = int(t)
    if not (1 <= p <= 65535):
        raise SystemExit(f"✗ 端口超范围：{p}")
    if p not in ports:
        ports.append(p)
if not ports:
    raise SystemExit("✗ 端口列表不能为空")
try:
    t = float(timeout_raw)
except ValueError:
    raise SystemExit(f"✗ 非法超时：{timeout_raw}")
if not math.isfinite(t) or t <= 0 or t > 60:
    raise SystemExit(f"✗ 超时需在 0-60 秒之间：{timeout_raw}")
try:
    j = int(jobs_raw)
except ValueError:
    raise SystemExit(f"✗ 非法并发数：{jobs_raw}")
j = max(1, min(64, j))
print(",".join(map(str, ports)))
print(str(t))
print(str(j))
PY
  ) || return 2
  PORTS="$(printf '%s\n' "$norm" | sed -n '1p')"
  TIMEOUT="$(printf '%s\n' "$norm" | sed -n '2p')"
  JOBS="$(printf '%s\n' "$norm" | sed -n '3p')"
}

need_tailscale() {
  command -v tailscale >/dev/null 2>&1 || { echo "本机没有 tailscale 命令" >&2; exit 1; }
}

build_ssh_opts() {
  SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [ -n "$SSH_PORT" ]; then
    SSH_OPTS+=(-p "$SSH_PORT")
  fi
  if [ -n "$SSH_KEY" ]; then
    SSH_KEY="$(expand_tilde "$SSH_KEY")"
    [ -f "$SSH_KEY" ] || { echo "✗ 找不到 SSH 私钥：$SSH_KEY" >&2; exit 2; }
    SSH_OPTS+=(-i "$SSH_KEY")
  fi
}

# 统一探测引擎（macOS / Linux 一致，不依赖 nc -G/-w 方言，并发探测 TCP 端口）
PY_PROBE_SCRIPT='
import concurrent.futures, json, socket, sys, time

ts_file, ports_raw, timeout_raw, jobs_raw, inc_offline_raw = sys.argv[1:6]
timeout = max(0.2, float(timeout_raw))
jobs = max(1, min(64, int(jobs_raw)))
include_offline = inc_offline_raw == "1"

ports = []
for token in ports_raw.split(","):
    token = token.strip()
    if not token:
        continue
    p = int(token)
    if not (1 <= p <= 65535):
        raise SystemExit(f"非法端口：{token}")
    if p not in ports:
        ports.append(p)
if not ports:
    raise SystemExit("端口列表不能为空")

data = json.load(open(ts_file, encoding="utf-8"))
peers_raw = list((data.get("Peer") or {}).values())

def pick_ip(peer):
    ips = peer.get("TailscaleIPs") or []
    for ip in ips:
        if ":" not in ip:
            return ip
    return ips[0] if ips else ""

nodes = []
for peer in sorted(peers_raw, key=lambda x: (x.get("HostName") or "").lower()):
    ip = pick_ip(peer)
    if not ip:
        continue
    nodes.append({
        "name": (peer.get("HostName") or ip).replace(" ", "_"),
        "ip": ip,
        "online": bool(peer.get("Online", True)),
        "tags": peer.get("Tags") or [],
    })

def probe(ip, port):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False

t0 = time.monotonic()
tasks = []
results = {}
for idx, node in enumerate(nodes):
    if not node["online"] and not include_offline:
        node["skipped"] = True
        node["ports"] = {}
        continue
    node["skipped"] = False
    node["ports"] = {}
    for port in ports:
        tasks.append((idx, port, node["ip"]))

if tasks:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(tasks))) as pool:
        futs = {pool.submit(probe, ip, port): (idx, port) for idx, port, ip in tasks}
        for fut in concurrent.futures.as_completed(futs):
            idx, port = futs[fut]
            results[(idx, port)] = fut.result()
    for idx, port, _ in tasks:
        nodes[idx]["ports"][str(port)] = results.get((idx, port), False)

elapsed = round(time.monotonic() - t0, 2)
out = {
    "ports": ports,
    "elapsed_seconds": elapsed,
    "total_peers": len(nodes),
    "probed_peers": sum(1 for n in nodes if not n["skipped"]),
    "skipped_offline": sum(1 for n in nodes if n["skipped"]),
    "nodes": nodes,
}
print(json.dumps(out, ensure_ascii=False))
'

render_matrix() {
  local source_label="$1" json_file="$2"
  if [ "$JSON_OUT" = "1" ]; then
    python3 - "$source_label" "$json_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[2], encoding="utf-8"))
d["source"] = sys.argv[1]
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  python3 - "$source_label" "$json_file" <<'PY'
import json, sys
source = sys.argv[1]
d = json.load(open(sys.argv[2], encoding="utf-8"))
ports = d["ports"]
print(f"来源: {source} | 端口: {','.join(map(str, ports))} | 耗时: {d['elapsed_seconds']}s | 探测 {d['probed_peers']} 台, 跳过离线 {d['skipped_offline']} 台")
print()
if not d["nodes"]:
    print("没有可测的目标（ACL 可能过滤了可见性）")
    raise SystemExit(0)
print(f"{'目标':<22} {'IP':<16} {'状态':<6} {'结果'}")
for n in d["nodes"]:
    st = "在线" if n["online"] else "离线"
    if n["skipped"]:
        res = "离线(跳过)"
    else:
        res = " ".join(f"{p}:{'通' if n['ports'].get(str(p)) else '-'}" for p in ports)
    print(f"{n['name'][:22]:<22} {n['ip']:<16} {st:<6} {res}")
print()
print("读法：隧道通（tailscale ping）+ 端口全不通 = ACL 在限；只有「通」的端口要逐个确认是什么服务。")
PY
}

check_acl_json() {
  python3 - "$1" <<'PY'
import json, sys
src_path = sys.argv[1]
raw = open(src_path, encoding="utf-8", errors="replace").read()
try:
    d = json.loads(raw)
except Exception:
    print("拿回来的不是 JSON：", raw[:200], file=sys.stderr)
    raise SystemExit(1)

acls = d.get("acls") or d.get("ACLs") or []
grants = d.get("grants") or []
wild_acls = [r for r in acls if "*" in (r.get("src") or []) and any("*" in str(x) for x in (r.get("dst") or []))]
wild_grants = [r for r in grants if "*" in (r.get("src") or []) and any("*" in str(x) for x in (r.get("dst") or []))]
wild = wild_acls + wild_grants

print(
    f"acls 条数: {len(acls)} | grants 条数: {len(grants)} | "
    f"含通配 src/dst 的规则: {len(wild)} | 有 ssh 段: {bool(d.get('ssh'))}"
)
if wild:
    print("⚠ 有全放开规则，重点审：", json.dumps(wild[:2], ensure_ascii=False)[:240])
PY
}

if [ "$SELF_TEST" = "1" ]; then
  bash -n "$0" || exit 1
  tmp_dir="$(mktemp -d)" || exit 1
  trap 'rm -rf "$tmp_dir"' EXIT

  # 0) 端口参数含空格规范化 + nan 超时拒绝 + expand_tilde
  PORTS="22, 445 , 22"
  normalize_probe_opts || exit 1
  [ "$PORTS" = "22,445" ] || { echo "✗ 端口规范化错误：$PORTS" >&2; exit 1; }
  TIMEOUT="nan"
  if normalize_probe_opts >/dev/null 2>&1; then
    echo "✗ --timeout nan 应被拒绝" >&2; exit 1
  fi
  TIMEOUT="2"
  t_exp="$(expand_tilde "~/.ssh/example key")"
  [ "$t_exp" = "$HOME/.ssh/example key" ] || { echo "✗ expand_tilde 错误：$t_exp" >&2; exit 1; }

  # 1) 真实回环 TCP 监听：1 个开放端口 + 1 个空闲关闭端口
  python3 - "$tmp_dir" "$PY_PROBE_SCRIPT" <<'PY' || exit 1
import json, os, socket, subprocess, sys

tmp_dir, probe_script = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
open_port = srv.getsockname()[1]

tmp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tmp_sock.bind(("127.0.0.1", 0))
closed_port = tmp_sock.getsockname()[1]
tmp_sock.close()

ts_mock = {
    "Self": {"HostName": "local-box", "TailscaleIPs": ["100.64.0.1"]},
    "Peer": {
        "p1": {"HostName": "loopback-node", "TailscaleIPs": ["127.0.0.1"], "Online": True, "Tags": ["tag:test"]},
        "p2": {"HostName": "offline-node", "TailscaleIPs": ["192.0.2.99"], "Online": False, "Tags": []},
    },
}
ts_path = os.path.join(tmp_dir, "ts.json")
with open(ts_path, "w", encoding="utf-8") as f:
    json.dump(ts_mock, f)

try:
    out = subprocess.check_output(
        [sys.executable, "-c", probe_script, ts_path, f"{open_port},{closed_port}", "0.5", "4", "0"],
        text=True,
    )
finally:
    srv.close()

res = json.loads(out)
assert res["total_peers"] == 2 and res["probed_peers"] == 1 and res["skipped_offline"] == 1
by_name = {n["name"]: n for n in res["nodes"]}
assert by_name["loopback-node"]["ports"][str(open_port)] is True
assert by_name["loopback-node"]["ports"][str(closed_port)] is False
assert by_name["offline-node"]["skipped"] is True

with open(os.path.join(tmp_dir, "matrix.json"), "w", encoding="utf-8") as f:
    f.write(out)
with open(os.path.join(tmp_dir, "acl.json"), "w", encoding="utf-8") as f:
    json.dump({
        "acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}],
        "grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]}],
    }, f)
print(f"self-test OK：并发探测（开放={open_port}/关闭={closed_port}）+ 离线跳过（耗时 {res['elapsed_seconds']}s）")
PY

  acl_out="$(check_acl_json "$tmp_dir/acl.json")" || exit 1
  printf '%s\n' "$acl_out" | grep -q '含通配 src/dst 的规则: 2' || { echo "✗ ACL 通配检测失败：$acl_out" >&2; exit 1; }
  mat_out="$(render_matrix "self-test" "$tmp_dir/matrix.json")" || exit 1
  printf '%s\n' "$mat_out" | grep -q '离线(跳过)' || { echo "✗ render_matrix 输出缺失离线跳过" >&2; exit 1; }

  # 2) 验证 acl 401 失败不会删掉原有快照，且拒绝目录作 --out
  mkdir -p "$tmp_dir/bin" "$tmp_dir/existing-dir"
  printf 'keep-me-existing-acl\n' > "$tmp_dir/existing-acl.json"
  cat > "$tmp_dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
out_file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out_file="$2"; shift 2; else shift; fi
done
printf '{"message":"unauthorized"}' > "$out_file"
printf '401'
STUB
  chmod +x "$tmp_dir/bin/curl"
  PATH="$tmp_dir/bin:$PATH" TS_API_KEY=dummy "$0" acl --out "$tmp_dir/existing-acl.json" >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "✗ acl 401 未返回非零" >&2; exit 1; }
  grep -q 'keep-me-existing-acl' "$tmp_dir/existing-acl.json" || { echo "✗ acl 失败误删或覆盖了旧快照" >&2; exit 1; }
  TS_API_KEY=dummy "$0" acl --out "$tmp_dir/existing-dir" >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "✗ acl --out 目录未拒绝" >&2; exit 1; }

  # 3) 验证远端 bash -s + <<'PYPROBE' 嵌套脚本拼装语法
  bash -s -- "22" "0.2" "4" "0" >/dev/null <<EOF || exit 1
if false; then
  cat <<'PYPROBE'
$PY_PROBE_SCRIPT
PYPROBE
fi
EOF
  exit 0
fi

case "$cmd" in
  status)
    need_tailscale
    tsjson="$(mktemp)" || exit 1
    trap 'rm -f "$tsjson"' EXIT
    tailscale status --json > "$tsjson" || exit 1
    if [ "$JSON_OUT" = "1" ]; then
      cat "$tsjson"
      exit 0
    fi
    python3 - "$tsjson" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
me = d.get("Self") or {}
print("本机 :", me.get("HostName", ""), (me.get("TailscaleIPs") or [""])[0],
      "tags=", me.get("Tags") or "无", "exit_node=", me.get("ExitNode"))
tn = d.get("CurrentTailnet") or {}
print("tailnet:", tn.get("Name"), "| MagicDNS:", tn.get("MagicDNSEnabled"))
peers = list((d.get("Peer") or {}).values())
print("设备数 :", len(peers) + 1)
print()
print("%-22s %-16s %-14s %-5s %-12s %s" % ("名称", "IP", "tags", "在线", "密钥到期", "子网路由"))
for p in sorted(peers, key=lambda x: (x.get("HostName") or "").lower()):
    exp = (p.get("KeyExpiry") or "")[:10] or "永不过期"
    routes = p.get("PrimaryRoutes") or []
    print("%-22s %-16s %-14s %-5s %-12s %s" % (
        (p.get("HostName") or "")[:22], (p.get("TailscaleIPs") or [""])[0],
        ",".join(p.get("Tags") or []) or "无", "是" if p.get("Online") else "否",
        exp, ",".join(routes) or "无"))
print()
print("要判断「谁能摸到谁」，别只看这张表：ACL 会过滤可见性，必须配合 matrix / from 实测。")
PY
    ;;

  matrix)
    normalize_probe_opts || exit 2
    need_tailscale
    tsjson="$(mktemp)" || exit 1
    outjson="$(mktemp)" || { rm -f "$tsjson"; exit 1; }
    trap 'rm -f "$tsjson" "$outjson"' EXIT
    tailscale status --json > "$tsjson" || exit 1
    python3 -c "$PY_PROBE_SCRIPT" "$tsjson" "$PORTS" "$TIMEOUT" "$JOBS" "$INCLUDE_OFFLINE" > "$outjson" || exit 1
    render_matrix "本机" "$outjson"
    ;;

  from)
    normalize_probe_opts || exit 2
    [ -n "$SSH_TARGET" ] || { echo "from 需要 --ssh user@host" >&2; exit 2; }
    build_ssh_opts
    rfile="$(mktemp)" || exit 1
    outjson="$(mktemp)" || { rm -f "$rfile"; exit 1; }
    trap 'rm -f "$rfile" "$outjson"' EXIT

    # 单次 SSH 完成：取 status + 远端并发探测；参数已本地校验为纯数字/逗号/小数点，无拆行或注入风险
    {
      cat <<'REMOTE_HEAD'
set -uo pipefail
command -v tailscale >/dev/null 2>&1 || { echo "目标机没有 tailscale 命令" >&2; exit 11; }
ts_tmp=$(mktemp)
trap 'rm -f "$ts_tmp"' EXIT
tailscale status --json > "$ts_tmp" || exit 12
if command -v python3 >/dev/null 2>&1; then
  python3 - "$ts_tmp" "$1" "$2" "$3" "$4" <<'PYPROBE'
REMOTE_HEAD
      printf '%s\n' "$PY_PROBE_SCRIPT"
      cat <<'REMOTE_TAIL'
PYPROBE
else
  echo "__NO_REMOTE_PY3__"
  cat "$ts_tmp"
fi
REMOTE_TAIL
    } | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash -s -- "$PORTS" "$TIMEOUT" "$JOBS" "$INCLUDE_OFFLINE" > "$rfile" || {
      echo "✗ 无法在 $SSH_TARGET 执行 tailscale 探测（检查 SSH 或 tailscale 状态）" >&2
      exit 1
    }

    if head -n 1 "$rfile" | grep -qx "__NO_REMOTE_PY3__"; then
      ts_fallback="$(mktemp)" || exit 1
      tlist="$(mktemp)" || { rm -f "$ts_fallback"; exit 1; }
      trap 'rm -f "$rfile" "$outjson" "$ts_fallback" "$tlist"' EXIT
      tail -n +2 "$rfile" > "$ts_fallback"
      python3 - "$ts_fallback" "$INCLUDE_OFFLINE" > "$tlist" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
inc = sys.argv[2] == "1"
for p in sorted((d.get("Peer") or {}).values(), key=lambda x: (x.get("HostName") or "").lower()):
    ips = p.get("TailscaleIPs") or []
    ip = next((x for x in ips if ":" not in x), ips[0] if ips else "")
    if not ip:
        continue
    online = 1 if p.get("Online", True) else 0
    if online or inc:
        print((p.get("HostName") or ip).replace(" ", "_"), ip, online)
PY
      # 单次 SSH 批量并发 /dev/tcp 兜底：先验 timeout 依赖，缺依赖直接失败避免全报关闭
      {
        printf 'PORTS=%s\nTIMEOUT=%s\nJOBS=%s\n' "$PORTS" "$TIMEOUT" "$JOBS"
        cat <<'FALLBACK_SH'
command -v timeout >/dev/null 2>&1 || { echo "远端既无 python3 也无 timeout，无法可靠探测端口" >&2; exit 13; }
run=0
while read -r name ip online; do
  [ -z "$ip" ] && continue
  for port in ${PORTS//,/ }; do
    (
      if timeout "$TIMEOUT" bash -c "echo > /dev/tcp/$ip/$port" >/dev/null 2>&1; then
        echo "$name|$ip|$online|$port|1"
      else
        echo "$name|$ip|$online|$port|0"
      fi
    ) &
    run=$((run + 1))
    if [ "$run" -ge "$JOBS" ]; then wait; run=0; fi
  done
done <<'NODES'
FALLBACK_SH
        cat "$tlist"
        printf 'NODES\nwait\n'
      } | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash -s > "$rfile" || {
        echo "✗ 远端无 python3 回退探测失败（检查远端是否缺少 timeout 或 bash /dev/tcp 支持）" >&2
        exit 1
      }
      python3 - "$rfile" "$ts_fallback" "$PORTS" "$INCLUDE_OFFLINE" > "$outjson" <<'PY' || exit 1
import json, sys
rows_file, ts_file, ports_raw, inc_raw = sys.argv[1:5]
ports = [int(p.strip()) for p in ports_raw.split(",") if p.strip()]
inc = inc_raw == "1"
ts = json.load(open(ts_file, encoding="utf-8"))
res_map = {}
for line in open(rows_file, encoding="utf-8"):
    parts = line.strip().split("|")
    if len(parts) == 5:
        res_map[(parts[0], parts[3])] = parts[4] == "1"
nodes = []
for p in sorted((ts.get("Peer") or {}).values(), key=lambda x: (x.get("HostName") or "").lower()):
    ips = p.get("TailscaleIPs") or []
    ip = next((x for x in ips if ":" not in x), ips[0] if ips else "")
    if not ip:
        continue
    name = (p.get("HostName") or ip).replace(" ", "_")
    online = bool(p.get("Online", True))
    skipped = (not online) and (not inc)
    pmap = {} if skipped else {str(pt): res_map.get((name, str(pt)), False) for pt in ports}
    nodes.append({"name": name, "ip": ip, "online": online, "skipped": skipped, "ports": pmap})
print(json.dumps({
    "ports": ports,
    "elapsed_seconds": 0,
    "total_peers": len(nodes),
    "probed_peers": sum(1 for n in nodes if not n["skipped"]),
    "skipped_offline": sum(1 for n in nodes if n["skipped"]),
    "nodes": nodes,
}, ensure_ascii=False))
PY
    else
      cp "$rfile" "$outjson" || exit 1
    fi

    render_matrix "$SSH_TARGET" "$outjson"
    ;;

  acl)
    [ -z "${TS_API_KEY:-}" ] && { echo "需要 TS_API_KEY（Tailscale 后台 → Settings → Keys，带 policy_file:read 读权限）" >&2; exit 2; }
    out="${OUT:-acl-$(date +%F).json}"
    [ ! -d "$out" ] || { echo "✗ --out 不能是目录：$out" >&2; exit 2; }
    out_dir="$(dirname "$out")"
    mkdir -p "$out_dir" || { echo "✗ 无法创建输出目录：$out_dir" >&2; exit 1; }
    tmp_out="$(mktemp "${out}.tmp.XXXXXX")" || exit 1
    trap 'rm -f "$tmp_out"' EXIT

    # 通过 stdin 传入 Authorization 头避免密钥进进程列表；先写临时文件，校验通过再原子替换
    http_code=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' "$TS_API_KEY" | \
      curl -sS -K - -w '%{http_code}' -o "$tmp_out" "https://api.tailscale.com/api/v2/tailnet/-/acl") || {
      echo "✗ 请求 Tailscale ACL API 失败" >&2; exit 1
    }
    if [ "$http_code" != "200" ]; then
      echo "✗ Tailscale API 返回 HTTP ${http_code}：$(head -c 200 "$tmp_out")" >&2
      exit 1
    fi
    acl_summary="$(check_acl_json "$tmp_out")" || exit 1
    [ ! -d "$out" ] || { echo "✗ --out 目标已是目录：$out" >&2; exit 1; }
    mv -f "$tmp_out" "$out" || { echo "✗ 保存快照失败：$out" >&2; exit 1; }
    echo "已保存: $out"
    printf '%s\n' "$acl_summary"
    ;;
esac
