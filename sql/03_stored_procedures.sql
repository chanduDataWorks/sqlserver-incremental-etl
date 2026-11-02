/* =====================================================================
   03 - ETL stored procedures

   Run order (wrapped by etl.usp_RunClaimsPipeline, or called step by
   step from SSIS Execute SQL Tasks):

     1. etl.usp_StartLoad          -> LoadID
     2. etl.usp_ExtractToStaging   -> incremental pull by watermark
     3. etl.usp_LoadDimProvider    -> SCD Type 1 (MERGE)
     4. etl.usp_LoadDimMember      -> SCD Type 2
     5. etl.usp_LoadFactClaim      -> MERGE upsert with key lookups
     6. etl.usp_EndLoad            -> promote watermarks, close audit row
   ===================================================================== */

USE ClaimsDW;
GO

-- Filtered indexes require these settings; procedures remember them at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------
   Error logger - call from inside a CATCH block
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_LogError
    @LoadID         INT,
    @ProcedureName  SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.ErrorLog
        (LoadID, ProcedureName, ErrorNumber, ErrorSeverity, ErrorState, ErrorLine, ErrorMessage)
    VALUES
        (@LoadID, @ProcedureName, ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_STATE(),
         ERROR_LINE(), ERROR_MESSAGE());
END;
GO

