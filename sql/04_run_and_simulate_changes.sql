/* =====================================================================
   04 - Demo: full load, then source changes, then incremental load
   Run this script one block at a time and look at the results.
   ===================================================================== */

USE ClaimsDW;
GO

/* ---------- RUN 1: initial load (watermarks start at 1900-01-01) ---------- */
EXEC etl.usp_RunClaimsPipeline;
-- Expect: 5,540 rows extracted, 5,000 claims inserted, 500 members, 40 providers
GO

/* ---------- Simulate a day of activity in the source system ---------- */
DECLARE @Now DATETIME2(3) = SYSDATETIME();

-- 1) 25 members switch plan        -> SCD2: new version, old one expired
UPDATE TOP (25) src.Member
SET    PlanCode = CASE WHEN PlanCode = 'PPO_GOLD' THEN 'HMO_GOLD' ELSE 'PPO_GOLD' END,
       ModifiedDate = @Now
WHERE  MemberID <= 'M000100';

-- 2) 10 members terminate coverage -> SCD2 again
UPDATE src.Member
SET    CoverageEndDate = '2026-09-30',
       ModifiedDate = @Now
WHERE  MemberID BETWEEN 'M000400' AND 'M000409';

-- 3) Pending claims get adjudicated -> fact UPDATE (not a duplicate insert)
UPDATE src.Claim
SET    ClaimStatus = 'PAID',
       PaidAmount  = CAST(AllowedAmount * 0.90 AS DECIMAL(12,2)),
       ModifiedDate = @Now
WHERE  ClaimStatus = 'PENDING';

-- 4) A provider leaves the network -> SCD1 overwrite
UPDATE TOP (1) src.Provider
SET    NetworkStatus = 'OUT',
       ModifiedDate = @Now
WHERE  NetworkStatus = 'IN';

-- 5) 200 brand-new claims, including one for a member not yet in the
--    warehouse (late-arriving dimension -> MemberKey = -1)
;WITH n AS
(
    SELECT TOP (200) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS i
    FROM sys.all_objects
)
INSERT INTO src.Claim
    (ClaimID, MemberID, ProviderNPI, ServiceDate, ClaimStatus,
     BilledAmount, AllowedAmount, PaidAmount, ModifiedDate)
SELECT
    'C' + RIGHT('0000000' + CAST(5000 + i AS VARCHAR(7)), 7),
    CASE WHEN i = 200 THEN 'M999999'
         ELSE 'M' + RIGHT('000000' + CAST(1 + i % 500 AS VARCHAR(6)), 6) END,
    CAST(1000000000 + (1 + i % 40) * 7919 AS VARCHAR(10)),
    DATEADD(DAY, i % 25, '2026-10-01'),
    'PAID',
    250.00, 175.00, 157.50,
    @Now
FROM n;
GO

/* ---------- RUN 2: incremental load picks up only the changes ---------- */
EXEC etl.usp_RunClaimsPipeline;
GO

/* ---------- RUN 3: nothing changed -> nothing loaded ---------- */
EXEC etl.usp_RunClaimsPipeline;
GO

/* ---------- Audit trail ---------- */
SELECT LoadID, PipelineName, StartTime, EndTime, Status,
       RowsExtracted, RowsInserted, RowsUpdated, ErrorMessage
FROM   etl.LoadLog
ORDER  BY LoadID;

SELECT * FROM etl.Watermark;
GO
