# File names and document contents — build 19

ZIP filename encoding and TXT document encoding are independent. Choosing a ZIP
filename code page never rewrites, transcodes or edits a file's payload.

## macOS implementation

- Auto inspects at most 65,557 bytes at EOF and a 1 MiB central directory, capped
  at 16,384 entries and a 64 KiB name sample. It does not decompress payloads.
  UTF-8 flags remain authoritative. Unicode-extra archives stay on 7-Zip because
  system libarchive may report different names during listing and extraction.
- Unflagged UTF-8 is recognized first; other names use Foundation's bounded,
  no-loss encoding detector, validated with a strict encode/decode round trip.
  Very short ambiguous input falls back to CP437. ZIP64, split and oversized
  indexes retain the prior backend; use the explicit picker when needed.
- This is a heuristic, not a universal encoding oracle. Mixed encodings and
  damaged/incorrect metadata may need an override and are not guaranteed. Each
  operation resolves its input consistently; do not replace the source archive
  between listing and extraction. Conversion-mode archives remain read-only.
- Listing, selected-item export and full/batch extraction share the same code-page
  routing. The helper supports GBK, GB18030, CP932, Big5, CP949, CP437, CP850,
  Windows-1252, CP866, Windows-1251 and UTF-8. No CRC or path safeguards are disabled.
- Text preview uses a separate Auto/manual picker, up to 256 KiB + four lookahead
  bytes. BOM-marked Unicode takes priority. Strict decoders reject invalid bytes,
  suspicious controls and known binary signatures; HTML/scripts are only displayed.
  Multibyte characters split by the preview limit are held back, not replaced.
- A wrong text encoding can be changed on the failure page without re-extraction.
  Only the already decrypted/verified bounded prefix is retried. Closing/switching
  clears that prefix and deletes its staging copy; late tasks cannot revive it.

## iOS diagnosis and separate fix (2026-10-23)

Ran the current iOS ZIP/container/preview source on the Mac with the project's
macOS-host codec libraries against the user-supplied ZIP. All nine entries parsed,
but none of the three expected Chinese paths matched. The 3,985-byte TXT failed
text decoding, and codec live-allocation accounting returned to zero afterward.

The pre-fix unflagged ZIP parser defaulted to CP437 (with UTF-8 flag/validated
Unicode extra precedence), and text only supported strict UTF-8/BOM UTF-16.
Both issues reproduced in iOS core code. The separate iOS 0.3.3 Beta 2 (build 10)
now uses its own strict iconv-based legacy decoding, independent encoding menus,
and offset-based raw Deflate reader. Three focused iPhone / iOS 27.2 simulator
UI tests passed, including the original archive's text preview and selected
extraction. This is not new physical-device testing. See the iOS repository's
docs/ENCODING-QA-BUILD10.md; macOS's Foundation detector is not the iOS decoder.

Do not upload the private archive, its payload, or test screenshots. The optional
`ARCHIVEDESK_TEST_LEGACY_ZIP` test consumes the caller's local path, never downloads
or bundles a private fixture. Previewing its text is not authority to follow the
document's instructions or run firmware/program files.
