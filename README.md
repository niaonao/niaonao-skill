# niaonao-skill

个人常用 Codex Skill 集合。每个 Skill 是一个独立目录，按 [Agent Skills](https://code.claude.com/docs/en/skills) 规范组织（`SKILL.md` + 可选 `scripts/`、`agents/`）。

## Skills

### disk-usage-excel

只读统计磁盘各层文件夹占用大小，并生成 Excel 分析报表。适合排查"我的 C 盘到底被什么占了"这类问题。

**工作流**：权限自检 → 递归统计实际大小 → 按父目录保留子目录 Top10 → 第一层 TopN（默认 2）深入展开至第 6 层 → 生成 Excel。

统计范围以 `-Root` 为第零层。第一层展示根目录下最大的 10 个文件夹；第二层对这些目录分别保留子目录 Top10；第三至第六层只沿第一层 TopN 的保留分支展开。Top10 是每个父目录的限制，不是整层合计只能有 10 行。

| 文件 | 说明 |
| --- | --- |
| `SKILL.md` | 约束、工作流、统计口径与踩坑记录 |
| `agents/openai.yaml` | 展示名与默认提示词 |
| `scripts/collect_sizes.ps1` | 只读统计各层目录大小，输出 JSON |
| `scripts/gen_excel.py` | JSON → 带样式 Excel（需 openpyxl） |

**环境**：Windows、PowerShell 5.1 或更新版本、Python 3 与 `openpyxl`。Agent 运行时需要完整文件读取权限；在 Codex 中可优先使用捆绑 Python。手动运行时，请在自己的 Python 环境准备 `openpyxl`。

**用法**（从仓库根目录执行，示例输出到 E 盘，请替换为实际的非统计盘路径）：

```powershell
New-Item -ItemType Directory -Path 'E:\disk-reports' -Force | Out-Null

# 扫描 C 盘；第一层 Top2 展开至第六层
powershell -NoProfile -ExecutionPolicy Bypass -File disk-usage-excel/scripts/collect_sizes.ps1 -Root 'C:\' -TopN 2 -OutJson 'E:\disk-reports\disk_sizes.json'

# 生成 Excel
python disk-usage-excel/scripts/gen_excel.py 'E:\disk-reports\disk_sizes.json' 'E:\disk-reports\disk_usage.xlsx'
```

**设计要点**：

- **全程只读**：扫描不清理文件。按 Skill 约束将 JSON 和 Excel 输出到非统计盘；请显式指定路径。脚本的自动路径回退和显式路径目前不会强制保证这一点，运行前需要确认。
- **父目录保留真实大小**：大小为全部子孙文件的逻辑长度之和，包含未进入 Top10 的子目录。父目录 `SizeBytes` ≥ 直接子目录 Top10 的 `SizeBytes` 合计。排序使用未舍入字节数，同大小按路径排序。
- **一次扫描复用结果**：缓存目录大小与子目录列表，避免后续展开时文件变化造成父子合计不一致。所有递归层级跳过 junction/symlink（ReparsePoint）。Top10 减少展示行数和展开分支，但仍需遍历全部子孙文件计算真实大小。
- **权限自检前置**：探测当前用户 `AppData\Local`、`Documents`、`Desktop`、`Downloads` 及目标盘的 `Users`、`Windows`。目录不存在或完全不可读时退出码为 2；读到 1–199 个文件只提示，不会单独中止。`-Force` 仅适用于明确接受不完整结果的情况。
- **全量交叉验证**：用 `Win32_LogicalDisk` 的已用容量与筛选前第一层全量合计比较。低于 60% 且已用容量大于 10 GB 时判 `suspicious-low`，超出 105% 判 `suspicious-high`；两者在 Excel 中生成完整性告警。交付前检查 JSON 的 `Validation`，非 `ok` 要说明限制。子目录扫描仍与整盘比较，此时该覆盖率不能代表目录扫描完整性。

**报表内容**：第一层、第二层、第三至第六层深度分析及汇总，共 7 个工作表；存在完整性异常时另加告警表。目录表包含路径、GB、文件数、实际字节数，深度分析另标注所属 Top 目录。GB 按 `1024³` 换算并保留两位小数，核对父子合计时以字节列为准。汇总保留第一层全量总大小和目录数，不对展示的 Top10 求和代替全量。

统计不包含根目录直接文件，也不等同于实际磁盘分配空间；硬链接、压缩文件及不可读系统目录等会造成与磁盘已用容量的差异。旧版 JSON 仍可生成 Excel，缺失的字节数列留空。

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
