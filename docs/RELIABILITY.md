# Reliability roadmap and 0.8 implementation

ArchiveDesk follows WinRAR's everyday archive-management workflow with native macOS UI. Reliability takes priority over additional formats or GPU acceleration. Existing RAR creation is retained; no proprietary RAR binary is distributed. This is **phase 1**, not completion of the entire large-archive roadmap.

## Fixed launch boundary

Two supplied local crash reports from 0.6/0.7 show an Objective-C exception inside `NSConcreteTask launchWithDictionary:error:` escaping Swift error handling. The reports do not identify the exact exception reason, so a bad path or external volume is not asserted as the root cause.

`CLIRunner` now uses Darwin `posix_spawn` directly (absolute executable path, no shell or PATH lookup). Launch errors are ordinary task errors, including nonexistent/non-executable tools, invalid working directories, invalid binaries and argument lists exceeding OS limits. Each launch has its own PID/process group. A runner refuses concurrent starts; cancellation sends TERM, then KILL after two seconds, and reaping is serialized with signalling to avoid targeting a recycled PID. Only descriptors explicitly configured for the child are inherited. Passwords remain bounded stdin-only data, never command arguments or environment variables.

This avoids this particular NSTask exception path; it is not a guarantee that no unrelated bug in the application could crash.

## Streaming and resource policy

- Pipe reads use fixed 64 KiB buffers. Text logs retain at most 512 KiB stdout / 256 KiB stderr (plus bounded safety flags). Updates are throttled to 5 Hz. Binary stdout is written incrementally to a private sibling `.partial` file and published exclusively only after success; failure/cancel removes that partial.
- Listings are parsed incrementally as UTF-8 records, rather than retaining a full raw listing and repeatedly decoding/copying it. A single record is limited to 1 MiB. Parsed entries remain an in-memory, budget-capped index; this is **not yet a disk-backed index**.
- Adaptive budgets are ceilings: around 1 GiB on an 8 GiB machine, up to 32 GiB on 64 GiB. Conservative halves the ceiling and uses one worker; Adaptive caps requested engine workers at four, Performance at sixteen, bounded by available cores. The 7z memory hint is advisory; the engine documentation explicitly says it can exceed that hint.
- Resident memory of the direct child is sampled every 0.5 seconds. Exceeding its launch-time budget stops it. Critical system memory pressure stops active children instead of trying to resize a decoder dictionary. Warning pressure reduces workers for subsequent commands. These are sampled per-child ceilings, **not a hard process-wide RAM allocation guarantee or a complete cache scheduler**; transient overshoot and application/index memory are additional.
- Disk checks happen before normal extraction, periodically during extraction/binary output, and during streamed destination copies. A 64 MiB reserve is kept where observed. Another process can consume disk between checks; write errors still fail the task.
- General archive extraction no longer inherits the mobile-inspector 2 GiB total / 512 MiB member limits. It rejects invalid sizes, excessive depth, unsafe paths, links, duplicate or case/normalization-colliding paths and extreme expansion (over 10 GiB and 10000:1). Mobile deep inspection/editing retain their separately documented limits.

## Publication, permissions, cancellation

The decoder extracts into a fresh private staging directory. Only an exit-zero result permits merging; CRC errors (where a format supplies CRC), wrong passwords and other failures never publish staged contents. Plain TAR has no content checksum: successful extraction is not cryptographic verification or authentication.

Each destination file is copied using a fixed 1 MiB buffer into a unique sibling partial, flushed, and published with exclusive filesystem linking. Existing files are backed up only after the incoming file has been fully copied. If publication fails, restoration is attempted and backups are retained. A failed/cancelled file is not left at its final name. Files completed earlier in the merge remain; merging a whole folder is **not** an atomic transaction. Crashes/power loss may leave identifiable hidden partials; no startup garbage collector is implemented.

Ordinary Unix `rwx` bits (including executable bits) and modification time are retained. Setuid/setgid/sticky are stripped; new-directory modes/times are finalized after children. Existing directories are not repermissioned. Mobile collision-streaming exports retain their documented non-executable behavior. Symlink and hardlink entries remain refused rather than being restored unsafely. ACL, xattr and resource forks are not claimed preserved.

Path preflight and no-follow/exclusive file opens add defense in depth, but the full extraction/merge is not yet a descriptor-relative sandbox against an adversary concurrently mutating destination ancestors. Use only trusted destination directories. Multi-volume sources also remain externally mutable while being read. CLI archive decoding continues to rely on the bundled engine's parser and its security fixes.

## UI and tasks

Engine task snapshots carry UUID, queued/running/completed/failed/cancelled, operation, stream byte counts and error. Stream bytes are not archive progress bytes. The UI observes snapshots; operation-level coordination is still in Model. Full cross-operation ArchiveTask scheduling/history and Pause/Resume are deferred.

Directory/filter rows are prepared off the main thread and presented in pages of 2000 using the native table. Cancelling/changing a filter discards stale results. The initial archive index still completes before browsable rows appear; fully incremental opening and a disk-backed index are the next indexing milestone. Directory selections are passed as directories instead of expanding every descendant into the OS argument list.

## Validation (2026-10-03)

- Local Ghidra ZIP: 6695 entries, 5219 regular files, 905891804 uncompressed bytes. Full engine extraction and destination merge passed; every file size checked, `ghidraRun` byte digest and executable permission checked. GUI extraction also completed with 5219 written / zero skipped.
- Synthetic ZIP64: a 5368709121-byte file was compressed, streamed back to disk and compared with incremental SHA-256. A 220000-entry synthetic listing (larger than the former 16 MB raw-text ceiling) parsed successfully.
- Invalid executable, invalid cwd, NUL argument, oversized argv, concurrent run, cancellation/reuse, bounded logs, secret redaction, output-limit cleanup, CRC corruption, Unicode/case collision, directory-prefix conflict and permission/mtime tests are included.
- Universal GUI and bundled 7zz both contain arm64 and x86_64. Runtime testing is Apple Silicon only. The three former IPA/APK fixtures were no longer at their supplied paths and that integration test is skipped; synthetic IPA/APK tests remain.
- 100 GB archives, actual 8/64 GB machines, forced real memory pressure/disk exhaustion, Intel and old macOS versions are **not** certified by these tests.

## Next phases

1. Finish a unified operation-level task coordinator and disk-backed progressive index; injectable resource-pressure tests; constrained safe symlink restoration and descriptor-relative extraction.
2. Legacy ZIP filename encoding selection with real CP437/GB18030/CP932/Big5/EUC-KR fixtures; no untested selector that silently fails. Broader TAR creation (TAR, tar.gz/xz/zst), existing tar/ISO extraction regression matrix, RAR4 fixtures and large archive stress testing.
3. Complete Apply to All conflict UI, Quick Look, archive comments and repair workflow, Finder actions and task queue. SHA-256/MD5 tools remain secondary to WinRAR-style workflows.
4. ACL/xattr/resource forks, additional package inspectors, Pause/Resume and measured tuning. No Metal/GPU extraction work.

References: [Apple Process documentation](https://developer.apple.com/documentation/foundation/process), Darwin SDK `spawn.h` / `libproc.h`, and the bundled official 7-Zip manual `cmdline/switches/method.htm` (memory limits and threads).
