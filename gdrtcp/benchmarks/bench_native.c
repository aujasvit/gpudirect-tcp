// bench_native.c
// Hello123
// Created on 24/4/26

#include <arpa/inet.h>
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define SERVER_IP "172.27.27.17"
#define SERVER_PORT 6970

#define BENCH_NATIVE_PORT 6966

#define BUFFER_SIZE (64 * 1024)  // 64 KB

size_t test_size = (1LL << 32);

void upd_checksum(const uint8_t* buf, size_t len, uint32_t* pos, uint32_t* checksum)
{
    for (int i = 0; i < len; i++) {
        *checksum += ((uint32_t)buf[i]) * ((*pos) ? (*pos) : 1);
        (*pos)++;
    }
}

int main(int argc, char** argv)
{
    int local_port = BENCH_NATIVE_PORT;

    int sock;
    struct sockaddr_in local_addr, server_addr;
    uint8_t buffer[BUFFER_SIZE];

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

        test_size -= ret;
    }

    assert(write(sock, &checksum, sizeof(checksum)) == sizeof(checksum));
    printf("Sent checksum = %u\n", checksum);

    close(sock);
    return 0;
}
