-- ============================================================
-- DWD 明细层（Data Warehouse Detail）
-- 职责：清洗 + 规范化 + 维度退化，产出可复用的干净明细事实表
-- 清洗规则：类型转换、缺失值统一、异常值过滤、字段标准化、去重
-- ============================================================

-- ---------- 月份名称 -> 月份序号 映射（提前建好，供多层复用）----------
CREATE OR REPLACE TABLE dim_month_map AS
SELECT * FROM (VALUES
    ('January',  1), ('February', 2), ('March',     3), ('April',   4),
    ('May',      5), ('June',     6), ('July',      7), ('August',  8),
    ('September',9), ('October', 10), ('November', 11), ('December',12)
) AS t(month_name, month_num);

-- ============================================================
-- DWD 1：酒店预订明细事实表 dwd_booking_detail
-- ============================================================
CREATE OR REPLACE TABLE dwd_booking_detail AS
WITH src AS (
    SELECT * FROM ods_hotel_booking
),
typed AS (
    SELECT
        hotel                                       AS hotel_type,
        TRY_CAST(is_canceled AS TINYINT)             AS is_canceled,
        TRY_CAST(lead_time AS INTEGER)               AS lead_time,
        TRY_CAST(arrival_date_year AS SMALLINT)      AS arrival_year,
        arrival_date_month                           AS arrival_month,
        TRY_CAST(arrival_date_week_number AS TINYINT) AS arrival_week,
        TRY_CAST(arrival_date_day_of_month AS TINYINT) AS arrival_day,
        COALESCE(TRY_CAST(stays_in_weekend_nights AS TINYINT), 0) AS weekend_nights,
        COALESCE(TRY_CAST(stays_in_week_nights     AS TINYINT), 0) AS week_nights,
        COALESCE(TRY_CAST(adults   AS TINYINT), 0)   AS adults,
        COALESCE(TRY_CAST(children AS TINYINT), 0)   AS children,
        COALESCE(TRY_CAST(babies   AS TINYINT), 0)   AS babies,
        -- 缺失值标准化：原始数据以字符串 'NULL' 表示空值，统一转为 NULL
        NULLIF(NULLIF(UPPER(TRIM(meal)), 'NULL'), '')             AS meal,
        NULLIF(NULLIF(UPPER(TRIM(country)), 'NULL'), '')          AS country,
        NULLIF(NULLIF(UPPER(TRIM(market_segment)), 'NULL'), '')   AS market_segment,
        NULLIF(NULLIF(UPPER(TRIM(distribution_channel)), 'NULL'), '') AS distribution_channel,
        COALESCE(TRY_CAST(is_repeated_guest AS TINYINT), 0)       AS is_repeated_guest,
        COALESCE(TRY_CAST(previous_cancellations AS INTEGER), 0)  AS previous_cancellations,
        TRY_CAST(adr AS DOUBLE)                                   AS adr,
        TRY_CAST(required_car_parking_spaces AS TINYINT)          AS parking_spaces,
        TRY_CAST(total_of_special_requests AS TINYINT)            AS special_requests
    FROM src
),
enriched AS (
    SELECT
        t.*,
        -- 维度退化：把日期维属性冗余进明细，减少下游 join
        MAKE_DATE(t.arrival_year, m.month_num, t.arrival_day)  AS arrival_date,
        STRFTIME(MAKE_DATE(t.arrival_year, m.month_num, t.arrival_day), '%Y-%m') AS arrival_month_id,
        t.weekend_nights + t.week_nights                       AS total_nights,
        t.adults + t.children + t.babies                       AS total_guests,
        ROUND(t.adr * (t.weekend_nights + t.week_nights), 2)   AS revenue_est
    FROM typed t
    LEFT JOIN dim_month_map m ON t.arrival_month = m.month_name
)
SELECT
    arrival_date            AS dt,          -- 分区键：入住日期
    hotel_type,
    is_canceled,
    lead_time,
    arrival_year,
    arrival_month,
    arrival_month_id,
    arrival_week,
    arrival_day,
    weekend_nights,
    week_nights,
    total_nights,
    adults,
    children,
    babies,
    total_guests,
    meal,
    country,
    market_segment,
    distribution_channel,
    is_repeated_guest,
    previous_cancellations,
    adr,
    revenue_est,
    parking_spaces,
    special_requests,
    '{BATCH_DATE}'          AS etl_date
FROM enriched
-- 清洗规则 1：剔除无入住人的无效订单
WHERE total_guests > 0
  -- 清洗规则 2：剔除 ADR 异常值（非正数、超过 5000 的极端值）
  AND adr > 0 AND adr <= 5000
  -- 清洗规则 3：剔除入住日期解析失败的记录
  AND arrival_date IS NOT NULL;

