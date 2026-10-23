# macOS media preview — 1.1 development build 16

This ports the user-facing preview workflow from ArchiveDesk iOS 0.3.3, not its
FFmpeg/dav1d binary backend. The macOS archive engine, passwords, editing, batch
queue, package inspectors and Universal 2 support are retained. iOS files are not modified.

## Interaction

Double-click a supported image, video, audio or text file; alternatively select it
and press Space, or choose Preview in the context/Tools menu. Folders still navigate.
A separate resizable window appears **before** extraction, with a loading state and
Cancel. No media autoplays. Audio has play/pause, seek, ±15 s and volume; video uses
AVPlayerView's controls, including fullscreen. Closing the window stops playback.

Music shows recognized common/ID3/iTunes labels (title, artist, album, album artist,
track, disc, date, genre, composer, comment, author, description, copyright, encoder)
and the first usable embedded JPEG/PNG cover. Not every format exposes every label
through AVFoundation. Missing/damaged artwork does not block audio. Tags are read-only.
System player control labels follow macOS's language; app-owned labels support English,
Simplified Chinese and Japanese, with the existing English-first language-pack interface.

Quick Look remains an explicit separate action, including for PDF/Office documents.
Open Selected Item retains its trusted-file confirmation and default-app behavior.
These older exports live until application exit; **internal preview** copies have
their own lifetime and are removed on close, switch, failure or archive reload.

## Formats and deliberate differences from iOS

- Video/audio: AVFoundation capability detection, then AVPlayer/AVKit. MP4/MOV with
  supported H.264/HEVC/audio codecs and common native audio formats are candidates,
  not guarantees based on extension. No transcoding, shell player, external download,
  FFmpeg runtime or private codec APIs are added. MKV/WebM/Ogg/AV1 support is not
  promised; unsupported or corrupt media gets a visible fallback message.
- Image: ImageIO first-frame thumbnail (up to 2560 px), EXIF orientation applied.
  JPEG/PNG/WebP/HEIF and other ImageIO-readable formats depend on the OS. Animation,
  pixel-perfect full-resolution viewing and editing are not included.
- Text: UTF-8, UTF-16 and bounded legacy-codepage decoding with an independent
  Auto/manual picker (build 19). Guesses are identified and can be overridden.
  A bounded prefix is rendered as plain text with selection/copy. XML, HTML, SVG
  and source are not executed or fetched. Binary signatures/control data are refused.
- The desktop app continues to support macOS 14+ and arm64 + x86_64. Runtime tests
  on an Apple Silicon development machine do not establish Intel/macOS 14 codec parity.

## Safety and lifecycle

1. Existing single-file export validates the whole archive's paths/links, uses a
   private `0700` temporary directory and an exact literal selection, streams to
   disk with output/disk limits, and requires a successful engine result and exact size.
   Encrypted entries use the existing in-memory/stdin password flow. CRC or password
   failure never supplies a URL to the player.
2. PreviewSafety rejects executable/archive signatures, unsafe paths and special
   files. Prefix reads use `O_NOFOLLOW | O_NONBLOCK`; no giant archive is read as Data.
3. Media signatures must match a recognized container family. HLS/ASX/URL-list text
   disguised as a movie is refused. `AVURLAssetReferenceRestrictionsKey = forbidAll`
   disallows both remote references and other local-file references; alias resolution
   and external playback are disabled. No remote cover lookup is implemented.
4. Up to 512 MiB per staged media/text file; images up to 32 MiB / 32 million pixels;
   video dimensions up to 32 million pixels, at most eight AV tracks. Text reads at
   most 256 KiB + four lookahead bytes. Covers up to 8 MiB and 1024 px output; at most
   64 metadata items and 2048 UTF-8 bytes per displayed string (including combining marks).
   From build 19, a text-codepage decoding failure retains only the bounded prefix
   and its verified staging directory until close/switch, allowing a manual retry;
   it does not bypass extraction, password or CRC validation.
5. The 3-second preferred playback buffer and 1440p preferred playback resolution
   are AVPlayer hints, **not hard RSS ceilings**. AVFoundation owns media/metadata
   allocations before app-level checks; a strict per-decoder sandbox memory cap is
   not claimed. ImageIO allocates within its implementation as well. No attempt is
   made to replicate iOS's software-decoder RAM budget using misleading constants.
