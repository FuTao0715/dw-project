-- ============================================================
-- DIM 维度层
-- 设计说明：采用星型模型（Star Schema）——维度表直接挂在事实表上，
--           不做进一步的规范化（不采用雪花模型），
--           理由：查询链路更短、join 更少、更适合聚合分析，
--                 且维度表体量小，冗余存储成本可忽略。
-- ============================================================

-- ---------- 日期维度表 dim_date ----------
-- 覆盖事实数据的时间范围，预计算所有时间属性，避免下游重复计算
CREATE OR REPLACE TABLE dim_date AS
WITH spine AS (
    -- 覆盖全部事实数据的时间范围（Twitter 语料最早 2009 年，B 站数据最新 2026 年）
    SELECT UNNEST(
        generate_series(DATE '2009-01-01', DATE '2027-12-31', INTERVAL 1 DAY)
    )::DATE AS d
),
base AS (
    SELECT
        d,
        CAST(STRFTIME(d, '%Y%m%d') AS INTEGER) AS date_key,
        EXTRACT(year    FROM d)               AS year_num,
        EXTRACT(quarter FROM d)               AS quarter_num,
        EXTRACT(month   FROM d)               AS month_num,
        STRFTIME(d, '%Y-%m')                  AS month_id,
        EXTRACT(week    FROM d)               AS week_num,
        EXTRACT(day     FROM d)               AS day_num,
        DAYOFWEEK(d)                          AS dow   -- 0=周日 1=周一 ... 6=周六
    FROM spine
)
SELECT
    date_key,
    d                                     AS date,
    year_num,
    quarter_num,
    month_num,
    month_id,
    week_num,
    day_num,
    -- 预先算出 dayofweek 列后再做 CASE 判断，避免解析器对 CASE 内嵌 EXTRACT 的兼容问题
    CASE dow WHEN 0 THEN '周日' WHEN 1 THEN '周一' WHEN 2 THEN '周二'
             WHEN 3 THEN '周三' WHEN 4 THEN '周四' WHEN 5 THEN '周五'
             ELSE '周六' END                                AS weekday_name,
    CASE WHEN dow IN (0, 6) THEN TRUE ELSE FALSE END        AS is_weekend,
    CASE WHEN dow IN (0, 6) THEN '周末' ELSE '工作日' END    AS day_type
FROM base;

-- ---------- 酒店类型维 ----------
-- 注意：必须先取 DISTINCT 再算代理键，否则 ROW_NUMBER 会让每行唯一，DISTINCT 失效，
--       维度表会被放大到明细规模，后续 join 造成指标膨胀（fan-out）
CREATE OR REPLACE TABLE dim_hotel_type AS
WITH distinct_val AS (
    SELECT DISTINCT hotel_type FROM dwd_booking_detail
)
SELECT
    ROW_NUMBER() OVER (ORDER BY hotel_type) AS hotel_type_key,
    hotel_type,
    CASE WHEN hotel_type = 'Resort Hotel' THEN '度假酒店'
         WHEN hotel_type = 'City Hotel'   THEN '城市酒店'
         ELSE '其他' END AS hotel_type_cn
FROM distinct_val;

-- ---------- 市场细分维 ----------
CREATE OR REPLACE TABLE dim_market_segment AS
WITH distinct_val AS (
    SELECT DISTINCT market_segment FROM dwd_booking_detail
)
SELECT
    ROW_NUMBER() OVER (ORDER BY market_segment) AS segment_key,
    market_segment,
    CASE market_segment
        WHEN 'ONLINE TA'        THEN '在线旅行社'
        WHEN 'OFFLINE TA/TO'    THEN '线下旅行社/旅游运营商'
        WHEN 'DIRECT'           THEN '直接预订'
        WHEN 'CORPORATE'        THEN '企业客户'
        WHEN 'GROUPS'           THEN '团队'
        WHEN 'COMPLEMENTARY'    THEN '免费赠送'
        WHEN 'AVIATION'         THEN '航空'
        ELSE '其他' END AS segment_cn
FROM distinct_val;

