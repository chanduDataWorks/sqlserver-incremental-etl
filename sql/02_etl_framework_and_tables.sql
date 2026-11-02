/* =====================================================================
   02 - ETL framework, staging tables and warehouse tables
   ===================================================================== */

USE ClaimsDW;
GO

-- required for the filtered unique index on dw.DimMember
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------
   ETL framework
   --------------------------------------------------------------------- */

DROP TABLE IF EXISTS etl.ErrorLog;
DROP TABLE IF EXISTS etl.LoadLog;
DROP TABLE IF EXISTS etl.Watermark;
GO

-- One row per source table: how far we have loaded.
-- PendingLoadedDate is set during extract and only promoted to
-- LastLoadedDate after the whole load commits - so a failed run is
-- simply re-extracted next time and nothing is skipped.
CREATE TABLE etl.Watermark
(
    TableName           SYSNAME       NOT NULL CONSTRAINT PK_etl_Watermark PRIMARY KEY,
    LastLoadedDate      DATETIME2(3)  NOT NULL,
    PendingLoadedDate   DATETIME2(3)  NULL,
    UpdatedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_etl_Watermark_UpdatedAt DEFAULT SYSDATETIME()
);

INSERT INTO etl.Watermark (TableName, LastLoadedDate)
VALUES ('src.Member',   '1900-01-01'),
       ('src.Provider', '1900-01-01'),
       ('src.Claim',    '1900-01-01');

-- Audit: one row per pipeline run
CREATE TABLE etl.LoadLog
(
    LoadID          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_LoadLog PRIMARY KEY,
    PipelineName    VARCHAR(100)   NOT NULL,
    StartTime       DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_LoadLog_StartTime DEFAULT SYSDATETIME(),
    EndTime         DATETIME2(3)   NULL,
    Status          VARCHAR(20)    NOT NULL,   -- Running / Succeeded / Failed
    RowsExtracted   INT            NULL,
    RowsInserted    INT            NULL,
    RowsUpdated     INT            NULL,
    ErrorMessage    NVARCHAR(4000) NULL
);

-- Error detail captured from CATCH blocks
CREATE TABLE etl.ErrorLog
(
    ErrorID         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_ErrorLog PRIMARY KEY,
    LoadID          INT            NULL,
    ProcedureName   SYSNAME        NULL,
    ErrorNumber     INT            NULL,
    ErrorSeverity   INT            NULL,
    ErrorState      INT            NULL,
    ErrorLine       INT            NULL,
    ErrorMessage    NVARCHAR(4000) NULL,
    LoggedAt        DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_ErrorLog_LoggedAt DEFAULT SYSDATETIME()
);
GO

/* ---------------------------------------------------------------------
   Staging: same shape as source + LoadID. Truncated every run.
   --------------------------------------------------------------------- */

DROP TABLE IF EXISTS stg.Member;
DROP TABLE IF EXISTS stg.Provider;
DROP TABLE IF EXISTS stg.Claim;
GO

CREATE TABLE stg.Member
(
    MemberID            VARCHAR(10)   NOT NULL,
    FirstName           VARCHAR(50)   NOT NULL,
    LastName            VARCHAR(50)   NOT NULL,
    DateOfBirth         DATE          NOT NULL,
    Gender              CHAR(1)       NOT NULL,
    PlanCode            VARCHAR(20)   NOT NULL,
    County              VARCHAR(50)   NOT NULL,
    CoverageStartDate   DATE          NOT NULL,
    CoverageEndDate     DATE          NULL,
    ModifiedDate        DATETIME2(3)  NOT NULL,
    LoadID              INT           NOT NULL
);

CREATE TABLE stg.Provider
(
    ProviderNPI         VARCHAR(10)   NOT NULL,
    ProviderName        VARCHAR(100)  NOT NULL,
    Specialty           VARCHAR(50)   NOT NULL,
    NetworkStatus       VARCHAR(3)    NOT NULL,
    ModifiedDate        DATETIME2(3)  NOT NULL,
    LoadID              INT           NOT NULL
);

CREATE TABLE stg.Claim
(
    ClaimID             VARCHAR(12)    NOT NULL,
    MemberID            VARCHAR(10)    NOT NULL,
    ProviderNPI         VARCHAR(10)    NOT NULL,
    ServiceDate         DATE           NOT NULL,
    ClaimStatus         VARCHAR(20)    NOT NULL,
    BilledAmount        DECIMAL(12,2)  NOT NULL,
    AllowedAmount       DECIMAL(12,2)  NOT NULL,
    PaidAmount          DECIMAL(12,2)  NOT NULL,
    ModifiedDate        DATETIME2(3)   NOT NULL,
    LoadID              INT            NOT NULL
);
GO

