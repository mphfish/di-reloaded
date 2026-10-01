#include "CBulkAttr.h"

#include <sys/attr.h>
#include <sys/vnode.h>
#include <string.h>
#include <unistd.h>

// Attributes are packed in this order: length, returned set, ATTR_CMN_ERROR,
// then the remaining common attributes in bit order, then file attributes in
// bit order. Only attributes flagged in `returned` are present. Values are
// 4-byte aligned, so 8-byte fields are read with memcpy.

#define DIB_ENTRY_MIN_SIZE 32

size_t dib_max_entries(size_t bufsize) {
    return bufsize / DIB_ENTRY_MIN_SIZE + 1;
}

static inline uint32_t read_u32(const char **p) {
    uint32_t v;
    memcpy(&v, *p, sizeof v);
    *p += sizeof v;
    return v;
}

static inline uint64_t read_u64(const char **p) {
    uint64_t v;
    memcpy(&v, *p, sizeof v);
    *p += sizeof v;
    return v;
}

int dib_read_entries(int dirfd, void *buf, size_t bufsize, dib_entry *out) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR |
                    ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

    int count = getattrlistbulk(dirfd, &al, buf, bufsize, 0);
    if (count <= 0) return count;

    const char *entry = (const char *)buf;
    for (int i = 0; i < count; i++) {
        dib_entry *e = &out[i];
        memset(e, 0, sizeof *e);
        e->link_count = 1;

        const char *p = entry;
        uint32_t length = read_u32(&p);
        attribute_set_t returned;
        memcpy(&returned, p, sizeof returned);
        p += sizeof returned;

        if (returned.commonattr & ATTR_CMN_ERROR) e->error = read_u32(&p);

        if (returned.commonattr & ATTR_CMN_NAME) {
            attrreference_t ref;
            memcpy(&ref, p, sizeof ref);
            e->name = p + ref.attr_dataoffset;
            e->name_len = ref.attr_length > 0 ? ref.attr_length - 1 : 0;
            p += sizeof ref;
        }
        if (returned.commonattr & ATTR_CMN_DEVID) e->dev = (int32_t)read_u32(&p);
        if (returned.commonattr & ATTR_CMN_OBJTYPE) {
            switch (read_u32(&p)) {
                case VREG: e->type = DIB_TYPE_FILE; break;
                case VDIR: e->type = DIB_TYPE_DIR; break;
                case VLNK: e->type = DIB_TYPE_SYMLINK; break;
                default:   e->type = DIB_TYPE_OTHER; break;
            }
        } else {
            e->type = DIB_TYPE_OTHER;
        }
        if (returned.commonattr & ATTR_CMN_FILEID) e->file_id = read_u64(&p);
        if (returned.fileattr & ATTR_FILE_LINKCOUNT) e->link_count = read_u32(&p);
        if (returned.fileattr & ATTR_FILE_TOTALSIZE) e->logical_size = read_u64(&p);
        if (returned.fileattr & ATTR_FILE_ALLOCSIZE) e->alloc_size = read_u64(&p);

        entry += length;
    }
    return count;
}
