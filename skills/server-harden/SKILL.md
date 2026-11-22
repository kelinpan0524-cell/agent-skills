---
name: server-harden
description: 按审计报告逐项加固 Linux 服务器（fail2ban、自动安全更新、SSH 禁密码），每步可回滚；改 SSH 先查可用公钥并挂 5 分钟自动还原。不用于无审计盲改或自动改防火墙。
version: 1.1.0
author: Kelin Pan, Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [安全, 加固, 回滚, SSH, Linux]
    related_skills: [server-audit, tailnet-audit]
---

# 服务器加固（每步可回滚）

> `$SKILL_DIR` 指本技能目录，执行前先替换成实际路径（支持在任意工作区直接调用）。

只做审计报告里已经点名的项，一次一项，每项都有回滚路径。改 SSH 之前会先核对目标机已有登录公钥，再挂 5 分钟自动还原定时器——即使改错失联，机器也会自己回到能登录的状态。

## When to Use

- `server-audit` 出了报告，要按 P0/P1 逐条处理
- 新机器上线前的基线加固
- 「远程改配置怕把自己锁在外面」——这正是本技能存在的理由

不适用：没有审计报告就上来改（先审后改）；生产窗口没确认就重启（先要窗口）；自动改 UFW 防火墙（见下方说明）。

## Prerequisites

- 目标机 SSH 可达，且**当前这条连接是通的**（改之前先确认；支持省略 `--key` 直接走 `~/.ssh/config` 别名）。
- 建议同时开两个终端：一个跑命令，一个留着验证能否重新登录。
- 拥有 root 权限。

## How to Run

```bash
# 只看要做什么，不动手
bash "$SKILL_DIR/scripts/harden.sh" --host root@192.0.2.10 --key ~/.ssh/deploy --check

# 逐项执行（一次一项，跑完验证再下一项；支持省略 --key / 指定 --port）
bash "$SKILL_DIR/scripts/harden.sh" --host root@192.0.2.10 --apply fail2ban
bash "$SKILL_DIR/scripts/harden.sh" --host root@192.0.2.10 --apply autoupdate
bash "$SKILL_DIR/scripts/harden.sh" --host root@192.0.2.10 --apply sshd-guard --yes

# 新终端确认能正常 SSH 登录后，取消 5 分钟回滚定时器并清临时备份
bash "$SKILL_DIR/scripts/harden.sh" --host root@192.0.2.10 --cancel-rollback
```

## Quick Reference

| 动作 | 改什么 | 回滚 |
| --- | --- | --- |
| `fail2ban` | 安装并启用 sshd jail | `apt purge fail2ban` |
| `autoupdate` | 只开 security 源自动更新 | 改回 `/etc/apt/apt.conf.d/20auto-upgrades` |
| `sshd-guard` | 核查公钥后写 `01-hardening.conf` 并校验 `sshd -T` | **5 分钟后自动还原**，或 `--cancel-rollback` |

## Procedure

1. **确认现状**：`--check` 打印主机、公钥数量与待改动作。完成标准：已有公钥 >= 1，且没有不想动的项。
2. **留后路**：另开一个终端保持登录；确认有云控制台救援入口。
3. **执行单项**：一条命令只做一件事。`sshd-guard` 必须显式加 `--yes`。
4. **立刻验证**：新开一个终端真的 ssh 一次（不是看日志），并留意脚本打印的 `sshd -T` 最终生效值。
5. **取消回滚**：确认新登录通了再跑 `--cancel-rollback`，确认定时器计数归 0。
6. **记录**：把改了什么、怎么回滚写进当次报告。

## Pitfalls

- **不许批量刷**：一次一项。批量失败时你不知道是哪一步把门锁了。
- **drop-in 覆盖陷阱**：云镜像常见 `50-cloud-init.conf` 或 `00-*.conf` 盖住 `01-hardening.conf`，脚本重载后会复查 `sshd -T` 并告警，看到告警务必手动处理。
- **脚本故意不自动改 UFW**：防火墙一改错会连回滚通路一起断，UFW 规则请对照参考文档人工逐条执行。
- **换端口先改安全组**：不要为了「安全」把 SSH 端口改成别的却忘了先放行安全组和监控。

## Verification

```bash
bash "$SKILL_DIR/scripts/harden.sh" --self-test
```

每项改完的验证命令由脚本打印；对不上就是没生效，别往下走。

## References

- [回滚机制细节](references/rollback.md)
- [各项改动的完整命令](references/playbook.md)
