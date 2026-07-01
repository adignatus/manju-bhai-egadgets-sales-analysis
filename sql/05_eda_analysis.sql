/*
==============================================================================
Script      : 05_eda_analysis.sql
Project     : Manju Bhai Gadgets — Sales Analysis (2023–2025)
Layer       : Silver + Gold (read-only — no data modifications)
Purpose     : Exploratory Data Analysis queries covering:
                - Channel distribution and revenue
                - Monthly and quarterly trends
                - Return rates by product family and city
                - Event-day impact analysis
                - City revenue rankings
                - Payment preference by city
                - Data quality insights
Run after   : 04_gold_layer.sql
==============================================================================
*/

USE e_gadgets_analysis;
GO


-- ============================================================================
-- PART A : SILVER LAYER — Row-level EDA (silver.sales_enriched)
-- ============================================================================
-- Use these queries when you need granular, row-level analysis.
-- For aggregated metrics, use the Gold layer queries in Part B.
-- ============================================================================


-- ── A1. Channel distribution — volume, revenue, avg price ────────────────────
SELECT
    channel,
    COUNT(*)                                          AS transactions,
    ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER(), 2)                   AS pct_of_total,
    SUM(total_revenue)                                AS total_revenue,
    ROUND(AVG(sku_price), 0)                          AS avg_price_pkr
FROM silver.sales_enriched
GROUP BY channel
ORDER BY transactions DESC;
GO


-- ── A2. Monthly sales trend — volume, revenue, returns ───────────────────────
-- Tip: use a running total on Tableau for cumulative month/year view
SELECT
    month_start,
    sale_year,
    FORMAT(month_start, 'MMM yyyy')            AS month_label,
    COUNT(*)                                   AS transactions,
    SUM(total_revenue)                         AS total_revenue,
    SUM(CAST(is_returned AS INT))              AS returns,
    ROUND(
        AVG(CAST(is_returned AS FLOAT)) * 100
    , 2)                                       AS return_rate_pct
FROM silver.sales_enriched
GROUP BY month_start, sale_year
ORDER BY month_start;
GO


-- ── A3. Return rate by product family and price tier ─────────────────────────
SELECT
    product_family,
    price_tier,
    COUNT(*)                                      AS total_units,
    SUM(CAST(is_returned AS INT))                 AS returned_units,
    ROUND(
        SUM(CAST(is_returned AS FLOAT))
        * 100 / NULLIF(COUNT(*), 0)
    , 2)                                          AS return_rate_pct,
    SUM(refund_amount)                            AS total_refund_value
FROM silver.sales_enriched
GROUP BY product_family, price_tier
ORDER BY return_rate_pct DESC;
GO


-- ── A4. Cities where total refunds exceed gross revenue ──────────────────────
-- Flags product-city combinations that are net-negative for the business
WITH city_product_summary AS (
    SELECT
        product_family,
        city,
        COUNT(*)                               AS total_units,
        SUM(CAST(is_returned AS INT))          AS returned_units,
        ROUND(
            SUM(CAST(is_returned AS FLOAT))
            * 100 / NULLIF(COUNT(*), 0)
        , 2)                                   AS return_rate_pct,
        SUM(refund_amount)                     AS total_refund_value,
        SUM(gross_revenue)                     AS gross_revenue
    FROM silver.sales_enriched
    GROUP BY city, product_family
)
SELECT *
FROM city_product_summary
WHERE total_refund_value >= gross_revenue
ORDER BY return_rate_pct DESC;
GO


-- ── A5. Event-day impact analysis — volume, revenue, returns ─────────────────
SELECT
    is_event_day,
    COUNT(*)                                           AS transactions,
    SUM(total_revenue)                                 AS total_revenue,
    ROUND(AVG(total_revenue), 2)                       AS avg_revenue_per_txn,
    ROUND(AVG(CAST(is_returned AS FLOAT)) * 100, 2)   AS return_rate_pct
FROM silver.sales_enriched
GROUP BY is_event_day;
GO


-- ── A6. City revenue ranking — basket value, returns, top payment method ─────
SELECT
    city,
    COUNT(*)                                            AS transactions,
    SUM(total_revenue)                                  AS total_revenue,
    ROUND(AVG(sku_price), 2)                            AS avg_basket_value_pkr,
    ROUND(AVG(CAST(is_returned AS FLOAT)) * 100, 2)    AS return_rate_pct,
    -- Top payment method per city (correlated subquery — no MODE() in T-SQL)
    (
        SELECT TOP 1 i.payment_method
        FROM   silver.sales_enriched i
        WHERE  i.city = se.city
        GROUP BY i.payment_method
        ORDER BY COUNT(*) DESC
    ) AS top_payment_method
FROM silver.sales_enriched se
GROUP BY city
ORDER BY total_revenue DESC;
GO


-- ── A7. Event × return cross-tab (2×2 correlation table) ─────────────────────
SELECT
    is_event_day,
    is_returned,
    COUNT(*)                                                      AS count,
    ROUND(
        COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (PARTITION BY is_event_day)
    , 2)                                                          AS pct_within_event_group
FROM silver.sales_enriched
GROUP BY is_event_day, is_returned
ORDER BY is_event_day, is_returned;
GO


