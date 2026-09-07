# Validation evidence — 2026-09-07

Environment: Apple Silicon, macOS 26.5.2 (25F84), Xcode 26.5, Swift 6.3.2. Deployment target is macOS 14; the delivered binary is arm64.

## v1.0.3 security and reliability audit

The full opt-in suite passed **125 tests, zero failures, zero skips**, in **75.065 seconds**. [Complete output](qa/security-devops-audit/full-test-run.txt). New regressions reproduce and reject changed reports during publication, changed recovery bindings between state reads, and mutations caused by invalid recovery records. Legacy subsecond report timestamps now verify within their specifically documented historical precision limit. [Findings and before/after evidence](qa/security-devops-audit/README.md).

The previous 72.84 GB actual-footage qualification below remains historical v1.0.2 evidence; that transfer was not repeated for this update. New corruption and interruption tests used disposable fixtures only.

## Automated checks — historical v1.0.0 baseline

The v1.0.0 full opt-in suite passed **64 tests, zero failures, zero skips**, in 31.805 seconds. The v1.0.1 and v1.0.2 results are recorded below:

```sh
ZIPPER_RUN_LARGE_ZIP_TESTS=1 ZIPPER_RUN_FILESYSTEM_TESTS=1 swift test
```

The complete output is [qa/full-test-run.txt](qa/full-test-run.txt).

| Evidence | Executed check |
| --- | --- |
| Source immutability | Recursively compared fixture paths, counts, sizes, SHA-256/content before and after complete handoffs; cancellation/recovery also preserves original content. |
| No-write preflight | Source and destination snapshots before/after; actual FAT32 target remained empty during both blocked analyses. |
| Source/destination isolation | Same path, aliases, symlinks, ancestor/descendant folders, firmlink paths, source replacements, no-read parents, unsafe output links, expected-identity publication. |
| Clip pairing and batching | Missing/ambiguous pairs, unexpected/hidden/nested files, exact N, oversized acknowledgment, exact ZIP overhead, and unrelated ZIP collisions. |
| ZIP interoperability | Deterministic STORE ZIP64, UTF-8 member names, independent libarchive verification, and `/usr/bin/unzip -t`. |
| Real ZIP64 boundary | Created media of 4,294,967,312 bytes plus XML, streamed the complete archive, verified SHA-256 of every member, and tested with system unzip. The large test passed in 20–21 seconds. |
| Corruption | Payload and CRC corruption, wrong hashes/names/counts, central-directory corruption and truncation, file replacement during hashing, and modifications to earlier archives while later ones are checked. |
| Actual process crashes | Child XCTest processes abruptly exited with `_exit(86)` during member verification, after the first archive was promoted, and before report publication. Parent checked durable non-complete state, unchanged source bytes, preserved verified ZIPs, released lock, and successful resume/deep verification. |
| Report transaction | Incomplete report publication cannot pass a delivery check. Recovery preserves pending files, completes owned reports, and only publishes completed JSON after final guards. |
| Cancellation | Source hashing/writing/verification boundaries and final publication, with no successful job returned after accepted cancellation. |
| Recovery | Rehashes existing ZIPs and source, rejects corrupt archives and changed directory identities, preserves partials, and recovers interrupted initial state writes. |
| Delivery check | No original source needed; missing/unexpected ZIPs, incomplete manifests, inconsistent checksum reports, report mutation, unsafe report links, and altered archives fail. |
| Filesystem limits | Mounted a disposable 128 MiB FAT32 image. A 25 GB sparse source was blocked by FAT32's 4,294,967,295-byte file limit. An 80 MiB source was blocked by reserve requirements despite enough free bytes for payload alone. Image was detached and removed. |
| Large-scale planning | Sparse 200 GB and 1 TB fixtures yielded 9 and 42 planned ZIPs with a 25 GB ceiling, exact byte accounting, unchanged source metadata/allocation, zero destination writes, and under 256 MiB additional peak RSS. This was preflight only, not a complete large-card transfer. |

## Native app and packaging — historical v1.0.0 baseline

The release bundle is `build/Zipper.app`, identifier `studio.zipper.handoff`.

