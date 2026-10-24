# agent-skills

我的 AI 助手技能仓库，一个仓库管所有技能，按需装、按需更。

每个技能都是「短入口 + 按需加载的参考 + 可直接跑的脚本」，符合渐进式披露：`SKILL.md` 只讲什么时候用、按什么顺序做、哪些不能做，细节拆进 `references/`。

## 里面有什么

| 技能 | 干什么 | 会不会改东西 |
| --- | --- | --- |
| `contract-redact` | 中文合同本地脱敏，换代号给 AI 审，或掩码对外发 | 只处理你给的副本 |
| `server-audit` | 只读审查一台 Linux 服务器的安全面，出分级报告 | 不改，只读 |
| `server-harden` | 按报告逐项改，每步可回滚，改 SSH 前挂 5 分钟自动还原 | 改，可回滚 |
| `tailnet-audit` | Tailscale 内网的谁能摸到谁，出可达性矩阵 | 不改，只读 |

## 装

```bash
git clone git@github.com:kelinpan0524-cell/agent-skills.git
cd agent-skills

./install.sh --list                 # 看有哪些
./install.sh contract-redact        # 只装一个（软链到 ~/.hermes/skills）
./install.sh --all                  # 全装
./install.sh --target ~/.claude/skills --all   # 装给 Claude Code
```

用软链装：以后在这个仓库里改技能，本机立刻生效，不会出现「仓库一份、本机一份」两套。

只想要某几个技能的文件、不想整仓 clone：

```bash
git clone --filter=blob:none --sparse git@github.com:kelinpan0524-cell/agent-skills.git
cd agent-skills
git sparse-checkout set skills/contract-redact skills/tailnet-audit
```

## 更

```bash
git pull                            # 全量更新（都是纯文本，秒完）
./install.sh --all                  # 软链是活的，这步通常不需要
```

要「只更新某个技能」其实不用特意做——一个技能就几百 KB，全量 `git pull` 比手工挑快。真正值得挑的是**装哪些**，那由 `install.sh` 决定。

## 自检

```bash
bash tests/smoke.sh          # 语法 + 内置样例 + 文档规范
```

`tests/check_skill.py` 查四件事：frontmatter 六个字段齐不齐、description 有没有超长、`SKILL.md` 有没有超 200 行、正文里的相对链接能不能打开。

## 约定

- 一个技能一个目录，目录名 = `name` 字段。
- `SKILL.md` 不超过 200 行；超了就把细节挪进 `references/`。
- 脚本要么只读，要么每步都能回滚；会改东西的技能必须在 `SKILL.md` 里写清回滚方法。
- 不放真实密钥、客户名单、内网地址；这些走各自的私有配置。

## 许可

MIT。
