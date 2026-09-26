# -*- coding: utf-8 -*-
"""
数仓全链路 ETL 驱动器（ODS -> DWD -> DIM -> DWS -> ADS）

运行方式：
    python run_etl.py

执行内容：
    1. 建 ODS 贴源层（直接读取原始 CSV）
    2. 装载非结构化来源（B 站弹幕 TXT / 视频 JSON）
    3. 逐层执行 SQL，输出各层行数与耗时
    4. 导出各层结果到 data/ 目录（Parquet 列式存储）
    5. 打印 ADS 应用层核心指标结果
"""
import os
import sys
import json
import time
import duckdb

# Windows 控制台默认 GBK，统一切到 UTF-8，避免中文输出报错
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# ---------------- 路径配置 ----------------
BASE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(BASE, "sql")
OUT_DIR = os.path.join(BASE, "data")
DB_FILE = os.path.join(BASE, "dw.duckdb")

# 数据源配置
# 解析顺序：环境变量  >  data/raw/ 目录
# 推荐把原始数据放入 data/raw/，项目即可自包含直接运行；
# 也可用环境变量指向本机任意位置（Windows 路径建议用正斜杠或双反斜杠）：
#   set HOTEL_CSV=D:/mydata/hotel_bookings.csv
RAW_DIR = os.path.join(BASE, "data", "raw")

def _src(env_key, filename):
    """优先取环境变量，其次取 data/raw/ 下的同名文件。"""
    p = os.environ.get(env_key)
    if p and os.path.exists(p):
        return p
    return os.path.join(RAW_DIR, filename)

HOTEL_CSV   = _src("HOTEL_CSV",   "hotel_bookings.csv")
TWITTER_CSV = _src("TWITTER_CSV", "training.1600000.processed.noemoticon.csv")
DANMAKU_TXT = _src("DANMAKU_TXT", "弹幕文本.txt")
VIDEO_JSON  = _src("VIDEO_JSON",  "哔哩哔哩数据.json")

# 数据源完整性校验：缺失时给出明确指引，而不是抛出底层异常
_REQUIRED = [
    ("hotel_bookings.csv",                        HOTEL_CSV),
    ("training.1600000.processed.noemoticon.csv", TWITTER_CSV),
    ("弹幕文本.txt",                               DANMAKU_TXT),
    ("哔哩哔哩数据.json",                           VIDEO_JSON),
]
_missing = [n for n, p in _REQUIRED if not os.path.exists(p)]
if _missing:
    print("=" * 64)
    print("[ERROR] 缺少原始数据文件：")
    for _n in _missing:
        print("        - " + _n)
    print("请将以上文件放入：" + RAW_DIR)
    print("数据来源与获取方式见 docs/数据获取.md")
    print("=" * 64)
    sys.exit(1)

BATCH_DATE = time.strftime("%Y-%m-%d")

os.makedirs(OUT_DIR, exist_ok=True)

# 接入层归一化后的 UTF-8 语料路径
TWITTER_UTF8 = os.path.join(OUT_DIR, "_twitter_sentiment_utf8.csv")

# 各层产出表，用于统计行数
LAYER_TABLES = {
    "ODS": ["ods_hotel_booking", "ods_twitter_sentiment", "ods_bilibili_danmaku", "ods_bilibili_video"],
    "DWD": ["dwd_booking_detail", "dwd_text_sentiment_detail", "dwd_danmaku_detail"],
    "DIM": ["dim_date", "dim_hotel_type", "dim_market_segment", "dim_country", "dim_video", "dim_video_scd2"],
    "DWS": ["dws_booking_hotel_day", "dws_booking_country_month",
            "dws_booking_segment_month", "dws_sentiment_day", "dws_danmaku_video_day"],
    "ADS": ["ads_hotel_booking_trend", "ads_channel_risk_rank", "ads_region_summary",
            "ads_sentiment_trend", "ads_video_danmaku_overview", "ads_danmaku_hourly_dist"],
    "DQC": ["dqc_result"],
}


def log(msg):
    print(msg, flush=True)


