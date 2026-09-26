-- ============================================================
-- DWS 轻度汇总层（Data Warehouse Summary）
-- 职责：按主题 + 分析粒度做轻度汇总，产出中间指标宽表
-- 特点：不直接面向业务报表，而是为 ADS 层提供可复用的公共指标
-- ============================================================

-- ---------- DWS 1：酒店 × 日期 粒度预订汇总 ----------
-- 粒度：一个酒店类型 + 一天的入住日期 = 一行
CREATE OR REPLACE TABLE dws_booking_hotel_day AS
SELECT
    dt                                  AS stat_date,
    hotel_type,
    COUNT(*)                            AS booking_cnt,             -- 预订量
    SUM(is_canceled)                    AS cancel_cnt,              -- 取消量
    ROUND(AVG(is_canceled) * 100, 2)    AS cancel_rate_pct,         -- 取消率(%)
    SUM(total_nights)                   AS total_nights,            -- 总间夜数
    SUM(total_guests)                   AS total_guests,            -- 总入住人数
    ROUND(AVG(lead_time), 2)            AS avg_lead_time,           -- 平均提前预订天数
    ROUND(AVG(adr), 2)                  AS avg_adr,                 -- 平均房价
    ROUND(SUM(revenue_est), 2)          AS revenue_est,             -- 估算收入
    ROUND(AVG(total_nights), 2)         AS avg_los                  -- 平均入住时长
FROM dwd_booking_detail
GROUP BY dt, hotel_type;

-- ---------- DWS 2：国家 × 月度 粒度预订汇总 ----------
CREATE OR REPLACE TABLE dws_booking_country_month AS
SELECT
    b.arrival_month_id                  AS stat_month,
    c.region,
    c.country_code,
    c.country_name,
    COUNT(*)                            AS booking_cnt,
    SUM(b.is_canceled)                  AS cancel_cnt,
    ROUND(AVG(b.is_canceled) * 100, 2)  AS cancel_rate_pct,
    ROUND(AVG(b.adr), 2)                AS avg_adr,
    ROUND(SUM(b.revenue_est), 2)        AS revenue_est
FROM dwd_booking_detail b
LEFT JOIN dim_country c ON b.country = c.country_code
GROUP BY b.arrival_month_id, c.region, c.country_code, c.country_name;

-- ---------- DWS 3：市场细分 × 月度 粒度渠道汇总 ----------
CREATE OR REPLACE TABLE dws_booking_segment_month AS
SELECT
    arrival_month_id                    AS stat_month,
    market_segment,
    distribution_channel,
    COUNT(*)                            AS booking_cnt,
    SUM(is_canceled)                    AS cancel_cnt,
    ROUND(AVG(is_canceled) * 100, 2)    AS cancel_rate_pct,
    ROUND(AVG(lead_time), 2)            AS avg_lead_time,
    ROUND(AVG(adr), 2)                  AS avg_adr
FROM dwd_booking_detail
GROUP BY arrival_month_id, market_segment, distribution_channel;

-- ---------- DWS 4：情感 × 日期 粒度文本汇总 ----------
CREATE OR REPLACE TABLE dws_sentiment_day AS
SELECT
    dt                                  AS stat_date,
    sentiment,
    COUNT(*)                            AS text_cnt,
    ROUND(AVG(text_len), 2)             AS avg_text_len,
    SUM(space_cnt)                      AS total_space_cnt
FROM dwd_text_sentiment_detail
GROUP BY dt, sentiment;

-- ---------- DWS 5：视频 × 日期 粒度弹幕汇总 ----------
CREATE OR REPLACE TABLE dws_danmaku_video_day AS
SELECT
    d.dt                                AS stat_date,
    d.video_bvid,
    v.title,
    COUNT(*)                            AS danmaku_cnt,
    ROUND(AVG(d.text_len), 2)           AS avg_text_len,
    MAX(d.text_len)                     AS max_text_len,
    COUNT(DISTINCT EXTRACT(hour FROM d.send_ts)) AS active_hour_cnt
FROM dwd_danmaku_detail d
LEFT JOIN dim_video v ON d.video_bvid = v.video_key
GROUP BY d.dt, d.video_bvid, v.title;
