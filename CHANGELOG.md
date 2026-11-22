# Changelog

## 3.0.0

- Default is now to write a repaired copy to an `Upload` folder (`-OutputDir`) and leave the SIUS file untouched; `-InPlace` restores the old behaviour.
- Shooter number 0 is detected by position (`-PlayerColumn`, default 1) when the file has no `PlayerNumber` header; a non-numeric first row is treated as a header.
- New `-ExcludePlayerZero` sets those rows aside in `<name>.skipped.csv`. Rows are never reassigned.
- Reads the file with shared access and retries, so a file still open in SIUS can be read.
- Strict UTF-8 decoding with a byte-exact fallback, so Windows-1252 characters are no longer replaced.
- Validates field count and the third-field value; reports row and field for every issue.
- Removed the restore-on-failure copy that could overwrite newer data; temp files are named `.guardian-*.tmp`.
- Tests rewritten for the new behaviour; fixed a CRLF-sensitive assertion.

## 2.0.0

- Converts confirmed third-field `0`/`1` values to `False`/`True`.
- Preserves repeated shooters and multiple sessions as independent rows.
- Adds dry-run, timestamped backups, atomic writes, and human-readable reports.
- Detects header-based `PlayerNumber 0` cases without mutating ambiguous data.
- Adds quoted-field parsing, encoding preservation, tests, documentation, and MIT license.
