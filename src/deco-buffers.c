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

/* (deco-buffers/open-shm path) → fd */
static Janet cfun_open_shm(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        janet_panicf("open-shm: %s: %s", path, strerror(errno));
    }
    return janet_wrap_integer(fd);
}

/* (deco-buffers/shm-create name size) → [fd path]
 * Create a POSIX shared memory object at /dev/shm/<name>, truncate to size,
 * fill with zeros. Returns [fd path]. */
static Janet cfun_shm_create(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    const char *name = janet_getcstring(argv, 0);
    int32_t size = janet_getinteger(argv, 1);

    /* Build /dev/shm path */
    char shm_name[128];
    snprintf(shm_name, sizeof(shm_name), "/tidepool-deco-%s", name);

    int fd = shm_open(shm_name, O_CREAT | O_RDWR, 0600);
    if (fd < 0) {
        janet_panicf("shm-create: shm_open %s: %s", shm_name, strerror(errno));
    }
    if (ftruncate(fd, size) < 0) {
        close(fd);
        shm_unlink(shm_name);
        janet_panicf("shm-create ftruncate: %s", strerror(errno));
    }
    /* Initialize to opaque black so decorations are visible immediately */
    void *ptr = mmap(NULL, size, PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr != MAP_FAILED) {
        uint32_t *pixels = ptr;
        for (int32_t i = 0; i < size / 4; i++) {
            pixels[i] = 0xFF000000; /* ARGB opaque black */
        }
        munmap(ptr, size);
    }

    char path[256];
    snprintf(path, sizeof(path), "/dev/shm%s", shm_name);
    Janet result[2] = {janet_wrap_integer(fd),
                       janet_cstringv(path)};
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
    {"shm-create", cfun_shm_create,
     "(deco-buffers/shm-create name size)\n\n"
     "Create POSIX shared memory at /dev/shm, return [fd path]."},
    {"close-fd", cfun_close_fd,
     "(deco-buffers/close-fd fd)\n\n"
     "Close a raw file descriptor."},
    {"recv-fd", cfun_recv_fd,
     "(deco-buffers/recv-fd stream)\n\n"
     "Receive message with SCM_RIGHTS fd from a Unix socket stream."},
    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "deco-buffers", cfuns);
}
