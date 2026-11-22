# SIUS CSV Guardian 2.0

A cautious Windows utility that prepares SIUS CSV exports for DGI SPConnector while preserving every shooting-session row.

## Confirmed repair

The utility changes only the third semicolon-separated field when its complete value is `0` or `1`:

- `0` becomes `False`
- `1` becomes `True`

It does not merge, deduplicate, reorder, or delete rows. If the same shooter has multiple sessions, each session remains a separate row in its original position.

## Important safety limit

An observed SPConnector upload failed when `PlayerNumber` was `0`, but the correct SIUS schema and replacement rule have not been validated. If a header named `PlayerNumber` exists, the utility reports the affected row numbers but does **not** change or remove them. If no such header exists, it says that detection was not possible. Never invent a player number.

## Windows use

1. Finish the shooting session and close anything that may be writing the CSV.
2. Extract the ZIP to a normal folder.
3. Double-click `Run-SIUS-CSV-Guardian.cmd` and select the CSV.
4. Read the report. Exit code 2 / a warning means unresolved rows need review.
5. Upload through SPConnector only after the report is acceptable.

When a confirmed change is made, the original is copied beside the CSV as `.backup-YYYYMMDD-HHMMSS`. The repaired file is written using a temporary file and atomic replacement. A timestamped UTF-8 report is always created.

## Dry run and unattended use

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File .\SIUS-CSV-Guardian.ps1 -Path "C:\SIUS\SiusData\Data\shooting.csv" -DryRun -NoGui
```

Remove `-DryRun` to repair. Use `-ReportPath` to choose the report location. Exit codes: `0` = completed without unresolved detected records; `2` = unresolved PlayerNumber 0 or malformed/short rows; other nonzero = error.

## Compatibility and assumptions

- Windows PowerShell 5.1 or PowerShell 7.
- Semicolon-delimited CSV, including correctly escaped quoted fields.
- The third field rule is positional, based on the known SIUS/SPConnector error.
- UTF-8, UTF-8 BOM, UTF-16 LE, and UTF-16 BE are preserved. A BOM-less file is treated as UTF-8.
- Embedded newlines inside quoted CSV fields are not supported; such exports need a real sample before support can be validated.

## Tests

Pester 5 tests are in `tests/SIUS-CSV-Guardian.Tests.ps1`. From the extracted folder:

```powershell
Invoke-Pester .\tests
```

The tests cover dry-run behavior, backup/report creation, quoted semicolons, repeated shooter/session rows, idempotence, and safe `PlayerNumber 0` reporting.

## What we still need

Please provide anonymized copies of:

1. A real SIUS CSV that failed.
2. The corresponding DGI/SPConnector error log.
3. If possible, one CSV that uploaded successfully.

Replace names and personal details consistently, but preserve delimiters, headers, field order, zero values, quoting, encoding, and multiple-session rows. With those samples, the positional assumption and a safe policy for `PlayerNumber 0` can be validated.

## Open source

Licensed under the MIT License. See `LICENSE`.
