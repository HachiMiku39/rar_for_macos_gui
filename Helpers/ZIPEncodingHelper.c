// ArchiveDesk's narrow, isolated adapter to macOS libarchive. No ZIP codec lives here.
// Input uses a subset of the existing 7-Zip command shape; output is SLT metadata.
#include "archive.h"
#include "archive_entry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <locale.h>
#include <limits.h>
#include <sys/stat.h>

static int fail(struct archive *a, const char *message) {
    const char *detail = a ? archive_error_string(a) : NULL;
    fprintf(stderr, "%s%s%s\n", message, detail ? ": " : "", detail ? detail : "");
    return 2;
}
static const char *charset(const char *page) {
    if (!strcmp(page, "65001")) return "UTF-8";
    if (!strcmp(page, "437")) return "CP437";
    if (!strcmp(page, "936")) return "GBK";
    if (!strcmp(page, "54936")) return "GB18030";
    if (!strcmp(page, "932")) return "CP932";
    if (!strcmp(page, "950")) return "BIG5";
    if (!strcmp(page, "949")) return "CP949";
    return NULL;
}
static const char *passphrase(struct archive *a, void *context) {
    (void)a; (void)context;
    static char secret[1024]; static int readOnce = 0;
    if (readOnce++) return NULL;
    if (!fgets(secret, sizeof(secret), stdin)) return NULL;
    secret[strcspn(secret, "\r\n")] = 0;
    return secret[0] ? secret : NULL;
}
static int safePath(const char *p) {
    if (!p || !*p || *p == '/' || strlen(p) >= 4096) return 0;
    int depth = 0; const char *part = p;
    for (const char *s = p;; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '\\' || c == ':' || c == '\n' || c == '\r') return 0;
        if (c == '/' || c == 0) {
            size_t n = (size_t)(s - part);
            if (n > 255 || (n == 0 && c != 0) || (n == 1 && *part == '.') || (n == 2 && part[0] == '.' && part[1] == '.') || ++depth > 128) return 0;
            if (!c) break;
            part = s + 1;
        }
    }
    return 1;
}
static int selected(const char *path, int count, char **names) {
    if (count == 0) return 1;
    for (int i = 0; i < count; ++i) {
        size_t n = strlen(names[i]);
        while (n && names[i][n - 1] == '/') --n;
        if (!strncmp(path, names[i], n) && (path[n] == 0 || path[n] == '/')) return 1;
    }
    return 0;
}
int main(int argc, char **argv) {
    setlocale(LC_ALL, "en_US.UTF-8");
    if (argc < 5 || (strcmp(argv[1], "l") && strcmp(argv[1], "x"))) return fail(NULL, "Unsupported ZIP adapter command");
    const int listing = !strcmp(argv[1], "l");
    const char *encoding = NULL, *destination = NULL; int index = 2, toStdout = 0;
    for (; index < argc && strcmp(argv[index], "--"); ++index) {
        const char *p = argv[index];
        if (!strncmp(p, "-mcp=", 5)) encoding = charset(p + 5);
        else if (!strncmp(p, "-o", 2)) destination = p + 2;
        else if (!strcmp(p, "-so")) toStdout = 1;
        else if (strcmp(p, "-slt") && strcmp(p, "-sccUTF-8") && strcmp(p, "-aos") && strcmp(p, "-bsp2") && strcmp(p, "-spd") && strncmp(p, "-mmt=", 5)) return fail(NULL, "Unsupported ZIP adapter option");
    }
    if (!encoding || ++index >= argc) return fail(NULL, "Missing ZIP encoding or archive");
    const char *source = argv[index++]; int selectionCount = argc - index;
    if (!listing && ((toStdout && selectionCount != 1) || (!toStdout && !destination))) return fail(NULL, "Invalid ZIP export target");
    for (int i = index; i < argc; ++i) if (!safePath(argv[i])) return fail(NULL, "Unsafe selected path");
    struct archive *a = archive_read_new(), *writer = NULL;
    if (!a) return fail(NULL, "Cannot initialize ZIP reader");
    archive_read_support_format_zip_seekable(a);
    archive_read_set_passphrase_callback(a, NULL, passphrase);
    if (archive_read_set_format_option(a, "zip", "hdrcharset", encoding) != ARCHIVE_OK || archive_read_open_filename(a, source, 65536) != ARCHIVE_OK) return fail(a, "Cannot open ZIP with this filename encoding");
    if (!listing && !toStdout) {
        struct stat st;
        if (lstat(destination, &st) || !S_ISDIR(st.st_mode) || chdir(destination)) return fail(NULL, "ZIP output must be a private directory");
        writer = archive_write_disk_new();
        if (!writer) return fail(NULL, "Cannot initialize ZIP writer");
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS | ARCHIVE_EXTRACT_NO_OVERWRITE);
    }
    struct archive_entry *entry; unsigned long count = 0, exported = 0;
    uint64_t total = 0; char buffer[65536]; int status;
    if (listing) printf("Type = zip\n\n");
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        const char *path = archive_entry_pathname_utf8(entry);
        const mode_t type = archive_entry_filetype(entry);
        const int directory = type == AE_IFDIR;
        const int link = archive_entry_symlink(entry) != NULL || archive_entry_hardlink(entry) != NULL || (type != AE_IFREG && !directory);
        const int64_t size = archive_entry_size(entry);
        if (!safePath(path) || size < 0 || ++count > 1000000 || total > INT64_MAX - (uint64_t)size) return fail(NULL, "Unsafe ZIP path, size or entry count");
        total += (uint64_t)size;
        if (listing) {
            printf("Path = %s\nSize = %lld\nFolder = %c\nSymbolic Link = %s\nEncrypted = %c\n\n", path, (long long)size, directory ? '+' : '-', link ? "refused" : "", archive_entry_is_encrypted(entry) ? '+' : '-');
            continue;
        }
        if (link) return fail(NULL, "ZIP links and special files are not exported");
        if (!selected(path, selectionCount, argv + index)) continue;
        if (toStdout && (directory || strcmp(path, argv[index]) || exported != 0)) return fail(NULL, "ZIP stream export requires one exact regular file");
        ++exported;
        if (writer) {
            archive_entry_set_pathname(entry, path);
            archive_entry_set_perm(entry, archive_entry_perm(entry) & 0777);
            if (archive_write_header(writer, entry) != ARCHIVE_OK) return fail(writer, "Cannot create ZIP output entry");
        }
        int64_t done = 0; la_ssize_t n;
        while ((n = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
            if (done > size - n) return fail(NULL, "ZIP entry exceeds declared size");
            if (toStdout) { if (fwrite(buffer, 1, (size_t)n, stdout) != (size_t)n) return fail(NULL, "Cannot write ZIP stream"); }
            else if (archive_write_data(writer, buffer, (size_t)n) != n) return fail(writer, "Cannot write ZIP file");
            done += n;
        }
        if (n < 0 || (!directory && done != size)) return fail(a, "ZIP integrity or size check failed");
        if (writer && archive_write_finish_entry(writer) != ARCHIVE_OK) return fail(writer, "Cannot finish ZIP file");
    }
    if (status != ARCHIVE_EOF) return fail(a, "ZIP metadata or filename conversion failed");
    if (!listing && selectionCount && exported == 0) return fail(NULL, "Selected ZIP entry was not found");
    if (archive_read_close(a) != ARCHIVE_OK) return fail(a, "Cannot finish ZIP read");
    if (writer && archive_write_close(writer) != ARCHIVE_OK) return fail(writer, "Cannot finish ZIP output");
    if (fflush(stdout)) return fail(NULL, "Cannot flush ZIP output");
    archive_read_free(a); if (writer) archive_write_free(writer);
    return 0;
}
