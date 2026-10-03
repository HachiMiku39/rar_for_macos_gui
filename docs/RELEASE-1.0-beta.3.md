# ArchiveDesk 1.0.0-beta.3

- Fix the blank running-app Dock icon by loading the bundled ICNS explicitly at launch; preserve the supplied artwork.
- Show CPU capacity share (0–100%) plus process CPU using Activity Monitor's one-core = 100% scale. Both cover ArchiveDesk + the active engine, not other applications. Multi-core process CPU may legitimately exceed 100%.
- Includes the 1.0 beta features: extraction queue, apply-to-all conflicts, SHA-256/MD5 tools, Quick Look, single-file drag export, legacy ZIP filename encodings, TAR-family creation and configurable split volumes.
- Compression/extraction/test operations automatically open a progress window with elapsed time, cancellation, memory, process disk I/O and destination capacity. Hiding it does not cancel the task.

macOS 14+, Apple Silicon + Intel (Universal). Beta, not Developer ID signed or notarized. No RARLAB binary is bundled. Quit the old version before replacing it in Applications.

CPU semantics: https://developer.apple.com/forums/thread/710931

Local validation: Universal build; 63 tests, 60 passed / 3 fixture-dependent skips; runtime CPU delta checked against POSIX accounting; native progress window tested with Ghidra ZIP. ICNS decoded with 11 representations and nontransparent image data. Physical Intel testing and a visual Dock check on the affected installation remain unverified.
