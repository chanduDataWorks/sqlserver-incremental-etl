/* =====================================================================
   05 - Data validation and reconciliation
   Every query should return 0 rows / "PASS". Run after each load.
   ===================================================================== */

USE ClaimsDW;
GO

/* 1. Row count and amount reconciliation: source vs warehouse */
SELECT
    'Claims reconciliation' AS CheckName,
    s.SrcRows, w.DwRows, s.SrcPaid, w.DwPaid,
    CASE WHEN s.SrcRows = w.DwRows AND s.SrcPaid = w.DwPaid THEN 'PASS' ELSE 'FAIL' END AS Result
FROM (SELECT COUNT(*) AS SrcRows, SUM(PaidAmount) AS SrcPaid FROM src.Claim) AS s
CROSS JOIN (SELECT COUNT(*) AS DwRows, SUM(PaidAmount) AS DwPaid FROM dw.FactClaim) AS w;

/* 2. Exactly one current row per member (SCD2 integrity) */
SELECT MemberID, COUNT(*) AS CurrentRows
FROM   dw.DimMember
WHERE  IsCurrent = 1
GROUP  BY MemberID
HAVING COUNT(*) > 1;

/* 3. No gaps or overlaps between SCD2 versions */
WITH v AS
(
    SELECT MemberID, EffectiveFrom, EffectiveTo,
           LEAD(EffectiveFrom) OVER (PARTITION BY MemberID ORDER BY EffectiveFrom) AS NextFrom
    FROM dw.DimMember
)
SELECT *
FROM   v
WHERE  NextFrom IS NOT NULL AND NextFrom <> EffectiveTo;

/* 4. Duplicate claims in the fact table */
SELECT ClaimID, COUNT(*) AS Cnt
FROM   dw.FactClaim
GROUP  BY ClaimID
HAVING COUNT(*) > 1;

/* 5. Business rules: paid never exceeds allowed; denied claims pay nothing */
SELECT ClaimID, ClaimStatus, AllowedAmount, PaidAmount
FROM   dw.FactClaim
WHERE  PaidAmount > AllowedAmount
   OR (ClaimStatus = 'DENIED' AND PaidAmount <> 0);

/* 6. Late-arriving members still pointing at Unknown (-1) - review list */
SELECT f.ClaimID, s.MemberID
FROM   dw.FactClaim AS f
JOIN   src.Claim    AS s ON s.ClaimID = f.ClaimID
WHERE  f.MemberKey = -1;

/* 7. SCD2 history example: members who changed plan */
SELECT m.MemberID, m.PlanCode, m.County, m.CoverageEndDate, m.EffectiveFrom, m.EffectiveTo, m.IsCurrent
FROM   dw.DimMember AS m
WHERE  m.MemberID IN (SELECT MemberID FROM dw.DimMember GROUP BY MemberID HAVING COUNT(*) > 1)
ORDER  BY m.MemberID, m.EffectiveFrom;

/* 8. Failed runs and their errors */
SELECT l.LoadID, l.StartTime, e.ProcedureName, e.ErrorNumber, e.ErrorLine, e.ErrorMessage
FROM   etl.LoadLog  AS l
JOIN   etl.ErrorLog AS e ON e.LoadID = l.LoadID
WHERE  l.Status = 'Failed'
ORDER  BY l.LoadID DESC;
GO


