# SSIS package: ClaimsDW_Incremental.dtsx

This guide walks you through building the package in Visual Studio. Building it yourself takes about 30–45 minutes, and then you can screenshot it and explain every task in an interview or client call.

**Tools:** Visual Studio 2022 Community + the *SQL Server Integration Services Projects 2022* extension, and SQL Server 2019/2022 Developer Edition.

There are two ways to orchestrate the pipeline. Build **Option B** for your portfolio, because it shows more SSIS skill. Option A is what you'd hand a client who wants something simple.

---

## Option A: one task (simple)

| Task | Type | Setting |
| --- | --- | --- |
| Run Claims Pipeline | Execute SQL Task | `EXEC etl.usp_RunClaimsPipeline;` |

The stored procedure handles the transaction, watermarks, logging and rollback. SSIS just schedules and alerts.

---

## Option B: step by step (portfolio version)

### 1. Project setup

1. **New Project → Integration Services Project** → name it `ClaimsDW_ETL`
2. **Project parameters** (Project.params):

| Name | Type | Value | Sensitive |
| --- | --- | --- | --- |
| `ServerName` | String | `localhost` | No |
| `DatabaseName` | String | `ClaimsDW` | No |

3. **Connection manager** (project level): OLE DB → `ClaimsDW`. Right-click it → *Parameterize* → bind `ServerName` and `DatabaseName`, so the same package runs in dev, test and prod without edits.

### 2. Package variables

| Variable | Type | Default |
| --- | --- | --- |
| `User::LoadID` | Int32 | 0 |
| `User::RowsExtracted` | Int32 | 0 |
| `User::ProvIns` / `User::ProvUpd` | Int32 | 0 |
| `User::MemIns` / `User::MemUpd` | Int32 | 0 |
| `User::FactIns` / `User::FactUpd` | Int32 | 0 |

### 3. Control flow

```
[SQL - Start Load] → [SQL - Extract to Staging] → [SEQ - Load Warehouse] → [SQL - End Load (Succeeded)]
                                                   ├─ [SQL - Load DimProvider]
                                                   ├─ [SQL - Load DimMember]
                                                   └─ [SQL - Load FactClaim]
```

**SQL - Start Load** (Execute SQL Task, connection `ClaimsDW`)

```sql
DECLARE @id INT;
EXEC etl.usp_StartLoad @PipelineName = 'ClaimsDW_SSIS', @LoadID = @id OUTPUT;
SELECT @id AS LoadID;
```

ResultSet: **Single row** → Result Set tab: `LoadID` → `User::LoadID`

**SQL - Extract to Staging**

```sql
EXEC etl.usp_ExtractToStaging ?, ? OUTPUT;
```

Parameter Mapping:

| Variable | Direction | Data type | Parameter name |
| --- | --- | --- | --- |
| `User::LoadID` | Input | LONG | 0 |
| `User::RowsExtracted` | Output | LONG | 1 |

**SEQ - Load Warehouse** (Sequence Container)

- Set `TransactionOption = Required`. The three loads then commit or roll back together, which needs the MSDTC service running. If you'd rather not use MSDTC, keep `Supported` and rely on the master stored proc for atomic loads.
- Inside it, chain three Execute SQL Tasks, each with the same pattern:

```sql
EXEC etl.usp_LoadDimProvider ?, ? OUTPUT, ? OUTPUT;   -- then usp_LoadDimMember, usp_LoadFactClaim
```

Map parameter 0 → `User::LoadID` (Input) and 1, 2 → that task's `Ins`/`Upd` variables (Output).

**SQL - End Load (Succeeded)**

```sql
EXEC etl.usp_EndLoad @LoadID = ?, @Status = 'Succeeded',
     @RowsExtracted = ?, @RowsInserted = ?, @RowsUpdated = ?;
```

Map `LoadID`, `RowsExtracted`, `FactIns` and `FactUpd`, in that order.

### 4. Error handling (Event Handlers tab)

Package-level **OnError** → Execute SQL Task:

```sql
EXEC etl.usp_EndLoad @LoadID = ?, @Status = 'Failed', @ErrorMessage = ?;
```

Map `User::LoadID` and `System::ErrorDescription`.

Set `System::Propagate = False` on the OnError handler of the child tasks, so one error doesn't log many times. Also set **MaximumErrorCount = 1** on the package.

### 5. Data Flow alternative for extract (shows Data Flow skill)

To show Data Flow work, replace *SQL - Extract to Staging* with this:

1. **SQL - Get Watermark**: `SELECT LastLoadedDate FROM etl.Watermark WHERE TableName = 'src.Claim'` → `User::LastLoaded` (String).
2. **Data Flow - Extract Claims**:
    - *OLE DB Source*, SQL command:
      `SELECT * FROM src.Claim WHERE ModifiedDate > ?` → parameter `User::LastLoaded`
    - *Derived Column*: `LoadID` = `@[User::LoadID]`, `ClaimStatus` = `UPPER(TRIM(ClaimStatus))`
    - *Row Count* → `User::RowsExtracted`
    - *OLE DB Destination* → `stg.Claim` (fast load, table lock)
    - Error output on the destination → redirect rows to a flat file for review
3. Repeat the Data Flow for Member and Provider. You can run the three in parallel in the control flow.

### 6. Deploy and schedule

1. In SSMS: **Integration Services Catalogs → Create Catalog** (SSISDB)
2. In Visual Studio: right-click the project → **Deploy** → folder `ClaimsDW`
3. In SSISDB, create an **Environment** `PROD` with `ServerName` and `DatabaseName`, then reference it from the project
4. Create a **SQL Agent job**: step type *SQL Server Integration Services Package*, source SSIS Catalog, environment PROD, scheduled daily at 2:00 AM, with an operator email notification on failure

### 7. Screenshots for your portfolio

- Control flow with the sequence container (after a green, successful run)
- Data Flow showing row counts on the arrows
- SSISDB *All Executions* report
- `SELECT * FROM etl.LoadLog` after three runs
