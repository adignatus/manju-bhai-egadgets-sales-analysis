/*
==============================================================================
Script      : 04_gold_layer.sql
Project     : Manju Bhai Gadgets — Sales Analysis (2023–2025)
Layer       : Gold
Purpose     : Build all four aggregated business mart tables from
              silver.sales_enriched. These tables are the direct
              data source for Tableau dashboards.
Run after   : 03_silver_layer.sql
Execute     : EXEC gold.usp_load;
==============================================================================

Tables created:
  gold.daily_sales            — Time-series mart (Tableau date spine)
  gold.sku_performance        — Product analytics by SKU/year/quarter
  gold.city_performance       — Geographic analytics by city/year
  gold.event_return_analysis  — Event impact & return correlation

Design notes:
  • All four tables are physical (not views) for Tableau query performance
  • DROP TABLE IF EXISTS on every run — safe for re-execution
  • RANK() applied in outer SELECT on top of subquery/CTE aggregation
    (SQL Server does not allow window functions alongside GROUP BY
    aggregate functions at the same SELECT INTO level)
  • most_popular_sku uses CTE + RANK() instead of a correlated subquery
    to avoid per-row re-scans on 5.5M rows
==============================================================================
*/

USE e_gadgets_analysis;
GO


-- ============================================================================
-- SECTION 1 : Stored Procedure — gold.usp_load
-- ============================================================================

