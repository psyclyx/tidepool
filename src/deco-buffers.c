/* deco-buffers — native helpers for decoration buffer import.
 *
 * Provides:
 *   (deco-buffers/open-shm path) → fd (integer)
 *     Open a shared memory file and return the raw fd.
 *
 *   (deco-buffers/memfd-create name size) → [fd path]
 *     Create an anonymous shared memory region, return fd and /proc path.
 *
 *   (deco-buffers/close-fd fd)
 *     Close a raw file descriptor.
 *
 *   (deco-buffers/recv-fd stream) → [data fd]
 *     Receive a message with SCM_RIGHTS ancillary data from a Unix socket.
 */

#define _GNU_SOURCE
#include <janet.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <string.h>
#include <errno.h>

#ifndef JANET_ENTRY_NAME
#define JANET_ENTRY_NAME janet_module_entry_deco_buffers
#endif

/* (deco-buffers/open-shm path) → fd */
static Janet cfun_open_shm(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        janet_panicf("open-shm: %s: %s", path, strerror(errno));
    }
    return janet_wrap_integer(fd);
}

/* (deco-buffers/memfd-create name size) → [fd path] */
static Janet cfun_memfd_create(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    const char *name = janet_getcstring(argv, 0);
    int32_t size = janet_getinteger(argv, 1);
    int fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        janet_panicf("memfd-create: %s", strerror(errno));
    }
    if (ftruncate(fd, size) < 0) {
        close(fd);
        janet_panicf("memfd-create ftruncate: %s", strerror(errno));
    }
    /* Build /proc/self/fd/N path for cross-process access */
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/%d/fd/%d", getpid(), fd);
    Janet result[2] = {janet_wrap_integer(fd),
                       janet_cstringv(proc_path)};
    return janet_wrap_tuple(janet_tuple_n(result, 2));
}

/* (deco-buffers/close-fd fd) */
static Janet cfun_close_fd(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    int fd = janet_getinteger(argv, 0);
    close(fd);
    return janet_wrap_nil();
}

/* (deco-buffers/recv-fd stream) → [data fd]
 * Receive one message with optional SCM_RIGHTS fd from a Unix socket.
 * stream must be a Janet stream (from net/accept etc). */
static Janet cfun_recv_fd(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    /* Get the raw fd from the Janet stream */
    JanetStream *stream = janet_getabstract(argv, 0, &janet_stream_type);
    int sockfd = stream->handle;

    char buf[8192];
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {.iov_base = buf, .iov_len = sizeof(buf)};
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsgbuf,
        .msg_controllen = sizeof(cmsgbuf),
    };

    ssize_t n = recvmsg(sockfd, &msg, MSG_DONTWAIT);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return janet_wrap_nil();
        }
        janet_panicf("recv-fd: %s", strerror(errno));
    }
    if (n == 0) {
        return janet_wrap_nil();
    }

    int received_fd = -1;
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg && cmsg->cmsg_level == SOL_SOCKET &&
        cmsg->cmsg_type == SCM_RIGHTS) {
        memcpy(&received_fd, CMSG_DATA(cmsg), sizeof(int));
    }

    Janet result[2] = {
        janet_stringv((uint8_t *)buf, (int32_t)n),
        received_fd >= 0 ? janet_wrap_integer(received_fd) : janet_wrap_nil()
    };
    return janet_wrap_tuple(janet_tuple_n(result, 2));
}

static const JanetReg cfuns[] = {
    {"open-shm", cfun_open_shm,
     "(deco-buffers/open-shm path)\n\n"
     "Open a file and return the raw fd as an integer."},
    {"memfd-create", cfun_memfd_create,
     "(deco-buffers/memfd-create name size)\n\n"
     "Create anonymous shared memory, return [fd proc-path]."},
    {"close-fd", cfun_close_fd,
     "(deco-buffers/close-fd fd)\n\n"
     "Close a raw file descriptor."},
    {"recv-fd", cfun_recv_fd,
     "(deco-buffers/recv-fd stream)\n\n"
     "Receive message with SCM_RIGHTS fd from a Unix socket stream."},
    {NULL, NULL, NULL}
};

void JANET_ENTRY_NAME(JanetTable *env) {
    janet_cfuns(env, "deco-buffers", cfuns);
}
