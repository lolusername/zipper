# v1.0.2 safety re-audit

Executed 2026-09-07 on the macOS/Swift environment in [VALIDATION.md](../../VALIDATION.md). User footage was accessed read-only. Corruption, crash, cancellation, filesystem-mutation, and export-into-source tests used disposable fixtures exclusively.

## Findings and fixes

| Finding | Fix and executed evidence |
| --- | --- |
| The export save panel could offer New Folder before destination validation. | Disabled native save-panel directory creation, matching both source and destination pickers. This prevents a folder being created through that control before the export protection gate runs. |
| Standalone report export could write inside the recorded source when no sidebar source was selected. | Reproduced in v1.0.1 on a disposable source. Export now checks all known source identities and ancestry; it fails closed when the original location cannot be established. Eight regression tests pass. Native v1.0.2 rejected a source export with both sidebar folders empty, and the complete synthetic source baseline remained unchanged. A separate output-folder export succeeded. |
| Writable FAT32/HFS+ metadata could miss same-size rewrites with restored modification times. | Reproduced a wrong source hash on FAT32, false final-source success on HFS+, and a false delivery PASS after earlier-archive mutation on HFS+. Writable output now requires local APFS; FAT/exFAT/HFS+ integrity reads require an OS read-only mount. Actual disposable FAT32, exFAT and HFS+ image tests pass. The exFAT restriction is conservative; a whole-job false PASS was not reproduced on it. |
| Altered human reports and audit logs could pass delivery verification. | Exact comparison against JSON-derived evidence. Native altered-report test now fails although all ZIP payloads remain valid. Legacy-format happy-path tests pass. |
| Swift canonical string equality could hide different UTF-8 filename bytes. | Byte-exact file/package equality and ZIP inventory comparisons. Three Unicode disagreement paths reject inconsistent names. |
| A recovery-state write failure after public completion could contradict the committed delivery outcome. | Completed JSON is the authoritative public commit; a later recovery-state failure gives a completion warning. Injected fault regression passes. |
| Interrupted text/log publication could imply completed delivery too early. | Current text describes matching check evidence, explicitly requires completed JSON plus verification, and uses a final-check timestamp. Canceled/failed records clear completion dates; legacy interrupted jobs upgrade report generation on resume. Crash/recovery tests pass. |
| Timestamp rounding could make a newly created log disagree with its own JSON. | Reproduced in the first audit run; current-version text dates are normalized to whole seconds before formatting. Boundary-fraction round-trip tests pass. Legacy format rendering remains supported for tested fixtures; legacy subsecond-edge compatibility was not exhaustively qualified. |
| A large valid inventory could produce reports exceeding the verifier's 64 MiB read bound. | Estimated evidence size blocks preflight; actual state/report writes also enforce the bound. A 9,000-clip long-filename regression exercises the limit without transferring media. |
| Throwing descriptor initializers could close one descriptor twice. | All throwing checks finish before ownership is transferred to the initialized object. Inspected the resulting ownership paths; no forced descriptor-reuse race claim is made. |
| Mixed BIM presence needed an explicit operator explanation. | Preflight lists missing BIM stems, preserves every present BIM, and warns that flat Clip packaging excludes the surrounding card tree. Exact 281-file listing regression and real-folder preflight pass. |

## Completed automated and native validation

- [Full opt-in suite](full-test-run.txt): **120 tests, 0 failures, 0 skips**, 70.293 seconds. Includes real >4 GiB ZIP64, disk images, real process crashes, repeated recovery, report tampering, source/export isolation, and sparse 200 GB/1 TB planning.
- [Final camera tests](camera-final-tests.txt): **17 tests passed** after adding the card-tree scope warning.
- The first failed run is preserved in [pre-timestamp-fix-test-run.txt](pre-timestamp-fix-test-run.txt); the timestamp discrepancy is preserved in [timestamp-before.txt](timestamp-before.txt). Its defects were fixed before the passing full run.
- **686 single-byte ZIP structural corruptions** were rejected. This covers the enumerated structures; it is not a proof against all possible malformed archives.
- Native synthetic creation: **8/8 ZIPs, 281/281 files, 415,551 source bytes**, 95 MXF + 95 XML + 91 BIM. [Ready screen](native-ready.png), [deep pass](native-deep-pass.png), [independent zipfile evidence](native-evidence.json).
- Native failure checks: [altered human report rejected](native-tampered-fail.png), [source export blocked with empty sidebar selections](native-source-export-blocked.png). The safely exported failure report also correctly said FAIL.
- [No-write preflight evidence](native-preflight.json): destination stayed empty through the actual-folder and synthetic-folder analyses.
- UI automation intermittently timed out around native file panels. Two process samples found an idle main event loop, with no blocked archive worker. The user independently confirmed normal window responsiveness. The native synthetic creation, deep-pass, altered-report rejection, and blocked-export checks were captured successfully. Later attempts to capture the full-size GUI result and final save-panel state timed out, so those visual confirmations are not claimed. The full-size release-engine run and independent reader checks passed separately. The timeout itself was not diagnosed as an application deadlock.

## Actual footage qualification

[Camera research](../../SONY-STRUCTURE-AUDIT.md) identifies Sony PXW-FX9V and matches all 95 actual XML/MXF UMIDs. Native preflight accounted for **72,835,846,074 bytes / 281 files / 95 packages**.

The release HandoffCore objects used by the packaged app were linked into a temporary audit harness and run on the actual folder. **Creation, final source rehashing, and a separate deep delivery verification all passed for eight archives and 281 files.** The complete source inventory identities, sizes, modification times and change times were unchanged. [Run log](actual-footage-run.txt), [summary](actual-footage-handoff.json). The harness writes only to its separate development-workspace output.

Synthetic `source`, `delivery`, and `tampered-delivery` folders under `.build/reaudit-native-*` are test artifacts. The actual-footage qualification output is separately identified in the run summary. Neither is a request to use a test folder as the user's chosen delivery destination.

An additional [independent reader check](actual-footage-independent.json) used Python zipfile to compare **every archived byte directly with the actual source**, while also checking each member CRC and SHA-256. All 281 files / 72,835,846,074 bytes matched; source and delivery metadata remained unchanged. [Independent run log](actual-footage-independent-run.txt).

The final UI-only change clears a previous blocked-export message after a successful export retry. [Final package log](package-final.txt) records the rebuilt bundle and strict code-signature validation. This does not change the HandoffCore objects used in the full-size archive test.

## Scope of the result

The tested bytes and implemented checks pass in this local APFS environment. This does not establish universal correctness, camera-codec decodability, whole-card completeness, or physical-hardware qualification. Real disconnect/reconnect, actual power loss, other supported macOS versions, removable-media enclosure behavior, and full 200 GB–1 TB transfers remain deployment checks. Original-file SHA-256 evidence is not a signed authentication chain. The exact M01/R01 filename subset is supported; complete XDROOT reconstruction is outside this flat-folder app.
