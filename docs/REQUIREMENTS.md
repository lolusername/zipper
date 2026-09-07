Build a production-quality native macOS application in Swift + SwiftUI for professional DIT/media-offload handoffs.

This application packages a directory containing professional camera footage and matching XML sidecars into multiple independently extractable ZIP archives while preserving source media exactly and providing cryptographic evidence that every delivered byte matches the source.

This is NOT a generic ZIP application.

Its design priorities, in order, are:

1. NEVER modify or endanger source media.
2. Never report success without actual end-to-end verification.
3. Make operator mistakes difficult or impossible.
4. Recover safely from interruption and hardware/filesystem failures.
5. Provide an exceptional, polished professional macOS UI.
6. Make every important operation auditable.

Treat this as software that could be used on a professional film set where irreplaceable camera originals are involved.

Do not optimize for minimum code or fastest implementation at the expense of safety.

# NON-NEGOTIABLE SOURCE-SAFETY ARCHITECTURE

The application MUST be incapable by design of modifying source media.

Do not merely disable deletion in the UI.

Create a read-only source abstraction whose public interface exposes ONLY operations required for:

* directory enumeration
* metadata inspection
* opening files for read-only streaming
* hashing
* validation

It must expose NO methods for:

* delete
* move
* rename
* truncate
* overwrite
* create
* write
* replace
* chmod
* changing timestamps
* modifying extended attributes
* modifying source directory contents in any way

Never use filesystem APIs that request write access to source files.

Never open a source file using a writable file descriptor.

Never create temporary files in the source directory.

Never use the source directory for application state.

Never put manifests, logs, ZIPs, caches, lock files, thumbnails, hidden files, or `.partial` files inside the source directory.

Never offer:

"Move instead of copy"
"Delete after transfer"
"Erase card"
"Clean source"
"Rename originals"

These features must not exist.

The application performs:

READ SOURCE → WRITE DESTINATION

and never:

MOVE SOURCE → DESTINATION.

All source-side production code must go through the read-only abstraction.

Add automated tests specifically designed to prove source immutability.

Before and after a complete test job, recursively compare the source fixture's:

* filenames
* paths
* file counts
* file sizes
* contents/hashes

The source tree must be byte-for-byte unchanged.

# SOURCE AND DESTINATION SEPARATION

Require the operator to independently select:

SOURCE
DESTINATION

Resolve/canonicalize URLs before comparison.

Block jobs when:

* source == destination
* destination is inside source
* source is inside destination where this creates unsafe recursion
* destination resolves through a symlink/alias to source
* source and destination resolve to the same directory through different path representations

Do not rely on string comparison alone.

Clearly label the source in the UI:

SOURCE — READ ONLY

Clearly label the destination:

DESTINATION — WRITABLE OUTPUT

If source and destination are on the same physical device, allow it only after displaying a non-blocking operational warning unless there is a technical reason to block it.

# EXPECTED INPUT

Initially support a flat source directory containing media files and matching XML sidecars with identical basenames.

Example:

A001C001.mov
A001C001.xml

A001C002.mov
A001C002.xml

A001C003.mxf
A001C003.xml

Define supported media extensions centrally rather than scattering extension checks throughout the code.

Do not assume every unknown file can be discarded.

During preflight, explicitly identify:

* recognized media
* XML sidecars
* matched pairs
* unmatched media
* unmatched XML
* unexpected files
* hidden/system files

Never silently omit an unexpected source file.

Unexpected files must appear in preflight so the operator knows they exist.

For v1, either include unexpected files safely according to a documented policy or block packaging until the operator resolves them. Prefer blocking over silently discarding potentially important camera metadata.

# CLIP PACKAGE MODEL

A matching media file and XML file constitute one indivisible ClipPackage.

Conceptually:

ClipPackage:

* basename
* media URL
* XML URL
* media size
* XML size
* total size
* media SHA-256
* XML SHA-256

Enforce:

exactly one supported media file
+
exactly one matching XML
========================

valid ClipPackage

Blocking errors include:

* media without XML
* XML without media
* duplicate basename
* multiple media files mapping ambiguously to one XML
* unreadable source file
* source file disappearing during analysis
* source file changing during the job

Never split a ClipPackage across archives.

# PREFLIGHT MUST WRITE NOTHING

Selecting Analyze / Preflight must perform zero destination writes and zero source writes.

Preflight should inspect:

