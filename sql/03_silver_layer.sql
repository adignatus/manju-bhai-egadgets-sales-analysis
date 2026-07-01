/*
==============================================================================
Script      : 03_silver_layer.sql
Project     : Manju Bhai Gadgets — Sales Analysis (2023–2025)
Layer       : Silver
Purpose     : Clean, type-cast, normalize, enrich and load three Silver
              tables from the Bronze layer.
              Also creates silver.anomalies — a data quality audit view.
Run after   : 02_bronze_layer.sql
Execute     : EXEC silver.usp_load;
==============================================================================

Tables created:
  silver.sku_details_cleaned  — price parsed, product_family, price_tier
  silver.sales_cleaned        — dates cast, columns normalized, BIT flags,
                                anomaly detection, NULLs handled
  silver.sales_enriched       — JOIN of above two + revenue columns derived

View created:
  silver.anomalies            — data quality audit (reads from sales_cleaned)
==============================================================================
*/

USE e_gadgets_analysis;
GO


-- ============================================================================
-- SECTION 1 : Stored Procedure — silver.usp_load
-- ============================================================================

CREATE OR ALTER PROCEDURE silver.usp_load
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time DATETIME2 = SYSDATETIME();
    DECLARE @row_count  INT;

    BEGIN TRY

        PRINT '================================================';
        PRINT '  Silver Layer Load — Manju Bhai Gadgets';
        PRINT '  Started : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
        PRINT '================================================';


        -- ════════════════════════════════════════════════════════
        -- TABLE 1 of 3 : silver.sku_details_cleaned
        -- Source       : bronze.sku_details_raw (20 rows)
        -- Changes      : sku_price commas stripped + cast to DECIMAL,
        --                product_family derived from SKU range,
        --                price_tier derived from price in PKR
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [1/3] Loading silver.sku_details_cleaned...';

        DROP TABLE IF EXISTS silver.sku_details_cleaned;

        SELECT
            sku,
            sku_name,

            -- Strip comma thousands-separator and cast to DECIMAL
            CAST(REPLACE(sku_price, ',', '') AS DECIMAL(10,2))  AS sku_price,

            -- Product family derived from SKU number
            CASE sku
                WHEN 'SKU0001' THEN 'Charger'
                WHEN 'SKU0002' THEN 'Charger'
                WHEN 'SKU0003' THEN 'Mouse'
                WHEN 'SKU0004' THEN 'Mouse'
                WHEN 'SKU0005' THEN 'Earbuds'
                WHEN 'SKU0006' THEN 'Earbuds'
                WHEN 'SKU0007' THEN 'Speaker'
                WHEN 'SKU0008' THEN 'Speaker'
                WHEN 'SKU0009' THEN 'Power Bank'
                WHEN 'SKU0010' THEN 'Power Bank'
                WHEN 'SKU0011' THEN 'Smartwatch'
                WHEN 'SKU0012' THEN 'Smartwatch'
                WHEN 'SKU0013' THEN 'Smartwatch'
                WHEN 'SKU0014' THEN 'Fitness Band'
                WHEN 'SKU0015' THEN 'Fitness Band'
                WHEN 'SKU0016' THEN 'Headphones'
                WHEN 'SKU0017' THEN 'Headphones'
                WHEN 'SKU0018' THEN 'USB Hub'
                WHEN 'SKU0019' THEN 'USB Hub'
                WHEN 'SKU0020' THEN 'Desk Lamp'
                ELSE            'Unknown'
            END AS product_family,

            -- Price tier in PKR
            -- Budget < 3,000  |  Mid-Range 3,000–8,000  |  Premium > 8,000
            CASE
                WHEN CAST(REPLACE(sku_price, ',', '') AS DECIMAL(10,2)) < 3000
                    THEN 'Budget'
                WHEN CAST(REPLACE(sku_price, ',', '') AS DECIMAL(10,2)) < 8000
                    THEN 'Mid-Range'
                ELSE 'Premium'
            END AS price_tier,

            _loaded_at    AS _bronze_loaded_at,
            SYSDATETIME() AS _silver_loaded_at

        INTO silver.sku_details_cleaned
        FROM bronze.sku_details_raw;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);


        -- ════════════════════════════════════════════════════════
        -- TABLE 2 of 3 : silver.sales_cleaned
        -- Source       : bronze.sales_raw (5,576,637 rows)
        -- Changes      :
        --   • date        → DATE + 8 extracted parts
        --   • channel     → Title Case  ('online'  → 'Online')
        --   • city        → ISNULL to 'Unknown'  (preserve the transaction)
        --   • payment     → Readable labels ('bt' → 'Bank Transfer')
        --   • return_flag → BIT
        --   • event_flag  → BIT
        --   • delivery    → INT
        --   • anomaly flags computed (delivery mismatch, instore COD)
        -- Filter        : Only drop rows where date or sku is NULL
        --                 — city/payment NULLs kept as 'Unknown' so revenue
        --                   figures are never understated
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [2/3] Loading silver.sales_cleaned...';

        DROP TABLE IF EXISTS silver.sales_cleaned;

        SELECT
            -- ── Date: safe cast + all derived date parts ─────────────
            TRY_CAST(date AS DATE)                                            AS sale_date,
            YEAR(TRY_CAST(date AS DATE))                                      AS sale_year,
            MONTH(TRY_CAST(date AS DATE))                                     AS sale_month,
            DATEPART(DAYOFYEAR, TRY_CAST(date AS DATE))                       AS day_of_year,
            DATEPART(WEEKDAY,   TRY_CAST(date AS DATE))                       AS day_of_week,
            DATEPART(QUARTER,   TRY_CAST(date AS DATE))                       AS sale_quarter,

            -- Week / Month / Quarter truncation via DATEADD/DATEDIFF trick
            -- Anchor = 0 (1900-01-01, a Monday) keeps week starts on Monday
            DATEADD(WEEK,    DATEDIFF(WEEK,    0, TRY_CAST(date AS DATE)), 0) AS week_start,
            DATEADD(MONTH,   DATEDIFF(MONTH,   0, TRY_CAST(date AS DATE)), 0) AS month_start,
            DATEADD(QUARTER, DATEDIFF(QUARTER, 0, TRY_CAST(date AS DATE)), 0) AS quarter_start,

            -- Quarter label: "Q1 2023"
            'Q' + CAST(DATEPART(QUARTER, TRY_CAST(date AS DATE)) AS NVARCHAR(1))
                + ' '
                + CAST(YEAR(TRY_CAST(date AS DATE)) AS NVARCHAR(4))           AS quarter_label,

            -- Weekend flag — DATENAME is safe regardless of @@DATEFIRST
            CASE
                WHEN DATENAME(WEEKDAY, TRY_CAST(date AS DATE))
                    IN ('Saturday', 'Sunday') THEN 'Weekend'
                ELSE 'Weekday'
            END AS day_type,

            -- ── SKU: force uppercase for consistency ──────────────────
            UPPER(sku) AS sku,

            -- ── Channel: normalize to Title Case, NULL → 'Unknown' ────
            ISNULL(
                CASE LOWER(channel)
                    WHEN 'online'  THEN 'Online'
                    WHEN 'instore' THEN 'In-Store'
                    ELSE                'Unknown'
                END,
            'Unknown') AS channel,

            -- ── City: NULL → 'Unknown' (preserve the transaction row) ─
            ISNULL(city, 'Unknown') AS city,

            -- ── Payment: normalize, NULL → 'Unknown' ─────────────────
            ISNULL(
                CASE LOWER(payment_method)
                    WHEN 'cash' THEN 'Cash'
                    WHEN 'card' THEN 'Card'
                    WHEN 'cod'  THEN 'COD'
                    WHEN 'bt'   THEN 'Bank Transfer'
                    ELSE             'Other'
                END,
            'Unknown') AS payment_method,

            -- ── Flags: cast to BIT (SQL Server has no BOOLEAN type) ───
            CAST(return_flag      AS BIT) AS is_returned,
            CAST(event_flag       AS BIT) AS is_event_day,
            CAST(delivery_charges AS INT) AS delivery_charges,

            -- ── Anomaly flag 1: delivery charge mismatch ──────────────
            -- In-Store should always be 0; Online should always be 500 PKR
            CASE
                WHEN LOWER(channel) = 'instore'
                     AND TRY_CAST(delivery_charges AS INT) <> 0   THEN 1
                WHEN LOWER(channel) = 'online'
                     AND TRY_CAST(delivery_charges AS INT) <> 500 THEN 1
                ELSE 0
            END AS delivery_anomaly,

            -- ── Anomaly flag 2: COD used on in-store transaction ───────
            CASE
                WHEN LOWER(channel)            = 'instore'
                     AND LOWER(payment_method) = 'cod' THEN 1
                ELSE 0
            END AS cod_instore_anomaly,

            _row_id,
            SYSDATETIME() AS _silver_loaded_at

        INTO silver.sales_cleaned
        FROM bronze.sales_raw
        WHERE TRY_CAST(date AS DATE) IS NOT NULL   -- must have a valid date
          AND sku IS NOT NULL;                     -- must have a product

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);


        -- ── Indexes on silver.sales_cleaned ──────────────────────────
        PRINT '';
        PRINT '>> Adding indexes on silver.sales_cleaned...';

        CREATE CLUSTERED INDEX CIX_silver_sales_date
            ON silver.sales_cleaned (sale_date);

        CREATE NONCLUSTERED INDEX IX_silver_sales_sku
            ON silver.sales_cleaned (sku);

        CREATE NONCLUSTERED INDEX IX_silver_sales_city
            ON silver.sales_cleaned (city);

        CREATE NONCLUSTERED INDEX IX_silver_sales_channel
            ON silver.sales_cleaned (channel);

        -- ── Index on silver.sku_details_cleaned ──────────────────────
        CREATE CLUSTERED INDEX CIX_silver_sku_sku
            ON silver.sku_details_cleaned (sku);

        PRINT '   Indexes created on silver.sales_cleaned + sku_details_cleaned.';


        -- ════════════════════════════════════════════════════════
        -- TABLE 3 of 3 : silver.sales_enriched
        -- Source       : silver.sales_cleaned
        --                LEFT JOIN silver.sku_details_cleaned
        -- Additions    : gross_revenue, total_revenue, refund_amount,
        --                units_sold (always 1 per row in this dataset)
        -- Note         : This is the primary source for the Gold layer
        --                and for ad-hoc analyst queries
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '>> [3/3] Loading silver.sales_enriched...';

        DROP TABLE IF EXISTS silver.sales_enriched;

        SELECT
            s.sale_date,
            s.sale_year,
            s.sale_month,
            s.sale_quarter,
            s.day_of_week,
            s.day_type,
            s.week_start,
            s.month_start,
            s.quarter_start,
            s.quarter_label,
            s.sku,
            d.sku_name,
            d.product_family,
            d.price_tier,
            d.sku_price,
            s.channel,
            s.city,
            s.payment_method,
            s.is_returned,
            s.is_event_day,
            s.delivery_charges,

            -- Revenue: returned items contribute 0 net revenue
            CASE WHEN s.is_returned = 1 THEN 0
                 ELSE d.sku_price
            END AS gross_revenue,

            -- Total revenue includes delivery for non-returned items
            CASE WHEN s.is_returned = 1 THEN 0
                 ELSE d.sku_price + s.delivery_charges
            END AS total_revenue,

            -- Refund exposure: full SKU price for returned items
            CASE WHEN s.is_returned = 1 THEN d.sku_price
                 ELSE 0
            END AS refund_amount,

            1 AS units_sold    -- dataset has 1 unit per transaction row

        INTO silver.sales_enriched
        FROM      silver.sales_cleaned       s
        LEFT JOIN silver.sku_details_cleaned d
            ON s.sku = d.sku;

        SET @row_count = @@ROWCOUNT;
        PRINT '   Rows loaded : ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '   Completed   : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);


        -- ── Indexes on silver.sales_enriched ─────────────────────────
        PRINT '';
        PRINT '>> Adding indexes on silver.sales_enriched...';

        CREATE NONCLUSTERED INDEX IX_enriched_date
            ON silver.sales_enriched (sale_date);

        CREATE NONCLUSTERED INDEX IX_enriched_sku
            ON silver.sales_enriched (sku);

        CREATE NONCLUSTERED INDEX IX_enriched_city
            ON silver.sales_enriched (city);

        PRINT '   Indexes created on silver.sales_enriched.';


        -- ════════════════════════════════════════════════════════
        -- SUMMARY
        -- ════════════════════════════════════════════════════════
        PRINT '';
        PRINT '================================================';
        PRINT '  Silver Layer Load Completed Successfully';
        PRINT '  Duration : '
            + CAST(DATEDIFF(SECOND, @start_time, SYSDATETIME()) AS NVARCHAR(10))
            + ' seconds';
        PRINT '================================================';

    END TRY
    BEGIN CATCH

        PRINT '';
        PRINT '================================================';
        PRINT '  ERROR — Silver Layer Load Failed';
        PRINT '  Error Number  : ' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
        PRINT '  Error Message : ' + ERROR_MESSAGE();
        PRINT '  Error Line    : ' + CAST(ERROR_LINE()   AS NVARCHAR(10));
        PRINT '================================================';

        THROW;

    END CATCH;