/* ---------------------------------------------------------------------
   Warehouse
   --------------------------------------------------------------------- */

DROP TABLE IF EXISTS dw.FactClaim;
DROP TABLE IF EXISTS dw.DimMember;
DROP TABLE IF EXISTS dw.DimProvider;
GO

-- SCD Type 2: a new row every time a tracked attribute changes
CREATE TABLE dw.DimMember
(
    MemberKey           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimMember PRIMARY KEY,
    MemberID            VARCHAR(10)    NOT NULL,
    FirstName           VARCHAR(50)    NOT NULL,
    LastName            VARCHAR(50)    NOT NULL,
    DateOfBirth         DATE           NULL,
    Gender              CHAR(1)        NOT NULL,
    PlanCode            VARCHAR(20)    NOT NULL,
    County              VARCHAR(50)    NOT NULL,
    CoverageStartDate   DATE           NULL,
    CoverageEndDate     DATE           NULL,
    RowHash             VARBINARY(32)  NOT NULL,
    EffectiveFrom       DATETIME2(3)   NOT NULL,
    EffectiveTo         DATETIME2(3)   NOT NULL CONSTRAINT DF_dw_DimMember_EffectiveTo DEFAULT '9999-12-31',
    IsCurrent           BIT            NOT NULL CONSTRAINT DF_dw_DimMember_IsCurrent DEFAULT 1,
    LoadID              INT            NOT NULL
);

-- only one current row per member
CREATE UNIQUE INDEX UX_dw_DimMember_Current
    ON dw.DimMember (MemberID) WHERE IsCurrent = 1;

CREATE INDEX IX_dw_DimMember_Lookup
    ON dw.DimMember (MemberID, EffectiveFrom, EffectiveTo) INCLUDE (MemberKey);

-- SCD Type 1: overwrite in place
CREATE TABLE dw.DimProvider
(
    ProviderKey         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimProvider PRIMARY KEY,
    ProviderNPI         VARCHAR(10)    NOT NULL CONSTRAINT UQ_dw_DimProvider_NPI UNIQUE,
    ProviderName        VARCHAR(100)   NOT NULL,
    Specialty           VARCHAR(50)    NOT NULL,
    IsInNetwork         BIT            NOT NULL,
    RowHash             VARBINARY(32)  NOT NULL,
    InsertedLoadID      INT            NOT NULL,
    UpdatedLoadID       INT            NULL
);

CREATE TABLE dw.FactClaim
(
    ClaimKey            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_FactClaim PRIMARY KEY,
    ClaimID             VARCHAR(12)    NOT NULL CONSTRAINT UQ_dw_FactClaim_ClaimID UNIQUE,
    MemberKey           INT            NOT NULL CONSTRAINT FK_FactClaim_DimMember REFERENCES dw.DimMember (MemberKey),
    ProviderKey         INT            NOT NULL CONSTRAINT FK_FactClaim_DimProvider REFERENCES dw.DimProvider (ProviderKey),
    ServiceDateKey      INT            NOT NULL,   -- yyyymmdd
    ClaimStatus         VARCHAR(20)    NOT NULL,
    BilledAmount        DECIMAL(12,2)  NOT NULL,
    AllowedAmount       DECIMAL(12,2)  NOT NULL,
    PaidAmount          DECIMAL(12,2)  NOT NULL,
    InsertedLoadID      INT            NOT NULL,
    UpdatedLoadID       INT            NULL
);
GO

/* ---------------------------------------------------------------------
   "Unknown" members (-1) so a claim whose member hasn't arrived yet
   (late-arriving dimension) still loads instead of failing.
   --------------------------------------------------------------------- */

SET IDENTITY_INSERT dw.DimMember ON;
INSERT INTO dw.DimMember
    (MemberKey, MemberID, FirstName, LastName, Gender, PlanCode, County,
     RowHash, EffectiveFrom, EffectiveTo, IsCurrent, LoadID)
VALUES
    (-1, 'UNKNOWN', 'Unknown', 'Unknown', 'U', 'UNKNOWN', 'Unknown',
     0x00, '1900-01-01', '9999-12-31', 1, 0);
SET IDENTITY_INSERT dw.DimMember OFF;

SET IDENTITY_INSERT dw.DimProvider ON;
INSERT INTO dw.DimProvider
    (ProviderKey, ProviderNPI, ProviderName, Specialty, IsInNetwork, RowHash, InsertedLoadID)
VALUES
    (-1, 'UNKNOWN', 'Unknown', 'Unknown', 0, 0x00, 0);
SET IDENTITY_INSERT dw.DimProvider OFF;
GO
