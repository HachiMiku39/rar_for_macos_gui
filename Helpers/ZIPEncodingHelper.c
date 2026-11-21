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
#include <errno.h>
#include <fcntl.h>

static int fail(struct archive *a, const char *message) {
    const char *detail = a ? archive_error_string(a) : NULL;
    if (detail && (strstr(detail, "Incorrect passphrase") || strstr(detail, "incorrect passphrase") || strstr(detail, "Incorrect password"))) {
        fprintf(stderr, "ERROR: Wrong password\n");
        return 2;
    }
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
    if (!strcmp(page, "850")) return "CP850";
    if (!strcmp(page, "1252")) return "WINDOWS-1252";
    if (!strcmp(page, "866")) return "CP866";
    if (!strcmp(page, "1251")) return "WINDOWS-1251";
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

struct path_list { char **names; size_t count, capacity; int supplied; };

static int compare_names(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}
static int read_list(struct path_list *list, const char *file) {
    if (*file != '/' || list->supplied) return -1;
    list->supplied = 1;
    int fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode)) return -1;
    FILE *input = fdopen(fd, "r");
    if (!input) return -1;
    // Each application-generated line is one quoted literal followed by LF.
    // Internal spaces, quotes, wildcard characters and leading @ are filenames.
    char line[4100];
    while (fgets(line, sizeof(line), input)) {
        size_t n = strlen(line);
        if (n < 4 || line[0] != '"' || line[n - 2] != '"' || line[n - 1] != '\n') return -1;
        line[n - 2] = 0;
        char *name = line + 1;
        if (!safePath(name) || list->count >= 1000000) return -1;
        size_t end = strlen(name);
        if (name[end - 1] == '/') name[end - 1] = 0;
        if (list->count == list->capacity) {
            size_t capacity = list->capacity ? list->capacity * 2 : 64;
            char **names = realloc(list->names, capacity * sizeof(*names));
            if (!names) return -1;
            list->names = names; list->capacity = capacity;
        }
        char *copy = strdup(name);
        if (!copy) return -1;
        list->names[list->count++] = copy;
    }
    if (ferror(input) || fclose(input)) return -1;
    if (list->count) qsort(list->names, list->count, sizeof(*list->names), compare_names);
    return 0;
}
static int listed(const struct path_list *list, const char *path) {
    if (!list->count) return 0;
    char prefix[4096];
    strcpy(prefix, path);  // caller checked safePath()
    const char *key = prefix;
    for (char *s = prefix;; ++s) {
        if (*s != '/' && *s != 0) continue;
        char saved = *s; *s = 0;
        if (bsearch(&key, list->names, list->count, sizeof(*list->names), compare_names)) return 1;
        if (!saved) return 0;
        *s = saved;
    }
}

