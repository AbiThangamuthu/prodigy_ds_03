/* ============================================================================
   Operator & Brand Performance (CUBE report) — live-query aggregate tables
   Source: gold.plix.player_game_name_daily_activity   (the only source table)
   Dialect: Trino / Starburst

   WHY THESE TABLES
   The report (fd-justslots/DEV/CUBE/operator_brand_performance_parameterized.html)
   fires its live loaders (Custom range / active filters / Detail View) straight
   at the raw activity cube. The expensive shapes, all eliminated below:

     loadKpiLive / loadOperatorLeaderboardLive / loadLeaderboardTurnoverLive /
     loadOperatorHealthLive / loadTrendTurnoverLive
        → T1  operator_brand_daily_stats   (any window = plain SUM over days)
     Detail View _fetchDetailViewLive: (brand, game) turnover/ggr/rounds
        → T2  operator_brand_game_daily_stats
     Detail View distinct players per (brand, game) + churn base per brand —
     today TWO player-grain _cubeQDimAll enumerations ship up to 50x10k raw
     player rows over the bridge just to count them
        → T3  operator_player_game_day     (cube does countDistinct server-side)
     Detail View dropdown catalogue: 4 scans over 400 days
        → T4  operator_dimension_catalogue (one tiny table, full rebuild)

   GRAIN RULE: every table is DAILY-grain and additive, so the report's
   arbitrary Custom windows become SUM(...) GROUP BY <dims> over a date range —
   no period precomputation, no player rows crossing the bridge.

   Standing filters below replicate the cube's exactly:
       active > 0
       player_group IS NULL OR LOWER(player_group) NOT IN (streamer/test/...)
   `excluded` and `is_test_brand` are intentionally NOT filtered, because the
   current cube queries do not filter them.

   active_players in T1/T2 is a PER-DAY distinct — reference only. Summing it
   over a window OVERCOUNTS players active on several days. Exact window
   distincts must come from T3 via COUNT(DISTINCT player_id) (the cube's
   `active` measure should point at T3).

   USD parity with the report: turnover_usd = real_bet_usd + bonus_bet_usd.

   RUN ORDER: Q1-Q4 once (backfill), then D1-D4 daily in any order.
   To reprocess a specific day instead of yesterday, swap the two
   `CURRENT_DATE - INTERVAL '1' DAY` expressions of that table's D-query
   for a literal date.
   ============================================================================ */


/* ###########################################################################
   T1 — BACKFILL: operator x brand x day rollup
   Covers the report's KPI / leaderboard / health / trend live queries:
   totals, (operator, account_manager), (operator), (brand), (operator, brand)
   365-day universe, and the (operator x day) trend series. All additive.
   ########################################################################### */

CREATE TABLE gold.plix.operator_brand_daily_stats AS
SELECT
    a.reporting_date,
    a.operator,
    a.account_manager,
    a.brand,
    a.country,
    CAST(SUM(a.turnover_eur) AS DOUBLE) AS turnover_eur,
    CAST(SUM(a.ggr_eur)      AS DOUBLE) AS ggr_eur,
    CAST(SUM(a.ngr_eur)      AS DOUBLE) AS ngr_eur,
    CAST(SUM(a.rounds)       AS DOUBLE) AS rounds,
    CAST(SUM(a.bets)         AS DOUBLE) AS bets,
    CAST(SUM(a.real_bet_eur) AS DOUBLE) AS real_bet_eur,
    CAST(SUM(a.bonus_bet_eur) AS DOUBLE) AS bonus_bet_eur,
    CAST(SUM(CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE)) AS DOUBLE) AS turnover_usd,
    CAST(SUM(a.ggr_usd)      AS DOUBLE) AS ggr_usd,
    CAST(SUM(a.ngr_usd)      AS DOUBLE) AS ngr_usd,
    COUNT(DISTINCT a.player_id) AS active_players   /* per-day distinct — see header */
FROM gold.plix.player_game_name_daily_activity a
WHERE a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.account_manager, a.brand, a.country;


/* ###########################################################################
   T2 — BACKFILL: operator x brand x game x day rollup
   Covers Detail View's (brand, game) current/prior fetches — turnover, ggr,
   rounds, games-causing-loss (ggr < 0), active-games lists — and the
   per-operator Top Games table.
   ########################################################################### */

CREATE TABLE gold.plix.operator_brand_game_daily_stats AS
SELECT
    a.reporting_date,
    a.operator,
    a.brand,
    a.game_name,
    CAST(SUM(a.turnover_eur) AS DOUBLE) AS turnover_eur,
    CAST(SUM(a.ggr_eur)      AS DOUBLE) AS ggr_eur,
    CAST(SUM(a.ngr_eur)      AS DOUBLE) AS ngr_eur,
    CAST(SUM(a.rounds)       AS DOUBLE) AS rounds,
    CAST(SUM(a.bets)         AS DOUBLE) AS bets,
    CAST(SUM(CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE)) AS DOUBLE) AS turnover_usd,
    CAST(SUM(a.ggr_usd)      AS DOUBLE) AS ggr_usd,
    CAST(SUM(a.ngr_usd)      AS DOUBLE) AS ngr_usd,
    COUNT(DISTINCT a.player_id) AS active_players   /* per-day distinct — see header */
