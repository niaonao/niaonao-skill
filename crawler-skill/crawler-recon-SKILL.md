---
name: crawler-recon
description: 使用 Playwright MCP 抓取目标平台的 XHR/接口详情，并产出标准 SOP 文档供 crawler-dev 后续生成代码。当用户说"抓包"、"调研接口"、"recon"、"先看一下接口"、"把这个页面的 XHR 抓出来" 时使用。该 skill 与 crawler-dev 串联：本 skill 产出 SOP 文档，crawler-dev 读 SOP 文档生成爬虫代码。
---

# crawler-recon — JCrawler 抓包 & SOP 产出 Skill

## 1. 核心定位

为 JCrawler 项目的"新接口调研"环节服务。用 **Playwright MCP** 抓到目标平台的 XHR 完整请求/响应，再固化为标准格式的 SOP 文档（`doc/{platform}/{业务}_抓包记录与SOP.md`），下一步可直接交给 `/crawler-dev` 生成爬虫代码。

不写爬虫代码 — 那是 `crawler-dev` 的职责。

---

## 2. 执行顺序（不得跳步）

### Step 0：明确目标
向用户确认两件事（如已说清可跳过）：
- **平台 + 业务**：例如"京准通 / CID 订单明细"。决定 SOP 文档落地路径 `doc/{platform}/{业务}_抓包记录与SOP.md`。
- **筛选条件**：例如"昨日至昨日 + 投放平台=腾讯"。决定触发哪个 XHR。

### Step 1：进入登录页，等扫码
```
mcp__playwright__browser_navigate(url='<平台主域>')
```
- 浏览器是 persistent_context，cookie 会复用。如果已登录直接跳 Step 2。
- 如果是首次进入需要扫码，**主动告诉用户「请扫码登录，登录完成后回复继续」**，不要自己反复 snapshot 浪费上下文。

### Step 2：直接 navigate 到目标页面 hash 路由

**重要：不要 hover 顶部 mega-menu**。京准通这类 SPA 的菜单 hover 触发慢、容易拿不到弹层。

先在代码库里搜已知 URL：
```
Grep(pattern='https?://[^\\s\'\"]*<关键字>', path='sites/{project}', output_mode='content')
```
拿到正确的 hash 路由后直接 navigate：
```
mcp__playwright__browser_navigate(url='https://xxx/#/<目标>')
```

### Step 3：截图确认页面状态 + 默认筛选

```
mcp__playwright__browser_take_screenshot(filename='{业务}.png', fullPage=true)
```
确认两件事：
- 页面正确加载，是否需要切换 Tab
- 默认筛选条件是否就是用户要的；不是的话进 Step 4 调

### Step 4：通过 JS 触发查询 / 关闭新手蒙层

新手蒙层通配关闭脚本：
```js
() => {
  const btns = [...document.querySelectorAll('button, a, div, span')]
    .filter(el => ['完成','跳过','我知道了','下次再说'].includes(el.innerText.trim()));
  btns[0] && btns[0].click();
  return btns.length;
}
```

触发查询：
```js
() => {
  const btn = [...document.querySelectorAll('button')].find(b => b.innerText.trim() === '查询');
  btn && btn.click();
  return !!btn;
}
```

之后等待 2 秒：
```
mcp__playwright__browser_wait_for(time=2)
```

> 如果筛选项是 React 组件（下拉 / 日期），优先用 JS 直接派发事件，少用 `browser_click` + `browser_type` 组合（容易因渲染时机失败）。

### Step 5：列出 XHR，定位目标接口

```
mcp__playwright__browser_network_requests(static=false, filter='<业务关键词,如cid|order|callback>')
```
得到一组带序号的 XHR 列表。挑业务命中的那条记录序号 `N`。

### Step 6：拿请求/响应详情

三连击拿全：
```
mcp__playwright__browser_network_request(index=N, filename='{业务}_full.txt')          # headers
mcp__playwright__browser_network_request(index=N, part='request-body',  filename='{业务}_req.json')
mcp__playwright__browser_network_request(index=N, part='response-body', filename='{业务}_resp.json')
```
然后 `Read` 这三个文件，把内容固化进 SOP 文档（见 §4）。

如果有依赖接口（如平台 ID 字典），按同样方法多抓几条。

---

## 3. 避坑清单

| 坑 | 应对 |
|----|------|
| 域名打不开（cert 错） | 先在代码库 `Grep` 已知 URL，别瞎试 |
| 顶部 mega-menu hover 没反应 | 跳过菜单，直接 `browser_navigate` 到 hash 路由 |
| Headers 看不到 Cookie/Authorization | MCP 会脱敏；生产侧从 redis 注入（参考已有 spider 中的 `login_redis_client.hget('jd:jm_cookies', credential_id)`） |
| 子模块第一次进有蒙层挡住 | §4 蒙层通配 JS |
| 截图全黑/空 | 等待 2-15 秒，复杂 dashboard 用 `wait_for(time=15)` |
| 请求 ID（如 `platformList=[390]`）和响应 ID（如 `platform=8`）不一致 | 在 SOP §3 显式记录两套映射，入库取字符串字段 |

