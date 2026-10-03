# Bundled third-party component

ArchiveDesk includes the unmodified official 7-Zip 26.03 macOS Universal `7zz` executable (Igor Pavlov, 1999–2026).

7-Zip is licensed primarily under GNU LGPL 2.1 or later, with BSD and unRAR restrictions for specified portions. See 7-Zip-License.txt, 7-Zip-License.html, LGPL-2.1.txt and the accompanying original source archive `7z2603-src.tar.xz`. No RAR encoder or registration key is included.

Website and source: https://www.7-zip.org/

Exact binary distribution: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz

Corresponding source distribution: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz

SHA-256 of bundled 7zz: 74b0910e50ea44d9760a57fada2192cfd530ba8bffbe7b47c412a464b796cabf

SHA-256 of source archive: 9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4

ArchiveDesk invokes this independent executable through posix_spawn; it does not link or modify 7-Zip. Users can substitute a compatible rebuilt 7zz using Settings. Source build instructions are in the source archive (DOC/readme.txt and the CPP/7zip/Bundles/Alone2 makefiles). RAR creation and recovery operations use a separately acquired RARLAB executable under its own license.

UUE decoding uses macOS-provided /usr/bin/uudecode and /usr/bin/tar. These system tools are not redistributed.

1.0 beta adds the project's own ArchiveDeskZIP executable for legacy ZIP filename encodings. It dynamically links macOS system libarchive, which is not redistributed. See Libarchive-Notice.txt for the vendored public-header attribution and BSD license. The adapter and both supported architectures are rebuilt from Helpers/ZIPEncodingHelper.c in the Xcode build phase; no Homebrew library is required at runtime. TAR creation uses system bsdtar.
