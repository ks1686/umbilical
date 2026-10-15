#ifndef UMB_PROC_H
#define UMB_PROC_H

#include <stddef.h>
#include <stdint.h>

/* Child pid count, or a negative value when the platform cannot list them.
   buffersize is the byte size of buffer. */
int umb_list_child_pids(int32_t parent, void *buffer, int buffersize);

#endif
