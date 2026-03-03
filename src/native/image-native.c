#define _GNU_SOURCE
#include <janet.h>
#include <sys/mman.h>
#include <unistd.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#include "stb_image.h"

/*
 * image/load path
 *
 * Decode image from filesystem path into a wl_shm-compatible anonymous
 * shared-memory buffer (XRGB8888 format). Returns a struct:
 *   {:fd <int> :width <int> :height <int> :stride <int> :size <int>}
 *
 * The caller is responsible for closing the fd when done.
 */
JANET_FN(jimg_load,
    "(image/load path)",
    "Decode image into shared memory. Returns {:fd fd :width w :height h :stride s :size sz}.") {
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);

    /* Read file into memory (stb_image_from_memory avoids locale issues) */
    FILE *f = fopen(path, "rb");
    if (!f)
        janet_panicf("image/load: cannot open %s", path);
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *fdata = janet_smalloc((size_t)fsize);
    if (fread(fdata, 1, (size_t)fsize, f) != (size_t)fsize) {
        fclose(f);
        janet_sfree(fdata);
        janet_panicf("image/load: failed to read %s", path);
    }
    fclose(f);

    int w, h, channels;
    unsigned char *pixels = stbi_load_from_memory(fdata, (int)fsize, &w, &h, &channels, 4);
    janet_sfree(fdata);
    if (!pixels)
        janet_panicf("image/load: decode failed: %s", stbi_failure_reason());

    int stride = w * 4;
    int size = stride * h;

    int fd = memfd_create("tidepool-wallpaper", MFD_CLOEXEC);
    if (fd < 0) {
        stbi_image_free(pixels);
        janet_panic("image/load: memfd_create failed");
    }
    if (ftruncate(fd, size) < 0) {
        stbi_image_free(pixels);
        close(fd);
        janet_panic("image/load: ftruncate failed");
    }

    unsigned char *map = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        stbi_image_free(pixels);
        close(fd);
        janet_panic("image/load: mmap failed");
    }

    /* Convert RGBA (stb output) to XRGB8888 / BGRX in memory (little-endian) */
    const unsigned char *src = pixels;
    unsigned char *dst = map;
    for (int i = 0; i < w * h; i++) {
        dst[0] = src[2]; /* B */
        dst[1] = src[1]; /* G */
        dst[2] = src[0]; /* R */
        dst[3] = 0xFF;   /* X */
        src += 4;
        dst += 4;
    }

    munmap(map, (size_t)size);
    stbi_image_free(pixels);

    JanetKV *result = janet_struct_begin(5);
    janet_struct_put(result, janet_ckeywordv("fd"), janet_wrap_integer(fd));
    janet_struct_put(result, janet_ckeywordv("width"), janet_wrap_integer(w));
    janet_struct_put(result, janet_ckeywordv("height"), janet_wrap_integer(h));
    janet_struct_put(result, janet_ckeywordv("stride"), janet_wrap_integer(stride));
    janet_struct_put(result, janet_ckeywordv("size"), janet_wrap_integer(size));
    return janet_wrap_struct(janet_struct_end(result));
}

JANET_FN(jimg_close_fd,
    "(image/close-fd fd)",
    "Close a file descriptor.") {
    janet_fixarity(argc, 1);
    close(janet_getinteger(argv, 0));
    return janet_wrap_nil();
}

JANET_MODULE_ENTRY(JanetTable *env) {
    JanetRegExt cfuns[] = {
        JANET_REG("load", jimg_load),
        JANET_REG("close-fd", jimg_close_fd),
        JANET_REG_END,
    };
    janet_cfuns_ext(env, "image-native", cfuns);
}
