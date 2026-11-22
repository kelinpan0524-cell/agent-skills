---
name: tailnet-audit
description: 审查 Tailscale 内网隔离与暴露面：跳过离线节点、单连接并发测端口可达性矩阵、查 ACL/grants 通配与 DERP 中继降级坑。不用于单机加固或代码审计。
version: 1.1.0
author: Kelin Pan, Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [安全, Tailscale, 内网, 可达性, NAS]
    related_skills: [server-audit, server-harden]
---

# Tailscale 内网审查

> `$SKILL_DIR` 指本技能目录，执行前先替换成实际路径（支持在任意工作区直接调用）。

回答一个具体问题：**某台机器（尤其是暴露在公网的那台）被攻破之后，攻击者能摸到内网里的哪些东西？**
方法是把「隧道层通不通」和「TCP 端口通不通」分开测，再看 ACL / grants 到底允许了什么。只看 `tailscale status` 是不够的——它只告诉你谁在线。

## When to Use

- 「香港/公网的服务器会不会危及整个内网」「谁能摸到 NAS」
- 加了新设备、新 tag、新服务之后复查，或监控经常走 DERP 掉线
- 要动 ACL 之前先留一份现状

不适用：单机加固（用 `server-harden`）、代码漏洞（SAST）。

## Prerequisites

- 本机装了 Tailscale 且已登录（`tailscale status` 有输出）。
- 读 ACL 需要后台权限：管理台人工查看，或带 `policy_file:read` 最小只读权限的 `TS_API_KEY`（用 `read -rsp` 读入，避免密钥留在命令历史）。
- 要测「从 A 能到 B 的哪些端口」，需要能 SSH 上 A（支持省略 `--key` 走 `~/.ssh/config` 别名）。

## How to Run

```bash
# 1) 本机视角的拓扑与在线状态（加 --json 输出原始 JSON）
bash "$SKILL_DIR/scripts/tailnet-recon.sh" status

# 2) 本机并发探测各在线节点端口（默认跳过离线节点，--timeout 2 --jobs 16）
bash "$SKILL_DIR/scripts/tailnet-recon.sh" matrix --ports 22,445,5000,8090,8123,5433

# 3) 从指定机器视角探测（单次 SSH 在远端并发探测，避免反复重连触发封禁）
bash "$SKILL_DIR/scripts/tailnet-recon.sh" from --ssh root@203.0.113.10 --ports 22,445,5433

# 4) 导出 ACL 快照并检查 acls / grants 通配规则（只读权限 policy_file:read，无回显读入避免进 history）
read -rsp "Tailscale API Key: " TS_API_KEY && export TS_API_KEY && echo
bash "$SKILL_DIR/scripts/tailnet-recon.sh" acl --out acl-$(date +%F).json
```

## Quick Reference

| 结论 | 判据 |
| --- | --- |
| 两台机器隔离 | 隧道层 ping 通，但目标端口全不通 |
| 完全不通 | `tailscale ping` 都不通（ACL 或路由问题） |
| 敞着 | 隧道通 + 端口通 + 服务无认证 |

**「ping 通但端口全不通」= ACL 在拦，不是机器防火墙**（机器防火墙挡不住自己的 0.0.0.0 监听，除非它按网卡过滤）。

## Procedure

1. **盘拓扑**：`status` 打出设备、tag、在线、密钥到期、是否有 exit node / 子网路由。完成标准：每台设备都能说出它属于哪个 tag。
2. **测可达性**：用 `from` 从「最危险的那台」（公网机器）出发测其他设备；若需要连离线节点历史占位也显式列出，可加 `--include-offline`。
3. **读 ACL**：拿 `acl` 快照，重点看 `acls` 与 `grants` 是否按 tag 写、有没有 `"*"` 通配、`ssh` 段是否放开、`tagOwners` 谁能打 tag。判据见 [ACL 要看的六件事](references/acl.md)。
4. **看端点**：对可达的每台机器，用 `server-audit` 看它开了哪些 0.0.0.0 服务。完成标准：每个「通」的端口都能说出是什么服务、要不要认证。
5. **出结论**：一句话回答「攻破 A 之后能到哪」，附可达性矩阵和 ACL 里的具体行。未验证的写清「没读到 ACL / 没测到 UDP」。

## Pitfalls

**云服务器 ufw 没放行 Tailscale 的 UDP 端口 → 只能走中继、监控反复掉线（实测坑）。**
症状：两端都显示在线，但对端路径长期是 `-` 或走 `DERP`；一边彻底不通一边能通；监控反复掉线。
根因：tailscaled 监听 UDP（`ss -ulnp | grep tailscaled` 查看，可在 `/etc/default/tailscaled` 固定 `PORT="41641"`），ufw 默认拦入站导致直连建不起。
判据与修法：`tailscale netcheck` DERP 正常但对端直连超时 → `ufw allow 41641/udp comment "tailscale direct"`（回滚：`ufw delete allow 41641/udp`），改完后 `tailscale ping` 变为直连 IP。

- **`tailscale status` 看不到不等于不存在**：ACL 可见性过滤会让部分节点互相不可见，以实测为准。
- **tag 化的设备容易被误放宽**、**机器上的 GitHub 密钥 / token 也能横向**——不要只盯端口。
- **别用 `tailscale up --reset` 修复网络**：会覆盖已有路由/DNS 配置。

## Verification

```bash
bash "$SKILL_DIR/scripts/tailnet-recon.sh" --self-test
```

对着真实 tailnet 跑一次，`status` 的设备数要和后台一致；可达性矩阵里至少抽取两格手工复核（`nc -z`）。

## References

- [ACL 要看的六件事](references/acl.md)
- [可达性矩阵怎么测、怎么读](references/reachability.md)
