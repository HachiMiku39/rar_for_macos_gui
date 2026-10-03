#!/bin/sh
set -eu
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output_file="${1:-$project_dir/Resources/Tools/ArchiveDeskZIP}"
# Link only the macOS system library, never a Homebrew runtime dependency.
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
  -I "$project_dir/Helpers/include" "$project_dir/Helpers/ZIPEncodingHelper.c" \
  -larchive -o "$output_file"
