#ifndef CBULKATTR_H
#define CBULKATTR_H

#include <stdint.h>
#include <stddef.h>

/// Simplified object type for a directory entry.
typedef enum {
    DIB_TYPE_FILE = 0,
    DIB_TYPE_DIR = 1,
    DIB_TYPE_SYMLINK = 2,
    DIB_TYPE_OTHER = 3,
} dib_type;

/// One parsed directory entry. `name` points into the caller's buffer and is
/// only valid until the next call to `dib_read_entries` with that buffer.
typedef struct {
    const char *name;
    uint32_t name_len;      // bytes, excluding the NUL terminator
    uint32_t type;          // dib_type
    uint32_t error;         // non-zero if the kernel couldn't read this entry's attributes
    uint32_t link_count;    // files only; 1 otherwise
    int32_t  dev;
    uint32_t _pad;
    uint64_t file_id;
    uint64_t logical_size;  // files only
    uint64_t alloc_size;    // files only
} dib_entry;

/// Reads the next batch of entries from an open directory with getattrlistbulk(2).
/// Returns the number of entries written to `out`, 0 at end of directory, or -1 with errno set.
/// `out` must hold at least `dib_max_entries(bufsize)` entries.
int dib_read_entries(int dirfd, void *buf, size_t bufsize, dib_entry *out);

/// Upper bound on how many entries one call can return for a given buffer size.
size_t dib_max_entries(size_t bufsize);

#endif
