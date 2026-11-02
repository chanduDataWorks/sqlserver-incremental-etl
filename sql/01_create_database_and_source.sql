/* =====================================================================
   01 - Database, schemas and a simulated source system
   ---------------------------------------------------------------------
   src  = pretend OLTP source (claims system)    - in real life another server
   stg  = staging, truncated on every run
   dw   = data warehouse (dimensions + fact)
   etl  = framework objects (watermarks, audit, errors, procedures)

   Requires SQL Server 2017+ (Developer Edition is free).
   ===================================================================== */

IF DB_ID('ClaimsDW') IS NULL
    CREATE DATABASE ClaimsDW;
GO

USE ClaimsDW;
GO

IF SCHEMA_ID('src') IS NULL EXEC('CREATE SCHEMA src');
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

/* ---------------------------------------------------------------------
   Source tables. Every source row carries ModifiedDate - that column is
   what makes incremental (watermark) extraction possible.
   --------------------------------------------------------------------- */

DROP TABLE IF EXISTS src.Claim;
DROP TABLE IF EXISTS src.Member;
DROP TABLE IF EXISTS src.Provider;
GO

CREATE TABLE src.Member
(
    MemberID            VARCHAR(10)   NOT NULL CONSTRAINT PK_src_Member PRIMARY KEY,
    FirstName           VARCHAR(50)   NOT NULL,
    LastName            VARCHAR(50)   NOT NULL,
    DateOfBirth         DATE          NOT NULL,
    Gender              CHAR(1)       NOT NULL,
    PlanCode            VARCHAR(20)   NOT NULL,
    County              VARCHAR(50)   NOT NULL,
    CoverageStartDate   DATE          NOT NULL,
    CoverageEndDate     DATE          NULL,
    ModifiedDate        DATETIME2(3)  NOT NULL
);

CREATE TABLE src.Provider
(
    ProviderNPI         VARCHAR(10)   NOT NULL CONSTRAINT PK_src_Provider PRIMARY KEY,
    ProviderName        VARCHAR(100)  NOT NULL,
    Specialty           VARCHAR(50)   NOT NULL,
    NetworkStatus       VARCHAR(3)    NOT NULL,   -- IN / OUT
    ModifiedDate        DATETIME2(3)  NOT NULL
);

CREATE TABLE src.Claim
(
    ClaimID             VARCHAR(12)    NOT NULL CONSTRAINT PK_src_Claim PRIMARY KEY,
    MemberID            VARCHAR(10)    NOT NULL,
    ProviderNPI         VARCHAR(10)    NOT NULL,
    ServiceDate         DATE           NOT NULL,
    ClaimStatus         VARCHAR(20)    NOT NULL,  -- PAID / DENIED / PENDING
    BilledAmount        DECIMAL(12,2)  NOT NULL,
    AllowedAmount       DECIMAL(12,2)  NOT NULL,
    PaidAmount          DECIMAL(12,2)  NOT NULL,
    ModifiedDate        DATETIME2(3)   NOT NULL
);

CREATE INDEX IX_src_Member_ModifiedDate   ON src.Member (ModifiedDate);
CREATE INDEX IX_src_Provider_ModifiedDate ON src.Provider (ModifiedDate);
CREATE INDEX IX_src_Claim_ModifiedDate    ON src.Claim (ModifiedDate);
GO

/* ---------------------------------------------------------------------
   Synthetic sample data (set-based, no loops).
   500 members, 40 providers, 5,000 claims - all fake.
   --------------------------------------------------------------------- */

;WITH n AS
(
    SELECT TOP (500) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO src.Member
    (MemberID, FirstName, LastName, DateOfBirth, Gender, PlanCode, County,
     CoverageStartDate, CoverageEndDate, ModifiedDate)
SELECT
    'M' + RIGHT('000000' + CAST(i AS VARCHAR(6)), 6),
    CHOOSE(1 + i % 10, 'James','Mary','Robert','Linda','Michael','Susan','Carlos','Maria','Kevin','Anh'),
    CHOOSE(1 + (i / 10) % 10, 'Smith','Garcia','Nguyen','Patel','Johnson','Lee','Brown','Lopez','Chen','Davis'),
    DATEADD(DAY, (i * 37) % 25000, '1945-01-01'),
    CASE WHEN i % 2 = 0 THEN 'F' ELSE 'M' END,
    CHOOSE(1 + i % 5, 'HMO_GOLD','HMO_SILVER','PPO_GOLD','PPO_SILVER','MEDICARE_ADV'),
    CHOOSE(1 + i % 4, 'Los Angeles','Orange','Riverside','San Diego'),
    DATEADD(MONTH, i % 24, '2023-01-01'),
    CASE WHEN i % 7 = 0 THEN DATEADD(MONTH, 30, '2023-01-01') END,
    '2026-01-01T00:00:00'
FROM n;

;WITH n AS
(
    SELECT TOP (40) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS i
    FROM sys.all_objects
)
INSERT INTO src.Provider (ProviderNPI, ProviderName, Specialty, NetworkStatus, ModifiedDate)
SELECT
    CAST(1000000000 + i * 7919 AS VARCHAR(10)),
    CONCAT('Provider ', i),
    CHOOSE(1 + i % 6, 'Family Medicine','Cardiology','Orthopedics','Pediatrics','General Hospital','Urgent Care'),
    CASE WHEN i % 8 = 0 THEN 'OUT' ELSE 'IN' END,
    '2026-01-01T00:00:00'
FROM n;

;WITH n AS
(
    SELECT TOP (5000) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
c AS
(
    SELECT
        i,
        CAST(100 + (i * 37) % 900 AS DECIMAL(12,2)) AS Billed,
        CASE WHEN i % 9 = 0 THEN 'DENIED' WHEN i % 20 = 0 THEN 'PENDING' ELSE 'PAID' END AS ClaimStatus
    FROM n
)
INSERT INTO src.Claim
    (ClaimID, MemberID, ProviderNPI, ServiceDate, ClaimStatus,
     BilledAmount, AllowedAmount, PaidAmount, ModifiedDate)
SELECT
    'C' + RIGHT('0000000' + CAST(i AS VARCHAR(7)), 7),
    'M' + RIGHT('000000' + CAST(1 + i % 500 AS VARCHAR(6)), 6),
    CAST(1000000000 + (1 + i % 40) * 7919 AS VARCHAR(10)),
    DATEADD(DAY, (i * 13) % 700, '2024-01-01'),
    ClaimStatus,
    Billed,
    CAST(Billed * 0.70 AS DECIMAL(12,2)),
    CASE WHEN ClaimStatus = 'PAID' THEN CAST(Billed * 0.70 * 0.90 AS DECIMAL(12,2)) ELSE 0 END,
    '2026-01-01T00:00:00'
FROM c;
GO

SELECT 'src.Member' AS TableName, COUNT(*) AS RowCnt FROM src.Member
UNION ALL SELECT 'src.Provider', COUNT(*) FROM src.Provider
UNION ALL SELECT 'src.Claim',    COUNT(*) FROM src.Claim;
GO
