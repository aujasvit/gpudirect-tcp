// bench_server.c
// Hello123
// Created on 19/4/26

#include <arpa/inet.h>
#include <assert.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PORT 6970
#define STATS_FILE "server_stats.csv"
#define BUFFER_SIZE (64 * 1024) // 64 KB
#define REPORT_INTERVAL 1 // seconds

#define BENCH_GPU_PORT 6969
#define BENCH_REDIRECT_PORT 6968
#define BENCH_HOST_PORT 6967
#define BENCH_NATIVE_PORT 6966

#define MAX_PROC_NAME 256
#define MAX_PROC_MONITORED 32

int num_cpus;

static double now_sec()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void fill_random(void* buf, size_t len)
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd <= 0) {
        perror("open");
        exit(1);
    }
    read(fd, buf, len);
    close(fd);
}

void upd_checksum(const uint8_t* buf, size_t len, uint32_t* pos, uint32_t* checksum)
{
    for (int i = 0; i < len; i++) {
        *checksum += ((uint32_t)buf[i]) * ((*pos) ? (*pos) : 1);
        (*pos)++;
    }
}

unsigned long long get_total_cpu_time()
{
    FILE* fp = fopen("/proc/stat", "r");
    if (!fp)
        return 0;

    unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
    fscanf(fp, "cpu  %llu %llu %llu %llu %llu %llu %llu %llu",
        &user, &nice, &system, &idle, &iowait, &irq, &softirq, &steal);
    fclose(fp);

    return user + nice + system + idle + iowait + irq + softirq + steal;
}

unsigned long long get_proc_cpu_time(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);

    FILE* fp = fopen(path, "r");
    if (!fp)
        return 0;

    unsigned long long utime, stime;
    char buf[1024];

    fgets(buf, sizeof(buf), fp);
    fclose(fp);

    char* token = strtok(buf, " ");
    int i = 1;
    while (token) {
        if (i == 14)
            utime = strtoull(token, NULL, 10);
        if (i == 15) {
            stime = strtoull(token, NULL, 10);
            break;
        }
        token = strtok(NULL, " ");
        i++;
    }

    return utime + stime;
}

pid_t find_pid_by_name(const char* name)
{
    DIR* dir = opendir("/proc");
    struct dirent* entry;

    if (!dir)
        goto error;

    while ((entry = readdir(dir)) != NULL) {
        if (!isdigit(entry->d_name[0]))
            continue;

        pid_t pid = atoi(entry->d_name);
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/comm", pid);

        FILE* fp = fopen(path, "r");
        if (!fp)
            continue;

        char proc_name[MAX_PROC_NAME];
        fgets(proc_name, sizeof(proc_name), fp);
        fclose(fp);

        proc_name[strcspn(proc_name, "\n")] = 0;

        if (strcmp(proc_name, name) == 0) {
            closedir(dir);
            return pid;
        }
    }

error:
    closedir(dir);
    printf("find_pid_by_name failed for %s\n", name);
    exit(1);
}

int get_peer_port(int conn_fd)
{
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);

    if (getpeername(conn_fd, (struct sockaddr*)&addr, &len) == -1) {
        perror("getpeername");
        exit(1);
    }

    return ntohs(addr.sin_port);
}

double get_cpu_usage(pid_t pid, int static_idx)
{
    static int totals[MAX_PROC_MONITORED] = { 0 };
    static int procs[MAX_PROC_MONITORED] = { 0 };

    unsigned long long total = get_total_cpu_time();
    unsigned long long proc = get_proc_cpu_time(pid);

    unsigned long long total_delta = total - totals[static_idx];
    unsigned long long proc_delta = proc - procs[static_idx];

    totals[static_idx] = total;
    procs[static_idx] = proc;

    if (total_delta == 0)
        return 0.0;

    return ((double)proc_delta / total_delta) * (double)(num_cpus * 100.0);
}