- `swift build -c release` passed.
- `codesign --verify --strict` passed; local ad-hoc signature with hardened runtime.
- `otool -L` confirms system dependencies only; no Homebrew library path or bundled third-party runtime.
- Native folder picker and real fixture preflight: 3 media/XML pairs. Requesting 8 ZIPs blocked creation before writes. Changing the mode invalidated the approved plan. Requesting 2 ZIPs produced a valid partition with inspectable paired members.
- Native creation: **2/2 verified ZIPs, 6/6 source files, 95 KB accounted for, zero missing files, zero mismatches**.
- Native deep reverify passed with 2 archives and 6 members. Python's independent `zipfile` reader additionally compared each member's size and SHA-256 to the original fixture baseline; all 6 source files remained unchanged. See [qa/source-integrity.json](qa/source-integrity.json).
- Native Export Report produced the pass report with 2 verified archives and 6 verified members. See [qa/exported-verification-report.txt](qa/exported-verification-report.txt).
- Initial native testing found and fixed unnecessary parent-directory traversal that delayed analysis. Release analysis then completed in about 1.24 seconds, including UI inspection overhead.
- Startup recovery discovery and bookmark resolution run away from the main thread. Saved raw paths are not synchronously opened during window construction.
- Normal Quit requests cancellation and waits for the worker. Abrupt process termination is covered by the independent crash harness.
- Final bundle relaunch with saved folder bookmarks completed in 892 ms. A completed handoff was reverified through the recovery action; READY was shown with Create disabled. Dedicated Verify Existing also passed. Only the four test source/destination preference keys were cleared, and the final app was left open on its clean initial screen.

Screenshots and the complete [native QA record](qa/NATIVE-QA.md) are in [qa](qa/).

## Qualification limits

These results establish the implemented safety and verification behavior in this environment. They do **not** establish qualification for all hardware or operating systems.

Before production deployment, validate representative physical camera media and destination enclosures, physical disconnect/reconnect in every phase, actual power loss, full 200 GB–1 TB transfers, sleep/wake behavior with removable hardware, and supported macOS versions. FAT32 validation used a real mounted disk image, not a physical FAT32 device. The source abstraction is a code-level read-only interface; this local build is not an OS-enforced read-only sandbox. Hardware write protection remains a separate assurance.

The app is locally runnable and ad-hoc signed. Public distribution still requires Developer ID signing and notarization. No signing credentials were supplied or used.

## v1.0.1 update — complete MXF/XML/BIM packages

The full opt-in suite passed **80 tests, zero failures, zero skips**, in **35.360 seconds**, including the real ZIP64 boundary and disposable FAT32 volume checks. The complete output is [qa/triplet-support/test-run.txt](qa/triplet-support/test-run.txt).

Native QA in the rebuilt v1.0.1 app used three groups, `DISCLOSURE_DAY0115` through `DISCLOSURE_DAY0117`, each containing `.MXF`, `M01.XML`, and `R01.BIM`: **9 files, 104,547 source bytes**, planned into **2 archives**.

- Preflight displayed **3 media, 3 XML, 3 BIM**. The destination remained empty and the source baseline remained unchanged.
- Native creation reached **VERIFIED HANDOFF READY**, with **2/2 archives**, **9/9 files**, **0 missing files**, and **0 hash mismatches**.
- **Verify Handoff Again** passed deep verification of **2 ZIPs and 9 archived members**.

See the [v1.0.1 QA record](qa/triplet-support/README.md) and [machine-readable native evidence](qa/triplet-support/native-evidence.json). The hardware and deployment qualification limits above still apply.

## v1.0.2 safety re-audit

The expanded opt-in suite passed **120 tests, zero failures, zero skips**, in **70.293 seconds**. After the final camera-scope warning was added, all **17 camera tests** passed again. The release build and strict code-signature validation passed. See [the complete audit record](qa/safety-reaudit/README.md), [full test output](qa/safety-reaudit/full-test-run.txt), and [final camera tests](qa/safety-reaudit/camera-final-tests.txt).

The rebuilt native app successfully created and deeply reverified **8 ZIPs / 281 synthetic source files** (95 MXF, 95 XML, 91 BIM), totaling 415,551 source bytes. Python zipfile independently matched every archived member against the source baseline. The test source remained unchanged; the output directory remained empty through preflight.

Separately, the user's actual 72,835,846,074-byte Sony folder passed **native preflight only** with 95 clip packages, 281 entries, and eight planned archives. Read-only XML/FFprobe inspection matched all 95 XML target UMIDs to the associated MXF material-package UMIDs and identified PXW-FX9V in every XML. A subsequent run linked the packaged release HandoffCore objects into a temporary audit harness and successfully archived all 72.84 GB, rehashed the full source, and deeply reverified all eight archives. Python zipfile then independently compared every archived byte directly with the current source, checked every member CRC and manifest SHA-256, and confirmed unchanged source/delivery metadata. This was not a video-codec decode or a physical camera-card qualification. See [the camera audit](SONY-STRUCTURE-AUDIT.md).

Current creation destinations are writable local APFS only. Local FAT/exFAT/HFS+ sources and delivered archives require an OS read-only mount. Network filesystems are unsupported. The physical-hardware qualification limits above still apply.