FROM gold.plix.player_game_name_daily_activity a
WHERE a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.brand, a.game_name;


/* ###########################################################################
   T3 — BACKFILL: player x game x day (pre-filtered, narrow)
   The exact-distinct workhorse. One row per active player x game x day per
   detail-scope dimension combo. The cube defines active as
   COUNT(DISTINCT player_id) over THIS table, so Detail View's per-game player
   counts, the per-brand churn base, and the KPI/leaderboard/health player
   figures are all computed server-side — the two _cubeQDimAll player
   enumerations in the report become one grouped count query each.
   Row count is close to the raw table (only country/channel/transaction_desc
   and filtered-out rows collapse), but the columns are few and the answers
   are tiny — that is what makes the bridge round-trips fast.
   ########################################################################### */

CREATE TABLE gold.plix.operator_player_game_day AS
SELECT
    a.reporting_date,
    a.operator,
    a.brand,
    a.game_name,
    a.instance,
    a.wallet,
    a.customer_entity,
    a.player_group,
    a.player_id,
    CAST(SUM(a.turnover_eur) AS DOUBLE) AS turnover_eur,
    CAST(SUM(a.ggr_eur)      AS DOUBLE) AS ggr_eur,
    CAST(SUM(a.rounds)       AS DOUBLE) AS rounds
FROM gold.plix.player_game_name_daily_activity a
WHERE a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.brand, a.game_name,
         a.instance, a.wallet, a.customer_entity, a.player_group, a.player_id;


/* ###########################################################################
   T4 — BACKFILL: operator dimension catalogue (trailing 400 days)
   Covers Detail View's Environment / Wallet / Entity / Segment dropdowns and
   the operator->dimension cascade — four 400-day scans become one tiny table.
   Full rebuild on every refresh: dimension membership changes slowly and the
   table is small.
   ########################################################################### */

CREATE TABLE gold.plix.operator_dimension_catalogue AS
WITH anchor AS (
    SELECT MAX(reporting_date) AS d
    FROM gold.plix.player_game_name_daily_activity
),
last400 AS (
    SELECT date_add('day', -400, d) AS sd, d AS ed FROM anchor
)
SELECT a.operator, 'instance' AS dimension, a.instance AS value
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.instance IS NOT NULL
GROUP BY a.operator, a.instance
UNION ALL
SELECT a.operator, 'wallet', a.wallet
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.wallet IS NOT NULL
GROUP BY a.operator, a.wallet
UNION ALL
SELECT a.operator, 'entity', a.customer_entity
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.customer_entity IS NOT NULL
GROUP BY a.operator, a.customer_entity
UNION ALL
SELECT a.operator, 'segment', a.player_group
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.player_group IS NOT NULL
GROUP BY a.operator, a.player_group;


/* ###########################################################################
   DAILY REFRESH — D1..D4. Run after the source table's daily load.
   Swap `CURRENT_DATE - INTERVAL '1' DAY` for a literal date to reprocess.
   ########################################################################### */

/* ===== D1 — T1: rebuild the load date ====================================== */
DELETE FROM gold.plix.operator_brand_daily_stats
WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY;

INSERT INTO gold.plix.operator_brand_daily_stats (
    reporting_date, operator, account_manager, brand, country,
    turnover_eur, ggr_eur, ngr_eur, rounds, bets, real_bet_eur, bonus_bet_eur,
    turnover_usd, ggr_usd, ngr_usd, active_players
)
SELECT
    a.reporting_date,
    a.operator,
    a.account_manager,
    a.brand,
    a.country,
    CAST(SUM(a.turnover_eur) AS DOUBLE),
    CAST(SUM(a.ggr_eur)      AS DOUBLE),
    CAST(SUM(a.ngr_eur)      AS DOUBLE),
    CAST(SUM(a.rounds)       AS DOUBLE),
    CAST(SUM(a.bets)         AS DOUBLE),
    CAST(SUM(a.real_bet_eur) AS DOUBLE),
    CAST(SUM(a.bonus_bet_eur) AS DOUBLE),
    CAST(SUM(CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE)) AS DOUBLE),
    CAST(SUM(a.ggr_usd)      AS DOUBLE),
    CAST(SUM(a.ngr_usd)      AS DOUBLE),
    COUNT(DISTINCT a.player_id)
FROM gold.plix.player_game_name_daily_activity a
WHERE a.reporting_date = CURRENT_DATE - INTERVAL '1' DAY
  AND a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.account_manager, a.brand, a.country;


/* ===== D2 — T2: rebuild the load date ====================================== */
DELETE FROM gold.plix.operator_brand_game_daily_stats
WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY;

