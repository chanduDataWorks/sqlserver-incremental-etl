/* =====================================================================
   06 - Simulate one day of source activity for the SSIS demo
   Order: run 01-03 -> SSIS package (full load) -> THIS SCRIPT ONCE
          -> SSIS package again (incremental load picks up only these rows)
   ===================================================================== */

USE ClaimsDW;
GO

DECLARE @Now DATETIME2(3) = SYSDATETIME();

-- 15 members move county -> SCD Type 2: new version, old one expired
UPDATE src.Member
SET    County = 'Ventura', ModifiedDate = @Now
WHERE  MemberID BETWEEN 'M000201' AND 'M000215';

-- paid claims get a $1 correction -> fact UPDATE, not a duplicate
UPDATE src.Claim
SET    PaidAmount = PaidAmount - 1.00, ModifiedDate = @Now
WHERE  ClaimID BETWEEN 'C0001001' AND 'C0001100'
  AND  ClaimStatus = 'PAID';

-- 300 brand-new claims -> fact INSERT
;WITH n AS
(
    SELECT TOP (300) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS i
    FROM sys.all_objects
)
INSERT INTO src.Claim
    (ClaimID, MemberID, ProviderNPI, ServiceDate, ClaimStatus,
     BilledAmount, AllowedAmount, PaidAmount, ModifiedDate)
SELECT
    'C' + RIGHT('0000000' + CAST(5200 + i AS VARCHAR(7)), 7),
    'M' + RIGHT('000000' + CAST(1 + i % 500 AS VARCHAR(6)), 6),
    CAST(1000000000 + (1 + i % 40) * 7919 AS VARCHAR(10)),
    DATEADD(DAY, i % 28, '2026-10-01'),
    'PAID', 300.00, 210.00, 189.00,
    @Now
FROM n;
GO