* source
* destination
* media/XML relationships
* unexpected files
* file readability
* source metadata
* source total bytes
* destination filesystem
* destination free capacity
* expected output requirements
* batching plan
* estimated archive count
* predicted archive sizes
* filesystem compatibility
* naming collisions

Only after preflight passes may creation begin.

# ARCHIVE SIZING MODES

Support two mutually exclusive batching modes.

MODE A — MAXIMUM ZIP SIZE

Operator specifies:

Maximum ZIP size: [25] GB

This is a hard ceiling, not merely a target.

Pack complete ClipPackages into independent ZIPs without exceeding the maximum.

Exception:

If one indivisible ClipPackage itself exceeds the maximum size, never split it automatically.

Preflight must prominently report:

"Clip A001C041 is 31.2 GB and exceeds the selected 25 GB maximum."

Require explicit operator acknowledgment before proceeding with that oversized archive.

MODE B — NUMBER OF ARCHIVES

Operator specifies:

Number of ZIPs: [8]

Distribute complete ClipPackages into exactly N archives while balancing total byte sizes as evenly as practical.

Never split ClipPackages.

Never create empty ZIPs.

If N exceeds the number of available ClipPackages, block the operation.

Show the exact planned partitioning during preflight.

# 200 GB PROFESSIONAL CARD WORKFLOW

The application should work comfortably with source sets around 200 GB and scale toward approximately 1 TB or more.

Default maximum archive size may be 25 GB, but it must be editable.

For a ~200 GB source, preflight might display:

Source: 200.3 GB
Clip packages: 184
Maximum archive size: 25 GB
Planned archives: 9
Largest planned archive: 24.7 GB

The exact number depends on clip sizes.

Never promise a specific archive count before calculating it.

# INDEPENDENT ZIP FILES

Outputs MUST be ordinary independently extractable ZIP files:

FOOTAGE_001.zip
FOOTAGE_002.zip
FOOTAGE_003.zip

DO NOT create:

FOOTAGE.z01
FOOTAGE.z02
FOOTAGE.zip

Do not create multipart/split-volume ZIP archives.

Every `.zip` must be independently usable if all other archives are unavailable.

Use ZIP64.

Use STORE / compression level 0 by default.

Professional video is commonly already compressed, and the purpose here is reliable packaging rather than compression.

If compression is ever added later, it must not alter verification semantics.

# ARCHIVE TRANSACTION SAFETY

Never initially write:

FOOTAGE_001.zip

Instead write:

.FOOTAGE_001.zip.partial

Workflow:

1. Create `.partial`
2. Write complete archive
3. Flush
4. Close
5. Reopen archive
6. Validate archive structure
7. Read every archived member
8. Hash every archived member
9. Compare against source hashes
10. Compute final archive SHA-256
11. Record successful verification
12. Atomically rename `.partial` to `.zip`

Only verified archives receive the `.zip` extension.

If anything fails, leave the artifact clearly marked incomplete/failed and NEVER present it as deliverable.

Do not overwrite an existing verified ZIP silently.

If the destination already contains expected output names, preflight must detect the collision and block until the operator explicitly chooses a safe new output naming scheme or destination.

Never silently replace an existing delivery.

# CRYPTOGRAPHIC VERIFICATION

Use SHA-256.

Use Apple's CryptoKit where appropriate.

All hashing MUST use streaming/chunked IO.

Never load entire video files into RAM.

STEP 1 — SOURCE HASH

Before packaging, calculate SHA-256 for every source file.

Record:

relative path
basename
file type
byte count
SHA-256
relevant immutable metadata used to detect mid-job changes

STEP 2 — ARCHIVE CONTENT VERIFICATION

After creating an archive:

close it completely.

Then independently reopen it through the ZIP reader.

For every archive member:

* decompress/read its actual archived stream
* calculate SHA-256
* compare it with the original source SHA-256
* compare expected byte count
* confirm expected filename/path

Do NOT consider a successful ZIP API return value sufficient verification.

Do NOT merely test CRC.

Do NOT merely compare file sizes.

Every delivered source file must pass SHA-256 comparison.

STEP 3 — ARCHIVE HASH

After member verification succeeds, calculate SHA-256 over the final complete ZIP itself.

This allows verification after:

* external-drive handoff
* network copy
* cloud upload
* download
* client delivery

# SOURCE CHANGE DETECTION

The source must remain stable during a job.

Record source metadata during initial scan.

