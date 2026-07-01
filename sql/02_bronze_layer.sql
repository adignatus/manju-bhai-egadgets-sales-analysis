/*
==============================================================================
Script      : 02_bronze_layer.sql
Project     : Manju Bhai Gadgets — Sales Analysis (2023–2025)
Layer       : Bronze
Purpose     : Create bronze tables, load stored procedure, and indexes.
Policy      : Source-faithful. All columns stored as NVARCHAR.
              Audit metadata added. NEVER update or delete bronze data.
Run after   : 01_init_database.sql
==============================================================================
*/

USE e_gadgets_analysis;
GO

-- ============================================================================
-- SECTION 1 : DDL — Bronze Table Definitions
-- ============================================================================

-- ── bronze.sales_raw ─────────────────────────────────────────────────────────
IF OBJECT_ID('bronze.sales_raw', 'U') IS NOT NULL
    DROP TABLE bronze.sales_raw;

CREATE TABLE bronze.sales_raw (
    -- Source columns: all NVARCHAR — no type assumption at Bronze layer
    date             NVARCHAR(250),
    sku              NVARCHAR(250),
    channel          NVARCHAR(250),
    city             NVARCHAR(250),
    payment_method   NVARCHAR(250),
    return_flag      NVARCHAR(250),
    event_flag       NVARCHAR(250),
    delivery_charges NVARCHAR(250),

    -- Audit metadata
    _row_id          BIGINT        IDENTITY(1,1) NOT NULL,
    _loaded_at       DATETIME2     DEFAULT SYSDATETIME(),
    _source_file     NVARCHAR(100) DEFAULT 'manju_bhai_sales.csv'
);
GO

-- ── bronze.sku_details_raw ────────────────────────────────────────────────────
IF OBJECT_ID('bronze.sku_details_raw', 'U') IS NOT NULL
    DROP TABLE bronze.sku_details_raw;

CREATE TABLE bronze.sku_details_raw (
    sku        NVARCHAR(250),
    sku_name   NVARCHAR(250),
    sku_price  NVARCHAR(250),    -- stored as-is, e.g. "2,499"

    -- Audit metadata
    _row_id      INT           IDENTITY(1,1) NOT NULL,
    _loaded_at   DATETIME2     DEFAULT SYSDATETIME(),
    _source_file NVARCHAR(100) DEFAULT 'sku_details.csv'
);
GO


-- ============================================================================
-- SECTION 2 : Stored Procedure — bronze.load_bronze
-- ============================================================================
/*
  NOTE ON DATA LOADING:
  ---------------------
  The preferred method is BULK INSERT (shown commented below). However,
  BULK INSERT requires the CSV file to be accessible by the SQL Server
  service account, not your Windows login.

  If running SQL Server Express locally:
    1. Use SSMS → Right-click database → Tasks → Import Flat File
    2. Load manju_bhai_sales.csv into a staging table (e.g. direct_sales_import)
    3. Load sku_details.csv into a staging table    (e.g. bronze.sku_raw)
    4. Run EXEC bronze.load_bronze — the procedure inserts from those tables.

  Update the staging table names below to match what SSMS created for you.
*/

