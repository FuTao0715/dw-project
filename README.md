# 数据仓库分层建设项目（dw-project）

> 基于 DuckDB 的六层离线数据仓库：把 **170 万条**多源异构原始数据，经清洗转换、维度建模与分层汇总，
> 产出 **24 张**可信指标表，并配套 **9 项**自动化数据质量校验，**全链路 20 秒**跑完。

**核心亮点**

|   |  |
|---|---|
| 🏗 **六层架构** | ODS → DWD → DIM → DWS → ADS + DQC，各层职责单一、可独立重跑 |
| 🧹 **数据治理** | 编码归一化（latin-1 → UTF-8）、类型转换、缺失值与异常值清洗，可用率 98.4% |
| ⭐ **维度建模** | 星型模型 + 日期维 + **SCD2 拉链表**，记录维度历史变更 |
| ✅ **质量保障** | 9 项自动校验：清洗率 / 主键唯一性 / 维度基数 / 字段完整性 / **指标对账** |
| ⚡ **性能** | 单机列式 OLAP 引擎，170 万行全链路 20 秒 |
| 📊 **业务产出** | 渠道风险排行、月度趋势（含环比）、区域分布、情感趋势等 6 类指标 |

**技术栈**：`DuckDB` · `SQL` · `Python` · `Parquet 列式存储` · `维度建模`

> 📌 SQL 采用标准方言，迁移至 Hive / Spark SQL 仅需少量适配。

---

## 快速开始

```bat
git clone <your-repo-url>
cd dw-project

:: 1) 按 docs/数据获取.md 下载原始数据，放入 data/raw/
:: 2) 一键运行（自动检测并安装依赖）
run.bat
```

预期输出：ODS/DWD/DIM/DWS/ADS 六层共 24 张表的行数与耗时（全链路约 20 秒），
以及 9 项 DQC 校验结果。

---

## 一、项目概述

| 项目 | 说明 |
|---|---|
| 目标 | 从原始多源数据出发，建设一套分层数据仓库，输出可直接服务于业务的指标表 |
| 数据规模 | 文本语料 1,600,000 条 + 业务数据 119,390 条 + 弹幕数据 3,383 条 |
| 执行引擎 | DuckDB（列式 OLAP 引擎，本地单机执行） |
| 全链路耗时 | **约 20 秒** |
| 产出 | 6 层共 **24 张表**，并导出 Parquet 列式文件 |
| 数据质量 | 9 项自动化校验，8 项 PASS |

---

## 二、技术栈与选型理由

- **DuckDB**：列式存储 + 向量化执行，单机即可完成 GB 级数据的 SQL 分析。
  选它的原因是**它本身就是列式 OLAP 引擎**，与 ClickHouse / Doris / StarRocks 的核心机制（列存、向量化、MPP 思想）同源，便于迁移理解。
  本项目 SQL 为标准 SQL（CTAS、窗口函数、MERGE 语义），**迁移到 Hive / Spark SQL 只需做少量方言适配**。
- **Python**：负责链路调度、非结构化数据装载、编码归一化等 SQL 不擅长的部分。
- **Parquet**：各层结果以列式格式落盘，对应数仓的物理存储设计。

> 迁移到 Spark 的方式：把 `sql/` 下文件内的路径替换为 HDFS 路径，用
> `spark.sql(open(f).read())` 逐层执行即可，SQL 主体逻辑无需重写。

---

## 三、分层设计

```
        数据源                   数仓分层                          产出
  ┌──────────────┐        ┌──────────────────┐
  │ 酒店业务 CSV │        │  ODS  贴源层     │  原样落地，不做业务处理
  │ Twitter 语料 │  ────> │  DWD  明细层     │  清洗 + 规范化 + 维度退化
  │ B站弹幕/视频 │        │  DIM  维度层     │  星型模型 + SCD2 拉链表
  └──────────────┘        │  DWS  轻度汇总层 │  按主题粒度的中间指标
                          │  ADS  应用层     │  面向业务的指标表
                          │  DQC  质量校验层 │  对账 + 规则校验
                          └──────────────────┘
```

### 各层职责

| 层 | 职责 | 设计要点 |
|---|---|---|
| **ODS** | 贴源落地 | 全部字段以 VARCHAR 落地，避免类型推断丢数据；增加 `etl_date` 批次字段便于回溯 |
| **DWD** | 清洗 + 规范化 + 维度退化 | 类型转换、缺失值统一（字符串 'NULL' → NULL）、异常值过滤、去重；把日期属性冗余进明细以减少下游 join |
| **DIM** | 维度建模 | 采用**星型模型**：维度直接挂事实表，不做进一步规范化（理由：查询链路更短、join 更少、更适合聚合分析） |
| **DWS** | 轻度汇总 | 按「酒店×天」「国家×月」「细分×月」「情感×天」「视频×天」等分析粒度预聚合 |
| **ADS** | 应用指标 | 取消率排行、月度趋势（含环比）、地区占比、情感看板（含 7 日移动平均）等 |
| **DQC** | 数据质量 | 清洗率、主键唯一性、维度基数、字段完整性、业务规则、**指标对账** |

