---
name: contract-redact
description: 中文合同本地脱敏：换可还原代号发 AI 审（支持 docx/doc/pdf/xlsx/扫描件 OCR），或打星掩码对外发送，含残留自检。不用于仅本机自阅或已外发文件。
version: 1.1.0
author: Kelin Pan (kelinpan0524-cell), Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [脱敏, 合同, 隐私, 中文, 可逆]
    related_skills: []
---

# 中文合同脱敏

> `$SKILL_DIR` 指本技能目录，执行配套脚本前先替换成实际路径。

把中文合同里「能指认是谁」的信息在**本机**换成代号，再把代号版交给 AI 审查；映射表留在本地，审完换回来。
纯规则引擎（正则 + 校验位 + 词表），不联网、不调模型。支持 docx / doc / pdf / xlsx / md / txt，扫描件走 OCR。

不负责：手写签名、盖章、图片里的字、附件与嵌入对象。也不保证遮干净——见 [已知限制](references/limits.md)。

## When to Use

- 「这份要**发外审**」「发给 AI 看看」「帮我审一下这合同」→ 可逆模式（默认）
- 「这份**发给客户**」「对外发」「给供应商看」→ 掩码模式（`--mask-only`）
- 「脱敏一下」「别把客户名带出去」「把手机号遮掉」

不适用：只在本机自己看、不出门；文件已经发出去过（直接提醒风险，别再脱敏）。

## Prerequisites

1. **先体检本机环境**（1 秒只读，确认命令行、Python、OCR 是否就绪）：

```bash
bash "$SKILL_DIR/scripts/doctor.sh"
```

2. **未安装命令行时**，从独立代码仓安装（二选一）：

- 日常使用（推荐）：`pipx install git+https://github.com/kelinpan0524-cell/contract-redact`
- 含扫描件 OCR：`pipx install "contract-redact[ocr] @ git+https://github.com/kelinpan0524-cell/contract-redact"`
- 无 `pipx` 时：克隆 `kelinpan0524-cell/contract-redact` 后在虚拟环境里用 `python3 redact_cli.py` 替代下文 `contract-redact`。

## How to Run

子命令只有四个：`redact`（脱敏）、`restore`（还原）、`check`（自检）、`serve`（本地服务）。

```bash
# 可逆：代号版 + 映射表
contract-redact redact 合同.docx -o 合同_脱敏.docx
contract-redact restore 合同_脱敏.docx --map 合同_脱敏.map.json -o 合同_还原.docx

# 掩码：留首尾打星，不生成映射表
contract-redact redact 合同.pdf -o 合同_对外.pdf --mask-only

# 带客户/供应商名单，并给映射表加密
contract-redact redact 合同.docx -o 合同_脱敏.docx --config vocab.json --passphrase '口令'

# 自检（脱敏之后必跑）：0=干净，2=有残留或未检完，1=跑不起来
contract-redact check 合同_脱敏.docx

# 本地服务：给别的程序调用，规则没加载好就拒绝返回，不发原文
contract-redact serve --port 8791
```

## Quick Reference

| 需求 | 参数 |
| --- | --- |
| 只遮 / 跳过某几类 | `--only phone,id,password` / `--skip address,person` |
| 不可逆掩码 | `--mask-only` |
| 映射表口令 | `--passphrase '口令'`，或环境变量 `CONTRACT_REDACT_PASSPHRASE` |
| 补充词表 / 候选回收 | `--config vocab.json` / `--candidates 候选.json` |
| 不写审计 / 记账 JSON | `--no-audit` / `--audit-json 审计.json` |
| 指定 OCR / 跳过图片 OCR | `--ocr-engine vision\|rapidocr` / `check --no-ocr` |
| 自检退出码 | 0 干净 / 2 有残留或未能自检 / 1 跑不起来 |

## Procedure

1. **查环境**：首次跑先执行 `bash "$SKILL_DIR/scripts/doctor.sh"`，缺命令行先引导安装。
2. **选模式**：要还原→默认；对外不回收→`--mask-only`。完成标准：能一句话说清这版能不能还原。
3. **确认格式**：docx/doc/pdf/xlsx/md/txt 直接跑；扫描件先说明「走 OCR，版式会变」。
4. **跑脱敏**：结束会打印命中统计；一处都没命中要当异常查（可能格式或规则没吃到）。
5. **跑自检**：`contract-redact check 脱敏件`。退出码 2 或 1 **一律不许外发**，先回去补规则或人工遮。
6. **人工复核**：转述批注/修订/页眉页脚提醒；让用户搜甲乙方真名、法人、手机号，看签名栏、附件和图片，确认「可以发」。
7. **交付与还原**：只发脱敏件；映射表和候选词文件留本机。还原后核对恢复报告。

## Pitfalls

- **映射表和候选词文件就是原文**：`*.map.json`、`*.candidates.json` 权限 600，不进 docx、不上传、不贴进对话。
- **掩码模式不可逆**：别承诺能还原，也别生成映射表。
- **OCR 会认错数字**：扫描件的金额、账号必须肉眼核对；没有 OCR 引擎时 PDF `check` 会退出 2（未查完 ≠ 干净）。
- **简称与全称**：词表有「星海」时会自动扩成完整主体，同音字或拼音进候选清单人工确认；金额/单价/比例/条款号默认不动。
- **自检不是绝对安全证明**：规则认不出的（无标签姓名、拼音、图片里的字）它也查不出；`serve` 只许监听本机。

## Verification

```bash
bash "$SKILL_DIR/scripts/doctor.sh" --self-test
contract-redact check 脱敏件.docx          # 真实交付前必跑，期望退出码 0
```

## References

- [两种模式与参数](references/modes.md) — 可逆 / 掩码、规则开关、口令、审计
- [格式与 OCR](references/formats.md) — 各格式行为、扫描件、跨平台差异
- [客户与供应商名单](references/wordlist.md) — 同步、别名、包含式扩展、候选回收
- [已知限制与复核清单](references/limits.md) — 会漏什么、外发前必须看什么
