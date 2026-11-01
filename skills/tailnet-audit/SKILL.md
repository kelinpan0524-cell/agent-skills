---
name: tailnet-audit
description: 审查 Tailscale 内网的分段与暴露面：谁能摸到谁、tag 权限、NAS 服务，出可达性矩阵。
version: 1.0.0
author: Kelin Pan, Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [安全, Tailscale, 内网, 可达性, NAS]
    related_skills: [server-audit, server-harden]
---

# Tailscale 内网审查

回答一个具体问题：**某台机器（尤其是暴露在公网的那台）被攻破之后，攻击者能摸到内网里的哪些东西？**
方法是把「隧道层通不通」和「TCP 端口通不通」分开测，再看 ACL 到底允许了什么。只看 `tailscale status` 是不够的——它只告诉你谁在线。

## When to Use

- 「香港/公网的服务器会不会危及整个内网」
- 加了新设备、新 tag、新 NAS 服务之后复查
- 定期体检（建议每月一次，跟 `server-audit` 一起）
- 要动 ACL 之前先留一份现状

不适用：单机加固（用 `server-harden`）、代码漏洞（SAST）。

## Prerequisites

- 本机装了 Tailscale 且已登录（`tailscale status` 有输出）。
- 读 ACL 需要后台权限：`login.tailscale.com/admin/acls`（人工登录，或用有 `policy_file` 权限的 API token）。
- 要测「从 A 能到 B 的哪些端口」，需要能 SSH 上 A。

## How to Run

```bash
# 1) 本机视角的拓扑与在线状态
scripts/tailnet-recon.sh status

# 2) 从本机测到各节点的端口可达性（默认只测 22）
scripts/tailnet-recon.sh matrix --ports 22,445,5000,8090,8123,5433

# 3) 从指定机器视角测（关键：判断公网机能不能横向）
scripts/tailnet-recon.sh from --ssh root@203.0.113.10 --key ~/.ssh/deploy --ports 22,445,5433

# 4) 导出 ACL 快照留档（需要 API token）
TS_API_KEY=tskey-api-xxx scripts/tailnet-recon.sh acl --out acl-$(date +%F).json
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
2. **测可达性**：从「最危险的那台」（公网机器）出发测其他设备。完成标准：矩阵里每一格都有「通/不通」，不漏。
3. **读 ACL**：拿 `acl` 快照，重点看 `grants` 是否按 tag 写、有没有 `"*"` 通配、`ssh` 段是否放开、`tagOwners` 谁能打 tag。判据见 [ACL 清单](references/acl.md)。
4. **看端点**：对可达的每台机器，用 `server-audit` 看它开了哪些 0.0.0.0 服务。完成标准：每个「通」的端口都能说出是什么服务、要不要认证。
5. **出结论**：一句话回答「攻破 A 之后能到哪」，附可达性矩阵和 ACL 里的具体行。未验证的写清「没读到 ACL / 没测到 UDP」。

## Pitfalls

**云服务器 ufw 没放行 Tailscale 的 UDP 端口 → 只能走中继、监控反复掉线（2026-11-01 实测）。**
症状：两端 `tailscale status` 都显示在线，但对端那栏是 `-`（没有任何路径）；一方到另一方 TCP 完全不通，反向 `tailscale ping` 又能通；Beszel 面板上一会儿在线一会儿离线，最后彻底 down。
根因：tailscaled 监听 UDP（端口见 `ss -ulnp | grep tailscaled`，可在 `/etc/default/tailscaled` 用 `PORT="41641"` 固定），而 ufw 默认拒绝入站 → 直连建不起来，只能靠 DERP 中继，中继不稳就断。**Tailscale 本身不上线也能显示"在线"**，所以只看 `tailscale status` 永远查不出这个问题。
判据：`ufw status verbose` 里没有对应 UDP 端口的 ALLOW；`tailscale netcheck` 的 DERP 延迟正常（说明出站没事）但对端 ping 超时；放行后 `tailscale ping` 立刻从 `via DERP` 变成 `via <公网IP>:端口`。
修法：`ufw allow 41641/udp comment "tailscale direct"`（端口以实测为准），只放加密的 WireGuard 流量，ACL 照样管谁能连谁。回滚：`ufw delete allow 41641/udp`。

- **`tailscale status` 看不到不等于不存在**：ACL 的可见性过滤会让某些节点彼此不可见；以 ping 和端口实测为准。
- **ping 通只说明隧道层**，不代表任何 TCP 端口可访问；反过来端口不通也不代表安全（UDP 服务可能通，DERP 中继也可能被滥用）。
- **tag 化的设备更容易被放宽**：`tag:cloud` 这种常被写成「允许访问所有」；重点审。
- **凭据不在 tailnet 里也能横向**：机器上的 GitHub 部署私钥、CI token 是另一条路，必须单独列一条风险。
- **别用 `tailscale up --reset` 之类命令「修复」网络**：会改路由配置，属于改线上。

## Verification

```bash
bash tests/smoke.sh
python3 tests/check_skill.py skills/tailnet-audit
```

对着真实 tailnet 跑一次，`status` 的设备数要和后台一致；可达性矩阵里至少抽取两格手工复核（`nc -z`）。

## References

- [ACL 要看的六件事](references/acl.md)
- [可达性矩阵怎么测、怎么读](references/reachability.md)
