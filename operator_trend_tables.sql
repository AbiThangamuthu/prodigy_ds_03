/* ============================================================================
   Operator 360 — Overview chart tables
   Source: gold.plix.player_game_name_daily_activity   (the only source table)
   Dialect: Trino / Starburst

   RUN ORDER: Q1 -> Q2 -> Q3 (backfill, once), then Q5 -> Q6 -> Q7 daily.
   Q1 must always run before Q2: Q2 joins to it, and a player missing from the
   debut table is silently misclassified as "returning".

   Standing filters below replicate the cube's exactly:
       active > 0
       player_group IS NULL OR LOWER(player_group) NOT IN (streamer/test/...)
   `excluded` and `is_test_brand` are intentionally NOT filtered, because the
   current cube queries do not filter them.
   ============================================================================ */


/* ===== Q1 — BACKFILL: operator x player debut dates ======================== */
CREATE TABLE gold.plix.operator_player_debut AS
SELECT
    operator,
    player_id,
    MIN(reporting_date) AS first_active_date
FROM gold.plix.player_game_name_daily_activity
WHERE active > 0
  AND (player_group IS NULL
       OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY operator, player_id;


/* ===== Q2 — BACKFILL: daily trend (operator x brand x day + All Brands) ==== */
CREATE TABLE gold.plix.operator_daily_trend AS
WITH base AS (
    SELECT
        a.reporting_date, a.operator, a.brand, a.game_name, a.player_id,
        CAST(a.turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(a.ggr_eur      AS DOUBLE) AS ggr_eur,
        CAST(a.ngr_eur      AS DOUBLE) AS ngr_eur,
        CAST(a.rounds       AS DOUBLE) AS rounds,
        CAST(a.ggr_usd      AS DOUBLE) AS ggr_usd,
        CAST(a.ngr_usd      AS DOUBLE) AS ngr_usd,
        CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE) AS turnover_usd_row,
        d.first_active_date
    FROM gold.plix.player_game_name_daily_activity a
    LEFT JOIN gold.plix.operator_player_debut d
           ON d.operator = a.operator AND d.player_id = a.player_id
    WHERE a.active > 0
      AND (a.player_group IS NULL
           OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
),
agg AS (
    SELECT
        reporting_date, operator, brand,
        SUM(turnover_eur)         AS turnover,
        SUM(ggr_eur)              AS ggr,
        SUM(ngr_eur)              AS ngr,
        SUM(rounds)               AS rounds,
        SUM(turnover_usd_row)     AS turnover_usd,
        SUM(ggr_usd)              AS ggr_usd,
        SUM(ngr_usd)              AS ngr_usd,
        COUNT(DISTINCT player_id) AS active_players,
        COUNT(DISTINCT game_name) AS active_games,
        COUNT(DISTINCT brand)     AS active_brands,
        COUNT(DISTINCT CASE WHEN first_active_date = reporting_date THEN player_id END) AS new_players,
        COUNT(DISTINCT CASE WHEN first_active_date < reporting_date THEN player_id END) AS returning_players,
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_eur     ELSE 0 END) AS new_player_turnover,
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_eur     ELSE 0 END) AS returning_player_turnover,
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_usd_row ELSE 0 END) AS new_player_turnover_usd,
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_usd_row ELSE 0 END) AS returning_player_turnover_usd
    FROM base
    GROUP BY reporting_date, operator, brand

    UNION ALL

    SELECT
        reporting_date, operator, 'All Brands',
        SUM(turnover_eur), SUM(ggr_eur), SUM(ngr_eur), SUM(rounds),
        SUM(turnover_usd_row), SUM(ggr_usd), SUM(ngr_usd),
        COUNT(DISTINCT player_id),
        COUNT(DISTINCT game_name),
        COUNT(DISTINCT brand),
        COUNT(DISTINCT CASE WHEN first_active_date = reporting_date THEN player_id END),
        COUNT(DISTINCT CASE WHEN first_active_date < reporting_date THEN player_id END),
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_eur     ELSE 0 END),
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_eur     ELSE 0 END),
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_usd_row ELSE 0 END),
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_usd_row ELSE 0 END)
    FROM base
    GROUP BY reporting_date, operator
)
SELECT
    agg.*,
    CASE WHEN turnover       > 0 THEN ggr     / turnover     * 100 END AS margin_pct,
    CASE WHEN turnover_usd   > 0 THEN ggr_usd / turnover_usd * 100 END AS margin_pct_usd,
    CASE WHEN active_players > 0 THEN rounds  / active_players     END AS rounds_per_player
