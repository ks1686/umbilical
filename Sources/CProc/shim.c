#include "umb_proc.h"

#if defined(__APPLE__)
#include <libproc.h>

int umb_list_child_pids(int32_t parent, void *buffer, int buffersize) {
    return proc_listchildpids((pid_t)parent, buffer, buffersize);
}
#else
int umb_list_child_pids(int32_t parent, void *buffer, int buffersize) {
    (void)parent;
    (void)buffer;
    (void)buffersize;
    return -1;
}
#endif