CREATE OR ALTER PROCEDURE gold.usp_load
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time DATETIME2 = SYSDATETIME();
    DECLARE @row_count  INT;

    BEGIN TRY

        PRINT '================================================';
        PRINT '  Gold Layer Load — Manju Bhai Gadgets';
        PRINT '  Started : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
        PRINT '================================================';


        -- ════════════════════════════════════════════════════════
        -- TABLE 1 of 4 : gold.daily_sales
        -- Purpose      : Time-series mart — Tableau date spine
        -- Granularity  : One row per sale_date × channel combination
        -- Source       : silver.sales_enriched
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [1/4] Loading gold.daily_sales...';

        DROP TABLE IF EXISTS gold.daily_sales;

        SELECT
            sale_date,
            sale_year,
            sale_month,
            quarter_label,
            week_start,
            day_type,
            channel,
            COUNT(*)                                              AS total_transactions,
            SUM(units_sold)                                       AS total_units,
            SUM(total_revenue)                                    AS total_revenue,
            SUM(gross_revenue)                                    AS gross_revenue,
            SUM(delivery_charges)                                 AS total_delivery_income,
            SUM(CAST(is_returned AS INT))                         AS total_returns,
            SUM(refund_amount)                                    AS total_refunds,
            ROUND(
                SUM(CAST(is_returned AS FLOAT))
                * 100 / NULLIF(COUNT(*), 0)
            , 2)                                                  AS return_rate_pct,
            SUM(CASE WHEN is_event_day = 1 THEN 1 ELSE 0 END)    AS event_day_txns,
            ROUND(AVG(total_revenue), 2)                          AS avg_order_value
        INTO gold.daily_sales
        FROM silver.sales_enriched
        GROUP BY
            sale_date, sale_year, sale_month,
            quarter_label, week_start, day_type, channel;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

        -- Index: speeds up Tableau date-range and channel filters
        CREATE NONCLUSTERED INDEX IX_gold_daily_date_channel
            ON gold.daily_sales (sale_date, channel);

        PRINT '   Index created on gold.daily_sales.';


        -- ════════════════════════════════════════════════════════
        -- TABLE 2 of 4 : gold.sku_performance
        -- Purpose      : Product analytics mart with revenue ranking
        -- Granularity  : One row per sku × sale_year × quarter_label
        -- Source       : silver.sales_enriched
        -- Design note  : RANK() requires a subquery wrapper because
        --                window functions cannot be used at the same
        --                SELECT level as GROUP BY aggregates
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [2/4] Loading gold.sku_performance...';

        DROP TABLE IF EXISTS gold.sku_performance;

        -- Outer SELECT: applies RANK() on pre-aggregated result
        SELECT *,
            RANK() OVER (
                PARTITION BY sale_year
                ORDER BY total_revenue DESC
            ) AS revenue_rank_in_year
        INTO gold.sku_performance
        FROM (
            -- Inner SELECT: all GROUP BY aggregations
            SELECT
                sku,
                sku_name,
                product_family,
                price_tier,
                sku_price,
                sale_year,
                quarter_label,
                COUNT(*)                                                    AS total_transactions,
                SUM(total_revenue)                                          AS total_revenue,
                SUM(CAST(is_returned AS INT))                               AS returns,
                ROUND(
                    SUM(CAST(is_returned AS FLOAT))
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                        AS return_rate_pct,
                SUM(refund_amount)                                          AS total_refund_cost,
                SUM(CASE WHEN channel    = 'Online'   THEN 1 ELSE 0 END)   AS online_units,
                SUM(CASE WHEN channel    = 'In-Store' THEN 1 ELSE 0 END)   AS instore_units,
                SUM(CASE WHEN is_event_day = 1        THEN 1 ELSE 0 END)   AS event_day_units,
                SUM(CASE WHEN is_event_day = 0        THEN 1 ELSE 0 END)   AS non_event_units
            FROM silver.sales_enriched
            GROUP BY
                sku, sku_name, product_family, price_tier, sku_price,
                sale_year, quarter_label
        ) agg;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

        CREATE NONCLUSTERED INDEX IX_gold_sku_year_sku
            ON gold.sku_performance (sale_year, sku);

        PRINT '   Index created on gold.sku_performance.';


        -- ════════════════════════════════════════════════════════
        -- TABLE 3 of 4 : gold.city_performance
        -- Purpose      : Geographic analytics mart
        -- Granularity  : One row per city × sale_year × quarter_label
        -- Source       : silver.sales_enriched
        -- Design note  : most_popular_sku uses CTE + RANK() instead of
        --                a correlated subquery — avoids per-row rescans
        --                on 5.5M rows which would be extremely slow.
        --                RANK() on revenue applied in the outer SELECT.
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [3/4] Loading gold.city_performance...';

        DROP TABLE IF EXISTS gold.city_performance;

        -- CTE 1: rank SKUs by volume within each city + year
        WITH TopSKU AS (
            SELECT
                city,
                sale_year,
                sku_name,
                RANK() OVER (
                    PARTITION BY city, sale_year
                    ORDER BY COUNT(*) DESC
                ) AS sku_rank
            FROM silver.sales_enriched
            GROUP BY city, sale_year, sku_name
        ),

        -- CTE 2: city-level aggregations
        CityAgg AS (
            SELECT
                se.city,
                se.sale_year,
                se.quarter_label,
                COUNT(*)                                                         AS transactions,
                SUM(se.total_revenue)                                            AS total_revenue,
                ROUND(AVG(se.sku_price), 0)                                      AS avg_basket_pkr,
                ROUND(
                    SUM(CAST(se.is_returned AS FLOAT))
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                             AS return_rate_pct,
                ROUND(
                    SUM(CASE WHEN se.channel = 'Online'   THEN 1.0 ELSE 0 END)
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                             AS online_pct,
                ROUND(
                    SUM(CASE WHEN se.payment_method = 'Cash'          THEN 1.0 ELSE 0 END)
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                             AS cash_pct,
                ROUND(
                    SUM(CASE WHEN se.payment_method = 'COD'           THEN 1.0 ELSE 0 END)
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                             AS cod_pct,
                ROUND(
                    SUM(CASE WHEN se.payment_method = 'Bank Transfer' THEN 1.0 ELSE 0 END)
                    * 100 / NULLIF(COUNT(*), 0)
                , 2)                                                             AS bank_transfer_pct
            FROM silver.sales_enriched se
            GROUP BY se.city, se.sale_year, se.quarter_label
        )

        -- Outer SELECT: join aggregation with top SKU + apply revenue RANK()
        SELECT
            ca.city,
            ca.sale_year,
            ca.quarter_label,
            ca.transactions,
            ca.total_revenue,
            ca.avg_basket_pkr,
            ca.return_rate_pct,
            ca.online_pct,
            ca.cash_pct,
            ca.cod_pct,
            ca.bank_transfer_pct,
            t.sku_name  AS most_popular_sku,
            RANK() OVER (
                PARTITION BY ca.sale_year
                ORDER BY ca.total_revenue DESC
            ) AS revenue_rank
        INTO gold.city_performance
        FROM      CityAgg ca
        LEFT JOIN TopSKU  t
            ON  ca.city      = t.city
            AND ca.sale_year = t.sale_year
            AND t.sku_rank   = 1;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

        CREATE NONCLUSTERED INDEX IX_gold_city_year_city
            ON gold.city_performance (sale_year, city);

        PRINT '   Index created on gold.city_performance.';


        -- ════════════════════════════════════════════════════════
        -- TABLE 4 of 4 : gold.event_return_analysis
        -- Purpose      : Event impact and return correlation mart
        -- Granularity  : is_event_day × product_family × channel × city
        -- Source       : silver.sales_enriched
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [4/4] Loading gold.event_return_analysis...';

        DROP TABLE IF EXISTS gold.event_return_analysis;

        SELECT
            is_event_day,
            product_family,
            channel,
            city,
            COUNT(*)                                              AS transactions,
            SUM(total_revenue)                                    AS total_revenue,
            SUM(CAST(is_returned AS INT))                         AS returned,
            ROUND(
                SUM(CAST(is_returned AS FLOAT))
                * 100 / NULLIF(COUNT(*), 0)
            , 2)                                                  AS return_rate_pct,
            ROUND(AVG(total_revenue), 2)                          AS avg_order_value,
            -- Average number of transactions per distinct day
            ROUND(
                CAST(COUNT(*) AS FLOAT)
                / NULLIF(COUNT(DISTINCT sale_date), 0)
            , 2)                                                  AS avg_daily_txns
        INTO gold.event_return_analysis
        FROM silver.sales_enriched
        GROUP BY
            is_event_day, product_family, channel, city;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

        CREATE NONCLUSTERED INDEX IX_gold_event_city_family
            ON gold.event_return_analysis (is_event_day, city, product_family);

        PRINT '   Index created on gold.event_return_analysis.';


        -- ════════════════════════════════════════════════════════
        -- SUMMARY
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '================================================';
        PRINT '  Gold Layer Load Completed Successfully';
        PRINT '  Duration : '
            + CAST(DATEDIFF(SECOND, @start_time, SYSDATETIME()) AS NVARCHAR(10))
            + ' seconds';
        PRINT '================================================';

    END TRY
    BEGIN CATCH

        PRINT '';
        PRINT '================================================';
        PRINT '  ERROR — Gold Layer Load Failed';
        PRINT '  Error Number  : ' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
        PRINT '  Error Message : ' + ERROR_MESSAGE();
        PRINT '  Error Line    : ' + CAST(ERROR_LINE()   AS NVARCHAR(10));
        PRINT '================================================';

        THROW;

    END CATCH;
END;
GO

-- ── Execute ───────────────────────────────────────────────────────────────────
EXEC gold.usp_load;
GO


-- ============================================================================
-- SECTION 2 : Gold Validation Queries
-- ============================================================================

SELECT TOP 10 * FROM gold.daily_sales          ORDER BY sale_date;
SELECT TOP 10 * FROM gold.sku_performance      ORDER BY sale_year, revenue_rank_in_year;
SELECT TOP 10 * FROM gold.city_performance     ORDER BY sale_year, revenue_rank;
SELECT TOP 10 * FROM gold.event_return_analysis;
GO

-- Event uplift quick summary
SELECT
    is_event_day,
    ROUND(AVG(avg_daily_txns),  2) AS avg_txns_per_day,
    ROUND(AVG(return_rate_pct), 2) AS avg_return_rate_pct
FROM gold.event_return_analysis
GROUP BY is_event_day;
GO
