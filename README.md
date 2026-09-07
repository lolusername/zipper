# Zipper

Native macOS media handoffs with independent ZIP64 archives and end-to-end SHA-256 verification. Built in Swift and SwiftUI for flat directories of camera media and matching XML/BIM sidecars.

## Run

Requires macOS 14 or later and Apple Silicon for the included local build. Open `build/Zipper.app`, or build from source with Xcode command-line tools:

```sh
./scripts/package.sh
open build/Zipper.app
```

The local app is ad-hoc signed with the hardened runtime. Redistribution requires your own Developer ID signing and Apple notarization. No Homebrew runtime, Python runtime, package server, or network service is required by the app. Public libarchive headers are vendored; runtime dependencies are the macOS system libarchive, zlib, CryptoKit, and SwiftUI.

## Operator workflow

1. Choose **SOURCE — READ ONLY** and a separate **DESTINATION — WRITABLE OUTPUT** directory.
2. Select a maximum size in decimal GB, or an exact number of archives. Set the output prefix.
3. **Analyze / Preflight**. This performs no source or destination writes. Inspect media/XML/BIM counts and bytes, sidecar matching errors, volume capacity, and every file in each proposed archive.
4. Resolve blocking issues outside this app. Oversized indivisible packages require explicit acknowledgment.
5. **Create Verified Handoff**. Source hashing, archive writing, member verification, archive hashing, and final source rehashing are distinct phases. Only the completed verification state means the delivery is ready.
6. Before handoff, use **Verify Existing Handoff**. Quick mode checks ZIP SHA-256 values; deep mode also reads and hashes every member. Both require complete reports, detect missing/unexpected ZIPs, write nothing, and work without the source card.

Each clip package contains exactly one supported media file and one matching XML, plus an optional matching BIM sidecar. Exact-basename pairs such as `A001C001.mov` + `A001C001.xml` remain supported. For MXF clips, Zipper also recognizes the `M01.XML` / `R01.BIM` naming pattern:

```text
DISCLOSURE_DAY0115.MXF
DISCLOSURE_DAY0115M01.XML
DISCLOSURE_DAY0115R01.BIM
```

These three files form one indivisible package. `DISCLOSURE_DAY0115M01.XML` maps to the media stem `DISCLOSURE_DAY0115`; the matching BIM is included, hashed, packaged, and verified alongside the MXF and XML. BIM is optional when absent and is never silently discarded when present. Original filenames remain unchanged inside the ZIP.

`BASER01.BIM` may accompany either `BASE.MXF` + `BASE.XML` or `BASE.MXF` + `BASEM01.XML`. Only the `M01` / `R01` suffixes are supported; suffixes and extensions may vary in ASCII case, while the shared media stem must match exactly, including case and Unicode representation. Bare `BASE.BIM`, other numbered suffixes, duplicate sidecars, and competing XML matches block creation.

Hidden/system files, unknown files, nested directories, symlinks, ambiguous mappings, and unmatched media/XML/BIM also block creation. Nothing is silently omitted. The app has no delete, move, rename-original, erase, or source-cleanup actions. Source selection does not imply format-level validation of camera codecs, XML schemas, or BIM contents; all accepted bytes are preserved exactly.

Supported media extensions are centralized in `SupportedMedia.extensions`. Camera formats that require folder trees or multiple media components are outside this flat-directory workflow.

## Delivery

```text
FOOTAGE_001.zip
FOOTAGE_002.zip
HANDOFF_MANIFEST.json
HANDOFF_MANIFEST.txt
SHA256SUMS.txt
HANDOFF_LOG.txt
.zipper-job.json
.zipper-job.lock
```

Each ZIP is independently extractable. Media, XML, and matching BIM files always remain together. Every included BIM receives the same source hashing, archived-member verification, final source check, and manifest evidence as media and XML. ZIP64 and STORE are unconditional; no split volumes or compression are used. Archive payloads retain original filenames and byte content. Filesystem extended attributes, resource forks, original permissions, and filesystem timestamps are not delivery payloads. Source extended attributes and timestamps are never explicitly changed; a filesystem may update access time as a consequence of reading.

Independent archive checks:

```sh
cd /path/to/delivery
shasum -a 256 -c SHA256SUMS.txt
unzip -t FOOTAGE_001.zip
```

SHA-256 values prove agreement with the supplied manifest. They are not a signed chain of custody; retain a trusted copy of the manifest/checksum evidence separately when authenticating a later delivery.

