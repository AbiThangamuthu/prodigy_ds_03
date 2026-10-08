/* ============================================================================
   gold.plix.operator_game_period_stats  —  "Games on this Operator"
   Source: gold.plix.player_game_name_daily_activity

   Today that section runs, for any period the notebook does not precompute
   (MTD / QTD / L3M / YTD / LastYear), an operator x game x PLAYER query across
   the WHOLE portfolio. Over a year that is the most expensive query the report
   makes — hence "Last 1 year" hanging on "Loading games for this period…".

   One row per period x operator x game (~9 x 100 x 14 = ~13k rows), so the
   section becomes a single filtered query with no distinct counting left.

   Portfolio averages and operator rank are computed HERE. Cube cannot express
   a window function, which is why the report derived them client-side from
   full portfolio grain — and that is what forced it to fetch every operator's
   rows just to render one operator's table.

   Period windows replicate dateRangeForPeriod() in the report exactly, anchored
   on MAX(reporting_date). date_add('month', -n, d) clamps to the last valid day,
   matching the report's _shiftMonths (31 Mar - 1 month -> 28 Feb).

   RUN ORDER
     Q8a  once, to create the table
     Q8b  daily: DELETE FROM + INSERT INTO (no DROP anywhere)
     Q8c  same as Q8b but one period at a time, for a heavy backfill or a rerun
   ============================================================================ */


