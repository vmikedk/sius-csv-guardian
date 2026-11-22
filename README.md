# SIUS CSV Guardian 3.0

A cautious Windows utility that prepares SIUS CSV exports for DGI SPConnector while preserving every shooting-session row.

## Confirmed repair

The utility changes only the third semicolon-separated field when its complete value is `0` or `1`:

- `0` becomes `False`
- `1` becomes `True`

SPConnector 1.3.0 reads that field with `Boolean.Parse`, which only accepts `False`/`True`. Rows are never merged, deduplicated or reordered. If the same shooter has several sessions, each stays a separate row.

By default the **original file is not touched**: the repaired copy is written to an `Upload` folder next to it (`-OutputDir` to change). Point SPConnector at that copy. `-InPlace` modifies the source instead and makes a `.backup-YYYYMMDD-HHMMSS` first.

## Shooter number 0

An upload containing a result group with shooter number 0 made DGI answer HTTP 500. The utility finds these rows by position (field 1, `-PlayerColumn` to change) when the file has no header, or through a `PlayerNumber` header when there is one. A first row with a non-numeric shooter field is treated as a header.

- Default: rows are kept and reported (exit code 2).
- `-ExcludePlayerZero` (or `Run-SIUS-CSV-Guardian-ExcludePlayerZero.cmd`): rows are removed from the repaired copy and saved to `<name>.skipped.csv`. They are **never reassigned** to another shooter; review them by hand.

## Validation

- Field count per row is compared with `-ExpectedFields` (default: the most common count in the file; SIUS Data 7.5p exports 28).
- A third field that is not `0/1/True/False` is reported with row and field number and left unchanged.
- Unparseable rows are reported and left unchanged. The remaining rows are still processed.

## Windows use

1. Finish the shooting session. A file still open in SIUS is read with shared access and retried a few times; if it is still locked, close SIUS or try again.
2. Extract the ZIP to a normal folder.
3. Double-click `Run-SIUS-CSV-Guardian.cmd` (or the `-ExcludePlayerZero` variant) and select the CSV.
4. Read the report. Exit code 2 / a warning means unresolved rows need review.
5. Upload the copy from the `Upload` folder through SPConnector, then check the result in DGI.

## Dry run and unattended use

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File .\SIUS-CSV-Guardian.ps1 -Path "C:\SIUS\SiusData\Data\20261114.csv" -DryRun -NoGui
```

Remove `-DryRun` to write the copy. Options: `-OutputDir`, `-ReportPath`, `-InPlace`, `-PlayerColumn`, `-ExpectedFields`, `-ExcludePlayerZero`. Exit codes: `0` = no unresolved rows; `2` = unresolved shooter 0 rows (not excluded), malformed/short/wrong-length rows or an unexpected third-field value; other nonzero = error.

## Compatibility and assumptions

- Windows PowerShell 5.1 or PowerShell 7.
- Semicolon-delimited CSV, including correctly escaped quoted fields.
- UTF-8, UTF-8 BOM, UTF-16 LE and UTF-16 BE are preserved. A BOM-less file that is not valid UTF-8 is handled byte for byte (for example Windows-1252), so characters such as æ, ø, å are not altered.
- Embedded newlines inside quoted fields are not supported.

## Tests

Pester 5 tests are in `tests/SIUS-CSV-Guardian.Tests.ps1`:

```powershell
Invoke-Pester .\tests
```

## Open source

Licensed under the MIT License. See `LICENSE`.