### 分层设计的核心理由（面试常问）

1. **ODS 与业务解耦**：原始数据不做加工，保证任何时候都能重跑全链路（可回溯）。
2. **DWD 只做一次清洗**：避免每个下游任务各写一套清洗逻辑，消除口径不一致。
3. **DWS 空间换时间**：把高频的聚合计算固化下来，ADS 层直接查，降低重复计算开销。
4. **ADS 口径单一**：所有报表引用同一张 ADS 表，杜绝"同名指标多个数值"。

---

## 四、目录结构

```
dw-project/
├── README.md                  # 本文档
├── LICENSE                    # MIT 开源协议
├── requirements.txt           # 依赖清单
├── run.bat                    # 一键启动（自动检测/安装依赖）
├── run_etl.py                 # 全链路调度驱动器
├── docs/
│   └── 数据获取.md             # 原始数据来源与下载方式
├── sql/
│   ├── 01_ods.sql             # 贴源层：建表 + 从原始文件加载
│   ├── 02_dwd.sql             # 明细层：清洗规则 + 维度退化
│   ├── 03_dim.sql             # 维度层：维度表 + 日期维 + SCD2 拉链表
│   ├── 04_dws.sql             # 轻度汇总层：主题粒度中间指标
│   ├── 05_ads.sql             # 应用层：业务指标（含窗口函数）
│   └── 06_dqc.sql             # 质量校验层：9 项自动化校验
└── data/                      # 运行后生成
    ├── raw/                   # 原始数据（不入库，见 docs/数据获取.md）
    ├── *.parquet              # 各层结果导出（列式存储）
    └── _twitter_sentiment_utf8.csv   # 编码归一化缓存
```

---

## 五、运行方式

```bash
# 方式一：双击 run.bat（自动检测依赖，缺 duckdb 会自动安装后执行）

# 方式二：手动执行
pip install -r requirements.txt
python run_etl.py
```

### 环境依赖

- Python 3.9+
- duckdb >= 1.0（见 `requirements.txt`）

**多环境机器请注意**：若终端里的 `python` 未安装 duckdb，会报
`ModuleNotFoundError: No module named 'duckdb'`。此时任选一种方式：

```bat
:: 1) 给当前解释器补装依赖（最直接）
python -m pip install duckdb

:: 2) 指定已装好依赖的解释器（路径换成你自己的）
"C:\path\to\envs\your_env\python.exe" run_etl.py

:: 3) 先激活 conda 环境
conda activate your_env
python run_etl.py
```

> 建议统一用 `run.bat` 或虚拟环境运行，避免依赖"当前激活的是哪个 Python"
> 这种隐式状态——这是本项目实际踩过的坑。

### 数据准备

本项目**不包含原始数据**（最大一份 228MB）。请按
[`docs/数据获取.md`](docs/数据获取.md) 的说明下载后放入 `data/raw/`，
脚本会自动识别（不写死任何绝对路径）：

```
data/raw/
├── hotel_bookings.csv                          (16MB)
├── training.1600000.processed.noemoticon.csv   (228MB)
├── 弹幕文本.txt
└── 哔哩哔哩数据.json
```

也可以用环境变量指向数据所在位置（优先级高于 `data/raw/`）：

```bat
set HOTEL_CSV=D:/mydata/hotel_bookings.csv
python run_etl.py
```

运行后在控制台输出：各层行数、耗时、DQC 校验结果、ADS 指标抽样。

---

## 六、运行结果（实测）

### 各层行数

| 层 | 表 | 行数 |
|---|---|---|
| ODS | ods_hotel_booking | 119,390 |
| ODS | ods_twitter_sentiment | 1,600,000 |
| ODS | ods_bilibili_danmaku | 3,383 |
| DWD | dwd_booking_detail | 117,398（清洗保留率 98.33%） |
| DWD | dwd_text_sentiment_detail | 1,573,855（清洗保留率 98.37%） |
| DWD | dwd_danmaku_detail | 3,370 |
| DIM | dim_date | 6,939 |
| DIM | dim_hotel_type / dim_market_segment / dim_country | 2 / 8 / 177 |
| DIM | dim_video_scd2 | 2（v1 历史 + v2 当前） |
| DWS | dws_booking_hotel_day | 1,586 |
| DWS | dws_booking_country_month | 1,955 |
| DWS | dws_booking_segment_month | 380 |
| DWS | dws_sentiment_day | 87 |
| DWS | dws_danmaku_video_day | 138 |
| ADS | ads_hotel_booking_trend | 52 |
| ADS | ads_channel_risk_rank | 14 |
| ADS | ads_region_summary | 178 |
| ADS | ads_sentiment_trend | 48 |
| ADS | ads_video_danmaku_overview | 1 |
| ADS | ads_danmaku_hourly_dist | 24 |

