#ifndef UMB_XATTR_H
#define UMB_XATTR_H

#include <stddef.h>
#include <sys/types.h>

int umb_setxattr(const char *path, const char *name, const void *value, size_t size);
ssize_t umb_getxattr(const char *path, const char *name, void *value, size_t size);

#endif