/* ===== Q8a — ONE TIME: create the table ==================================== */
CREATE TABLE gold.plix.operator_game_period_stats AS
WITH anchor AS (
    SELECT MAX(reporting_date) AS d
    FROM gold.plix.player_game_name_daily_activity
),
all_periods AS (
    SELECT 'Yesterday' AS period, d AS from_date, d AS to_date FROM anchor
    UNION ALL SELECT 'L7D',       date_add('day',  -6, d), d FROM anchor
    UNION ALL SELECT 'L30D',      date_add('day', -29, d), d FROM anchor
    UNION ALL SELECT 'MTD',       date_trunc('month',   d), d FROM anchor
    UNION ALL SELECT 'LastMonth', date_trunc('month', date_add('month', -1, d)),
                                  date_add('day', -1, date_trunc('month', d))    FROM anchor
    UNION ALL SELECT 'QTD',       date_trunc('quarter', d), d FROM anchor
    UNION ALL SELECT 'L3M',       date_add('day', 1, date_add('month',  -3, d)), d FROM anchor
    UNION ALL SELECT 'YTD',       date_trunc('year',    d), d FROM anchor
    UNION ALL SELECT 'LastYear',  date_add('day', 1, date_add('month', -12, d)), d FROM anchor
),
periods AS (
    SELECT * FROM all_periods
),
base AS (
    SELECT
        p.period, a.operator, a.game_name, a.player_id,
        CAST(a.turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(a.ggr_eur      AS DOUBLE) AS ggr_eur,
        CAST(a.ggr_usd      AS DOUBLE) AS ggr_usd,
        CAST(a.rounds       AS DOUBLE) AS rounds,
        CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE) AS turnover_usd_row
    FROM gold.plix.player_game_name_daily_activity a
    JOIN periods p
      ON a.reporting_date BETWEEN p.from_date AND p.to_date
    WHERE a.active > 0
      AND (a.player_group IS NULL
           OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
),
og AS (
    SELECT
        period, operator, game_name,
        SUM(turnover_eur)         AS turnover,
        SUM(ggr_eur)              AS ggr,
        SUM(turnover_usd_row)     AS turnover_usd,
        SUM(ggr_usd)              AS ggr_usd,
        SUM(rounds)               AS rounds,
        COUNT(DISTINCT player_id) AS active_players
    FROM base
    GROUP BY period, operator, game_name
)
SELECT
    period, operator, game_name,
    turnover, ggr, turnover_usd, ggr_usd, active_players, rounds,
    CASE WHEN rounds > 0 THEN turnover     / rounds END AS avg_bet,
    CASE WHEN rounds > 0 THEN turnover_usd / rounds END AS avg_bet_usd,
    AVG(turnover)     OVER (PARTITION BY period, game_name) AS portfolio_avg_turnover,
    AVG(ggr)          OVER (PARTITION BY period, game_name) AS portfolio_avg_ggr,
    AVG(turnover_usd) OVER (PARTITION BY period, game_name) AS portfolio_avg_turnover_usd,
    AVG(ggr_usd)      OVER (PARTITION BY period, game_name) AS portfolio_avg_ggr_usd,
    AVG(CAST(active_players AS DOUBLE))
                      OVER (PARTITION BY period, game_name) AS portfolio_avg_players,
    AVG(rounds)       OVER (PARTITION BY period, game_name) AS portfolio_avg_rounds,
    /* RANK, not ROW_NUMBER: equal turnovers share a rank and the next value
       skips — the tie semantics the report's hand-rolled ranking reproduces. */
    RANK()   OVER (PARTITION BY period, game_name ORDER BY turnover DESC) AS operator_rank,
    COUNT(*) OVER (PARTITION BY period, game_name)                        AS operator_rank_total
FROM og;


/* ===== Q8b — DAILY REFRESH: whole table, no DROP ==========================
   Every period window moves when the anchor moves, so all nine are rebuilt.
   The table is ~13k rows; this is cheap to delete and correct to redo.       */

DELETE FROM gold.plix.operator_game_period_stats;

INSERT INTO gold.plix.operator_game_period_stats (
    period, operator, game_name,
    turnover, ggr, turnover_usd, ggr_usd, active_players, rounds,
    avg_bet, avg_bet_usd,
    portfolio_avg_turnover, portfolio_avg_ggr,
    portfolio_avg_turnover_usd, portfolio_avg_ggr_usd,
    portfolio_avg_players, portfolio_avg_rounds,
    operator_rank, operator_rank_total
)
WITH anchor AS (
    SELECT MAX(reporting_date) AS d
    FROM gold.plix.player_game_name_daily_activity
),
all_periods AS (
    SELECT 'Yesterday' AS period, d AS from_date, d AS to_date FROM anchor
    UNION ALL SELECT 'L7D',       date_add('day',  -6, d), d FROM anchor
    UNION ALL SELECT 'L30D',      date_add('day', -29, d), d FROM anchor
    UNION ALL SELECT 'MTD',       date_trunc('month',   d), d FROM anchor
    UNION ALL SELECT 'LastMonth', date_trunc('month', date_add('month', -1, d)),
                                  date_add('day', -1, date_trunc('month', d))    FROM anchor
    UNION ALL SELECT 'QTD',       date_trunc('quarter', d), d FROM anchor
    UNION ALL SELECT 'L3M',       date_add('day', 1, date_add('month',  -3, d)), d FROM anchor
    UNION ALL SELECT 'YTD',       date_trunc('year',    d), d FROM anchor
    UNION ALL SELECT 'LastYear',  date_add('day', 1, date_add('month', -12, d)), d FROM anchor
),
periods AS (
    SELECT * FROM all_periods
),
base AS (
    SELECT
        p.period, a.operator, a.game_name, a.player_id,
        CAST(a.turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(a.ggr_eur      AS DOUBLE) AS ggr_eur,
        CAST(a.ggr_usd      AS DOUBLE) AS ggr_usd,
        CAST(a.rounds       AS DOUBLE) AS rounds,
        CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE) AS turnover_usd_row
    FROM gold.plix.player_game_name_daily_activity a
    JOIN periods p
      ON a.reporting_date BETWEEN p.from_date AND p.to_date
    WHERE a.active > 0
      AND (a.player_group IS NULL
           OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
),
og AS (
    SELECT
        period, operator, game_name,
        SUM(turnover_eur)         AS turnover,
        SUM(ggr_eur)              AS ggr,
        SUM(turnover_usd_row)     AS turnover_usd,
        SUM(ggr_usd)              AS ggr_usd,
        SUM(rounds)               AS rounds,
        COUNT(DISTINCT player_id) AS active_players
    FROM base
    GROUP BY period, operator, game_name
)
SELECT
    period, operator, game_name,
    turnover, ggr, turnover_usd, ggr_usd, active_players, rounds,
    CASE WHEN rounds > 0 THEN turnover     / rounds END,
    CASE WHEN rounds > 0 THEN turnover_usd / rounds END,
    AVG(turnover)     OVER (PARTITION BY period, game_name),
    AVG(ggr)          OVER (PARTITION BY period, game_name),
    AVG(turnover_usd) OVER (PARTITION BY period, game_name),
    AVG(ggr_usd)      OVER (PARTITION BY period, game_name),
    AVG(CAST(active_players AS DOUBLE)) OVER (PARTITION BY period, game_name),
    AVG(rounds)       OVER (PARTITION BY period, game_name),
    RANK()   OVER (PARTITION BY period, game_name ORDER BY turnover DESC),
    COUNT(*) OVER (PARTITION BY period, game_name)
FROM og;


/* ===== Q8c — ONE PERIOD AT A TIME =========================================
   Same as Q8b but scoped, for a heavy backfill or re-running a single period.
   Edit the period name in BOTH places (the DELETE and the periods CTE).
   Run YTD and LastYear last — they are by far the largest.

   IMPORTANT: portfolio_avg_* and operator_rank partition by (period, game_name),
   so a period is internally complete on its own. Scoping to one period is safe;
   scoping to one OPERATOR would not be, because the averages and the rank span
   every operator carrying the game.                                          */

DELETE FROM gold.plix.operator_game_period_stats
WHERE period = 'LastYear';

INSERT INTO gold.plix.operator_game_period_stats (
    period, operator, game_name,
    turnover, ggr, turnover_usd, ggr_usd, active_players, rounds,
    avg_bet, avg_bet_usd,
    portfolio_avg_turnover, portfolio_avg_ggr,
    portfolio_avg_turnover_usd, portfolio_avg_ggr_usd,
    portfolio_avg_players, portfolio_avg_rounds,
    operator_rank, operator_rank_total
)
WITH anchor AS (
    SELECT MAX(reporting_date) AS d
    FROM gold.plix.player_game_name_daily_activity
),
all_periods AS (
    SELECT 'Yesterday' AS period, d AS from_date, d AS to_date FROM anchor
    UNION ALL SELECT 'L7D',       date_add('day',  -6, d), d FROM anchor
    UNION ALL SELECT 'L30D',      date_add('day', -29, d), d FROM anchor
    UNION ALL SELECT 'MTD',       date_trunc('month',   d), d FROM anchor
    UNION ALL SELECT 'LastMonth', date_trunc('month', date_add('month', -1, d)),
                                  date_add('day', -1, date_trunc('month', d))    FROM anchor
    UNION ALL SELECT 'QTD',       date_trunc('quarter', d), d FROM anchor
    UNION ALL SELECT 'L3M',       date_add('day', 1, date_add('month',  -3, d)), d FROM anchor
    UNION ALL SELECT 'YTD',       date_trunc('year',    d), d FROM anchor
    UNION ALL SELECT 'LastYear',  date_add('day', 1, date_add('month', -12, d)), d FROM anchor
),
periods AS (
    SELECT * FROM all_periods
    WHERE period = 'LastYear'            -- <<< the only line that changes
),
base AS (
    SELECT
        p.period, a.operator, a.game_name, a.player_id,
        CAST(a.turnover_eur AS DOUBLE) AS turnover_eur,
        CAST(a.ggr_eur      AS DOUBLE) AS ggr_eur,
        CAST(a.ggr_usd      AS DOUBLE) AS ggr_usd,
        CAST(a.rounds       AS DOUBLE) AS rounds,
        CAST(a.real_bet_usd AS DOUBLE) + CAST(a.bonus_bet_usd AS DOUBLE) AS turnover_usd_row
    FROM gold.plix.player_game_name_daily_activity a
    JOIN periods p
      ON a.reporting_date BETWEEN p.from_date AND p.to_date
    WHERE a.active > 0
      AND (a.player_group IS NULL
           OR LOWER(a.player_group) NOT IN ('streamer', 'test account', 'test_user'))
),
og AS (
    SELECT
        period, operator, game_name,
        SUM(turnover_eur)         AS turnover,
        SUM(ggr_eur)              AS ggr,
        SUM(turnover_usd_row)     AS turnover_usd,
        SUM(ggr_usd)              AS ggr_usd,
        SUM(rounds)               AS rounds,
        COUNT(DISTINCT player_id) AS active_players
    FROM base
    GROUP BY period, operator, game_name
)
SELECT
    period, operator, game_name,
    turnover, ggr, turnover_usd, ggr_usd, active_players, rounds,
    CASE WHEN rounds > 0 THEN turnover     / rounds END,
    CASE WHEN rounds > 0 THEN turnover_usd / rounds END,
    AVG(turnover)     OVER (PARTITION BY period, game_name),
    AVG(ggr)          OVER (PARTITION BY period, game_name),
    AVG(turnover_usd) OVER (PARTITION BY period, game_name),
    AVG(ggr_usd)      OVER (PARTITION BY period, game_name),
    AVG(CAST(active_players AS DOUBLE)) OVER (PARTITION BY period, game_name),
    AVG(rounds)       OVER (PARTITION BY period, game_name),
    RANK()   OVER (PARTITION BY period, game_name ORDER BY turnover DESC),
    COUNT(*) OVER (PARTITION BY period, game_name)
FROM og;


/* ===== Q8d — VERIFY one operator/game/period against the live table ======== */
SELECT COUNT(DISTINCT player_id)            AS active_players,
       SUM(CAST(turnover_eur AS DOUBLE))    AS turnover,
       SUM(CAST(ggr_eur      AS DOUBLE))    AS ggr,
       SUM(CAST(rounds       AS DOUBLE))    AS rounds
FROM gold.plix.player_game_name_daily_activity
WHERE operator = 'Gamdom'
  AND game_name = 'Rain and Ruin'
  AND reporting_date BETWEEN
        (SELECT date_add('day', 1, date_add('month', -12, MAX(reporting_date)))
         FROM gold.plix.player_game_name_daily_activity)
    AND (SELECT MAX(reporting_date) FROM gold.plix.player_game_name_daily_activity)
  AND active > 0
  AND (player_group IS NULL
       OR LOWER(player_group) NOT IN ('streamer', 'test account', 'test_user'));

SELECT active_players, turnover, ggr, rounds, operator_rank, operator_rank_total
FROM gold.plix.operator_game_period_stats
WHERE period = 'LastYear'
  AND operator = 'Gamdom'
  AND game_name = 'Rain and Ruin';