/* ---------------------------------------------------------------------
   1. Start: open an audit row and return its LoadID
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_StartLoad
    @PipelineName   VARCHAR(100),
    @LoadID         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.LoadLog (PipelineName, Status)
    VALUES (@PipelineName, 'Running');

    SET @LoadID = SCOPE_IDENTITY();
END;
GO

/* ---------------------------------------------------------------------
   2. Extract: pull only rows changed since the last successful load.
      Window = (LastLoadedDate, PendingLoadedDate]. The upper bound is
      fixed at the start so rows written during the load are not lost -
      they are picked up next run.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_ExtractToStaging
    @LoadID         INT,
    @RowsExtracted  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows INT = 0;
    DECLARE @From DATETIME2(3), @To DATETIME2(3);

    TRUNCATE TABLE stg.Member;
    TRUNCATE TABLE stg.Provider;
    TRUNCATE TABLE stg.Claim;

    -- Members
    SELECT @From = LastLoadedDate FROM etl.Watermark WHERE TableName = 'src.Member';
    SELECT @To = ISNULL(MAX(ModifiedDate), @From) FROM src.Member;

    INSERT INTO stg.Member
        (MemberID, FirstName, LastName, DateOfBirth, Gender, PlanCode, County,
         CoverageStartDate, CoverageEndDate, ModifiedDate, LoadID)
    SELECT MemberID, LTRIM(RTRIM(FirstName)), LTRIM(RTRIM(LastName)), DateOfBirth,
           UPPER(Gender), UPPER(PlanCode), County, CoverageStartDate, CoverageEndDate,
           ModifiedDate, @LoadID
    FROM src.Member
    WHERE ModifiedDate > @From AND ModifiedDate <= @To;

    SET @Rows += @@ROWCOUNT;
    UPDATE etl.Watermark SET PendingLoadedDate = @To WHERE TableName = 'src.Member';

    -- Providers
    SELECT @From = LastLoadedDate FROM etl.Watermark WHERE TableName = 'src.Provider';
    SELECT @To = ISNULL(MAX(ModifiedDate), @From) FROM src.Provider;

    INSERT INTO stg.Provider
        (ProviderNPI, ProviderName, Specialty, NetworkStatus, ModifiedDate, LoadID)
    SELECT ProviderNPI, LTRIM(RTRIM(ProviderName)), Specialty, UPPER(NetworkStatus),
           ModifiedDate, @LoadID
    FROM src.Provider
    WHERE ModifiedDate > @From AND ModifiedDate <= @To;

    SET @Rows += @@ROWCOUNT;
    UPDATE etl.Watermark SET PendingLoadedDate = @To WHERE TableName = 'src.Provider';

    -- Claims
    SELECT @From = LastLoadedDate FROM etl.Watermark WHERE TableName = 'src.Claim';
    SELECT @To = ISNULL(MAX(ModifiedDate), @From) FROM src.Claim;

    INSERT INTO stg.Claim
        (ClaimID, MemberID, ProviderNPI, ServiceDate, ClaimStatus,
         BilledAmount, AllowedAmount, PaidAmount, ModifiedDate, LoadID)
    SELECT ClaimID, MemberID, ProviderNPI, ServiceDate, UPPER(LTRIM(RTRIM(ClaimStatus))),
           BilledAmount, AllowedAmount, PaidAmount, ModifiedDate, @LoadID
    FROM src.Claim
    WHERE ModifiedDate > @From AND ModifiedDate <= @To;

    SET @Rows += @@ROWCOUNT;
    UPDATE etl.Watermark SET PendingLoadedDate = @To WHERE TableName = 'src.Claim';

    SET @RowsExtracted = @Rows;
END;
GO

/* ---------------------------------------------------------------------
   3. DimProvider - SCD Type 1 via MERGE
      Hash comparison means unchanged rows are never rewritten.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_LoadDimProvider
    @LoadID         INT,
    @RowsInserted   INT OUTPUT,
    @RowsUpdated    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Actions TABLE (ActionTaken NVARCHAR(10));

    MERGE dw.DimProvider AS tgt
    USING
    (
        SELECT
            ProviderNPI,
            ProviderName,
            Specialty,
            CAST(CASE WHEN NetworkStatus = 'IN' THEN 1 ELSE 0 END AS BIT) AS IsInNetwork,
            HASHBYTES('SHA2_256', CONCAT(ProviderName, '|', Specialty, '|', NetworkStatus)) AS RowHash
        FROM stg.Provider
    ) AS src
        ON tgt.ProviderNPI = src.ProviderNPI
    WHEN MATCHED AND tgt.RowHash <> src.RowHash THEN
        UPDATE SET
            tgt.ProviderName  = src.ProviderName,
            tgt.Specialty     = src.Specialty,
            tgt.IsInNetwork   = src.IsInNetwork,
            tgt.RowHash       = src.RowHash,
            tgt.UpdatedLoadID = @LoadID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ProviderNPI, ProviderName, Specialty, IsInNetwork, RowHash, InsertedLoadID)
        VALUES (src.ProviderNPI, src.ProviderName, src.Specialty, src.IsInNetwork, src.RowHash, @LoadID)
    OUTPUT $action INTO @Actions;

    SELECT @RowsInserted = COUNT(CASE WHEN ActionTaken = 'INSERT' THEN 1 END),
           @RowsUpdated  = COUNT(CASE WHEN ActionTaken = 'UPDATE' THEN 1 END)
    FROM @Actions;
END;
GO

/* ---------------------------------------------------------------------
   4. DimMember - SCD Type 2
      a) close the current row of members whose attributes changed
      b) insert a new current row for changed + brand-new members
      Brand-new members start at 1900-01-01 so historical claims match.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_LoadDimMember
    @LoadID         INT,
    @RowsInserted   INT OUTPUT,
    @RowsUpdated    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSDATETIME();

    -- staged rows with a hash of every tracked attribute
    -- (ISNULL stops NULL values from producing the same hash as other values)
    SELECT
        s.*,
        HASHBYTES('SHA2_256', CONCAT(
            s.FirstName, '|', s.LastName, '|', s.PlanCode, '|', s.County, '|',
            ISNULL(CONVERT(VARCHAR(10), s.CoverageEndDate, 23), '~'))) AS RowHash
    INTO #src
    FROM stg.Member AS s;

    -- a) expire changed rows
    UPDATE d
    SET    d.EffectiveTo = @Now,
           d.IsCurrent   = 0
    FROM   dw.DimMember AS d
    JOIN   #src         AS s ON s.MemberID = d.MemberID
    WHERE  d.IsCurrent = 1
      AND  d.RowHash <> s.RowHash;

    SET @RowsUpdated = @@ROWCOUNT;

    -- b) insert new versions (changed members now have no current row)
    INSERT INTO dw.DimMember
        (MemberID, FirstName, LastName, DateOfBirth, Gender, PlanCode, County,
         CoverageStartDate, CoverageEndDate, RowHash, EffectiveFrom, EffectiveTo, IsCurrent, LoadID)
    SELECT
        s.MemberID, s.FirstName, s.LastName, s.DateOfBirth, s.Gender, s.PlanCode, s.County,
        s.CoverageStartDate, s.CoverageEndDate, s.RowHash,
        CASE WHEN EXISTS (SELECT 1 FROM dw.DimMember h WHERE h.MemberID = s.MemberID)
             THEN @Now ELSE '1900-01-01' END,
        '9999-12-31',
        1,
        @LoadID
    FROM #src AS s
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dw.DimMember AS d
        WHERE d.MemberID = s.MemberID AND d.IsCurrent = 1
    );

    SET @RowsInserted = @@ROWCOUNT;
END;
GO

/* ---------------------------------------------------------------------
   5. FactClaim - MERGE upsert
      - Member key = the member version valid on the service date
      - Missing member/provider -> -1 (late-arriving dimension)
      - Only real changes update an existing claim
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_LoadFactClaim
    @LoadID         INT,
    @RowsInserted   INT OUTPUT,
    @RowsUpdated    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Actions TABLE (ActionTaken NVARCHAR(10));

    MERGE dw.FactClaim AS tgt
    USING
    (
        SELECT
            c.ClaimID,
            ISNULL(m.MemberKey, -1)                              AS MemberKey,
            ISNULL(p.ProviderKey, -1)                            AS ProviderKey,
            CONVERT(INT, CONVERT(CHAR(8), c.ServiceDate, 112))   AS ServiceDateKey,
            c.ClaimStatus,
            c.BilledAmount,
            c.AllowedAmount,
            c.PaidAmount
        FROM stg.Claim AS c
        LEFT JOIN dw.DimMember AS m
               ON m.MemberID = c.MemberID
              AND c.ServiceDate >= m.EffectiveFrom
              AND c.ServiceDate <  m.EffectiveTo
        LEFT JOIN dw.DimProvider AS p
               ON p.ProviderNPI = c.ProviderNPI
    ) AS src
        ON tgt.ClaimID = src.ClaimID
    WHEN MATCHED AND
    (
           tgt.ClaimStatus   <> src.ClaimStatus
        OR tgt.BilledAmount  <> src.BilledAmount
        OR tgt.AllowedAmount <> src.AllowedAmount
        OR tgt.PaidAmount    <> src.PaidAmount
        OR tgt.MemberKey     <> src.MemberKey
        OR tgt.ProviderKey   <> src.ProviderKey
    ) THEN
        UPDATE SET
            tgt.MemberKey     = src.MemberKey,
            tgt.ProviderKey   = src.ProviderKey,
            tgt.ClaimStatus   = src.ClaimStatus,
            tgt.BilledAmount  = src.BilledAmount,
            tgt.AllowedAmount = src.AllowedAmount,
            tgt.PaidAmount    = src.PaidAmount,
            tgt.UpdatedLoadID = @LoadID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ClaimID, MemberKey, ProviderKey, ServiceDateKey, ClaimStatus,
                BilledAmount, AllowedAmount, PaidAmount, InsertedLoadID)
        VALUES (src.ClaimID, src.MemberKey, src.ProviderKey, src.ServiceDateKey, src.ClaimStatus,
                src.BilledAmount, src.AllowedAmount, src.PaidAmount, @LoadID)
    OUTPUT $action INTO @Actions;

    SELECT @RowsInserted = COUNT(CASE WHEN ActionTaken = 'INSERT' THEN 1 END),
           @RowsUpdated  = COUNT(CASE WHEN ActionTaken = 'UPDATE' THEN 1 END)
    FROM @Actions;
END;
GO

/* ---------------------------------------------------------------------
   6. End: promote watermarks (success only) and close the audit row
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_EndLoad
    @LoadID         INT,
    @Status         VARCHAR(20),          -- Succeeded / Failed
    @RowsExtracted  INT = NULL,
    @RowsInserted   INT = NULL,
    @RowsUpdated    INT = NULL,
    @ErrorMessage   NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Status = 'Succeeded'
        UPDATE etl.Watermark
        SET    LastLoadedDate    = PendingLoadedDate,
               PendingLoadedDate = NULL,
               UpdatedAt         = SYSDATETIME()
        WHERE  PendingLoadedDate IS NOT NULL;
    ELSE
        UPDATE etl.Watermark SET PendingLoadedDate = NULL;

    UPDATE etl.LoadLog
    SET    EndTime       = SYSDATETIME(),
           Status        = @Status,
           RowsExtracted = @RowsExtracted,
           RowsInserted  = @RowsInserted,
           RowsUpdated   = @RowsUpdated,
           ErrorMessage  = @ErrorMessage
    WHERE  LoadID = @LoadID;
END;
GO

/* ---------------------------------------------------------------------
   Master procedure - the whole pipeline in one transaction.
   SSIS can call this single proc, or call steps 1-6 individually.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_RunClaimsPipeline
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- any runtime error dooms the transaction -> clean rollback

    DECLARE @LoadID INT,
            @Extracted INT = 0,
            @ProvIns INT = 0, @ProvUpd INT = 0,
            @MemIns  INT = 0, @MemUpd  INT = 0,
            @FactIns INT = 0, @FactUpd INT = 0,
            @ErrMsg  NVARCHAR(4000);

    EXEC etl.usp_StartLoad @PipelineName = 'ClaimsDW_Incremental', @LoadID = @LoadID OUTPUT;

    BEGIN TRY
        EXEC etl.usp_ExtractToStaging @LoadID, @Extracted OUTPUT;

        BEGIN TRANSACTION;
            EXEC etl.usp_LoadDimProvider @LoadID, @ProvIns OUTPUT, @ProvUpd OUTPUT;
            EXEC etl.usp_LoadDimMember   @LoadID, @MemIns  OUTPUT, @MemUpd  OUTPUT;
            EXEC etl.usp_LoadFactClaim   @LoadID, @FactIns OUTPUT, @FactUpd OUTPUT;
        COMMIT TRANSACTION;

        EXEC etl.usp_EndLoad
            @LoadID        = @LoadID,
            @Status        = 'Succeeded',
            @RowsExtracted = @Extracted,
            @RowsInserted  = @FactIns,
            @RowsUpdated   = @FactUpd;

        SELECT @LoadID AS LoadID, @Extracted AS RowsExtracted,
               @ProvIns AS ProvidersInserted, @ProvUpd AS ProvidersUpdated,
               @MemIns  AS MemberVersionsInserted, @MemUpd AS MemberVersionsExpired,
               @FactIns AS ClaimsInserted, @FactUpd AS ClaimsUpdated;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SET @ErrMsg = ERROR_MESSAGE();
        EXEC etl.usp_LogError @LoadID, 'etl.usp_RunClaimsPipeline';
        EXEC etl.usp_EndLoad @LoadID = @LoadID, @Status = 'Failed', @ErrorMessage = @ErrMsg;

        THROW;   -- re-raise so SSIS / SQL Agent marks the job as failed
    END CATCH;
END;
GO
