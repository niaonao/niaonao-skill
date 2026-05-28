---
name: crawler-dev
description: 基于 Speedy 框架（Scrapy 二次开发）开发或维护 JCrawler 爬虫项目。根据需求文档或 API 接口信息，生成符合规范的 items.py、spider.py、task_queue.py、job.py、deployments.yml 完整代码结构。
---

# JCrawler 爬虫开发 Skill 定义

## 1. 核心定位

本 Skill 专为基于 **Speedy** 框架（Scrapy 二开）的 JCrawler 项目设计。涵盖从需求分析、数据库设计、编码实现到线上部署的全生命周期研发。

---

## 2. 开发执行顺序（必须按此顺序）

拿到需求后，严格按以下步骤执行，**不得跳步**：

### Step 1：读需求文档
- 读取 `doc/{platform}/xxx.md`，提取：API URL、cURL Headers、请求参数、响应字段、业务逻辑
- 确认目标项目（`sites/{project}/`）和平台前缀

### Step 2：读参考爬虫
- 在同项目 `sites/{project}/spiders/` 中找一个结构相似的现有 spider 读取，理解项目的：
  - Cookie/Token 获取方式
  - 公共 Headers 来源（`utils/common.py`）
  - 签名生成方法（如 `get_h5st`、`get_user_mnp`）
- 读取 `sites/{project}/items.py` 了解 `BaseItem` 定义和 `session` 对象
- 读取 `sites/{project}/task_queues/__init__.py` 了解 Redis db 配置

### Step 3：生成代码（按顺序）

| 序号 | 文件 | 说明 |
|------|------|------|
| 1 | DDL 建表语句 | 优先输出，若需求文档缺失则回写至文档末尾 |
| 2 | `sites/{project}/items.py` | 追加新 Item 定义 |
| 3 | `sites/{project}/task_queues/{spider}.py` | 新建队列配置文件 |
| 4 | `sites/{project}/spiders/{spider}.py` | 新建 spider 文件 |
| 5 | `sites/{project}/jobs/add_task.py` | 追加 Job 方法 |
| 6 | `sites/{project}/deployments.yml` | 追加 services/jobs/check_dlq_jobs 配置 |

### Step 4：自检输出 CheckList（见第 5 节）

---

## 3. 各文件开发规范

### 3.1 建表规范（DDL）