END;
GO

-- ── Execute ───────────────────────────────────────────────────────────────────
EXEC silver.usp_load;
GO


-- ============================================================================
-- SECTION 2 : Data Quality Audit View — silver.anomalies
-- ============================================================================
/*
  Reads from silver.sales_cleaned (physical table built above).
  Uses pre-computed anomaly flag columns — no re-evaluation needed.

  Anomalies detected:
    1. In-store orders with non-zero delivery charge
    2. Online orders with unexpected delivery charge (not 500 PKR)
    3. COD payment method used on an in-store transaction
*/

CREATE OR ALTER VIEW silver.anomalies AS
SELECT
    _row_id,
    sale_date,
    sku,
    channel,
    city,
    payment_method,
    delivery_charges,
    CASE
        WHEN delivery_anomaly    = 1 AND channel = 'In-Store'
            THEN 'In-store order has non-zero delivery charge'
        WHEN delivery_anomaly    = 1 AND channel = 'Online'
            THEN 'Online order has unexpected delivery charge'
        WHEN cod_instore_anomaly = 1
            THEN 'COD payment used for in-store transaction'
    END AS anomaly_reason
FROM silver.sales_cleaned
WHERE delivery_anomaly    = 1
   OR cod_instore_anomaly = 1;
GO

-- ── Anomaly summary report ────────────────────────────────────────────────────
SELECT
    anomaly_reason,
    COUNT(*)                                               AS occurrences,
    ROUND(COUNT(*) * 100.0
        / (SELECT COUNT(*) FROM silver.sales_cleaned), 4) AS pct_of_total
FROM  silver.anomalies
GROUP BY anomaly_reason
ORDER BY occurrences DESC;
GO


-- ============================================================================
-- SECTION 3 : Silver Validation Queries
-- ============================================================================

SELECT TOP 10 * FROM silver.sku_details_cleaned;
SELECT TOP 10 * FROM silver.sales_cleaned;
SELECT TOP 10 * FROM silver.sales_enriched;
GO