int main()
{
    num_cpus = sysconf(_SC_NPROCESSORS_ONLN);

    int server_fd, client_fd;
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);

    FILE* stats_fp;
    stats_fp = fopen(STATS_FILE, "w");
    if (stats_fp == NULL) {
        perror("Failed to open stats file");
        return 1;
    }

    char* buffer = malloc(BUFFER_SIZE);
    if (!buffer) {
        perror("malloc");
        return 1;
    }

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    int mss = 1460;
    setsockopt(server_fd, IPPROTO_TCP, TCP_MAXSEG, &mss, sizeof(mss));

    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }

    if (listen(server_fd, 1) < 0) {
        perror("listen");
        return 1;
    }

    printf("Listening on port %d...\n", PORT);

    client_fd = accept(server_fd, (struct sockaddr*)&addr, &addr_len);
    if (client_fd < 0) {
        perror("accept");
        return 1;
    }

    char proc_ksoftirq[num_cpus][MAX_PROC_NAME];
    for (int i = 0; i < num_cpus; i++) {
        sprintf(proc_ksoftirq[i], "ksoftirqd/%d", i);
    }

    pid_t pid_ksoftirq[num_cpus];
    for (int i = 0; i < num_cpus; i++) {
        pid_ksoftirq[i] = find_pid_by_name(proc_ksoftirq[i]);
        get_cpu_usage(pid_ksoftirq[i], i);
    }

    char proc_gpu[2][MAX_PROC_NAME] = { "irq/54-nvidia", "bench_gdrtcp" };
    char proc_cpu[1][MAX_PROC_NAME] = { "bench_host" };
    char proc_native[1][MAX_PROC_NAME] = { "bench_native" };

    int num_proc_monitor;
    char (*proc_monitor)[MAX_PROC_NAME];

    int peer_port = get_peer_port(client_fd);
    if (peer_port == BENCH_GPU_PORT) {
        printf("Client connected; client is GPU TCP/IP stack.\n");
        num_proc_monitor = sizeof(proc_gpu) / sizeof(proc_gpu[0]);
        proc_monitor = proc_gpu;
    } else if (peer_port == BENCH_REDIRECT_PORT) {
        printf("Client connected; client is linux TCP/IP stack, performing *redirect* test.\n");
        num_proc_monitor = sizeof(proc_gpu) / sizeof(proc_gpu[0]);
        proc_monitor = proc_gpu;
    } else if (peer_port == BENCH_HOST_PORT) {
        printf("Client connected; client is linux TCP/IP stack, performing *host* test.\n");
        num_proc_monitor = sizeof(proc_cpu) / sizeof(proc_cpu[0]);
        proc_monitor = proc_cpu;
    } else if (peer_port == BENCH_NATIVE_PORT) {
        printf("Client connected; client is linux TCP/IP stack, performing *native* test.\n");
        num_proc_monitor = sizeof(proc_native) / sizeof(proc_native[0]);
        proc_monitor = proc_native;
    } else {
        printf("Client connected from unknown port %d\n", peer_port);
        exit(1);
    }

    pid_t pid_monitor[num_proc_monitor];
    for (int i = 0; i < num_proc_monitor; i++) {
        pid_monitor[i] = find_pid_by_name(proc_monitor[i]);
        get_cpu_usage(pid_monitor[i], num_cpus + i);
    }

    fprintf(stats_fp, "time_sec,tp_total_mbps,tp_recent_mbps,rtt_us,rtt_variance_us,cwnd_kb,total_cpu,ksoftirq");
    for (int i = 0; i < num_proc_monitor; i++) {
        fprintf(stats_fp, ",%s", proc_monitor[i]);
    }
    fprintf(stats_fp, "\n");

    size_t test_size = 0;
    if (read(client_fd, &test_size, sizeof(test_size)) < 0) {
        perror("read");
        return 1;
    }

    printf("Client has requested test size of %lu bytes.\n", test_size);

    setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

    double start = now_sec();
    double last_report = start;

    size_t total_bytes = 0;
    size_t last_bytes = 0;

    uint32_t checksum = 0, checksum_pos = 0;

    size_t bytes_to_refresh = BUFFER_SIZE;
    fill_random(buffer, BUFFER_SIZE);

    while (test_size) {
        if (!bytes_to_refresh) {
            fill_random(buffer, BUFFER_SIZE);
            bytes_to_refresh = BUFFER_SIZE;
        }

        size_t bytes_to_send = bytes_to_refresh;
        if (test_size < bytes_to_send) {
            bytes_to_send = test_size;
        }

        void* ptr = buffer + (BUFFER_SIZE - bytes_to_refresh);
        ssize_t sent = send(client_fd, ptr, bytes_to_send, 0);

        if (sent < 0) {
            if (errno == EPIPE || errno == ECONNRESET) {
                printf("Client disconnected.\n");
                break;
            } else {
                perror("send");
                break;
            }
        }

        total_bytes += sent;
        test_size -= sent;
        bytes_to_refresh -= sent;
        upd_checksum(ptr, sent, &checksum_pos, &checksum);

        double t = now_sec();
        if (t - last_report >= REPORT_INTERVAL) {
            double elapsed_start = t - start;
            double elapsed_delta = t - last_report;

            double mbits_start = (total_bytes * 8.0) / (1000 * 1000);
            double mbits_delta = ((total_bytes - last_bytes) * 8.0) / (1000 * 1000);

            double throughput_start = mbits_start / elapsed_start;
            double throughput_delta = mbits_delta / elapsed_delta;

            struct tcp_info info;
            socklen_t len = sizeof(info);

            if (getsockopt(client_fd, IPPROTO_TCP, TCP_INFO, &info, &len) == -1) {
                perror("getsockopt");
                return -1;
            }

            double ksoftirq_cpu = 0.0;
            for (int i = 0; i < num_cpus; i++) {
                ksoftirq_cpu += get_cpu_usage(pid_ksoftirq[i], i);
            }

            double total_cpu = ksoftirq_cpu;
            double cpu_monitor[num_proc_monitor];
            for (int i = 0; i < num_proc_monitor; i++) {
                cpu_monitor[i] = get_cpu_usage(pid_monitor[i], num_cpus + i);
                total_cpu += cpu_monitor[i];
            }

            uint32_t cwnd_kb = (long long)(info.tcpi_snd_cwnd * info.tcpi_snd_mss) / (long long)(1000);
            printf("[%.1f sec] Throughput (total, recent): (%.2f, %.2f) Mbps, RTT: %u us, RTT variance: %u us, Cwnd (KB): %u, Total CPU: %.2f, ksoftirq: %.2f",
                elapsed_start, throughput_start, throughput_delta, info.tcpi_rtt, info.tcpi_rttvar, cwnd_kb,
                total_cpu, ksoftirq_cpu);

            for (int i = 0; i < num_proc_monitor; i++) {
                printf(", %s: %.2f", proc_monitor[i], cpu_monitor[i]);
            }
            printf("\n");

            fprintf(stats_fp, "%d,%d,%d,%d,%d,%d,%.2f,%.2f", (int)elapsed_start, (int)throughput_start, (int)throughput_delta,
                (int)info.tcpi_rtt, (int)info.tcpi_rttvar, (int)cwnd_kb, total_cpu, ksoftirq_cpu);
            for (int i = 0; i < num_proc_monitor; i++) {
                fprintf(stats_fp, ",%.2f", cpu_monitor[i]);
            }
            fprintf(stats_fp, "\n");

            last_bytes = total_bytes;
            last_report = t;
        }
    }

    uint32_t client_checksum;
    if (read(client_fd, &client_checksum, sizeof(client_checksum)) < 0) {
        perror("read");
        return 1;
    }

    if (client_checksum != checksum) {
        printf("Checksum does not match, expected %u got %u\n", checksum, client_checksum);
    } else {
        printf("Checksum verified! value = %u\n", checksum);
    }

    close(client_fd);
    close(server_fd);
    fclose(stats_fp);
    free(buffer);

    return 0;
}