---

## 4. SOP 文档输出模板（固定 8 节）

文档路径：`doc/{platform}/{业务}_抓包记录与SOP.md`

```markdown
# {平台} {业务} - 抓包记录与 SOP

> 抓包日期：YYYY-MM-DD
> 抓包账号：xxx（账户 ID xxx）
> 用途：作为后续新增「xxx」相关爬虫的标准参考

## 1. 接口清单
| Tab/场景 | 业务含义 | 接口 |
|----------|---------|------|
| ... | ... | `POST https://...` |

辅助接口：
| 用途 | 接口 |
|-----|------|
| ... | ... |

## 2. 请求

### 2.1 通用 Headers
（贴出 content-type / referer / origin / language / cookie 来源说明）

### 2.2 请求体
```json
{ ... }
```
字段说明：
| 字段 | 含义 | 取值 |
|------|------|------|
| ... | ... | ... |

## 3. 枚举 ID 映射
来源接口：`xxx`
| ID | 名称 |
|----|------|
| ... | ... |

> 注意：请求 ID 与响应 ID 是否一致？

## 4. 响应结构
顶层：
```jsonc
{ "code": 1, "content": { "total": N, "data": [...] } }
```
行级字段：
| 字段 | 类型 | 说明 |
|------|------|------|
| ... | ... | ... |

## 5. 异常处理
按 CLAUDE.md，`code != 1` 必须 `raise Exception(f'credential_id: {id}, Err: {res}')`。

## 6. 抓包 SOP 脚本（自身复制，便于下次套用）
（贴 Step 1-6 的 MCP 调用片段）

## 7. 后续爬虫开发要点
- 项目：sites/{project}/
- 命名（按 CLAUDE.md）
- 队列、Item、Spider、Job 名约定
- UNIQUE_KEY 设计
- 分页策略

## 8. 建表 DDL
（占位 — 由 crawler-dev 在生成代码时回填）
```

**填写要求**：
- 字段表必须**全量列出**响应字段，不省略，否则下游 crawler-dev 会漏字段
- `2.2 请求体` 与 `4. 行级字段` 两个表是 crawler-dev 生成 Item / Spider 的核心依据
- §3 枚举映射可以省略仅当业务无 ID 字典

---

## 5. 临时产物清理（必做）

抓包过程中会在仓库产生临时文件，固化进 SOP 后**必须清理**：

| 类型 | 位置 | 处理 |
|------|------|------|
| MCP 截图 / snapshot | `.playwright-mcp/*.yml`、`.playwright-mcp/*.log` | 删除 |
| 抓到的 raw 请求/响应 | 项目根目录 `*_full.txt` / `*_request_body.json` / `*_response_body.json` | 关键内容已进 SOP，删除 |
| 截图 | 项目根目录 `*.png` | 关键截图可移入 `doc/{platform}/` 留作截图证据，其他删除 |

清理流程：
1. `git status` 列出未跟踪文件
2. 与 SOP 文档保留项对比，过滤出可删的临时产物
3. **告诉用户「将清理以下临时文件：xxx」，得到确认后再删**（避免误删用户已有文件）
4. 删除后再 `git status` 确认只剩 SOP 文档

---

## 6. 与 crawler-dev 串联

完成时打印一行：
```
SOP 文档已落地：doc/{platform}/{业务}_抓包记录与SOP.md
下一步可用 /crawler-dev 让其读该文件生成爬虫代码。
```

crawler-dev skill 的 Step 1 「读需求文档」天然支持 SOP 文档作为输入，无需任何改动。

---

## 7. CheckList（结束前自检）

- [ ] §1 接口清单：URL/method/业务含义齐全
- [ ] §2.1 通用 Headers 已记录（含 cookie 来源说明）
- [ ] §2.2 请求体每个字段都有含义说明
- [ ] §3 枚举 ID 映射收集完整（如业务涉及）
- [ ] §4 响应字段**全量**列出，不省略
- [ ] §5 异常处理段落明确 `raise Exception` 格式
- [ ] §6 SOP 脚本快照已复制（让下次抓类似页面可直接套）
- [ ] §7 后续爬虫开发要点已写：命名、UNIQUE_KEY、分页策略
- [ ] §8 留 DDL 占位（标注「由 crawler-dev 回填」）
- [ ] 临时产物已清理（用户确认后）
- [ ] 文档路径符合 `doc/{platform}/{业务}_抓包记录与SOP.md`
