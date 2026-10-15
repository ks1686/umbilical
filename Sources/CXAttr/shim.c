#include "umb_xattr.h"

#if defined(__APPLE__)
#include <sys/xattr.h>
#else
#include <sys/xattr.h>
#endif

int umb_setxattr(const char *path, const char *name, const void *value, size_t size) {
#if defined(__APPLE__)
    return setxattr(path, name, value, size, 0, 0);
#else
    return setxattr(path, name, value, size, 0);
#endif
}

ssize_t umb_getxattr(const char *path, const char *name, void *value, size_t size) {
#if defined(__APPLE__)
    return getxattr(path, name, value, size, 0, 0);
#else
    return getxattr(path, name, value, size);
#endif
}