```sql
CREATE TABLE `{table_name}` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `credential_id` int DEFAULT NULL COMMENT '账号ID',
  `item_filter_date` date DEFAULT NULL COMMENT '筛选日期（业务日期）',
  -- 业务字段（一律 VARCHAR，保留原始值）
  `field_name` varchar(255) DEFAULT NULL COMMENT '字段说明',
  `bd_create_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `bd_update_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_xxx` (`credential_id`, `item_filter_date`, `sku_id`) USING BTREE,
  KEY `idx_bd_update_time` (`bd_update_time`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

**规则**：
- 主键必须是 `id BIGINT AUTO_INCREMENT`
- 必备字段：`credential_id`、`item_filter_date`、`bd_create_time`、`bd_update_time`
- 业务字段全部用 `VARCHAR`，不做数值转换，保留原始区间值（如 `"10.0 ~ 25.0"`）
- 只建两个索引：`bd_update_time` 和唯一键

---

### 3.2 Item 定义（`items.py`）

在现有文件中**追加**新 Item 类，继承项目的 `BaseItem`：

```python
class XxxItem(BaseItem):
    session = mysql_crawL_db_session  # 根据项目选择 session

    TABLE = '{table_name}'
    MODE = speedy.ItemMode.REPLACE
    UNIQUE_KEY = ['credential_id', 'item_filter_date', 'sku_id']

    field_name = speedy.StringField(max_length=255, comment='字段说明')
```

---

### 3.3 任务队列（`task_queues/{spider}.py`）

新建文件，队列名与 spider 名一致：

```python
GROUPS_SETTINGS = {
    'name': '{queue_name}',
    # 'priority_list': [0, 1, 2],  # 优先级列表，默认 [0]
    # 'rate': 10,                   # 每秒并发数
    # 'ack_timeout': 180000,        # ack 超时（ms）
    # 'max_retry': 5,               # 最大重试次数
}
```

`task_queues/__init__.py` 中的 `TaskQueueManager.find_settings` 会自动发现该文件，**无需手动注册**。

---

### 3.4 Spider 文件（`spiders/{spider}.py`）

#### 3.4.1 完整文件结构模板

```python
import json

from sites.{project}.items import XxxItem
from sites.{project}.settings import BASE_SETTINGS
from sites.{project}.task_queues import task_queue_manager
from sites.{project}.utils.common import common_headers
from sites.login.task_queues import redis_client as login_redis_client
from speedy import SimpleSpider, SpiderRunner


class XxxSpider(SimpleSpider):
    task_queue_manager = task_queue_manager  # 必须声明，不可省略
    name = '{project}_{platform}_{function}'
    task_queue_group = '{queue_name}'

    url = 'https://...'

    def debug_task(self):
        body = {
            'credential_id': 451,
            'filter_date': '2026-03-01',
        }
        return {'body': body}

    def start_task(self, task):
        task_body = task['body']
        credential_id = task_body['credential_id']

        cookie_str = login_redis_client.hget('jd:jm_cookies', credential_id)
        if not cookie_str:
            raise Exception(f'credential_id: {credential_id} cookie 为空')

        headers = common_headers.copy()
        headers['cookie'] = cookie_str

        yield self.Request(url=self.url, headers=headers)

    def parse(self, response):
        task = response.meta['task']
        task_body = task['body']
        credential_id = task_body['credential_id']

        res_dic = json.loads(response.text)
        if res_dic.get('code') != 0:
            raise Exception(f'credential_id: {credential_id}, Err: {res_dic}')

        for item in res_dic['data']['list']:
            update_info = {
                'credential_id': credential_id,
                'field_name': item.get('fieldName'),
            }
            yield XxxItem(update_info)


BASE_SETTINGS['DEBUG'] = False  # 生产环境关闭 DEBUG
runner = SpiderRunner(XxxSpider, BASE_SETTINGS)

if __name__ == '__main__':
    runner.run()
```

#### 3.4.2 多阶段抓取（`next_spider` 模式）

适用于「先获取列表，再遍历抓取详情」等场景：

```python
def start_task(self, task):
    task_body = task['body']
    next_spider = task_body.get('next_spider')

    if not next_spider:
        yield self.Request(url=self.list_url, headers=headers)
    elif next_spider == 'detail':
        yield self.Request(url=self.detail_url, headers=headers, callback=self.parse_detail)

def parse(self, response):
    # 解析列表，发送子任务
    for item in data_list:
        sub_body = task_body.copy()
        sub_body.update({'next_spider': 'detail', 'item_id': item['id']})
        yield self.Task(1, sub_body)  # 子任务优先级高于父任务

def parse_detail(self, response):
    # 解析详情，入库
    yield XxxItem({...})
```

**优先级设计原则**：数字越大越先处理；链路越深优先级越高，确保深度优先消费。

#### 3.4.3 延迟任务

```python
# 延迟 3 分钟后再消费（单位 ms）
yield self.Task(1, task_body_copy, delay=3 * 60 * 1000)
```

#### 3.4.4 读取重试次数

```python
retry_count = task.get('meta', {}).get('retry', 0)
```

#### 3.4.5 分页处理

- `page` 参数必须维护在 `task_body` 中
- 第 1 页解析完成后，根据 `total` 计算总页数，动态 `yield self.Task` 剩余页（优先级建议 3）

---

### 3.5 Job 文件（`jobs/add_task.py`）

**同一项目的所有 Job 方法集中在一个 Job 类中**，新需求追加静态方法：

```python
import time

from sites.{project}.task_queues import task_queue_manager
from sites.login.utils.common import get_platform_user_info
from speedy import Job
from utils.common import get_past_datetime_str


class {Project}Job(Job):
    name = '{project}'

    @staticmethod
    def add_{queue_name}_task():
        my_group = task_queue_manager.get('{queue_name}')
        filter_date = get_past_datetime_str(days_ago=1, fmt='%Y-%m-%d')
        account_list = get_platform_user_info([1])  # platform_id 列表
        for account_item in account_list:
            body = {
                'credential_id': account_item['credential_id'],
                'username': account_item['username'],
                'filter_date': filter_date,
                'datetime': time.strftime('%Y-%m-%d %H:%M:%S', time.localtime()),
            }
            my_group.publish(0, body)
        print(f'filter_date: {filter_date} 任务发布成功~')


if __name__ == '__main__':
    {Project}Job().run()
```

---

### 3.6 部署配置（`deployments.yml`）

在现有文件中**追加**对应配置段：

```yaml
# services 段追加
- name: {queue_name}
  replicas: 1
  spider: sites.{project}.spiders.{spider}

# jobs 段追加
- name: add_{queue_name}_task
  timeout: 5m
  retry: 3
  cron: '0 7 * * *'
  script: sites.{project}.jobs.add_task add_{queue_name}_task

# check_dlq_jobs 段追加（DLQ 监控，必须配置）
- spider: sites.{project}.spiders.{spider}
  cron: '30 9 * * *'
  informs: 'zyn'  # 告警接收人

# auto_revive_jobs 段追加（可选，长期运行的 spider 需配置）
- spider: sites.{project}.spiders.{spider}
  cron: '35,55 7-9 * * *'
```

---

## 4. Playwright 浏览器自动化开发

**适用场景**：监控截图、动态页面数据抓取、需要模拟真实用户操作的场景

### 4.1 反检测配置（核心）

```python
context = p.chromium.launch_persistent_context(
    user_data_dir=os.path.join(os.path.expanduser("~"), "playwright_user_data"),
    channel='chrome',
    headless=False,
    args=[
        '--disable-blink-features=AutomationControlled',
        '--disable-infobars',
        '--disable-dev-shm-usage',
        '--disable-features=AutomationControlled',
    ],
    ignore_default_args=['--enable-automation'],
    viewport={'width': 1920, 'height': 1080},
    user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
    locale='zh-CN',
    timezone_id='Asia/Shanghai',
    permissions=['geolocation', 'notifications'],
    extra_http_headers={'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'}
)
```

| 参数 | 作用 |
|------|------|
| `--disable-blink-features=AutomationControlled` | 禁用 `navigator.webdriver` 检测（核心） |
| `ignore_default_args=['--enable-automation']` | 移除自动化标志（核心） |
| `launch_persistent_context` | 持久化上下文，保留 Cookie/Session |
| `channel='chrome'` | 使用本地安装的 Chrome |

### 4.2 登录与截图模式

```python
def check_login_status(page):
    cookies = page.context.cookies()
    session_cookie = [c for c in cookies if c['name'] == 'session_name']
    return len(session_cookie) > 0 and '/login' not in page.url

def login(page):
    page.goto(LOGIN_URL, wait_until='networkidle', timeout=60000)
    time.sleep(15)
    page.evaluate('''
        Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
        window.navigator.chrome = {runtime: {}};
    ''')
    user_input = page.locator('input[name="user"]')
    user_input.click()
    user_input.fill(USERNAME)
    user_input.press('End')  # 触发 React onChange 事件
    # ... 其余表单填写
    page.locator('button[type="submit"]').click()
    time.sleep(15)
    page.wait_for_load_state('networkidle', timeout=30000)
```

截图前等待 15 秒确保页面完全渲染；上传 OSS 后删除本地文件；OSS 失败和钉钉失败均须 `raise Exception`。

### 4.3 批量 URL 优化

多个 URL（如 3 台服务器监控）：Job 一次性发送包含数组的 body，Spider 在同一个浏览器上下文中循环处理，减少浏览器启动次数。

---

## 5. 编码规范 CheckList（开发完成后必须逐项核查）

### 通用
- [ ] Spider 类定义上方 2 行空行；方法间 1 行空行
- [ ] 三方库 import 在前，业务包在后，中间空 1 行
- [ ] `task_queue_manager = task_queue_manager` 已作为 Spider 类变量声明
- [ ] `start_task` 内只有 1 个 `yield self.Request()`
- [ ] `self.Request(url=url, headers=headers)` 关键字参数 `=` 前后无空格
- [ ] 文件末尾有 `SpiderRunner` + `if __name__ == '__main__': runner.run()`
- [ ] 所有业务字段入库前已转 `str()`（除非明确需要数值类型）

### 异常处理
- [ ] API 响应码非 0：`raise Exception(f'credential_id: {credential_id}, Err: {res_dic}')`，不允许只打印日志后 return
- [ ] Cookie 为空：记录日志并 `raise Exception` 或 return（视业务决定）
- [ ] JSON 解析异常：包裹 try/except，raise Exception

### 数据正确性
- [ ] 需求文档中的所有字段均已抓取并入库
- [ ] `UNIQUE_KEY` 能唯一标识一条业务记录
- [ ] DDL 已生成，若需求文档缺失则已回写至文档末尾

### 部署
- [ ] `deployments.yml` 已追加 `services`、`jobs`、`check_dlq_jobs` 三段
- [ ] `job_emails` 已配置

### Playwright（如适用）
- [ ] 包含 `--disable-blink-features=AutomationControlled` 和 `ignore_default_args=['--enable-automation']`
- [ ] 实现 `check_login_status`，避免重复登录
- [ ] 使用 `locator` API + `press('End')` 填写 React 表单
- [ ] 截图前等待 15 秒
- [ ] OSS 上传失败、钉钉发送失败通过 `raise Exception` 抛出

---

## 6. 核心命令手册

| 场景 | 命令 |
|------|------|
| 创建项目 | `python -m speedy startproject --project-name {name}` |
| 创建爬虫 | `python -m speedy genspider --project-name {project} --spider-name {spider}` |
| 本地调试 | `python -m sites.{project}.spiders.{spider}`（需 `DEBUG=True`） |
| 语法检查 | `python -m py_compile sites/{project}/spiders/{spider}.py` |
| 代码同步 | `python -m speedy deploy sync-codes` |
| 线上发布 | `python -m speedy deploy publish -f sites/{project}/deployments.yml` |
| 停止服务 | `python -m speedy deploy stop-services -f sites/{project}/deployments.yml` |
| 查看日志 | `supervisorctl tail -f speedy-sites_{project}-{spider}` |

---

## 7. 命名规范

| 类型 | 规则 | 示例 |
|------|------|------|
| 表名 | `{平台前缀}_{功能}` | `sz_market_category_rank` |
| Item 类名 | `{平台前缀首字母大写}{功能}` | `SzMarketCategoryRank` |
| Spider name | `{project}_{平台}_{功能}` | `jd_sz_market_category_rank` |
| 队列名 | `{平台前缀}_{功能}` | `sz_market_category_rank` |
| Job 方法名 | `add_{平台}_{功能}_task` | `add_sz_market_category_rank_task` |

平台前缀：`sz_`（京东商智）、`jm_`（京麦）、`jzt_`（直通车）、`zy_`（站外）
