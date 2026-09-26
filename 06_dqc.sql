-- ============================================================
-- DQC 数据质量校验层（Data Quality Check）
-- 职责：在链路末端做自动化对账与规则校验，保障数据的准确性、
--       完整性与一致性——这是数仓"能上线"的前提
-- 输出：dqc_result 表，每行一个校验项，status = PASS / FAIL
-- ============================================================

CREATE OR REPLACE TABLE dqc_result AS
WITH checks AS (

    -- ---------- 1. 清洗率校验：DWD 相对 ODS 的过滤比例应在合理阈值内 ----------
    SELECT
        '清洗率-酒店预订' AS check_name,
        'ODS 119390 -> DWD 保留率应 > 95%' AS rule_desc,
        '95.00%' AS expect_value,
        CAST(ROUND(
            (SELECT COUNT(*) FROM dwd_booking_detail) * 100.0
            / (SELECT COUNT(*) FROM ods_hotel_booking), 2) AS VARCHAR) || '%' AS actual_value,
        CASE WHEN (SELECT COUNT(*) FROM dwd_booking_detail) * 100.0
                  / (SELECT COUNT(*) FROM ods_hotel_booking) > 95
             THEN 'PASS' ELSE 'FAIL' END AS status

    UNION ALL
    -- ---------- 2. 清洗率校验：文本语料 ----------
    SELECT
        '清洗率-文本情感语料',
        'ODS 1600000 -> DWD 保留率应 > 90%',
        '90.00%',
        CAST(ROUND(
            (SELECT COUNT(*) FROM dwd_text_sentiment_detail) * 100.0
            / (SELECT COUNT(*) FROM ods_twitter_sentiment), 2) AS VARCHAR) || '%',
        CASE WHEN (SELECT COUNT(*) FROM dwd_text_sentiment_detail) * 100.0
                  / (SELECT COUNT(*) FROM ods_twitter_sentiment) > 90
             THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 3. 主键唯一性校验 ----------
    SELECT
        '主键唯一性-dwd_text_sentiment_detail',
        'tweet_id 不允许重复',
        '0 个重复',
        CAST((SELECT COUNT(*) - COUNT(DISTINCT tweet_id) FROM dwd_text_sentiment_detail) AS VARCHAR) || ' 个重复',
        CASE WHEN (SELECT COUNT(*) FROM dwd_text_sentiment_detail)
                = (SELECT COUNT(DISTINCT tweet_id) FROM dwd_text_sentiment_detail)
             THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 4. 维度表基数校验（防 fan-out 回归）----------
    SELECT
        '维度基数-dim_hotel_type',
        '酒店类型维应为 2 行',
        '2',
        CAST((SELECT COUNT(*) FROM dim_hotel_type) AS VARCHAR),
        CASE WHEN (SELECT COUNT(*) FROM dim_hotel_type) = 2 THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 5. 维度表基数校验：市场细分 ----------
    SELECT
        '维度基数-dim_market_segment',
        '市场细分维应 <= 15 行',
        '<= 15',
        CAST((SELECT COUNT(*) FROM dim_market_segment) AS VARCHAR),
        CASE WHEN (SELECT COUNT(*) FROM dim_market_segment) <= 15 THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 6. 指标对账校验（最关键）：ADS 汇总口径 = DWD 明细口径 ----------
    SELECT
        '指标对账-酒店预订量',
        'ADS 月度趋势汇总 = DWD 明细行数',
        CAST((SELECT COUNT(*) FROM dwd_booking_detail) AS VARCHAR),
        CAST((SELECT SUM(booking_cnt) FROM ads_hotel_booking_trend) AS VARCHAR),
        CASE WHEN (SELECT SUM(booking_cnt) FROM ads_hotel_booking_trend)
                = (SELECT COUNT(*) FROM dwd_booking_detail)
             THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 7. SCD2 拉链表当前版本唯一性校验 ----------
    SELECT
        'SCD2 当前版本唯一性',
        '每个维度键有且仅有一个 is_current = TRUE 的版本',
        CAST((SELECT COUNT(DISTINCT video_key) FROM dim_video_scd2) AS VARCHAR),
        CAST((SELECT COUNT(*) FROM dim_video_scd2 WHERE is_current) AS VARCHAR),
        CASE WHEN (SELECT COUNT(*) FROM dim_video_scd2 WHERE is_current)
                = (SELECT COUNT(DISTINCT video_key) FROM dim_video_scd2)
             THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 8. 字段完整性校验：国家字段空值率 ----------
    SELECT
        '字段完整性-国家空值率',
        'country 空值率应 < 5%',
        '< 5.00%',
        CAST(ROUND(
            (SELECT COUNT(*) FROM dwd_booking_detail WHERE country IS NULL) * 100.0
            / (SELECT COUNT(*) FROM dwd_booking_detail), 2) AS VARCHAR) || '%',
        CASE WHEN (SELECT COUNT(*) FROM dwd_booking_detail WHERE country IS NULL) * 100.0
                  / (SELECT COUNT(*) FROM dwd_booking_detail) < 5
             THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- ---------- 9. 业务规则校验：ADR 取值区间 ----------
    SELECT
        '业务规则-ADR 区间',
        'ADR 应落在 (0, 5000] 区间内',
        '0 条越界',
        CAST((SELECT COUNT(*) FROM dwd_booking_detail WHERE adr <= 0 OR adr > 5000) AS VARCHAR) || ' 条越界',
        CASE WHEN (SELECT COUNT(*) FROM dwd_booking_detail WHERE adr <= 0 OR adr > 5000) = 0
             THEN 'PASS' ELSE 'FAIL' END
)
SELECT * FROM checks;
