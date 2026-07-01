/*
==============================================================================
Script      : 01_init_database.sql
Project     : Manju Bhai Gadgets — Sales Analysis (2023–2025)
Layer       : Initialisation
Purpose     : Create the database and all three medallion schemas.
              Run this script FIRST before any other script.
==============================================================================
*/

-- ── Create database ───────────────────────────────────────────────────────
CREATE DATABASE e_gadgets_analysis;
GO

USE e_gadgets_analysis;
GO

-- ── Create schemas ────────────────────────────────────────────────────────
-- Bronze : Raw ingestion — source-faithful, no transformations
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'bronze')
    EXEC(N'CREATE SCHEMA [bronze]');
GO

-- Silver : Cleaned, type-cast, validated and enriched
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'silver')
    EXEC(N'CREATE SCHEMA [silver]');
GO

-- Gold   : Aggregated business marts, Tableau-ready
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'gold')
    EXEC(N'CREATE SCHEMA [gold]');
GO

PRINT 'Database e_gadgets_analysis and schemas (bronze, silver, gold) created successfully.';