FROM agg;


/* ===== Q3 — BACKFILL: per-game daily turnover (Stack By -> Game) =========== */
CREATE TABLE gold.plix.operator_game_daily_turnover AS
WITH base AS (
    SELECT
        reporting_date, operator, brand, game_name,
        CAST(turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(real_bet_usd AS DOUBLE) + CAST(bonus_bet_usd AS DOUBLE) AS turnover_usd_row
    FROM gold.plix.player_game_name_daily_activity
    WHERE active > 0
      AND (player_group IS NULL
           OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'))
)
SELECT reporting_date, operator, brand, game_name,
       SUM(turnover_eur) AS turnover, SUM(turnover_usd_row) AS turnover_usd
FROM base
GROUP BY reporting_date, operator, brand, game_name
UNION ALL
SELECT reporting_date, operator, 'All Brands', game_name,
       SUM(turnover_eur), SUM(turnover_usd_row)
FROM base
GROUP BY reporting_date, operator, game_name;


/* ===== Q4 — VERIFY the backfill against the live table ===================== */
/* Same day, same operator, straight from the source. Every figure must match
   the corresponding row in operator_daily_trend. */
SELECT
    COUNT(DISTINCT player_id) AS active_players,
    COUNT(DISTINCT game_name) AS active_games,
    COUNT(DISTINCT brand)     AS active_brands,
    SUM(CAST(turnover_eur AS DOUBLE)) AS turnover,
    SUM(CAST(ggr_eur      AS DOUBLE)) AS ggr
FROM gold.plix.player_game_name_daily_activity
WHERE reporting_date = DATE '2026-09-23'
  AND operator = 'Gamdom'
  AND active > 0
  AND (player_group IS NULL
       OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'));

SELECT active_players, active_games, active_brands, turnover, ggr,
       new_players, returning_players
FROM gold.plix.operator_daily_trend
WHERE reporting_date = DATE '2026-09-23'
  AND operator = 'Gamdom'
  AND brand = 'All Brands';


/* ###########################################################################
   DAILY REFRESH — Q5, Q6, Q7. Run in this order.
   Swap the two `CURRENT_DATE - INTERVAL '1' DAY` expressions for a literal
   date to reprocess a specific day.
   ########################################################################### */


/* ===== Q5 — DAILY: add players who debuted on the load date =============== */
INSERT INTO gold.plix.operator_player_debut (operator, player_id, first_active_date)
SELECT a.operator, a.player_id, MIN(a.reporting_date)
FROM gold.plix.player_game_name_daily_activity a
LEFT JOIN gold.plix.operator_player_debut d
       ON d.operator = a.operator AND d.player_id = a.player_id
WHERE a.reporting_date = CURRENT_DATE - INTERVAL '1' DAY
  AND d.player_id IS NULL
  AND a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.operator, a.player_id;


/* ===== Q6 — DAILY: rebuild that day in operator_daily_trend =============== */
DELETE FROM gold.plix.operator_daily_trend
WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY;

INSERT INTO gold.plix.operator_daily_trend (
    reporting_date, operator, brand,
    turnover, ggr, ngr, rounds, turnover_usd, ggr_usd, ngr_usd,
    active_players, active_games, active_brands,
    new_players, returning_players,
    new_player_turnover, returning_player_turnover,
    new_player_turnover_usd, returning_player_turnover_usd,
    margin_pct, margin_pct_usd, rounds_per_player
)
WITH base AS (
    SELECT
        a.reporting_date, a.operator, a.brand, a.game_name, a.player_id,
        CAST(a.turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(a.ggr_eur      AS DOUBLE) AS ggr_eur,
        CAST(a.ngr_eur      AS DOUBLE) AS ngr_eur,
        CAST(a.rounds       AS DOUBLE) AS rounds,
        CAST(a.ggr_usd      AS DOUBLE) AS ggr_usd,
        CAST(a.ngr_usd      AS DOUBLE) AS ngr_usd,
        CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE) AS turnover_usd_row,
        d.first_active_date
    FROM gold.plix.player_game_name_daily_activity a
    LEFT JOIN gold.plix.operator_player_debut d
           ON d.operator = a.operator AND d.player_id = a.player_id
    WHERE a.reporting_date = CURRENT_DATE - INTERVAL '1' DAY
      AND a.active > 0
      AND (a.player_group IS NULL
           OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
),
agg AS (
    SELECT
        reporting_date, operator, brand,
        SUM(turnover_eur)         AS turnover,
        SUM(ggr_eur)              AS ggr,
        SUM(ngr_eur)              AS ngr,
        SUM(rounds)               AS rounds,
        SUM(turnover_usd_row)     AS turnover_usd,
        SUM(ggr_usd)              AS ggr_usd,
        SUM(ngr_usd)              AS ngr_usd,
        COUNT(DISTINCT player_id) AS active_players,
        COUNT(DISTINCT game_name) AS active_games,
        COUNT(DISTINCT brand)     AS active_brands,
        COUNT(DISTINCT CASE WHEN first_active_date = reporting_date THEN player_id END) AS new_players,
        COUNT(DISTINCT CASE WHEN first_active_date < reporting_date THEN player_id END) AS returning_players,
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_eur     ELSE 0 END) AS new_player_turnover,
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_eur     ELSE 0 END) AS returning_player_turnover,
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_usd_row ELSE 0 END) AS new_player_turnover_usd,
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_usd_row ELSE 0 END) AS returning_player_turnover_usd
    FROM base
    GROUP BY reporting_date, operator, brand

    UNION ALL

    SELECT
        reporting_date, operator, 'All Brands',
        SUM(turnover_eur), SUM(ggr_eur), SUM(ngr_eur), SUM(rounds),
        SUM(turnover_usd_row), SUM(ggr_usd), SUM(ngr_usd),
        COUNT(DISTINCT player_id),
        COUNT(DISTINCT game_name),
        COUNT(DISTINCT brand),
        COUNT(DISTINCT CASE WHEN first_active_date = reporting_date THEN player_id END),
        COUNT(DISTINCT CASE WHEN first_active_date < reporting_date THEN player_id END),
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_eur     ELSE 0 END),
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_eur     ELSE 0 END),
        SUM(CASE WHEN first_active_date = reporting_date THEN turnover_usd_row ELSE 0 END),
        SUM(CASE WHEN first_active_date < reporting_date THEN turnover_usd_row ELSE 0 END)
    FROM base
    GROUP BY reporting_date, operator
)
SELECT
    agg.*,
    CASE WHEN turnover       > 0 THEN ggr     / turnover     * 100 END,
    CASE WHEN turnover_usd   > 0 THEN ggr_usd / turnover_usd * 100 END,
    CASE WHEN active_players > 0 THEN rounds  / active_players     END
FROM agg;


/* ===== Q7 — DAILY: rebuild that day in operator_game_daily_turnover ======= */
DELETE FROM gold.plix.operator_game_daily_turnover
WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY;

INSERT INTO gold.plix.operator_game_daily_turnover (
    reporting_date, operator, brand, game_name, turnover, turnover_usd
)
WITH base AS (
    SELECT
        reporting_date, operator, brand, game_name,
        CAST(turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(real_bet_usd AS DOUBLE) + CAST(bonus_bet_usd AS DOUBLE) AS turnover_usd_row
    FROM gold.plix.player_game_name_daily_activity
    WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY
      AND active > 0
      AND (player_group IS NULL
           OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'))
)
SELECT reporting_date, operator, brand, game_name,
       SUM(turnover_eur), SUM(turnover_usd_row)
FROM base
GROUP BY reporting_date, operator, brand, game_name
UNION ALL
SELECT reporting_date, operator, 'All Brands', game_name,
       SUM(turnover_eur), SUM(turnover_usd_row)
FROM base
GROUP BY reporting_date, operator, game_name;
