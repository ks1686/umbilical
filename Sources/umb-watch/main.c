// SPDX-License-Identifier: GPL-3.0-or-later
// Reap the aria2 child when the parent exits.
// macOS has no PR_SET_PDEATHSIG, so the parent is watched with kqueue.
// Linux sets PR_SET_PDEATHSIG and also watches the parent with pidfd.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/event.h>
#else
#include <poll.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

static volatile sig_atomic_t child_pgid = 0;

/* Foundation.Process starts the child with most signals blocked. A blocked
   SIGTERM makes terminate() a no-op, and the aria2 child would inherit that
   mask so PR_SET_PDEATHSIG could not be delivered. */
static void unblock_signals(void) {
    sigset_t set;
    sigemptyset(&set);
    sigprocmask(SIG_SETMASK, &set, NULL);
}

static void on_term(int sig) {
    pid_t pg = (pid_t)child_pgid;
    if (pg > 0) {
        kill(-pg, SIGTERM);
    }
    _exit(128 + sig);
}

static void kill_group(pid_t pg) {
    int status = 0;
    if (pg <= 0) {
        return;
    }
    kill(-pg, SIGTERM);
    for (int i = 0; i < 50; i++) {
        if (waitpid(pg, &status, WNOHANG) == pg) {
            return;
        }
        if (kill(-pg, 0) != 0) {
            waitpid(pg, &status, WNOHANG);
            return;
        }
        usleep(100000);
    }
    kill(-pg, SIGKILL);
    waitpid(pg, &status, 0);
}

static int child_status(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}

static pid_t spawn_child(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(1);
    }
    if (pid == 0) {
        unblock_signals();
#if defined(__linux__)
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) {
            perror("prctl");
            _exit(1);
        }
        if (getppid() == 1) {
            _exit(1);
        }
#endif
        if (setpgid(0, 0) != 0) {
            perror("setpgid");
            _exit(1);
        }
        execv(argv[0], argv);
        perror("exec");
        _exit(127);
    }
    if (setpgid(pid, pid) != 0 && errno != EACCES && errno != ESRCH) {
        perror("setpgid");
    }
    child_pgid = (sig_atomic_t)pid;
    return pid;
}

#if defined(__APPLE__)
static int watch(pid_t parent, pid_t child) {
    if (kill(parent, 0) != 0) {
        kill_group(child);
        return 0;
    }
    int kq = kqueue();
    if (kq < 0) {
        perror("kqueue");
        return 1;
    }
    struct kevent changes[2];
    EV_SET(&changes[0], parent, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], child, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
    struct kevent event;
    int rc = kevent(kq, changes, 2, &event, 1, NULL);
    close(kq);
    if (rc < 0) {
        perror("kevent");
        return 1;
    }
    if ((pid_t)event.ident == parent) {
        kill_group(child);
        return 0;
    }
    int status = 0;
    if (waitpid(child, &status, 0) < 0) {
        return 1;
    }
    return child_status(status);
}
#else
#ifndef __NR_pidfd_open
#if defined(__x86_64__)
#define __NR_pidfd_open 434
#elif defined(__aarch64__)
#define __NR_pidfd_open 434
#endif
#endif

static int pidfd_open_raw(pid_t pid) {
#ifdef __NR_pidfd_open
    return (int)syscall(__NR_pidfd_open, pid, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}

static int watch_poll(pid_t parent, pid_t child) {
    for (;;) {
        int status = 0;
        pid_t got = waitpid(child, &status, WNOHANG);
        if (got == child) {
            return child_status(status);
        }
        if (kill(parent, 0) != 0) {
            kill_group(child);
            return 0;
        }
        usleep(200000);
    }
}

static int watch(pid_t parent, pid_t child) {
    if (kill(parent, 0) != 0) {
        kill_group(child);
        return 0;
    }
    int parent_fd = pidfd_open_raw(parent);
    int child_fd = pidfd_open_raw(child);
    if (parent_fd < 0 || child_fd < 0) {
        if (parent_fd >= 0) {
            close(parent_fd);
        }
        if (child_fd >= 0) {
            close(child_fd);
        }
        if (errno == ESRCH) {
            kill_group(child);
            return 0;
        }
        return watch_poll(parent, child);
    }
    struct pollfd pfds[2];
    pfds[0].fd = parent_fd;
    pfds[0].events = POLLIN;
    pfds[0].revents = 0;
    pfds[1].fd = child_fd;
    pfds[1].events = POLLIN;
    pfds[1].revents = 0;
    for (;;) {
        int rc = poll(pfds, 2, -1);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(parent_fd);
            close(child_fd);
            return 1;
        }
        if (pfds[0].revents != 0) {
            close(parent_fd);
            close(child_fd);
            kill_group(child);
            return 0;
        }
        if (pfds[1].revents != 0) {
            int status = 0;
            close(parent_fd);
            close(child_fd);
            if (waitpid(child, &status, 0) < 0) {
                return 1;
            }
            return child_status(status);
        }
    }
}
#endif

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: umb-watch executable arg...\n");
        return 2;
    }
    unblock_signals();
    pid_t parent = getppid();
    pid_t child = spawn_child(&argv[1]);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_term;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    return watch(parent, child);
}
