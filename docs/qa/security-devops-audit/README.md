# Security and reliability audit — v1.0.3

Executed September 7, 2026. The user reported an informal concern from a friend but had no specific findings to provide. These are independently investigated findings, not an attributed review by that person. All fault injection used disposable fixtures. This audit did not alter or re-transfer the user's camera originals.

## Confirmed findings

| ID | Priority | Defect and consequence | Correction and evidence |
| --- | --- | --- | --- |
| REL-01 | High | A required human report changed while JSON was still provisional, but creation returned completed. The later delivery checker correctly failed. | Read back every published report and compare its exact bytes with the intended bytes and its identity with the written object. Recheck all report identities before committing completed JSON. [Before](publication-before.txt), [after](publication-after.txt). Regression also checks failed durable state and successful recovery. |
| REL-02 | High | Recovery validated one state snapshot's directory bindings, then accepted a second snapshot under the destination lock after checking only its UUID. Changed source/destination paths or identities could be carried into completed evidence while the original descriptors were used. | Revalidate the locked record and bind it to the opened source/destination before accepting it. Deterministic fault injection at the second-read boundary reproduced all four mismatched-binding cases. [Before](recovery-before.txt), [after](recovery-after.txt). |
| REL-03 | Medium | Recovery renamed pending artifacts before validating the newly read record. An invalid second snapshot could therefore cause mutations before rejection. | Validate structure and bindings before preserving pending artifacts. The regression confirms the pending filename and bytes remain intact. Same recovery logs as REL-02. |
| COMPAT-01 | Medium | Valid v1.0.0/v1.0.1 human reports and logs could fail verification when their text timestamps rounded upward but their JSON timestamps discarded fractions. | Allow only the recorded second or following second at known legacy timestamp positions. All remaining bytes must match. Current versions retain exact comparison. Tests reject two-second changes, backward changes, extra log text, and current-version timestamp alterations. [Before](legacy-before.txt), [after](legacy-after.txt). |
| BUILD-01 | Medium | Packaging overwrote the existing executable before generating icons and signing/verifying the new bundle. A later failure could leave the previously working app unusable; running instances were not protected. | Build and verify a separate bundle, then publish using an atomic directory swap. Serialize packaging and check for the running executable before building and again before publication. [Packaging tests](package-tests.txt), [actual running-app rejection](package-running-guard.txt). |

The timing allowance in COMPAT-01 reflects information irretrievably omitted from old JSON. It is not a general tolerance for report edits. Legacy maximum-size descriptions also used locale-dependent formatting; cross-locale legacy reports remain outside the compatibility qualification. Current versions use locale-independent byte counts.

## Verification record

- [Publication regressions](publication-regressions.txt): 59 related tests passed before the final combined suite.
- [Combined suite](full-test-run.txt): **125 tests, zero failures, zero skips, 75.065 seconds**. Includes real ZIP64 over 4 GiB, disposable filesystem images, process-crash recovery, and the new fault-injection regressions.
- [Packaging tests](package-tests.txt): 14 disposable scenarios passed, including compile/icon/signature/publication failure, concurrent packaging, startup during a build, replacement/first publication, and symlink rejection. The final test-fixture display-name/signing adjustment received syntax checking only; its launch tests were not repeated after the incident below. The production packaging code was unchanged by that fixture adjustment.
- [Release packaging](package-release.txt): v1.0.3/build 4 built, signed, strictly verified and atomically published. The [actual running-app guard](package-running-guard.txt) then rejected a rebuild before release compilation; the published bundle still passed strict signature verification afterward.
- Native v1.0.3 opened normally: [launch screenshot](native-launch.png). **Deep verification passed for 8 ZIPs and 281 synthetic members**, reading the existing v1.0.2 fixture delivery: [result screenshot](native-deep-pass.png), [accessibility record](native-deep-pass.txt). The app was left on its initial screen with no source/destination selected.
- [Release identity](release.json) records the executable hash. The prior 72.84 GB actual-footage transfer was not repeated for this release.

## Packaging test incident

The first packaging test harness tried to launch a copied system `sleep` executable inside an intentionally incomplete fixture named `Zipper.app`. macOS killed that fixture. The user then saw a damaged-app warning naming Zipper.app; this is consistent with that rejected fixture, but the warning's exact path was not captured. The actual workspace app remained v1.0.2 and passed strict signature verification at the time. No Gatekeeper settings or quarantine attributes were changed.

The test was corrected to compile its own fixture executable. Those tests passed. Future fixtures additionally have a valid signed bundle and the distinct display name **Zipper Packaging Test Fixture**. The real v1.0.3 app subsequently built and opened normally and completed the native verification above. [Incident details](package-fixture-incident.md).

## Practical limits

The destination lock coordinates Zipper jobs; it cannot freeze files against other software. Report/source/archive identities are checked up to the completion boundary. Later edits require another **Verify Existing Handoff** check. Keep a trusted copy of the manifest separately if authenticity, rather than agreement with supplied checksums, is required.

The existing local-APFS destination policy and read-only requirements for FAT/exFAT/HFS+ reads remain. The app's read-only source abstraction is a code boundary, not an OS-enforced sandbox. The ad-hoc signed local build is not a notarized redistribution release. Physical power loss/unplug tests, full 200 GB–1 TB transfers, and whole-card completeness are not established by this audit. See [previous qualification](../safety-reaudit/README.md) for the already completed 72.84 GB byte-level test and native automation limitations.
