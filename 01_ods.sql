-- ============================================================
-- ODS 贴源层（Operational Data Store）
-- 职责：原样落地，不做任何业务逻辑处理，保留原始字段与格式，保证可回溯
-- 约定：所有字段以 VARCHAR 落地，避免在贴源层因类型推断丢失数据
-- ============================================================

-- 事实源 1：酒店预订业务数据（原始 CSV）
CREATE OR REPLACE TABLE ods_hotel_booking AS
SELECT
    *,
    '{BATCH_DATE}'   AS etl_date,          -- 批次日期（分区字段）
    'hotel_bookings.csv' AS src_table      -- 来源标识
FROM read_csv('{HOTEL_CSV}', header = true, all_varchar = true);

-- 事实源 2：Twitter 情感语料（160 万行，原始为 ISO-8859-1 编码）
--         编码在接入层统一归一化为 UTF-8 后落地（见 run_etl.py: normalize_twitter_encoding）
CREATE OR REPLACE TABLE ods_twitter_sentiment AS
SELECT
    *,
    '{BATCH_DATE}'   AS etl_date,
    'twitter_sentiment' AS src_table
FROM read_csv(
    '{TWITTER_UTF8}',
    header   = false,
    ignore_errors = true,
    columns  = {
        'sentiment' : 'VARCHAR',
        'tweet_id'  : 'VARCHAR',
        'ts'        : 'VARCHAR',
        'query'     : 'VARCHAR',
        'user'      : 'VARCHAR',
        'text'      : 'VARCHAR'
    }
);

-- 事实源 3：B 站弹幕行为数据（原始 TXT，一行一条）
--         由 run_etl.py 从文本文件装载（见 load_danmaku_ods）
CREATE OR REPLACE TABLE ods_bilibili_danmaku (
    danmaku_id   BIGINT,
    video_bvid   VARCHAR,
    content      VARCHAR,
    send_time    VARCHAR,
    etl_date     VARCHAR,
    src_table    VARCHAR
);

-- 维表源：B 站视频元信息（由 JSON 装载）
CREATE OR REPLACE TABLE ods_bilibili_video (
    bvid         VARCHAR,
    title        VARCHAR,
    author       VARCHAR,
    publish_time VARCHAR,
    view_cnt     BIGINT,
    danmaku_cnt  BIGINT,
    like_cnt     BIGINT,
    coin_cnt     BIGINT,
    favorite_cnt BIGINT,
    share_cnt    BIGINT,
    reply_cnt    BIGINT,
    etl_date     VARCHAR,
    src_table    VARCHAR
);
