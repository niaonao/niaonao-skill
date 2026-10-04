# niaonao-skill

个人常用 Codex Skill 集合。每个 Skill 是一个独立目录，按 [Agent Skills](https://code.claude.com/docs/en/skills) 规范组织（`SKILL.md` + 可选 `scripts/`、`agents/`）。

## Skills

### disk-usage-excel

只读统计磁盘各层文件夹占用大小，并生成 Excel 分析报表。适合排查"我的 C 盘到底被什么占了"这类问题。

**工作流**：权限自检 → 统计第 1~2 层 → 仅对占比前 N 的目录深入统计第 3~4 层 → 渲染 Excel。

| 文件 | 说明 |
| --- | --- |
| `SKILL.md` | 约束、工作流、统计口径与踩坑记录 |
| `agents/openai.yaml` | 展示名与默认提示词 |
| `scripts/collect_sizes.ps1` | 只读统计各层目录大小，输出 JSON |
| `scripts/gen_excel.py` | JSON → 带样式 Excel（需 openpyxl） |

**用法**：

```powershell
# 统计 C 盘（脚本自动挑选非 C 盘的输出目录并打印路径）
powershell -ExecutionPolicy Bypass -File scripts/collect_sizes.ps1 -Root 'C:\'

# 生成 Excel
python scripts/gen_excel.py '<上一步输出的 JSON 路径>'
```

**设计要点**：

- **全程只读**，禁止对被统计磁盘做任何写入/移动/删除；JSON 和 Excel 强制输出到非被统计盘。
- **权限自检前置**：多点探测 `AppData\Local`、`Documents`、`Desktop`、`C:\Users`、`C:\Windows`，任一读不到 200 个文件即以退出码 2 中止，避免受限权限下产出残缺报表。
- **交叉验证**：用 `Win32_LogicalDisk` 取该盘真实已用容量作基准，第一层合计覆盖率低于 60% 判`suspicious-low`，超 105% 判 `suspicious-high`，结果写入 JSON 的 `Validation` 字段并渲染成 Excel 的"数据完整性告警"表。**交付前必须看这个字段**，非 `ok` 不能当作有效结果。

### crawler-skill

JCrawler 爬虫相关的两个串联 Skill：

| 文件 | 说明 |
| --- | --- |
| `crawler-dev-SKILL.md` | 基于 Speedy 框架（Scrapy 二开）生成 `items.py` / `spider.py` / `task_queue.py` / `job.py` / `deployments.yml` |
| `crawler-recon-SKILL.md` | 用 Playwright MCP 抓目标平台 XHR，产出 SOP 文档交给 `crawler-dev` |

## 安装

把需要的 Skill 目录复制到 skills 目录即可：

```powershell
# Codex
Copy-Item -Recurse disk-usage-excel "$env:USERPROFILE\.codex\skills\"
# Claude Code
Copy-Item -Recurse disk-usage-excel "$env:USERPROFILE\.claude\skills\"
```

## License

[Apache License 2.0](LICENSE)