CREATE OR ALTER PROCEDURE bronze.load_bronze
AS
BEGIN
    DECLARE @start_time      DATETIME,
            @end_time        DATETIME,
            @batch_start_time DATETIME,
            @batch_end_time  DATETIME;

    BEGIN TRY
        SET @batch_start_time = GETDATE();

        PRINT '========================================================';
        PRINT 'Loading Bronze Layer';
        PRINT 'Started : ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
        PRINT '========================================================';

        -- ── bronze.sales_raw ─────────────────────────────────────
        SET @start_time = GETDATE();
        PRINT '';
        PRINT '>> Truncating  : bronze.sales_raw';
        TRUNCATE TABLE bronze.sales_raw;

        PRINT '>> Inserting   : bronze.sales_raw';

        /* ── OPTION A: BULK INSERT (preferred — update path) ──────
        BULK INSERT bronze.sales_raw (
            date, sku, channel, city, payment_method,
            return_flag, event_flag, delivery_charges
        )
        FROM 'C:\YourPath\manju_bhai_sales.csv'
        WITH (
            FIRSTROW        = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '\r\n',
            TABLOCK
        );
        */

        -- ── OPTION B: Insert from SSMS-imported staging table ─────
        -- Replace 'direct_sales_import' with your actual staging table name
        INSERT INTO bronze.sales_raw (
            date, sku, channel, city, payment_method,
            return_flag, event_flag, delivery_charges
        )
        SELECT
            date, sku, channel, city, payment_method,
            return_flag, event_flag, delivery_charges
        FROM direct_sales_import;

        SET @end_time = GETDATE();
        PRINT '>> Rows loaded : ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
        PRINT '>> Duration    : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';


        -- ── bronze.sku_details_raw ────────────────────────────────
        SET @start_time = GETDATE();
        PRINT '';
        PRINT '>> Truncating  : bronze.sku_details_raw';
        TRUNCATE TABLE bronze.sku_details_raw;

        PRINT '>> Inserting   : bronze.sku_details_raw';

        /* ── OPTION A: BULK INSERT (preferred — update path) ──────
        BULK INSERT bronze.sku_details_raw (sku, sku_name, sku_price)
        FROM 'C:\YourPath\sku_details.csv'
        WITH (
            FIRSTROW        = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR   = '\r\n',
            TABLOCK
        );
        */

        -- ── OPTION B: Insert from SSMS-imported staging table ─────
        -- Replace 'bronze.sku_raw' with your actual staging table name
        INSERT INTO bronze.sku_details_raw (sku, sku_name, sku_price)
        SELECT sku, sku_name, sku_price
        FROM bronze.sku_raw;

        SET @end_time = GETDATE();
        PRINT '>> Rows loaded : ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
        PRINT '>> Duration    : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';


        SET @batch_end_time = GETDATE();
        PRINT '';
        PRINT '========================================================';
        PRINT 'Bronze Layer Load Completed Successfully';
        PRINT 'Total Duration : ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '========================================================';

    END TRY
    BEGIN CATCH
        PRINT '';
        PRINT '========================================================';
        PRINT 'ERROR — Bronze Layer Load Failed';
        PRINT 'Error Message : ' + ERROR_MESSAGE();
        PRINT 'Error Number  : ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State   : ' + CAST(ERROR_STATE()  AS NVARCHAR);
        PRINT '========================================================';
    END CATCH;
END;
GO

-- ── Execute ───────────────────────────────────────────────────────────────────
EXEC bronze.load_bronze;
GO


-- ============================================================================
-- SECTION 3 : Indexes on bronze.sales_raw
-- ============================================================================
-- Indexes are created after the initial load for maximum insert performance.
-- Re-run this section if you recreate the table.

-- Clustered index on identity key — eliminates heap scans entirely
CREATE CLUSTERED INDEX CIX_sales_raw_row_id
    ON bronze.sales_raw (_row_id);
GO

-- Date filter — used by almost every query
CREATE NONCLUSTERED INDEX IX_sales_raw_date
    ON bronze.sales_raw (date);
GO

-- SKU — used in JOINs to sku_details_raw
CREATE NONCLUSTERED INDEX IX_sales_raw_sku
    ON bronze.sales_raw (sku);
GO

-- Channel — used in GROUP BY and WHERE across all Silver views
CREATE NONCLUSTERED INDEX IX_sales_raw_channel
    ON bronze.sales_raw (channel);
GO

-- City — used in geographic GROUP BY queries
CREATE NONCLUSTERED INDEX IX_sales_raw_city
    ON bronze.sales_raw (city);
GO

-- Composite covering index — satisfies the most common combined filter
-- (date range + channel) in a single seek
CREATE NONCLUSTERED INDEX IX_sales_raw_date_channel
    ON bronze.sales_raw (date, channel)
    INCLUDE (sku, city, payment_method, return_flag, event_flag, delivery_charges);
GO


-- ============================================================================
-- SECTION 4 : Bronze QA Validation Queries
-- ============================================================================

-- Confirm index creation
SELECT
    i.name      AS index_name,
    i.type_desc AS index_type,
    c.name      AS column_name
FROM sys.indexes       i
JOIN sys.index_columns ic ON i.object_id = ic.object_id
                          AND i.index_id  = ic.index_id
JOIN sys.columns       c  ON ic.object_id = c.object_id
                          AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('bronze.sales_raw')
ORDER BY i.name, ic.key_ordinal;
GO

-- Row counts, null checks, and date range validation
SELECT
    COUNT(*)                                                  AS total_rows,
    COUNT(DISTINCT date)                                      AS unique_dates,
    COUNT(DISTINCT sku)                                       AS unique_skus,
    COUNT(DISTINCT city)                                      AS unique_cities,
    SUM(CASE WHEN date           IS NULL THEN 1 ELSE 0 END)   AS null_date,
    SUM(CASE WHEN sku            IS NULL THEN 1 ELSE 0 END)   AS null_sku,
    SUM(CASE WHEN city           IS NULL THEN 1 ELSE 0 END)   AS null_city,
    SUM(CASE WHEN payment_method IS NULL THEN 1 ELSE 0 END)   AS null_payment,
    MIN(date)                                                  AS earliest_date,
    MAX(date)                                                  AS latest_date
FROM bronze.sales_raw;
GO

-- Quick peek at raw data
SELECT TOP 10 * FROM bronze.sales_raw;
SELECT TOP 10 * FROM bronze.sku_details_raw;
GO
