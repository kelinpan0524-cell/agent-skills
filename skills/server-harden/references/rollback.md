# 回滚机制细节

## 为什么需要它

远程改 SSH 最常见的翻车：配置写错 → reload → 连接断开 → 再也进不去 → 只能开工单找机房。

本技能的做法：**先挂定时器，再改配置**。定时器在 5 分钟后无条件把备份还原并 reload sshd。改的人（或 agent）确认自己能登录之后，再执行 `--cancel-rollback` 取消定时器。

## 实现

脚本会在目标机加锁（`/run/sshd-harden.lockdir`），确认当前没有未完成的回滚事务后，按下面顺序执行：

1. **受保护备份**：在 `/etc/ssh/` 下创建 `600` 权限临时备份 `/etc/ssh/.01-hardening.bak.<随机>`（不在 `sshd_config.d/*.conf` 加载路径内），并把是否存在原文件与备份路径记录到 `/run/sshd-rollback.meta`（600）。
2. **挂 5 分钟自动还原**（`systemd-run --on-active=5min --unit=sshd-rollback`）：到期后按 `/etc/ssh/.01-hardening.bak.*` 原样还原（或删除新建的 `01-hardening.conf`），清理元文件、`sshd -t` 校验并重载 `ssh` / `sshd`。
3. **写新配置 → `sshd -t` 语法检查 → reload → 复查 `sshd -T`**；语法或重载失败会当场还原原配置并撤掉定时器。
4. **新终端登录验证**：必须用同用户、同端口、同私钥另开终端实测登录成功。
5. **确认取消**：执行 `--cancel-rollback`，脚本确认 `sshd-rollback.timer` 与 `sshd-rollback.service` 均已变为 `inactive` 后，才删除保护备份与 `/run/sshd-rollback.meta`；若停止或查询失败，备份保留、脚本报错退出。

## 失败与防重入保护

- **重复执行 `sshd-guard` 会被拒绝**：在 5 分钟回滚窗口尚未结束（或 `/run/sshd-rollback.meta` 仍存在）时再次执行会被拦截，避免用已加固配置覆盖原始基线。
- **配置语法错**：`sshd -t` 返回非零，脚本立刻还原原配置，不重载，连接不断。
- **reload 后新规则把你自己挡了**：什么都别做，5 分钟后定时器触发，配置回到原样，连接恢复。
- **机器重启**：transient unit 会丢失，所以改配置和验证应一气呵成，中间别重启。

## 不该用回滚兜底的场景

- 改防火墙（回滚定时器本身也要靠网络连上去取消，防火墙一错就全断）：改防火墙要人工逐条加放行再加拒绝。
- 改云安全组：那是控制台操作，脚本管不到。

## 验证回滚定时器是否存在

```bash
systemctl list-timers --all | grep sshd-rollback
systemctl is-active sshd-rollback.timer sshd-rollback.service
```