## Interruption and recovery

Use **Cancel Job** to stop at an I/O boundary. Verified ZIPs remain, incomplete data remains `.partial`, and the durable job state remains non-complete. App Quit requests the same cancellation and waits for the worker to stop. Abrupt process termination leaves the last durable phase for recovery.

The last selected destination is remembered. On relaunch, an interrupted job there is offered for recovery; another destination can be selected manually. **Resume Verified Handoff** checks the original source and destination identities, rehashes the source, rehashes and deeply verifies every purportedly complete archive, and resumes remaining work. It never trusts a filename or boolean. A complete verified partial interrupted just before promotion can be recovered. Other incomplete partials and interrupted state writes are renamed to unique retained artifacts before rebuilding; they are never silently deleted.

A disconnected or read-only destination can prevent recording the last failure. In that case the app reports the persistence failure, and the previous durable state remains non-complete. Reconnection does not imply trust. Changed directory identity, remapped mounts, changed source bytes, corrupted archived bytes, or ambiguous ownership stop recovery. Choose a new destination and perform a fresh job if exact identity cannot be restored. Verified ZIPs are never overwritten or deleted automatically.

Delivery reports are published transactionally: provisional JSON is non-complete, all report files are flushed, final source/output guards run, then completed JSON becomes the public commit marker. A partially published report set cannot pass the delivery checker.

## Safety architecture

- `ReadOnlySource` owns private, read-only directory/file descriptors. Its public operations are scan, inspect, validate, stream, and hash. All production source access goes through this abstraction.
- `Destination` confines writes to a separately selected, identity-checked directory. Leaf names, no-follow opens, exclusive creation, private regular files, and identity-bound exclusive promotions prevent accidental redirection and replacement.
- Preflight accounts for exact ZIP64 overhead, manifests/state snapshots, and a safety reserve of at least 64 MiB or 5%. A partial is renamed in place, so no duplicate archive-sized temporary copy is required.
- For this deterministic format, planned bytes are exactly `98 + sum(fileBytes + 148 + 2 * UTF8FilenameBytes)`. The writer checks this bound during every write and on completion.
- The custom STORE writer never trusts its own successful return. An explicit structural validator checks local/central ZIP64 records and the footer; the independent macOS libarchive reader streams every actual archived member through CryptoKit SHA-256.
- Completed archive SHA-256, size, identity, and exact membership are recorded before `.partial` is promoted. A final source rehash and output identity checks precede completion.
- Memory use is bounded by streaming chunks and file/plan metadata, not media size. Source chunks are 4 MiB; archive verification/hash chunks are 1 MiB.
- A destination advisory lock prevents concurrent cooperating jobs. Drives receive `fsync` and macOS `F_FULLFSYNC` where supported. Hardware and remote servers still determine whether they honor flush requests.

The source API is a capability boundary in code, supported by source immutability and filesystem guard tests. This local build is not an OS-enforced read-only security sandbox. Use hardware write protection or an OS-mounted read-only source when operational policy requires an independent protection boundary.

## Validation and operational qualification

Run the core suite:

```sh
swift test
```

Opt-in tests use only disposable test fixtures:

```sh
ZIPPER_RUN_LARGE_ZIP_TESTS=1 swift test --filter ZIPArchiveTests.testRealZIP64OverFourGiB
./scripts/test-filesystems.sh
```

See [validation evidence](docs/VALIDATION.md) for executed checks and remaining qualification limits. Routine tests include byte-for-byte source snapshots, preflight zero writes, pairing/ancestry/alias guards, exact partitioning, corruption/truncation, cancellation, recovery, independent extraction, source changes, and delivery checks without source media.

This release has not been qualified with an entire 200 GB–1 TB physical card, physical unplug/replug during each phase, real power loss, all USB/Thunderbolt enclosures, every macOS version, or all SMB/NFS server configurations. Identical device numbers trigger a warning; separate filesystems do not prove separate physical drives. Network filesystem capacity/durability limits can depend on the server. Complete those deployment-specific checks before treating this as a field-qualified sole handoff workflow.

## Source references

- [Apple CryptoKit SHA256](https://developer.apple.com/documentation/cryptokit/sha256) — incremental hashing.
- [PKWARE ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) — ZIP64 structures.
- [libarchive public API](https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h) — independent archive reading.

Original project requirements are retained in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).
