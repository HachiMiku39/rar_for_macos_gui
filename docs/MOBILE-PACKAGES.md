# IPA and APK packages

ArchiveDesk 0.6 adds package-aware browsing, extraction and read-only inspection. The bundled 7-Zip remains the archive decoder. The app neither executes package code nor decrypts FairPlay, unpacks Android protectors, dumps runtime memory, bypasses signatures or rebuilds installable apps.

## Use

Open or drop an IPA/APK, browse folders, then use Extract All or Extract Selected. The Inspector button runs an optional background check using a private temporary copy; you can close its panel and continue browsing. Cancel stops the scan, and temporary inspection data is removed when the task exits normally or is cancelled. An abrupt process crash can leave system-temporary data behind.

Format identification combines ZIP magic and the decoded archive structure, not the extension alone. IPA requires `Payload/*.app/` contents; APK requires a root `AndroidManifest.xml`. DEX/resources are supplementary signals, since resource-only split APKs may omit them. Malformed or missing metadata is reported separately. An ordinary ZIP renamed to IPA is not labeled as a validated iOS app. This is structural recognition, not an installability or signature check.

## IPA

Reads XML/binary Info.plist with Foundation, locating `CFBundleExecutable` and displaying bundle identifier, names, version and build. Multiple top-level apps are displayed separately and flagged. Counts framework/extension bundle names, and scans every extracted regular file for Mach-O magic, plus expected executables and dylibs. Framework/extension Info.plists contribute expected executable paths; missing or unreadable targets make inspection incomplete.

The bounds-checked parser supports 32/64-bit thin Mach-O and 32/64-bit Fat tables, either byte order, with up to 64 slices. Each slice reports architecture, `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64`, `cryptid`, `cryptoff` and `cryptsize`. Invalid ranges, truncated commands and invalid/overlapping slices are unknown, not clear.

- Encrypted: at least one observed active marker, no observed clear slice.
- Mixed: observed active and clear/no-command slices coexist.
- No active FairPlay encryption detected: completed inspection found no active marker.
- Unknown: no reliable clean conclusion can be formed.

Incomplete coverage is shown independently, even if another component proves an active marker exists. Zero cryptid does not prove historical decryption, absence of obfuscation, or absence of other protection. Extraction does not decrypt code.

## APK

A native Swift, bounds-checked AXML subset reads the string pool and manifest attributes; it does not require a Java runtime or Android SDK. It reads package, version, SDK levels, Application name/label, and inventories DEX, Multi-Dex, ABI and native libraries. Resource references remain IDs (for example `@0x7f100031`); full resources.arsc resolution, DEX decompilation and signature verification are not implemented. Plaintext/nonstandard or malformed manifests return Unknown with an explanation.

`Resources/PackageRules/apk-packers.json` is a deliberately small heuristic rule list. Matching a filename or Application class yields **Packer suspected**, with the exact matched evidence. No match means only **No known packer signatures detected**, never “unprotected.” This first rule set checks selected Jiagu/DexHelper-style names, not all protectors; it does not establish vendor identity. Unknown/custom schemes, renamed loaders and runtime behavior can evade these checks. Missing rules or failed manifest parsing produce Unknown.

## Safe export and filename collisions

Mobile-package operations enforce 50000 entries, 512 MiB per file and 2 GiB listed uncompressed size (and 2 GiB input). Unsafe/absolute/traversal paths, links, duplicate paths, invalid sizes and file/directory prefix conflicts are refused. The input is copied to a private snapshot and relisted before extraction, so the checked listing and extractor use the same copy. This is defense in depth, not a guarantee against every malformed archive or engine vulnerability.

Android resource names often differ only in case. A case-insensitive macOS volume cannot retain both original spellings at the same path. ArchiveDesk creates a deterministic collision-safe path plan. If needed, each file is decoded through a bounded stdout stream into an app-selected destination, never an archive-controlled output path. Conflicting or overlong components receive `__ArchiveDesk_N` suffixes; a unique `ArchiveDesk-path-map-*.json` records original and exported names, with a completion flag. This preserves contents, not an installable package layout. A sample APK required 39 renamed paths.

The destination is always a new folder. Existing files are not overwritten. Normal exports retain whatever timestamps/modes 7-Zip supports. Collision-safe streaming exports use private directories and non-executable regular files; original timestamps, Unix modes, quarantine and extended attributes are not reconstructed. Symlinks are refused rather than followed or silently converted. Cancellation/failure may leave partial output; the UI reports this and does not show success. CRC/unsupported-method/password/structural errors remain visible in the engine logs. ZIP Test checks archive integrity, not mobile signing or trust.

Existing restrictions on nested archive opening and direct `.app` resource launching remain. Drag-out, Quick Look, a full Manifest/plist editor, APK signature schemes, IPA code-signing details and repacking are not part of this version.

From 0.7 onward, the new-folder rule above applies to internal staging. The GUI may then merge staged content into an existing destination with explicit conflict policies and backups; see EDITING-EXTRACTION.md.

## Tests and provenance

Three user-supplied local samples were checked without executing them or uploading their bytes, metadata files, or the supplied research document. The source tree includes synthetic parser tests and an opt-in local integration test, not third-party packages. Set `ARCHIVEDESK_TEST_PACKAGES` to newline-separated local paths and `ARCHIVEDESK_TEST_7ZZ` to the engine executable. RAR tests additionally use `ARCHIVEDESK_TEST_RAR`.

The provided logo is packaged unchanged apart from resolution/format conversion. Rebuild its ICNS with `python3 scripts/build-icon.py`. The supplied artwork and third-party characters/marks are not licensed by the project's source-code license; no ownership or third-party clearance is asserted.

Implementation references:

- [Android APK Analyzer](https://developer.android.com/studio/debug/apk-analyzer)
- [Android apkanalyzer metadata fields](https://developer.android.com/tools/apkanalyzer)
- [AOSP ResourceTypes.h AXML layout](https://android.googlesource.com/platform/frameworks/base/+/master/libs/androidfw/include/androidfw/ResourceTypes.h)
- [Apple Mach-O loader.h](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h)
- User-provided IPA research v2: consulted locally; not redistributed.
