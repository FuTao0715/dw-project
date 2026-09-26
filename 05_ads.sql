-- ============================================================
-- ADS 应用层（Application Data Service）
-- 职责：面向业务场景输出可直接查询、可直接用于报表与决策的指标表
-- 特点：口径明确、字段语义清晰、一般不再做二次加工
-- ============================================================

-- ---------- ADS 1：酒店类型 × 月度 取消率与预订趋势（含环比）----------
-- 业务用途：监控取消率异常、支撑运营策略调整
-- 窗口函数：LAG 计算环比，体现指标趋势分析能力
CREATE OR REPLACE TABLE ads_hotel_booking_trend AS
WITH monthly AS (
    SELECT
        b.arrival_month_id                                          AS stat_month,
        b.hotel_type,
        COUNT(*)                                                    AS booking_cnt,
        SUM(b.is_canceled)                                          AS cancel_cnt,
        ROUND(AVG(b.is_canceled) * 100, 2)                          AS cancel_rate_pct,
        ROUND(AVG(b.adr), 2)                                        AS avg_adr,
        ROUND(SUM(b.revenue_est), 2)                                AS revenue_est
    FROM dwd_booking_detail b
    GROUP BY b.arrival_month_id, b.hotel_type
)
SELECT
    stat_month,
    hotel_type,
    booking_cnt,
    cancel_cnt,
    cancel_rate_pct,
    avg_adr,
    revenue_est,
    LAG(booking_cnt)   OVER (PARTITION BY hotel_type ORDER BY stat_month) AS prev_month_booking_cnt,
    LAG(cancel_rate_pct) OVER (PARTITION BY hotel_type ORDER BY stat_month) AS prev_month_cancel_rate,
    -- 环比增长率(%)
    ROUND(
        (booking_cnt - LAG(booking_cnt) OVER (PARTITION BY hotel_type ORDER BY stat_month))
        * 100.0
        / NULLIF(LAG(booking_cnt) OVER (PARTITION BY hotel_type ORDER BY stat_month), 0)
    , 2) AS booking_mom_growth_pct
FROM monthly;

-- ---------- ADS 2：预订渠道风险排行 ----------
-- 业务用途：识别高取消率的渠道/市场细分，指导渠道政策
CREATE OR REPLACE TABLE ads_channel_risk_rank AS
SELECT
    s.market_segment,
    m.segment_cn,
    s.distribution_channel,
    SUM(s.booking_cnt)                          AS booking_cnt,
    SUM(s.cancel_cnt)                           AS cancel_cnt,
    ROUND(SUM(s.cancel_cnt) * 100.0 / SUM(s.booking_cnt), 2) AS cancel_rate_pct,
    ROUND(AVG(s.avg_lead_time), 2)              AS avg_lead_time,
    RANK() OVER (ORDER BY SUM(s.cancel_cnt) * 100.0 / SUM(s.booking_cnt) DESC) AS risk_rank
FROM dws_booking_segment_month s
LEFT JOIN dim_market_segment m ON s.market_segment = m.market_segment
GROUP BY s.market_segment, m.segment_cn, s.distribution_channel
HAVING SUM(s.booking_cnt) >= 100          -- 过滤样本量过小的渠道，保证统计显著性
ORDER BY cancel_rate_pct DESC;

-- ---------- ADS 3：地区来源分析（Top 国家/地区）----------
CREATE OR REPLACE TABLE ads_region_summary AS
SELECT
    region,
    country_code,
    country_name,
    SUM(booking_cnt)                            AS booking_cnt,
    ROUND(SUM(cancel_cnt) * 100.0 / SUM(booking_cnt), 2) AS cancel_rate_pct,
    ROUND(AVG(avg_adr), 2)                      AS avg_adr,
    ROUND(SUM(revenue_est), 2)                  AS revenue_est,
    ROUND(SUM(booking_cnt) * 100.0 / SUM(SUM(booking_cnt)) OVER (), 2) AS booking_share_pct  -- 占比
FROM dws_booking_country_month
GROUP BY region, country_code, country_name
ORDER BY booking_cnt DESC;

-- ---------- ADS 4：情感趋势看板（含 7 日移动平均）----------
-- 业务用途：内容/舆情监控，识别情感异常波动
-- 窗口函数：ROWS BETWEEN 6 PRECEDING AND CURRENT ROW 实现移动平均
CREATE OR REPLACE TABLE ads_sentiment_trend AS
WITH daily AS (
    SELECT
        stat_date,
        SUM(CASE WHEN sentiment = 'positive' THEN text_cnt ELSE 0 END) AS positive_cnt,
        SUM(CASE WHEN sentiment = 'negative' THEN text_cnt ELSE 0 END) AS negative_cnt,
        SUM(text_cnt)                                                  AS total_cnt
    FROM dws_sentiment_day
    GROUP BY stat_date
)
SELECT
    stat_date,
    total_cnt,
    positive_cnt,
    negative_cnt,
    ROUND(positive_cnt * 100.0 / NULLIF(total_cnt, 0), 2) AS positive_rate_pct,
    ROUND(AVG(positive_cnt * 100.0 / NULLIF(total_cnt, 0))
          OVER (ORDER BY stat_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS positive_rate_ma7
FROM daily
ORDER BY stat_date;

-- ---------- ADS 5：视频弹幕互动概览（含活跃时段分布）----------
-- 业务用途：内容运营分析，识别用户活跃时段与互动质量
CREATE OR REPLACE TABLE ads_video_danmaku_overview AS
SELECT
    d.video_bvid,
    v.title,
    v.view_cnt,
    COUNT(*)                                            AS danmaku_cnt,
    ROUND(COUNT(*) * 100.0 / NULLIF(v.danmaku_cnt, 0), 2) AS danmaku_coverage_pct,  -- 采集覆盖率
    ROUND(AVG(d.text_len), 2)                           AS avg_text_len,
    COUNT(DISTINCT EXTRACT(hour FROM d.send_ts))        AS active_hour_cnt,
    MIN(d.send_ts)                                      AS first_send_ts,
    MAX(d.send_ts)                                      AS last_send_ts
FROM dwd_danmaku_detail d
LEFT JOIN dim_video v ON d.video_bvid = v.video_key
GROUP BY d.video_bvid, v.title, v.view_cnt, v.danmaku_cnt;

-- ---------- ADS 6：弹幕活跃时段分布（小时粒度）----------
CREATE OR REPLACE TABLE ads_danmaku_hourly_dist AS
SELECT
    EXTRACT(hour FROM send_ts)  AS hour_of_day,
    COUNT(*)                    AS danmaku_cnt,
    ROUND(AVG(text_len), 2)     AS avg_text_len,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS hour_share_pct
FROM dwd_danmaku_detail
GROUP BY hour_of_day
ORDER BY danmaku_cnt DESC;