6. Loading has a 20-second UI timeout; cancellation invalidates the request before
   cancelling tasks/assets. Late results cannot reopen a closed preview. Player KVO,
   time observers, failure notifications, media references and temporary roots are
   released together. Cancellation cannot forcibly interrupt an ImageIO C call;
   its bounded result is discarded when the worker returns.

Temporary file deletion is ordinary filesystem removal, not secure erasure. The
app does not promise recovery/cleanup after an OS crash. This preview code is not a
new process-isolated codec sandbox; only open archives from sources you trust.

## Verification

Run `swift test` with the same real-engine environment used by the existing tests.
`FilePreviewTests` covers multilingual text/BOMs/truncation, malformed images,
downsampling, symlink/FIFO/oversized-file rejection, playlist rejection, reference
restrictions, WAV metadata, stale requests, cancellation, player teardown, password
gating and CRC failure. Existing archive tests continue to cover security/extraction.

Optional synthetic video/tagged-audio fixture generation (host FFmpeg is test-only):

```sh
bash scripts/make-preview-fixtures.sh /absolute/path/to/new-fixture-directory
ARCHIVEDESK_TEST_MEDIA=/absolute/path/to/new-fixture-directory swift test
```

No private IPA/APK/music/video files belong in source or release packages. The fixture
ZIP can be opened in the app to verify video seeking, cover/tag layout and cleanup.

### Local verification, 2026-10-20

- Xcode release build succeeded for arm64 and x86_64, including both bundled engines.
- 77 test cases: 74 passed, three optional tests skipped (private mobile packages,
  full Ghidra archive, and >4 GiB ZIP64 fixture). All 14 preview tests ran and passed,
  including synthetic MP4/MP3 metadata, encrypted ZIP/7z media and corrupted ZIP CRC.
- Native UI checked: double-click MP4, play and seek; MP3 cover/tags, audio play,
  timeline adjustment and close; Space opens multilingual text; image preview;
  a playlist renamed `.mp4` gives the unsupported-media message without crashing.
- Packaged ZIP extracted into a clean temporary directory and passed ad-hoc
  `codesign --verify --deep --strict`. This is **not** Developer ID signing or notarization.
- No Intel hardware playback test or macOS 14 runtime test was performed.

Apple API references: [AVPlayerView](https://developer.apple.com/documentation/avkit/avplayerview),
[AVMetadataItem](https://developer.apple.com/documentation/avfoundation/avmetadataitem),
[AVURLAssetReferenceRestrictionsKey](https://developer.apple.com/documentation/avfoundation/avurlassetreferencerestrictionskey).

### Password prompt correction, 2026-10-22

Visible filenames do not imply decrypted contents. Per-entry encryption flags
from the engine listing are now retained. Double-click/Space/internal preview,
Quick Look and single-file copy/export request a password when an encrypted
entry has none. Incorrect-password engine diagnostics request another attempt;
7-Zip progress/backspace prefixes do not prevent classification. Ordinary CRC,
I/O and cancellation failures are not automatically treated as password errors.
An encrypted-data error can still mean corruption rather than a wrong password;
no authentication or repair guarantee is implied.

The password uses a secure text field and the existing bounded stdin pipe,
never process arguments, settings, files or logs. A successful password may be
reused for the current archive session, matching the existing password field;
opening another archive/clearing the password removes it from that session.
Failed attempts remove their staging directory, cancellation closes the pending
internal preview, and only a successful engine exit, integrity result and exact
output size allow a URL to reach the decoder. No executable is launched by
internal text preview.

Verification: synthetic encrypted-text missing/wrong/correct password and
no-plaintext-on-failure checks, per-file listing flags and password diagnostic
classification were added. Full host suite: 80 cases, 71 passed, nine optional
fixture/tool-dependent cases explicitly skipped. All 17 preview cases passed.
Universal arm64/x86_64 Release build succeeded. Native UI with a private real
ZipCrypto ZIP on an external volume verified cancel, wrong-password retry and
correct-password UTF-8 preview of its 3,056-byte text entry. The original archive
was not modified or fully extracted. Test payload and password are not included
in this source tree. The freshly built temporary app initially waited opening
the external file from Recents; selecting that same file through NSOpenPanel
allowed immediate listing and preview. This is not a full external-volume or
TCC lifecycle regression test.
