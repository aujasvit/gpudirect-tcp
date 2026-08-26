// bench_host.c
// Hello123
// Created on 24/4/26

#include <arpa/inet.h>
#include <assert.h>
#include <dirent.h>
#include <driver_types.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <cuda_runtime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define SERVER_IP "172.27.27.17"
#define SERVER_PORT 6970

#define BENCH_HOST_PORT 6967

#define BUFFER_SIZE (64 * 1024)  // 64 KB

size_t test_size = (1LL << 32);

#define CUDA_CHECK(expr_to_check)                      \
    do {                                               \
        cudaError_t result = expr_to_check;            \
        if (result != cudaSuccess) {                   \
            fprintf(stderr,                            \
                "CUDA Runtime Error: %s:%i:%d = %s\n", \
                __FILE__,                              \
                __LINE__,                              \
                result,                                \
                cudaGetErrorString(result));           \
            fflush(stderr);                            \
            exit(1);                                   \
        }                                              \
    } while (0)

void upd_checksum(const uint8_t* buf, size_t len, uint32_t* pos, uint32_t* checksum)
{
    for (int i = 0; i < len; i++) {
        *checksum += ((uint32_t)buf[i]) * ((*pos) ? (*pos) : 1);
        (*pos)++;
    }
}

__global__ void dummy_kernel(volatile int* d_exit, volatile uint8_t* d_buffer, int buf_len)
{
    uint32_t sum = 0;
    int idx = 0;
    while (!(*d_exit)) {
        sum += d_buffer[idx];
        idx = (idx + 1) % buf_len;
    }
    printf("sum = %u\n", sum);
}

int main(int argc, char** argv)
{
    int local_port = BENCH_HOST_PORT;

    int sock;
    struct sockaddr_in local_addr, server_addr;
    uint8_t buffer[BUFFER_SIZE];

    cudaStream_t kernel_stream, copy_stream;

    int* d_exit;
    uint8_t* d_buffer;
    CUDA_CHECK(cudaMalloc(&d_exit, sizeof(int)));
    int exit_flag = 0;
    CUDA_CHECK(cudaMemcpy(d_exit, &exit_flag, sizeof(exit_flag), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_buffer, BUFFER_SIZE));
    CUDA_CHECK(cudaStreamCreate(&kernel_stream));
    CUDA_CHECK(cudaStreamCreate(&copy_stream));

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt");
        close(sock);
        return 1;
    }

    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    local_addr.sin_port = htons(local_port);
    local_addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind");
        close(sock);
        return 1;
    }

    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(SERVER_PORT);

    if (inet_pton(AF_INET, SERVER_IP, &server_addr.sin_addr) <= 0) {
        perror("inet_pton");
        close(sock);
        return 1;
    }

    if (connect(sock, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("connect");
        close(sock);
        return 1;
    }

    printf("Connected to %s from local port %d\n", SERVER_IP, local_port);
    printf("Test size of %ld bytes\n", test_size);

    assert(write(sock, &test_size, sizeof(test_size)) == sizeof(test_size));

    uint32_t checksum = 0, checksum_pos = 0;

    dummy_kernel<<<1,1, 0, kernel_stream>>>(d_exit, d_buffer, BUFFER_SIZE);

    while (test_size) {
        size_t count = test_size;
        if (BUFFER_SIZE < count) 
            count = BUFFER_SIZE;

        ssize_t ret = read(sock, buffer, count);
        if (ret < 0) {
            perror("read");
            return 1;
        }

        upd_checksum(buffer, ret, &checksum_pos, &checksum);

        cudaMemcpyAsync(d_buffer, buffer, ret, cudaMemcpyHostToDevice, copy_stream);
        cudaStreamSynchronize(copy_stream);

        test_size -= ret;
    }

    assert(write(sock, &checksum, sizeof(checksum)) == sizeof(checksum));
    printf("Sent checksum = %u\n", checksum);

    exit_flag = 1;
    CUDA_CHECK(cudaMemcpy(d_exit, &exit_flag, sizeof(exit_flag), cudaMemcpyHostToDevice));

    close(sock);

    cudaDeviceSynchronize();
    return 0;
}