INSERT INTO gold.plix.operator_brand_game_daily_stats (
    reporting_date, operator, brand, game_name,
    turnover_eur, ggr_eur, ngr_eur, rounds, bets,
    turnover_usd, ggr_usd, ngr_usd, active_players
)
SELECT
    a.reporting_date,
    a.operator,
    a.brand,
    a.game_name,
    CAST(SUM(a.turnover_eur) AS DOUBLE),
    CAST(SUM(a.ggr_eur)      AS DOUBLE),
    CAST(SUM(a.ngr_eur)      AS DOUBLE),
    CAST(SUM(a.rounds)       AS DOUBLE),
    CAST(SUM(a.bets)         AS DOUBLE),
    CAST(SUM(CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE)) AS DOUBLE),
    CAST(SUM(a.ggr_usd)      AS DOUBLE),
    CAST(SUM(a.ngr_usd)      AS DOUBLE),
    COUNT(DISTINCT a.player_id)
FROM gold.plix.player_game_name_daily_activity a
WHERE a.reporting_date = CURRENT_DATE - INTERVAL '1' DAY
  AND a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.brand, a.game_name;


/* ===== D3 — T3: rebuild the load date ====================================== */
DELETE FROM gold.plix.operator_player_game_day
WHERE reporting_date = CURRENT_DATE - INTERVAL '1' DAY;

INSERT INTO gold.plix.operator_player_game_day (
    reporting_date, operator, brand, game_name,
    instance, wallet, customer_entity, player_group, player_id,
    turnover_eur, ggr_eur, rounds
)
SELECT
    a.reporting_date,
    a.operator,
    a.brand,
    a.game_name,
    a.instance,
    a.wallet,
    a.customer_entity,
    a.player_group,
    a.player_id,
    CAST(SUM(a.turnover_eur) AS DOUBLE),
    CAST(SUM(a.ggr_eur)      AS DOUBLE),
    CAST(SUM(a.rounds)       AS DOUBLE)
FROM gold.plix.player_game_name_daily_activity a
WHERE a.reporting_date = CURRENT_DATE - INTERVAL '1' DAY
  AND a.active > 0
  AND (a.player_group IS NULL
       OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
GROUP BY a.reporting_date, a.operator, a.brand, a.game_name,
         a.instance, a.wallet, a.customer_entity, a.player_group, a.player_id;


/* ===== D4 — T4: full rebuild (trailing 400 days from the new anchor) ======= */
DELETE FROM gold.plix.operator_dimension_catalogue;

INSERT INTO gold.plix.operator_dimension_catalogue (operator, dimension, value)
WITH anchor AS (
    SELECT MAX(reporting_date) AS d
    FROM gold.plix.player_game_name_daily_activity
),
last400 AS (
    SELECT date_add('day', -400, d) AS sd, d AS ed FROM anchor
)
SELECT a.operator, 'instance', a.instance
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.instance IS NOT NULL
GROUP BY a.operator, a.instance
UNION ALL
SELECT a.operator, 'wallet', a.wallet
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.wallet IS NOT NULL
GROUP BY a.operator, a.wallet
UNION ALL
SELECT a.operator, 'entity', a.customer_entity
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.customer_entity IS NOT NULL
GROUP BY a.operator, a.customer_entity
UNION ALL
SELECT a.operator, 'segment', a.player_group
FROM gold.plix.player_game_name_daily_activity a, last400 w
WHERE a.reporting_date BETWEEN w.sd AND w.ed
  AND a.player_group IS NOT NULL
GROUP BY a.operator, a.player_group;


/* ###########################################################################
   VERIFY — every figure must match the source for the same window.
   ########################################################################### */

/* T1/T2 check: one operator, one day */
SELECT
    COUNT(DISTINCT player_id) AS active_players,
    SUM(CAST(turnover_eur AS DOUBLE)) AS turnover,
    SUM(CAST(ggr_eur      AS DOUBLE)) AS ggr,
    SUM(CAST(rounds       AS DOUBLE)) AS rounds
FROM gold.plix.player_game_name_daily_activity
WHERE reporting_date = DATE '2026-09-23'
  AND operator = 'Gamdom'
  AND active > 0
  AND (player_group IS NULL
       OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'));

SELECT
    SUM(active_players) AS day_active_players,
    SUM(turnover_eur)   AS turnover,
    SUM(ggr_eur)        AS ggr,
    SUM(rounds)         AS rounds
FROM gold.plix.operator_brand_daily_stats
WHERE reporting_date = DATE '2026-09-23'
  AND operator = 'Gamdom';

/* T3 check: exact window distinct per (brand, game) — the Detail View shape */
SELECT brand, game_name, COUNT(DISTINCT player_id) AS players
FROM gold.plix.operator_player_game_day
WHERE operator = 'Gamdom'
  AND reporting_date BETWEEN DATE '2026-09-17' AND DATE '2026-09-23'
GROUP BY brand, game_name
ORDER BY players DESC
LIMIT 10;