-- ============================================================
-- DWD 2：文本情感明细事实表 dwd_text_sentiment_detail
-- 清洗：去重、去 URL、去 @提及、长度过滤、情感标签映射、时间解析
-- ============================================================
CREATE OR REPLACE TABLE dwd_text_sentiment_detail AS
WITH cleaned AS (
    SELECT DISTINCT
        tweet_id,
        user                                                      AS user_name,
        text                                                      AS raw_text,
        -- 清洗规则 1：去除 URL
        REGEXP_REPLACE(text, 'https?://\S+', '', 'g')            AS text_no_url,
        TRY_CAST(sentiment AS TINYINT)                            AS sentiment_label_raw,
        ts                                                        AS raw_ts
    FROM ods_twitter_sentiment
    WHERE text IS NOT NULL
),
normalized AS (
    SELECT
        tweet_id,
        user_name,
        raw_text,
        -- 清洗规则 2：去除 @提及 与多余空白
        TRIM(REGEXP_REPLACE(text_no_url, '@\w+', '', 'g'))       AS clean_text,
        -- 清洗规则 3：情感标签映射（原始 0=负面, 4=正面）
        CASE sentiment_label_raw WHEN 0 THEN 'negative'
                                 WHEN 4 THEN 'positive'
                                 ELSE 'unknown' END               AS sentiment,
        -- 清洗规则 4：时间解析（原始格式 "Mon Apr 06 22:19:45 PDT 2009"）
        --   使用 TRY_CAST + NULLIF 容错：无匹配或格式不规整的记录置为 NULL，不中断任务
        TRY_CAST(NULLIF(REGEXP_EXTRACT(raw_ts, '(\d{4})$', 1), '') AS SMALLINT) AS ts_year,
        m.month_num                                                           AS ts_month,
        TRY_CAST(NULLIF(REGEXP_EXTRACT(raw_ts, '^\w{3} \w{3} (\d{2})', 1), '') AS TINYINT) AS ts_day
    FROM cleaned
    LEFT JOIN dim_month_map m
           ON REGEXP_EXTRACT(raw_ts, '^\w{3} (\w{3})', 1) = SUBSTR(m.month_name, 1, 3)
),
dated AS (
    SELECT
        n.*,
        CASE WHEN ts_year IS NOT NULL AND ts_month IS NOT NULL AND ts_day IS NOT NULL
             THEN MAKE_DATE(ts_year, ts_month, ts_day)
             ELSE NULL END  AS dt
    FROM normalized n
)
SELECT
    dt,
    tweet_id,
    user_name,
    clean_text,
    -- 质量字段：文本长度与空格数，供下游质量过滤使用
    LENGTH(clean_text)                      AS text_len,
    LENGTH(clean_text) - LENGTH(REPLACE(clean_text, ' ', '')) AS space_cnt,
    sentiment,
    '{BATCH_DATE}'                          AS etl_date
FROM dated
-- 清洗规则 5：剔除空文本、过短文本与时间解析失败的记录
WHERE clean_text IS NOT NULL
  AND LENGTH(clean_text) >= 10
  AND dt IS NOT NULL;

-- ============================================================
-- DWD 3：弹幕明细事实表 dwd_danmaku_detail
-- 清洗：去表情符号、去特殊字符、长度过滤、去重
-- 说明：RE2 引擎不支持 \u 转义，中文范围使用 Unicode 属性类 \p{Han}
-- ============================================================
CREATE OR REPLACE TABLE dwd_danmaku_detail AS
WITH base AS (
    SELECT
        danmaku_id,
        video_bvid,
        content,
        send_time,
        CASE WHEN send_time IS NULL OR TRIM(send_time) = '' THEN NULL
             ELSE CAST(send_time AS TIMESTAMP) END      AS send_ts
    FROM ods_bilibili_danmaku
),
cleaned AS (
    SELECT
        danmaku_id,
        video_bvid,
        CAST(send_ts AS DATE) AS dt,
        send_ts,
        content AS raw_content,
        -- 清洗规则 1：剔除表情、颜文字、特殊符号，仅保留中文、英文、数字与常用标点
        REGEXP_REPLACE(content, '[^\p{Han}A-Za-z0-9，。！？、：；（）]', '', 'g') AS clean_content
    FROM base
    WHERE send_ts IS NOT NULL
)
SELECT DISTINCT
    danmaku_id,
    video_bvid,
    dt,
    send_ts,
    raw_content,
    clean_content,
    LENGTH(clean_content) AS text_len,
    '{BATCH_DATE}'        AS etl_date
FROM cleaned
-- 清洗规则 2：剔除清洗后为空或过短的弹幕（纯表情/纯符号）
WHERE LENGTH(clean_content) >= 2;