def normalize_twitter_encoding():
    """
    数据接入层：编码归一化
    原始语料为 ISO-8859-1(Latin-1) 编码，且含非 UTF-8 字符，
    在接入层统一转为 UTF-8 落盘，避免下游解析失败。
    """
    utf8_path = os.path.join(OUT_DIR, "_twitter_sentiment_utf8.csv")
    if os.path.exists(utf8_path):
        log(f"      编码归一化文件已存在，跳过（{os.path.getsize(utf8_path)/1024/1024:.1f}MB）")
        return utf8_path

    import csv
    src = TWITTER_CSV
    n = 0
    with open(src, "r", encoding="latin-1", newline="", errors="replace") as fin, \
         open(utf8_path, "w", encoding="utf-8", newline="") as fout:
        reader = csv.reader(fin)
        writer = csv.writer(fout, quoting=csv.QUOTE_ALL)
        for i, row in enumerate(reader):
            if len(row) < 6:
                continue
            writer.writerow(row[:6])
            n += 1
            if n % 500000 == 0:
                log(f"      已转换 {n:,} 行 ...")
    log(f"      编码归一化完成：{n:,} 行 -> {os.path.getsize(utf8_path)/1024/1024:.1f}MB UTF-8")
    return utf8_path


def run_sql_file(con, filename):
    """读取 SQL 文件（做路径占位符替换）并执行"""
    path = os.path.join(SQL_DIR, filename)
    with open(path, encoding="utf-8") as f:
        sql = f.read()
    sql = (sql.replace("{HOTEL_CSV}", HOTEL_CSV)
              .replace("{TWITTER_UTF8}", TWITTER_UTF8.replace("\\", "/"))
              .replace("{BATCH_DATE}", BATCH_DATE))
    t0 = time.time()
    con.execute(sql)
    return time.time() - t0


def load_danmaku(con):
    """装载 B 站弹幕 TXT（一行一条弹幕）"""
    bvid = "BV1_placeholder"
    # 从 JSON 中取真实 ID 与视频信息
    with open(VIDEO_JSON, encoding="utf-8") as f:
        data = json.load(f)
    vinfo = data.get("视频信息", {})
    bvid = vinfo.get("aid") or vinfo.get("bvid") or vinfo.get("标题", "")[:12]

    rows = []
    with open(DANMAKU_TXT, encoding="utf-8", errors="ignore") as f:
        for i, line in enumerate(f, 1):
            txt = line.strip()
            if not txt:
                continue
            rows.append((i, bvid, txt, None, BATCH_DATE, "bilibili_danmaku.txt"))

    # 弹幕发送时间：优先用 JSON 中的结构化弹幕列表（含发送时间）
    detail = data.get("弹幕列表") or []
    if detail:
        rows = []
        for i, item in enumerate(detail, 1):
            rows.append((
                i,
                bvid,
                str(item.get("弹幕内容", "")).strip(),
                item.get("发送时间"),
                BATCH_DATE,
                "bilibili_danmaku.json",
            ))

    con.executemany(
        "INSERT INTO ods_bilibili_danmaku VALUES (?,?,?,?,?,?)", rows
    )

    con.execute(
        "INSERT INTO ods_bilibili_video VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [
            bvid,
            vinfo.get("标题"),
            vinfo.get("作者"),
            vinfo.get("发布日期"),
            vinfo.get("播放量"),
            vinfo.get("弹幕数"),
            vinfo.get("点赞数"),
            vinfo.get("硬币数"),
            vinfo.get("收藏数"),
            vinfo.get("转发数"),
            vinfo.get("评论数"),
            BATCH_DATE,
            "bilibili_video.json",
        ],
    )
    return len(rows)


def count_rows(con, layer):
    out = []
    for t in LAYER_TABLES[layer]:
        try:
            n = con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
            out.append((t, n))
        except Exception as e:
            out.append((t, f"ERROR: {e}"))
    return out


def export(con, layer):
    """导出该层全部表为 Parquet（列式存储，对应数仓落盘）"""
    for t in LAYER_TABLES[layer]:
        try:
            dst = os.path.join(OUT_DIR, f"{t}.parquet").replace("\\", "/")
            con.execute(f"COPY (SELECT * FROM {t}) TO '{dst}' (FORMAT PARQUET)")
        except Exception:
            pass