-- ---------- 国家/地区维 ----------
CREATE OR REPLACE TABLE dim_country AS
WITH src AS (
    SELECT DISTINCT country AS country_code FROM dwd_booking_detail WHERE country IS NOT NULL
),
region_map AS (
    SELECT * FROM (VALUES
        ('PRT','葡萄牙','欧洲'), ('GBR','英国','欧洲'),   ('ESP','西班牙','欧洲'),
        ('FRA','法国','欧洲'),   ('DEU','德国','欧洲'),   ('ITA','意大利','欧洲'),
        ('IRL','爱尔兰','欧洲'), ('NLD','荷兰','欧洲'),   ('AUT','奥地利','欧洲'),
        ('BEL','比利时','欧洲'), ('CHE','瑞士','欧洲'),   ('SWE','瑞典','欧洲'),
        ('USA','美国','北美'),   ('CAN','加拿大','北美'), ('MEX','墨西哥','北美'),
        ('BRA','巴西','南美'),   ('ARG','阿根廷','南美'),
        ('CHN','中国','亚洲'),   ('JPN','日本','亚洲'),   ('KOR','韩国','亚洲'),
        ('IND','印度','亚洲'),   ('AUS','澳大利亚','大洋洲'), ('NZL','新西兰','大洋洲')
    ) AS t(country_code, country_name, region)
)
SELECT
    ROW_NUMBER() OVER (ORDER BY s.country_code) AS country_key,
    s.country_code,
    COALESCE(r.country_name, '其他' || s.country_code) AS country_name,
    COALESCE(r.region, '其他地区')                      AS region
FROM src s
LEFT JOIN region_map r ON s.country_code = r.country_code;

-- ---------- 视频维 ----------
CREATE OR REPLACE TABLE dim_video AS
SELECT DISTINCT
    bvid                          AS video_key,
    bvid,
    title,
    author,
    CAST(publish_time AS TIMESTAMP) AS publish_ts,
    view_cnt,
    danmaku_cnt,
    like_cnt,
    coin_cnt,
    favorite_cnt,
    share_cnt,
    reply_cnt
FROM ods_bilibili_video;

-- ============================================================
-- 缓慢变化维 SCD Type 2（拉链表）实现演示
-- 场景：视频的标题/分类可能被作者修改，需要保留历史状态与生效区间
-- 实现：start_date + end_date + is_current 三字段标识版本有效期
-- ============================================================

-- Step 1：初始化——所有记录作为第一个版本，生效区间开放到最大日期
DROP TABLE IF EXISTS dim_video_scd2;
CREATE TABLE dim_video_scd2 AS
SELECT
    video_key,
    title,
    author,
    DATE '2026-01-12'  AS start_date,        -- 版本生效日
    DATE '9999-12-31'  AS end_date,          -- 9999-12-31 表示当前有效版本
    TRUE               AS is_current,
    1                  AS version_num
FROM dim_video;

-- Step 2：模拟上游源表发生变更（视频标题被修改）
DROP TABLE IF EXISTS tmp_video_source_change;
CREATE TABLE tmp_video_source_change AS
SELECT video_key, title || '【已更新封面】' AS title, author
FROM dim_video;

-- Step 3：SCD2 拉链更新（三步走：快照版本号 -> 识别变更 -> 关旧插新）
--   3.0 更新前先快照各维度键的最大版本号（避免更新过程中自引用同表）
CREATE OR REPLACE TABLE tmp_dim_video_maxver AS
SELECT video_key, MAX(version_num) AS max_ver
FROM dim_video_scd2
GROUP BY video_key;

--   3.1 识别需要开新版本的记录（仅标题发生变化的记录才需开新版本）
CREATE OR REPLACE TABLE tmp_scd2_changed AS
SELECT d.video_key
FROM dim_video_scd2 d
JOIN tmp_video_source_change s ON s.video_key = d.video_key
WHERE d.is_current = TRUE
  AND s.title <> d.title;

--   3.2 关闭旧版本（end_date = 变更日 - 1 天，is_current = FALSE）
UPDATE dim_video_scd2
SET end_date   = DATE '2026-02-01' - INTERVAL 1 DAY,
    is_current = FALSE
WHERE is_current = TRUE
  AND video_key IN (SELECT video_key FROM tmp_scd2_changed);

--   3.3 写入新版本（start_date = 变更日，end_date = 9999-12-31 表示当前有效）
INSERT INTO dim_video_scd2
SELECT
    s.video_key,
    s.title,
    s.author,
    DATE '2026-02-01' AS start_date,
    DATE '9999-12-31' AS end_date,
    TRUE              AS is_current,
    m.max_ver + 1     AS version_num
FROM tmp_video_source_change s
JOIN tmp_scd2_changed   c ON s.video_key = c.video_key
JOIN tmp_dim_video_maxver m ON s.video_key = m.video_key;

-- Step 4：清理临时表
DROP TABLE IF EXISTS tmp_dim_video_maxver;
DROP TABLE IF EXISTS tmp_scd2_changed;
DROP TABLE IF EXISTS tmp_video_source_change;