### ADS 指标示例

**预订渠道风险排行（Top 5）**

| 市场细分 | 渠道 | 预订量 | 取消率 |
|---|---|---|---|
| GROUPS | TA/TO | 16,909 | 65.86% |
| OFFLINE TA/TO | CORPORATE | 211 | 48.82% |
| GROUPS | DIRECT | 1,440 | 37.57% |
| ONLINE TA | TA/TO | 55,774 | 37.05% |
| OFFLINE TA/TO | TA/TO | 23,613 | 34.54% |

**地区来源 Top 5**

| 地区 | 国家 | 预订量 | 取消率 | 占比 |
|---|---|---|---|---|
| 欧洲 | 葡萄牙 | 47,026 | 58.12% | 40.06% |
| 欧洲 | 英国 | 12,052 | 20.34% | 10.27% |
| 欧洲 | 法国 | 10,359 | 18.65% | 8.82% |
| 欧洲 | 西班牙 | 8,488 | 25.64% | 7.23% |
| 欧洲 | 德国 | 7,246 | 16.81% | 6.17% |

---

## 七、踩坑记录（重点，可直接作为面试案例）

### 坑 1：维度表基数爆炸，导致指标膨胀 2800 倍

**现象**：`dim_hotel_type`（酒店类型维，正确应为 2 行）输出了 **117,398 行**；下游 `ads_channel_risk_rank` 出现「GROUPS/TA/TO 预订 **330,689,313** 笔」，而全量明细只有 117,398 行，指标放大了约 2,800 倍。

**根因**：维度表 SQL 写成了
```sql
SELECT DISTINCT
    ROW_NUMBER() OVER (ORDER BY hotel_type) AS hotel_type_key,  -- 每行唯一
    hotel_type
FROM dwd_booking_detail;
```
`ROW_NUMBER()` 为每一行生成唯一值，导致 `SELECT DISTINCT` 对整行去重完全失效，维度表被放大到明细规模（fan-out）。后续事实表 join 该维度表时，一行事实被匹配上万次，指标被乘爆。

**修复**：分成两层——先取维值，再生成代理键。
```sql
WITH distinct_val AS (SELECT DISTINCT hotel_type FROM dwd_booking_detail)
SELECT ROW_NUMBER() OVER (ORDER BY hotel_type) AS hotel_type_key, hotel_type
FROM distinct_val;
```

**验证**：修复后 `dim_hotel_type` = 2 行，渠道预订量回到合理量级；并新增 DQC 校验项「维度基数」防止该问题回归。

### 坑 2：DQC 拦截到主键重复缺陷（待修复）

**现象**：DQC 校验「主键唯一性-dwd_text_sentiment_detail」**FAIL**，检测到 1,685 个重复 `tweet_id`。

**根因**：DWD 清洗时对整行做了 `SELECT DISTINCT`，而部分推文被重复采集、`tweet_id` 重复但时间戳不同，整行去重无法消除。

**修复方案**（待实现）：
```sql
-- 按主键去重，保留最新一条
SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY tweet_id ORDER BY dt DESC) AS rn
    FROM dwd_text_sentiment_detail
) t WHERE rn = 1;
```

> 这条 FAIL 恰好说明 DQC 层不是摆设：**它能真实拦截上游数据缺陷**。

---

## 八、面试要点速记

| 问题 | 回答要点 |
|---|---|
| 为什么要分层？ | ODS 解耦可重跑、DWD 统一清洗口径、DWS 空间换时间、ADS 指标单一来源 |
| 星型 vs 雪花模型怎么选？ | 星型：维度冗余、join 少、查询快（本项目选择）；雪花：维度规范化、省空间、join 多。数仓场景优先星型 |
| 拉链表怎么实现？ | `start_date` + `end_date` + `is_current`；更新分三步：快照最大版本号 → 识别变更记录 → 关闭旧版本 + 写入新版本（本项目 `03_dim.sql` 有完整实现） |
| 指标膨胀（fan-out）怎么排查？ | 检查维度表基数是否异常、join 键是否唯一；对策是维度表先去重再生成代理键，并加基数校验 |
| 数据准确性怎么保障？ | 建立 DQC 层：清洗率、主键唯一性、字段完整性、业务规则、**ADS 与 DWD 指标对账** |

---

## 九、待办（TODO）

- [ ] 修复 DWD 文本表主键重复（见「坑 2」），使 DQC 全项 PASS
- [ ] 用 PySpark local 模式重跑一遍同批 SQL，对比单机 DuckDB 的执行计划与耗时
- [ ] 引入 ClickHouse / Doris，把 ADS 表同步过去，对比聚合查询响应时间
- [ ] 增加按天分区落盘与调度（对应生产环境的离线调度）
