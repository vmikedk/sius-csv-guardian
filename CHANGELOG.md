# Changelog

## 2.0.0

- Converts confirmed third-field `0`/`1` values to `False`/`True`.
- Preserves repeated shooters and multiple sessions as independent rows.
- Adds dry-run, timestamped backups, atomic writes, and human-readable reports.
- Detects header-based `PlayerNumber 0` cases without mutating ambiguous data.
- Adds quoted-field parsing, encoding preservation, tests, documentation, and MIT license.