Before consuming each source file, ensure it still corresponds to the expected source object.

If a source file:

* changes size
* changes identity
* disappears
* becomes unreadable
* changes unexpectedly while hashing/reading

stop safely.

Never continue using a potentially changing source while claiming a verified result.

For maximum assurance, after packaging is complete, revalidate source hashes or otherwise verify source stability before declaring the entire job finished.

The final success state should mean:

the source bytes verified at the end of the operation correspond to the bytes verified inside the archives.

# REMOVABLE MEDIA SAFETY

Assume source and/or destination may be removable drives.

Handle:

* source card disconnected
* destination drive disconnected
* drive temporarily unavailable
* filesystem becoming read-only
* write failure
* I/O error
* destination running out of space
* application crash
* application force quit
* macOS restart
* sleep/wake
* USB/Thunderbolt interruption

Never convert these conditions into apparent success.

If source disappears:

pause/stop safely and preserve already verified destination archives.

If destination disappears:

stop writes immediately and mark current archive incomplete.

Do not automatically trust a reconnected drive solely because it has the same display name.

Revalidate filesystem identity/path/job state as appropriate before resuming.

# DISK SPACE

Preflight destination capacity conservatively.

Account for:

* archive payload
* ZIP overhead
* manifests
* temporary `.partial` output
* safety margin

Do not simply check:

free space > source size

without considering actual output behavior.

Monitor available destination capacity during the job.

If free space becomes dangerously low:

stop before an uncontrolled filesystem-full failure when possible.

Clearly explain what happened.

Never delete verified archives automatically to recover space.

# FILESYSTEM COMPATIBILITY

Inspect the destination filesystem.

Detect relevant limitations such as file-size restrictions.

For example, a destination filesystem incapable of holding a planned 25 GB ZIP must cause preflight failure.

Do not let a 25 GB archive begin writing to a filesystem with a ~4 GB per-file limit.

Present the problem in plain language and suggest choosing an appropriate destination.

# CANCELLATION

Cancellation must be safe.

When the operator presses Cancel:

* stop at a safe boundary
* never touch source
* preserve already verified ZIPs
* leave the currently incomplete archive marked `.partial`
* persist accurate job state
* never label the job successful

Do not implement cancellation using destructive cleanup of source files.

Provide an explicit distinction between:

CANCEL JOB

and any later optional operation to remove incomplete destination artifacts.

Never remove verified outputs automatically.

# RESUME AND CRASH RECOVERY

Persist job state on the destination or in an appropriate application-support location, never in the source.

Job state should include:

* job UUID
* source identity/path information
* destination identity/path information
* source manifest
* source hashes
* planned ClipPackages
* planned archive membership
* archive statuses
* completed archive SHA-256 values
* timestamps
* application version
* verification state

Archive states should include:

Queued
Hashing Source
Writing
Verifying Contents
Hashing Archive
Verified
Failed
Interrupted

After application restart:

detect interrupted jobs.

Offer:

Resume Verified Handoff

Before trusting an existing supposedly completed archive:

recompute its archive SHA-256 and compare against persisted state.

If it does not match, invalidate it.

Never trust a filename or persisted boolean alone.

# MANIFESTS

Generate:

HANDOFF_MANIFEST.txt
HANDOFF_MANIFEST.json
SHA256SUMS.txt

The human-readable manifest should clearly summarize the delivery.

The machine-readable manifest should contain enough information to independently audit the packaging process.

Include:

* application name/version
* job UUID
* creation timestamp
* completion timestamp
* source label/path information appropriate for the manifest
* source file count
* media count
* XML count
* unexpected-file count
* ClipPackage count
* total source bytes
* batching mode
* configured max size or archive count
* final archive count
* every archive name
* archive byte size
* archive SHA-256
* files contained in each archive
* each source file's byte size
* each source file's SHA-256
* verification result
* warnings
* failures, if generating a failure report

SHA256SUMS.txt should use a conventional format suitable for independent verification.

# FINAL VERIFICATION / DELIVERY CHECK

Provide a separate:

VERIFY EXISTING HANDOFF

workflow.

The operator should be able to select an existing delivery directory later.

The app should:

* read the manifest
* verify every expected ZIP exists
* calculate every ZIP SHA-256
* compare it with the manifest
* optionally perform deep archive-member verification
* report missing/unexpected archives
* produce a clear pass/fail result