// Every lookup below an opened parent uses a single component. The caller
// receives an owned descriptor and a leaf inside its mutable copy of the path.
static int output_parent(int root, char **leaf) {
    int parent = dup(root);
    char *slash;
    while (parent >= 0 && (slash = strchr(*leaf, '/')) != NULL) {
        *slash = 0;
        int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
        int child = openat(parent, *leaf, flags);
        if (child < 0 && errno == ENOENT && (mkdirat(parent, *leaf, 0777) == 0 || errno == EEXIST))
            child = openat(parent, *leaf, flags);
        close(parent); parent = child; *leaf = slash + 1;
    }
    return parent;
}
static int write_bytes(int fd, const char *data, size_t length) {
    while (length) {
        ssize_t count = write(fd, data, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        data += count; length -= (size_t)count;
    }
    return 0;
}
static int finish_file(int fd, int parent, const char *leaf, struct archive_entry *entry) {
    struct stat opened, named;
    if (fstat(fd, &opened) || !S_ISREG(opened.st_mode) || opened.st_nlink != 1 ||
        fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) ||
        opened.st_dev != named.st_dev || opened.st_ino != named.st_ino) return -1;
    if (fchmod(fd, archive_entry_perm(entry) & 0777)) return -1;
    if (archive_entry_atime_is_set(entry) || archive_entry_mtime_is_set(entry)) {
        struct timespec times[] = {opened.st_atimespec, opened.st_mtimespec};
        if (archive_entry_atime_is_set(entry)) times[0] = (struct timespec){archive_entry_atime(entry), archive_entry_atime_nsec(entry)};
        if (archive_entry_mtime_is_set(entry)) times[1] = (struct timespec){archive_entry_mtime(entry), archive_entry_mtime_nsec(entry)};
        if (futimens(fd, times)) return -1;
    }
    return close(fd);
}
int main(int argc, char **argv) {
    setlocale(LC_ALL, "en_US.UTF-8");
    if (argc < 5 || (strcmp(argv[1], "l") && strcmp(argv[1], "x"))) return fail(NULL, "Unsupported ZIP adapter command");
    const int listing = !strcmp(argv[1], "l");
    const char *encoding = NULL, *destination = NULL; int index = 2, toStdout = 0;
    struct path_list included = {0}, excluded = {0};
    for (; index < argc && strcmp(argv[index], "--"); ++index) {
        const char *p = argv[index];
        if (!strncmp(p, "-mcp=", 5)) encoding = charset(p + 5);
        else if (!strncmp(p, "-o", 2)) destination = p + 2;
        else if (!strcmp(p, "-so")) toStdout = 1;
        else if (!strncmp(p, "-i@", 3) || !strncmp(p, "-x@", 3)) {
            if (read_list(p[1] == 'i' ? &included : &excluded, p + 3)) return fail(NULL, "Invalid ZIP path list");
        }
        else if (strcmp(p, "-slt") && strcmp(p, "-sccUTF-8") && strcmp(p, "-scsUTF-8") && strcmp(p, "-aos") && strcmp(p, "-bsp2") && strcmp(p, "-spd") && strncmp(p, "-mmt=", 5)) return fail(NULL, "Unsupported ZIP adapter option");
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
    int root = -1;
    if (!listing && !toStdout) {
        root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (root < 0 || fchdir(root)) return fail(NULL, "ZIP output directory unavailable");
        writer = archive_write_disk_new();
        if (!writer) return fail(NULL, "Cannot initialize ZIP writer");
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS | ARCHIVE_EXTRACT_NO_OVERWRITE);
    }
    struct archive_entry *entry; unsigned long count = 0, exported = 0;
    uint64_t total = 0, writtenFiles = 0, writtenBytes = 0; char buffer[65536]; int status;
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
        if (!selected(path, selectionCount, argv + index) || (included.supplied && !listed(&included, path))) continue;
        if (toStdout && (directory || strcmp(path, argv[index]) || exported != 0)) return fail(NULL, "ZIP stream export requires one exact regular file");
        ++exported;
        if (listed(&excluded, path)) continue;
        int parent = -1, output = -1;
        char relative[4096], *leaf = relative;
        if (writer) {
            strcpy(relative, path);
            size_t length = strlen(relative);
            if (directory && relative[length - 1] == '/') relative[length - 1] = 0;
            parent = output_parent(root, &leaf);
            if (parent < 0 || !*leaf) return fail(NULL, "Cannot open ZIP output parent");
            if (!directory) output = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (!directory && output < 0 && errno != EEXIST) return fail(NULL, "Cannot create ZIP output file");
            struct stat existing;
            if (output < 0 && fstatat(parent, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
                if (!((directory && S_ISDIR(existing.st_mode)) ||
                      (!directory && S_ISREG(existing.st_mode) && existing.st_nlink == 1)))
                    return fail(NULL, "ZIP output conflicts with a link or different entry type");
                if (archive_read_data_skip(a) != ARCHIVE_OK) return fail(a, "Cannot skip existing ZIP entry");
                close(parent);
                continue;
            }
            if (output < 0) {
                if (!directory || errno != ENOENT) return fail(NULL, "Cannot inspect existing ZIP output");
                archive_entry_set_pathname(entry, path);
                archive_entry_set_perm(entry, archive_entry_perm(entry) & 0777);
                if (archive_write_header(writer, entry) != ARCHIVE_OK) return fail(writer, "Cannot create ZIP directory");
            }
        }
        int64_t done = 0; la_ssize_t n;
        while ((n = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
            if (done > size - n) return fail(NULL, "ZIP entry exceeds declared size");
            if (toStdout) { if (fwrite(buffer, 1, (size_t)n, stdout) != (size_t)n) return fail(NULL, "Cannot write ZIP stream"); }
            else if (output < 0 || write_bytes(output, buffer, (size_t)n)) return fail(NULL, "Cannot write ZIP file");
            done += n;
        }
        if (n < 0 || (!directory && done != size)) return fail(a, "ZIP integrity or size check failed");
        if (output >= 0) {
            if (finish_file(output, parent, leaf, entry)) return fail(NULL, "Cannot finish ZIP output file");
            ++writtenFiles; writtenBytes += (uint64_t)done;
        } else if (writer && archive_write_finish_entry(writer) != ARCHIVE_OK) return fail(writer, "Cannot finish ZIP directory");
        if (parent >= 0) close(parent);
    }
    if (status != ARCHIVE_EOF) return fail(a, "ZIP metadata or filename conversion failed");
    if (!listing && (selectionCount || included.supplied) && exported == 0) return fail(NULL, "Selected ZIP entry was not found");
    if (archive_read_close(a) != ARCHIVE_OK) return fail(a, "Cannot finish ZIP read");
    if (writer && archive_write_close(writer) != ARCHIVE_OK) return fail(writer, "Cannot finish ZIP output");
    if (writer) printf("Everything is Ok\n\nFiles: %llu\nSize: %llu\n", (unsigned long long)writtenFiles, (unsigned long long)writtenBytes);
    if (fflush(stdout)) return fail(NULL, "Cannot flush ZIP output");
    archive_read_free(a); if (writer) archive_write_free(writer);
    if (root >= 0) close(root);
    for (size_t i = 0; i < included.count; ++i) free(included.names[i]);
    for (size_t i = 0; i < excluded.count; ++i) free(excluded.names[i]);
    free(included.names); free(excluded.names);
    return 0;
}
