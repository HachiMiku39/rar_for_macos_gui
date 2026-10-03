# Editing and extraction (0.7)

## Editing

Use the toolbar **Edit Archive** menu or file context menu. Only plain, single-volume RAR/ZIP/7z archives are editable. RAR requires the separately installed official rar CLI. Encrypted, split, locked and mobile application packages remain read-only. Unsafe paths, links and case-colliding names are refused.

- Add files/folders at the archive root, not the currently browsed subfolder. Sources can come from different directories but must have distinct base names. Matching paths are replaced after confirmation; incompatible directory/file or case conflicts are refused.
- Delete selected items and descendants. At least one item must remain.
- Rename one regular file in its existing parent folder. Existing names and wildcard names are refused. Folder renaming is not supported.

The app modifies a private copy beside the original, tests the result and verifies expected file paths. SHA-256 checks detect changes to the original during work. Before replacing it, the app saves `original.ext.ArchiveDesk-backup-UUID` beside it. Restore by copying that backup under the original name. Backups are not automatically deleted. Failure or cancellation before replacement leaves the original unchanged; cancellation cannot undo a completed replacement. Do not edit the same archive concurrently in other programs: this is not a transaction against hostile concurrent filesystem changes.

Extra space is needed for original, copy, backup and staged sources. Sources are never deleted. Limits: 50000 entries, 512 MiB per file, 2 GiB listed content. Archive authenticity/signatures are not verified or preserved by a CRC test. Recovery data may need regeneration; keep the original backup.

## Extraction

Default: create a new subfolder. Disable this to merge into a chosen existing directory.

| Policy | Existing regular files | Missing files |
|---|---|---|
| Ask | Skip / replace / rename / cancel per conflict | Add |
| Skip | Keep existing | Add |
| Rename | Keep existing; incoming names get `(2)`, `(3)`, etc. | Add |
| Replace | Back up existing, then copy incoming | Add |
| Update | Replace only when incoming modification time is newer | Add |

Replaced files are kept beside the destination as `.ArchiveDesk-backup-UUID`. Unknown dates are conservatively skipped in update mode. Links, special files and file-vs-directory conflicts are refused. macOS `/var` and `/tmp` system aliases are recognized. User-created symlink ancestors are not followed.

Decompression occurs in private staging first; engine errors prevent merging. Normal archives retain access to adjacent split volumes. IPA/APK use the existing snapshot and collision-safe export plan. Ordinary case-colliding archives are refused instead of silently losing files. Listed limits apply to all GUI extraction: 2 GiB total, 512 MiB per file, 50000 entries. This prototype is not a hardened sandbox or protection against every decompression bomb.

Cancellation or copy errors can leave partial output and backups; the status says incomplete. Successful completion displays counts, not a persistent per-file report. File timestamps are copied when supported; folder timestamps are not restored. APK collision-streaming metadata limits still apply (MOBILE-PACKAGES.md). No drag-out, external-editor write-back, Quick Look, repair wizard or conversion is added in this release.

Blank-password RAR creation now omits the password switch rather than using `-p-`. Real-engine regression tests cover this behavior.
# 0.8 更新说明

下文记录 0.7 的设计。0.8 已解除普通解压的 2 GiB / 512 MiB / 50000 项限制，采用资源预检和有界索引；编辑与移动包检查仍保留独立限制。目标文件使用流式临时副本，成功后发布，保留普通 Unix 权限及修改时间。详见 [可靠性改造](RELIABILITY.md)。