This means the app can verify the external drive immediately before physically handing it to a client.

This workflow must not require the original source for archive-level verification.

If the original source is available, optionally support full source ↔ archive member verification.

# LOGGING AND AUDITABILITY

Create a useful job log.

Record:

* preflight start/end
* hashing start/end
* archive writing
* archive verification
* archive hash
* failures
* interruptions
* resume operations
* completion

Do not log sensitive file contents.

Make logs exportable with the delivery report.

Errors should contain enough context to diagnose the affected file/archive without exposing irrelevant system information.

# PROFESSIONAL UI / VISUAL QUALITY

The UI is a first-class product requirement.

Do NOT make this look like a generic SwiftUI tutorial application.

Do NOT simply place default Form controls in a window.

The visual language should feel appropriate next to professional post-production / DIT software:

* restrained
* precise
* high-information-density
* visually sophisticated
* calm
* extremely legible
* dark-mode excellent
* native to macOS without looking generic

Take inspiration from the level of polish associated with professional media applications such as DaVinci Resolve, Hedge, ShotPut Pro, Frame.io Transfer, or high-end ingest tools, without copying proprietary branding or interfaces.

Build a small internal design system.

Define reusable:

* typography hierarchy
* spacing scale
* surfaces
* borders
* status colors
* status badges
* progress components
* buttons
* archive rows/cards
* error panels
* warning panels
* verified states
* hover states
* focus states
* disabled states

Avoid excessive gradients, giant rounded cards, decorative glassmorphism, and generic AI-generated-dashboard aesthetics.

Favor dense, intentional desktop software.

# MAIN WORKFLOW UI

Initial view:

SOURCE — READ ONLY
[ Choose Source ]

DESTINATION
[ Choose Destination ]

PACKAGING
○ Maximum ZIP Size
[25] GB

○ Number of ZIPs
[8]

[ ANALYZE / PREFLIGHT ]

The primary packaging button must NOT exist as enabled until preflight completes.

After preflight, show:

SOURCE
200.3 GB
184 media
184 XML
184 matched packages

DESTINATION
412.7 GB available
Filesystem: APFS
Writable: Yes

PACKAGING
Maximum archive: 25 GB
Planned archives: 9
Largest predicted archive: 24.7 GB

INTEGRITY
✓ All media/XML pairs matched
✓ Source readable
✓ Destination writable
✓ Filesystem supports planned archive sizes
✓ Sufficient free space
✓ No output collisions

Then enable:

CREATE VERIFIED HANDOFF

# PREFLIGHT PLAN INSPECTOR

Let the operator inspect exactly what will happen BEFORE writes begin.

Show each proposed archive:

FOOTAGE_001.zip
24.7 GB
23 ClipPackages
46 files

FOOTAGE_002.zip
24.3 GB
21 ClipPackages
42 files

etc.

Allow expanding an archive to see its planned members.

This is inspection only.

Do not let users drag individual media/XML files between archives in v1 unless pairing invariants can be absolutely guaranteed.

# LIVE JOB UI

Display truthful progress.

Show:

Overall Progress
Current Archive
Current Operation
Current File
Bytes Read
Bytes Written
Verified Bytes
Elapsed Time
Throughput
Archives Verified / Total

Archive lifecycle:

QUEUED
HASHING SOURCE
WRITING
VERIFYING CONTENTS
HASHING ARCHIVE
VERIFIED

Never display 100% overall completion before verification completes.

Writing 100% is NOT job completion.

The visual hierarchy should make this distinction obvious.

Example:

FOOTAGE_004.zip

Writing
████████████████████████ 100%

Verifying contents
██████████████████░░░░░ 76%

A001C041.mov      ✓ SHA-256 MATCH
A001C041.xml      ✓ SHA-256 MATCH
A001C042.mov      VERIFYING

# SUCCESS STATE

The success state is cryptographically meaningful.

Display:

VERIFIED HANDOFF READY

9 / 9 archives verified
368 / 368 source files verified
200.3 GB source accounted for
0 missing files
0 hash mismatches

Destination:
[location]

Manifest:
HANDOFF_MANIFEST.txt

[Reveal in Finder]
[Verify Handoff Again]
[Export Report]

Do not display this state if ANY required integrity check failed.

# ERROR UX

Errors must be explicit and actionable.

Examples:

BLOCKED — Missing XML

A001C041.mov has no matching XML sidecar.

No destination data has been written.