def main():
    if os.path.exists(DB_FILE):
        os.remove(DB_FILE)
    con = duckdb.connect(DB_FILE)
    con.execute("SET threads TO 4")

    log("=" * 72)
    log(f"数仓全链路 ETL  |  批次日期 {BATCH_DATE}")
    log("=" * 72)

    total = 0.0

    # ---------- 1. ODS ----------
    log("\n[1/5] ODS 贴源层 —— 原样落地，不做业务处理")
    normalize_twitter_encoding()
    cost = run_sql_file(con, "01_ods.sql")
    t0 = time.time()
    n_danmaku = load_danmaku(con)
    cost += time.time() - t0
    log(f"      装载 B 站弹幕 {n_danmaku} 条（非结构化来源）")
    for t, n in count_rows(con, "ODS"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "ODS")

    # ---------- 2. DWD ----------
    log("\n[2/5] DWD 明细层 —— 清洗 / 规范化 / 维度退化")
    cost = run_sql_file(con, "02_dwd.sql")
    for t, n in count_rows(con, "DWD"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "DWD")

    # ---------- 3. DIM ----------
    log("\n[3/5] DIM 维度层 —— 星型模型维度表 + SCD2 拉链表")
    cost = run_sql_file(con, "03_dim.sql")
    for t, n in count_rows(con, "DIM"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "DIM")

    # ---------- 4. DWS ----------
    log("\n[4/5] DWS 轻度汇总层 —— 按主题粒度产出中间指标")
    cost = run_sql_file(con, "04_dws.sql")
    for t, n in count_rows(con, "DWS"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "DWS")

    # ---------- 5. ADS ----------
    log("\n[5/5] ADS 应用层 —— 面向业务的指标结果")
    cost = run_sql_file(con, "05_ads.sql")
    for t, n in count_rows(con, "ADS"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "ADS")

    # ---------- 6. DQC ----------
    log(chr(10) + "[6/6] DQC 数据质量校验 —— 自动化对账与规则校验")
    cost = run_sql_file(con, "06_dqc.sql")
    for t, n in count_rows(con, "DQC"):
        log(f"      {t:<28} {n:>10,} 行")
    log(f"      耗时 {cost:.2f}s")
    total += cost
    export(con, "DQC")

    log(chr(10) + "-" * 72)
    log("数据质量校验结果")
    log("-" * 72)
    for r in con.execute("""
        SELECT check_name, rule_desc, expect_value, actual_value, status
        FROM dqc_result""").fetchall():
        mark = "[PASS]" if r[4] == "PASS" else "[FAIL]"
        log(f"   {mark} {r[0]}")
        log(f"          规则：{r[1]}  期望：{r[2]}  实际：{r[3]}")

    # ---------- 结果抽样 ----------
    log("\n" + "=" * 72)
    log("ADS 核心指标结果（Top 5 抽样）")
    log("=" * 72)

    log("\n① 预订渠道风险排行（高取消率渠道）")
    for r in con.execute("""
        SELECT market_segment, distribution_channel, booking_cnt, cancel_rate_pct, risk_rank
        FROM ads_channel_risk_rank ORDER BY risk_rank LIMIT 5""").fetchall():
        log(f"   {r[0]:<16} {str(r[1]):<12} 预订 {r[2]:>7,}  取消率 {r[3]:>6}%  NO.{r[4]}")

    log("\n② 酒店预订月度趋势（含环比）")
    for r in con.execute("""
        SELECT stat_month, hotel_type, booking_cnt, cancel_rate_pct, booking_mom_growth_pct
        FROM ads_hotel_booking_trend
        WHERE booking_mom_growth_pct IS NOT NULL
        ORDER BY stat_month DESC LIMIT 5""").fetchall():
        log(f"   {r[0]}  {r[1]:<14} 预订 {r[2]:>6,}  取消率 {r[3]:>6}%  环比 {r[4]:>8}%")

    log("\n③ 地区来源 Top 5")
    for r in con.execute("""
        SELECT region, country_name, booking_cnt, cancel_rate_pct, booking_share_pct
        FROM ads_region_summary ORDER BY booking_cnt DESC LIMIT 5""").fetchall():
        log(f"   {r[0]:<8} {r[1]:<12} 预订 {r[2]:>6,}  取消率 {r[3]:>6}%  占比 {r[4]:>5}%")

    log("\n④ SCD2 拉链表效果（版本历史）")
    for r in con.execute("""
        SELECT video_key, LEFT(title, 26) AS title, start_date, end_date, is_current, version_num
        FROM dim_video_scd2 ORDER BY video_key, version_num""").fetchall():
        log(f"   {str(r[0])[:14]:<14} {r[1]:<28} {r[2]} ~ {r[3]}  current={r[4]}  v{r[5]}")

    log("\n⑤ 弹幕活跃时段 Top 3")
    for r in con.execute("""
        SELECT hour_of_day, danmaku_cnt, avg_text_len, hour_share_pct
        FROM ads_danmaku_hourly_dist LIMIT 3""").fetchall():
        log(f"   {int(r[0]):02d}:00  {r[1]:>5} 条  平均 {r[2]} 字  占比 {r[3]}%")

    log("\n" + "=" * 72)
    log(f"全链路完成，总耗时 {total:.2f}s")
    log(f"结果已导出至 {OUT_DIR}")
    log("=" * 72)
    con.close()


if __name__ == "__main__":
    main()
