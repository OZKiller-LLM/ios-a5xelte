/* Compile one shader and capture its real Panfrost jobs; drm-shim runs no GPU.
 * RWA_SOFTWARE=1 runs the identical input against the software reference.
 */
#include "air_metal.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    if (size <= 0 || size > 1048576) return 2;
    rewind(file);
    void *code = malloc(size);
    if (!code || fread(code, 1, size, file) != (size_t)size) return 2;
    fclose(file);
    char why[1024] = "";
    struct rwa_device *device = rwa_device_open(why, sizeof(why));
    if (!device) { fprintf(stderr, "open: %s\n", why); return 2; }
    printf("compute_capture: device %s\n", rwa_device_name(device));
    struct rwa_compute_info info = {0};
    struct rwa_compute *compute = rwa_compute_create(device, code, size, "gpu_probe", &info, why, sizeof(why));
    if (!compute) { fprintf(stderr, "compile: %s\n", why); return 2; }
    struct rwa_buffer *buffers[2];
    for (unsigned i = 0; i < 2; i++) {
        buffers[i] = rwa_buffer_create(device, 4096, why, sizeof(why));
        if (!buffers[i]) { fprintf(stderr, "buffer: %s\n", why); return 2; }
        memset(rwa_buffer_map(buffers[i]), 0xa5, 4096);
    }
    uint32_t *input = rwa_buffer_map(buffers[0]), *output = rwa_buffer_map(buffers[1]);
    input[0] = 17; input[1] = 0x4e49504c;
    output[1] = 0x54554f50;
    const struct rwa_bindings bindings = { .buffers = buffers, .buffer_count = 2 };
    const unsigned grid[3] = {1,1,1};
    int status = rwa_dispatch(compute, &bindings, grid, grid, why, sizeof(why));
    if (!status) status = rwa_finish(device, why, sizeof(why));
    printf("compute_capture: dispatch %d, output %#x, expected 0x3a; %s\n", status, output[0], why);
    int passed = !status && output[0] == 58 && output[1] == 0x54554f50;
    rwa_compute_destroy(compute);
    rwa_buffer_destroy(buffers[0]); rwa_buffer_destroy(buffers[1]);
    rwa_device_close(device); free(code);
    return passed ? 0 : 1;
}
