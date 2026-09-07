# v1.0.1 MXF/XML/BIM validation

Recorded on 2026-09-07 in the rebuilt native Zipper v1.0.1 app. This supplements the historical v1.0.0 evidence in the parent QA directory.

The fixture contained three clip groups, `DISCLOSURE_DAY0115` through `DISCLOSURE_DAY0117`. Each group contained its original `.MXF`, `M01.XML`, and `R01.BIM` files: **3 media + 3 XML + 3 BIM = 9 files**, totaling **104,547 bytes**. The operator selected exactly **2 archives**.

| Native check | Observed result |
| --- | --- |
| No-write preflight | Displayed 3 media, 3 XML, and 3 BIM. Destination remained empty; source baseline remained unchanged. |
| Create Verified Handoff | Reached VERIFIED HANDOFF READY: 2/2 archives verified, 9/9 files verified, 0 missing files, 0 hash mismatches. |
| Verify Handoff Again | Deep verification passed for 2 ZIPs and 9 archived members. |
| Independent Python reader | Both ZIP SHA-256 values matched the manifest; all 9 extracted member sizes and hashes matched the original baseline. Each complete triplet stayed in one archive. Source names, sizes, and hashes remained unchanged. |

The final bundle passed `codesign --verify --strict` and reports version 1.0.1. Only the four disposable QA source/destination preference keys were cleared; the rebuilt app was reopened on its clean initial screen.

The complete opt-in automated suite passed **80 tests, 0 failures, 0 skips**, in **35.360 seconds**:

```sh
ZIPPER_RUN_LARGE_ZIP_TESTS=1 ZIPPER_RUN_FILESYSTEM_TESTS=1 swift test
```

Evidence files:

- [test-run.txt](test-run.txt): complete automated test output.
- [native-evidence.json](native-evidence.json): machine-readable native results and supplementary independent Python `zipfile` checks.

This fixture validates complete triplet accounting and verification. It does not replace physical-media, enclosure, disconnect/reconnect, power-loss, or full-card qualification described in [VALIDATION.md](../../VALIDATION.md).
