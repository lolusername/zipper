# Native macOS acceptance checks

Executed on macOS 26.5.2, Apple Silicon, 2026-09-07, using the actual `build/Zipper.app` release bundle (`studio.zipper.handoff`). UI actions used native folder/save panels and the application's real model and archive engine. Screenshots show real fixture results, not preview data.

## Fixture and evidence

- Source: `.build/UI-QA/fixtures/camera-originals` — three media/XML pairs, six files, 95,066 bytes.
- Destination: `.build/UI-QA/fixtures/delivery` — a separately selected sibling directory on APFS.
- Before/after source names, sizes, SHA-256 values, archive hashes, and independent member checks are recorded in `source-integrity.json`.
- `exported-verification-report.txt` is the actual report produced by the native Export Report / Save workflow.

## Executed workflow

1. Opened the release `.app` and independently selected source and destination using `NSOpenPanel`.
2. Confirmed Create Verified Handoff was disabled before preflight.
3. Selected Archive count, retained 8 for 3 clip packages, and ran Analyze. The app reported one blocking issue, prohibited empty ZIPs, explicitly stated that nothing was written, and kept Create disabled. Analyze click through returned completed UI state in 1.24 seconds.
4. Changed archive count to 2. The previous preflight immediately disappeared and Create remained disabled until reanalysis.
5. Ran Analyze again. It passed with exactly two nonempty archives, three paired clip packages, six source files, expected capacity reserve, and a visible same-device operational warning.
6. Confirmed the destination still contained zero entries after both the failed and successful native preflights.
7. Expanded `FOOTAGE_002.zip` and inspected `A001C001.mov` + `.xml` and `A001C003.mov` + `.xml` together in the planned archive.
8. Clicked Create Verified Handoff. The real job finished with 2 / 2 archives verified, 6 / 6 source files verified, zero missing files, and zero hash mismatches.
9. Independently reopened both created ZIPs using Python's `zipfile`, read all six actual member streams, and compared their byte counts and SHA-256 values to the original source baseline. Every comparison passed; no members were duplicated or missing. The entire source filename/size/hash snapshot remained identical.
10. Confirmed persisted job state was `completed` and `finalSourceVerified` was true. Both manifests, conventional `SHA256SUMS.txt`, job state, and audit log were present.
11. Clicked Verify Handoff Again with deep verification enabled. The UI reported an independent pass for two ZIPs and six members. Historical creation panels were replaced by the delivery-check result.
12. Used Export Report, accepted the native Save panel's new filename, then read the actual exported text. It contained PASS, 2 archives, deep verification Yes, and 6 members.
13. Quit the application normally after verification.
14. Relaunched the final rebuilt release with saved source/destination bookmarks. The window and restored paths appeared in 892 ms. No filesystem-permission workaround or broad access grant was used.
15. Used the dedicated Verify Existing Handoff folder chooser after relaunch. The final build again reported two ZIPs verified and six members checked.
16. Revalidated the already completed saved handoff using Resume. The final READY state showed 2 / 2 archives and 6 / 6 files, with Create Verified Handoff disabled and the completed-handoff explanatory text. `04-ready.png` was replaced with this final-build screenshot.
17. Quit and cleared only the four fixture-specific Zipper source/destination path and bookmark preference keys, then relaunched the application with no source or destination selected for user handoff.

## Issues found and corrected during native testing

- Initial parent-directory identity traversal could stall in a native application's `openat("..")` access request. Source/destination guards now obtain canonical paths from open descriptors and avoid parent traversal for disjoint selected roots. The final release native preflight completed promptly.
- Synchronous startup recovery inspection could prevent a window appearing when reopening a previously selected protected folder. Recovery/bookmark work now runs away from the main thread, and window creation performs no saved-path filesystem read.
- The Create button initially remained enabled after completion, although the engine still blocked overwrite collisions. It now requires no existing job.
- Starting creation while viewing the lower plan inspector could leave the success panel above the viewport. Operation transitions now scroll the work area to the result at its top.

This GUI fixture validates the real operator path and independent byte verification. It does not stand in for a physical removable-drive disconnect test or a complete 200 GB / 1 TB transfer.
