# Sony structure and pairing audit — 2026-09-07

The actual selected folder is Sony **PXW-FX9V** footage. All 95 XML sidecars identify that model. The app supports this folder's naming pattern, and native preflight accounted for all 281 entries. This audit does not establish compatibility with every Sony camera or every card layout.

## Documented relationship

A clip's logical stem comes from the media filename, with only its extension removed:

| File | Logical clip stem | Role |
| --- | --- | --- |
| `DISCLOSURE_DAY0115.MXF` | `DISCLOSURE_DAY0115` | Media |
| `DISCLOSURE_DAY0115M01.XML` | `DISCLOSURE_DAY0115` | Non-real-time metadata |
| `DISCLOSURE_DAY0115R01.BIM` | `DISCLOSURE_DAY0115` | Real-time metadata |

`M01` and `R01` belong to the sidecar naming convention. They are not part of the shared logical clip stem. The original filenames are retained verbatim; Zipper never renames the source or archive members. An MXF stem that itself ends in `M01` or `R01` is retained in full.

Primary sources checked:

- [Adobe XMP Specification Part 3, section 1.3.4.4, XDCAM FAM Memory SxS](https://github.com/adobe/XMP-Toolkit-SDK/blob/main/docs/XMPSpecificationPart3.pdf): the flat Clip layout includes MXF, M01.XML and R01.BIM; BIM is real-time native metadata. The downloaded PDF SHA-256 was `2e80d671f87501c91ab18c0722c233e35a72d1c9245c70accb743917ebe2eb18`.
- [Adobe's XDCAM FAM handler](https://github.com/adobe/XMP-Toolkit-SDK/blob/main/XMPFiles/source/FileHandlers/XDCAMFAM_Handler.cpp): `SetPathVariables` locates the MXF and M01.XML; `FillAssociatedResources` collects matching existing `Mdd.XML` and `Rdd.BIM` resources, plus related resources outside Clip. `MakeClipFilePath` appends the appropriate suffix to the media clip name.
- [Sony Catalyst Prepare supported video devices](https://helpguide.sony.net/di-app/cpv3/v1/en/contents/0802_video_device.html): Sony identifies XDROOT as the XAVC-XD-Style root, including XAVC Intra and XAVC Long formats.
- [Sony FX9 recording specifications](https://pro.sony/en_MX/products/handheld-camcorders/pxw-fx9): 180 fps slow-and-quick recording is supported in the listed 2K scan/HD XAVC-I modes. This source does not independently establish a universal rule for BIM omission at that setting.

Zipper intentionally accepts only the implemented M01/R01 subset, one media + one XML + zero or one BIM. Other numbered metadata, XMP, KLV, proxy/take resources, nested directories, and unknown entries block preflight rather than being silently discarded. The logical prefix must be byte-exact; ASCII suffix/extension case variants are supported. Duplicate, shared, or competing sidecars block the entire job.

## Actual folder evidence

Source supplied by the user:

`/Users/atiliobarreda/Desktop/video/VISUAL DEALERS/VISUAL DEALERS/NYC/CAM 1/XDROOT/Clip`

- 95 MXF + 95 XML + 91 BIM = **281 files**, 72,835,846,074 bytes.
- Clip numbers 0024 through 0118 are present.
- All **95** XML `TargetMaterial.umidRef` values matched FFprobe's `material_package_umid` from the corresponding MXF. This independently checked actual MXF/XML identity in addition to filename pairing. FFprobe is an audit tool, not an app dependency.
- 87 normal 23.98p clips have BIM. Four 29.97p slow-and-quick clips also have BIM.
- Exactly clips **0057, 0058, 0059, 0060** lack BIM. All four XMLs record `slowAndQuickMotion`, capture rate `179.82p`, and `none` for the listed camera/lens/distortion/gyro/accelerometer acquisition events.
- This correlation is consistent with absent acquisition metadata for those recordings. It is not proof that every missing file was absent on the original card. An original card or trusted earlier offload manifest is required to establish that independently.
- Read-only metadata inspection preserved names, sizes, identities, modification times, and change times. No source file was renamed or written.

See [per-clip metadata results](qa/safety-reaudit/real-source-metadata.json) and [native actual-folder preflight](qa/safety-reaudit/real-source-preflight.png). The metadata audit does not semantically validate BIM internals, decode the complete videos, or make XML/UMID validation a built-in feature of Zipper.

The full release-engine packaging and verification run subsequently passed on this actual folder; see [full-run evidence](qa/safety-reaudit/actual-footage-handoff.json). The archive verification checks complete byte content, independent of camera codecs.

## Card-tree boundary

Selecting `XDROOT/Clip` includes only that flat folder. It does not include XDROOT-level metadata or sibling proxy, edit, take, or other folders. Adobe's documented layout and associated-resource handler explicitly contain these additional relationships. The app now warns about this scope during Sony-pattern preflight and includes that warning in the handoff evidence.

These archives preserve the selected clip files. They do not recreate a complete camera card or establish that a selected folder contains all recorded takes. Retain the complete original card tree separately when that is the required deliverable.
