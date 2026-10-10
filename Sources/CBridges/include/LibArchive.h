//
//  LibArchive.h
//  Tutto
//
//  Declarations for the libarchive that ships with macOS (/usr/lib/libarchive.2.dylib,
//  libarchive 3.7.4 on macOS 26). The SDK includes the library stub but not its
//  headers, so the small, long-stable part of the C API Tutto uses is declared here.
//  libarchive is BSD-licensed; see https://www.libarchive.org.
//

#ifndef LibArchive_h
#define LibArchive_h

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_RETRY (-10)
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL (-30)

#define ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED (-2)
#define ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW (-1)

#define ARCHIVE_EXTRACT_OWNER (0x0001)
#define ARCHIVE_EXTRACT_PERM (0x0002)
#define ARCHIVE_EXTRACT_TIME (0x0004)
#define ARCHIVE_EXTRACT_NO_OVERWRITE (0x0008)
#define ARCHIVE_EXTRACT_UNLINK (0x0010)
#define ARCHIVE_EXTRACT_ACL (0x0020)
#define ARCHIVE_EXTRACT_FFLAGS (0x0040)
#define ARCHIVE_EXTRACT_XATTR (0x0080)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)
#define ARCHIVE_EXTRACT_NO_AUTODIR (0x0400)
#define ARCHIVE_EXTRACT_SPARSE (0x1000)
#define ARCHIVE_EXTRACT_MAC_METADATA (0x2000)
#define ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS (0x10000)

#define AE_IFMT ((mode_t)0170000)
#define AE_IFREG ((mode_t)0100000)
#define AE_IFLNK ((mode_t)0120000)
#define AE_IFDIR ((mode_t)0040000)

// Reading
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_set_options(struct archive *, const char *options);
int archive_read_set_format_option(struct archive *, const char *module, const char *option, const char *value);
int archive_read_add_passphrase(struct archive *, const char *passphrase);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_open_filenames(struct archive *, const char **filenames, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int archive_read_data_block(struct archive *, const void **buffer, size_t *size, int64_t *offset);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// Status
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int index);
int64_t archive_filter_bytes(struct archive *, int index);
int archive_file_count(struct archive *);

// Entries
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
struct archive_entry *archive_entry_clear(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
void archive_entry_copy_pathname(struct archive_entry *, const char *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_copy_hardlink(struct archive_entry *, const char *);
void archive_entry_set_hardlink_utf8(struct archive_entry *, const char *);
void archive_entry_copy_symlink(struct archive_entry *, const char *);
void archive_entry_set_symlink_utf8(struct archive_entry *, const char *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int type);
void archive_entry_set_perm(struct archive_entry *, mode_t perm);
void archive_entry_set_size(struct archive_entry *, int64_t size);
void archive_entry_set_mtime(struct archive_entry *, time_t seconds, long nanoseconds);
void archive_entry_copy_stat(struct archive_entry *, const struct stat *);

// Writing to disk
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *buffer, size_t size);
ssize_t archive_write_data_block(struct archive *, const void *buffer, size_t size, int64_t offset);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// Writing archives
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_set_options(struct archive *, const char *options);
int archive_write_open_filename(struct archive *, const char *filename);

// ---------------------------------------------------------------------------
// Added for TuttoKit/Archives. Every symbol below is exported by the macOS
// libarchive 3.7.4 (see the SDK's libarchive.2.tbd).

const char *archive_version_string(void);
const char *archive_version_details(void);

// Formats (archive_format() & ARCHIVE_FORMAT_BASE_MASK)
#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_CPIO 0x10000
#define ARCHIVE_FORMAT_SHAR 0x20000
#define ARCHIVE_FORMAT_TAR 0x30000
#define ARCHIVE_FORMAT_ISO9660 0x40000
#define ARCHIVE_FORMAT_ZIP 0x50000
#define ARCHIVE_FORMAT_EMPTY 0x60000
#define ARCHIVE_FORMAT_AR 0x70000
#define ARCHIVE_FORMAT_MTREE 0x80000
#define ARCHIVE_FORMAT_RAW 0x90000
#define ARCHIVE_FORMAT_XAR 0xA0000
#define ARCHIVE_FORMAT_LHA 0xB0000
#define ARCHIVE_FORMAT_CAB 0xC0000
#define ARCHIVE_FORMAT_RAR 0xD0000
#define ARCHIVE_FORMAT_7ZIP 0xE0000
#define ARCHIVE_FORMAT_WARC 0xF0000
#define ARCHIVE_FORMAT_RAR_V5 0x100000

// Individual read filters (built in; zstd/lz4/lzop/lrzip/grzip are external-program only on macOS)
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_compress(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_lzip(struct archive *);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_filter_uu(struct archive *);
int archive_read_support_filter_rpm(struct archive *);

// Individual read formats (format_all also enables mtree, which can reference local files)
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_support_format_cab(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_lha(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_warc(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_zip(struct archive *);

// Entry details
int archive_entry_is_data_encrypted(struct archive_entry *);
int archive_entry_is_metadata_encrypted(struct archive_entry *);

#endif /* LibArchive_h */