-- ── A8. Payment preference crosstab by city ───────────────────────────────────
SELECT
    city,
    SUM(CASE WHEN payment_method = 'Cash'          THEN 1 ELSE 0 END) AS cash_txns,
    SUM(CASE WHEN payment_method = 'Card'          THEN 1 ELSE 0 END) AS card_txns,
    SUM(CASE WHEN payment_method = 'COD'           THEN 1 ELSE 0 END) AS cod_txns,
    SUM(CASE WHEN payment_method = 'Bank Transfer' THEN 1 ELSE 0 END) AS bt_txns
FROM silver.sales_enriched
GROUP BY city
ORDER BY city;
GO


-- ============================================================================
-- PART B : GOLD LAYER — Pre-aggregated Analytics (Tableau sources)
-- ============================================================================
-- Use these queries for dashboards, reports, and performance-sensitive
-- queries. Gold tables are indexed and aggregated — much faster than
-- querying silver.sales_enriched directly for summary metrics.
-- ============================================================================


-- ── B1. Annual revenue summary by channel ────────────────────────────────────
SELECT
    sale_year,
    channel,
    SUM(total_transactions)  AS total_transactions,
    SUM(total_units)         AS total_units,
    SUM(total_revenue)       AS total_revenue,
    SUM(gross_revenue)       AS gross_revenue,
    SUM(total_delivery_income) AS total_delivery_income,
    SUM(total_returns)       AS total_returns,
    SUM(total_refunds)       AS total_refunds,
    AVG(return_rate_pct)     AS avg_return_rate_pct,    -- AVG, not SUM
    SUM(event_day_txns)      AS event_day_txns,
    AVG(avg_order_value)     AS avg_order_value         -- AVG, not SUM
FROM gold.daily_sales
GROUP BY sale_year, channel
ORDER BY sale_year, channel;
GO


-- ── B2. Monthly revenue trend by channel ─────────────────────────────────────
SELECT
    sale_year,
    sale_month,
    channel,
    SUM(total_transactions)  AS total_transactions,
    SUM(total_units)         AS total_units,
    SUM(total_revenue)       AS total_revenue,
    SUM(gross_revenue)       AS gross_revenue,
    SUM(total_delivery_income) AS total_delivery_income,
    SUM(total_returns)       AS total_returns,
    SUM(total_refunds)       AS total_refunds,
    AVG(return_rate_pct)     AS avg_return_rate_pct,
    SUM(event_day_txns)      AS event_day_txns,
    AVG(avg_order_value)     AS avg_order_value
FROM gold.daily_sales
GROUP BY sale_year, sale_month, channel
ORDER BY sale_year, sale_month;
GO


-- ── B3. Top 5 SKUs by revenue per year ───────────────────────────────────────
SELECT
    sale_year,
    sku,
    sku_name,
    product_family,
    price_tier,
    total_revenue,
    return_rate_pct,
    revenue_rank_in_year
FROM gold.sku_performance
WHERE revenue_rank_in_year <= 5
ORDER BY sale_year, revenue_rank_in_year;
GO


-- ── B4. Bottom 5 SKUs by revenue per year ────────────────────────────────────
SELECT
    sale_year,
    sku,
    sku_name,
    product_family,
    price_tier,
    total_revenue,
    return_rate_pct,
    revenue_rank_in_year
FROM gold.sku_performance
WHERE revenue_rank_in_year > (
    SELECT MAX(revenue_rank_in_year) - 5
    FROM gold.sku_performance sp2
    WHERE sp2.sale_year = gold.sku_performance.sale_year
)
ORDER BY sale_year, revenue_rank_in_year DESC;
GO


-- ── B5. City revenue leaderboard per year ────────────────────────────────────
SELECT
    sale_year,
    city,
    total_revenue,
    avg_basket_pkr,
    return_rate_pct,
    online_pct,
    cash_pct,
    cod_pct,
    bank_transfer_pct,
    most_popular_sku,
    revenue_rank
FROM gold.city_performance
ORDER BY sale_year, revenue_rank;
GO


-- ── B6. Event uplift summary — avg daily transactions and return rate ─────────
SELECT
    is_event_day,
    ROUND(AVG(avg_daily_txns),  2) AS avg_txns_per_day,
    ROUND(AVG(return_rate_pct), 2) AS avg_return_rate_pct,
    SUM(transactions)              AS total_transactions,
    SUM(total_revenue)             AS total_revenue
FROM gold.event_return_analysis
GROUP BY is_event_day;
GO


-- ── B7. Return rate by product family on event vs non-event days ──────────────
SELECT
    product_family,
    MAX(CASE WHEN is_event_day = 1 THEN return_rate_pct END) AS return_rate_event_day,
    MAX(CASE WHEN is_event_day = 0 THEN return_rate_pct END) AS return_rate_non_event,
    MAX(CASE WHEN is_event_day = 1 THEN return_rate_pct END)
    - MAX(CASE WHEN is_event_day = 0 THEN return_rate_pct END) AS return_rate_uplift
FROM gold.event_return_analysis
GROUP BY product_family
ORDER BY return_rate_uplift DESC;
GO
