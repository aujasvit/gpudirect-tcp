// gdrtcp.cu
// GPUDirect TCP - Hello123
// created on 8/4/26

#include "gdr_common.h"
#include "gdrtcp.h"
#include "helpers.cuh"

#include <arpa/inet.h>
#include <asm-generic/socket.h>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime_api.h>
#include <driver_types.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace gdrtcp {

__device__ uint32_t library_op_id = 1;

static double now_sec()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

struct {
    long long tx_cnt { 0 };
    long long redirect_cnt { 0 };
    long long invalid_tx_checksum { 0 };

    long long bytes_acked { 0 };
    double throughput_total { 0 };
    double throughput_recent { 0 };

    long long tx_ring_used;
    long long tx_ring_capacity;
    long long redirect_ring_used;
    long long redirect_ring_capacity;
    long long inject_ring_used;
    long long inject_ring_capacity;

    double start_time;
    double last_report;
    long long last_bytes_acked { 0 };
} cpu_stats;

static void print_cpu_stats()
{
    double now = now_sec();
    if ((now - cpu_stats.last_report) > STATS_INTERVAL_SEC) {
        cpu_stats.throughput_total = (8.0 * cpu_stats.bytes_acked) / ((now - cpu_stats.start_time) * 1000 * 1000);

        cpu_stats.throughput_recent = (8.0 * (cpu_stats.bytes_acked - cpu_stats.last_bytes_acked)) / ((now - cpu_stats.last_report) * 1000 * 1000);
        cpu_stats.last_bytes_acked = cpu_stats.bytes_acked;

        printf(
            "======= CPU Stats [%.2f sec] =======\n"
            "%-25s : %lld\n"
            "%-25s : %lld\n"
            "%-25s : %lld\n"
            "%-25s : %lld\n"
            "%-25s : %.2f Mbps\n"
            "%-25s : %.2f Mbps\n"
            "%-25s : %lld %lld\n"
            "%-25s : %lld %lld\n"
            "%-25s : %lld %lld\n\n",
            now_sec() - cpu_stats.start_time,
            "tx_cnt", cpu_stats.tx_cnt,
            "redirect_cnt", cpu_stats.redirect_cnt,
            "invalid_tx_checksum", cpu_stats.invalid_tx_checksum,
            "bytes_acked", cpu_stats.bytes_acked,
            "throughput_total", cpu_stats.throughput_total,
            "throughput_recent", cpu_stats.throughput_recent,
            "tx ring (used, sz)", cpu_stats.tx_ring_used, cpu_stats.tx_ring_capacity,
            "redirect ring (used, sz)", cpu_stats.redirect_ring_used, cpu_stats.redirect_ring_capacity,
            "inject ring (used, sz)", cpu_stats.inject_ring_used, cpu_stats.inject_ring_capacity);

        cpu_stats.last_report = now;
    }
}

// TCP only, for now at least
void* gdr_thread(void* _cpu_env)
{
    printf("gdr thread tid = %d\n", gettid());
    cpu_env_t* cpu_env = (cpu_env_t*)_cpu_env;

    cudaStream_t tx_memcpy_stream;
    CUDA_CHECK(cudaStreamCreate(&tx_memcpy_stream));

    // redirect, tx are MMIO mapped GPU addresses
    // inject is kernel vmalloc'd memory mapped to userspace
    volatile spsc_ring_t *redirect_ring, *inject_ring, *tx_ring;

    redirect_ring = (volatile spsc_ring_t*)((char*)cpu_env->redirect_mem + sizeof(spsc_ring_t));
    tx_ring = (volatile spsc_ring_t*)((char*)cpu_env->tx_mem + 2 * sizeof(spsc_ring_t));
    inject_ring = (volatile spsc_ring_t*)(cpu_env->inject_mem);

    if (redirect_ring->magic != GDR_MAGIC || tx_ring->magic != GDR_MAGIC
        || inject_ring->magic != GDR_MAGIC) {
        fprintf(stderr, "gdr_thread: invalid magic on redirect/tx/inject ring.\n");
        fflush(stderr);
        exit(1);
    }

    uint32_t ihead, itail, isz;
    uint32_t rhead, rtail, rsz;
    uint32_t thead, ttail, tsz;
    ihead = inject_ring->head, itail = inject_ring->tail, isz = inject_ring->num_slots;
    rhead = redirect_ring->head, rtail = redirect_ring->tail, rsz = redirect_ring->num_slots;
    thead = tx_ring->head, ttail = tx_ring->tail, tsz = tx_ring->num_slots;
    int events_ring_sz = sizeof(cpu_env->copy_events) / sizeof(cpu_env->copy_events[0]);

    cpu_stats.inject_ring_capacity = isz;
    cpu_stats.tx_ring_capacity = tsz;
    cpu_stats.redirect_ring_capacity = isz;

    uint32_t prev_ack = 0;
    uint32_t curr_ack = 0;

    // Binary heuristic to switch between continuous polling and sleeping
    bool polling = true;
    long long redirect_recent_cnt = 0;
    long long tx_recent_cnt = 0;
    const int heuristic_flush_freq = 500;
    int heuristic_stale_ticks = heuristic_flush_freq;

    int iteration = 0;
    while (!cpu_env->exiting) {
        if (!(--heuristic_stale_ticks)) {
            heuristic_stale_ticks = heuristic_flush_freq;
            redirect_recent_cnt = 0;
            tx_recent_cnt = 0;
        } else if (heuristic_stale_ticks < heuristic_flush_freq) {
            if (tx_recent_cnt > redirect_recent_cnt)
                polling = false;
            else
                polling = true;
        }

        // this thread writes to ihead, rtail, ttail
        itail = inject_ring->tail;
        rhead = redirect_ring->head;
        thead = tx_ring->head;

        cpu_stats.tx_ring_used = (thead - ttail + tsz) % tsz;
        cpu_stats.redirect_ring_used = (rhead - rtail + rsz) % rsz;
        cpu_stats.inject_ring_used = (ihead - itail + isz) % isz;
        print_cpu_stats();

        bool nothing_done = true;

        while (thead != ttail) {
            nothing_done = false;
            char packet[PACKET_SZ];
            volatile pkt_desc_t* tdesc = (volatile pkt_desc_t*)((char*)cpu_env->tx_mem + CPU_PAGE_SIZE + ttail * tx_ring->slot_sz);

            // NOTE: The head/tail variables are located on a different page from the descriptor. We had
            // observed that sometimes reading the descriptors we were getting stale data even if
            // head/tail had been updated. And this stale data always happened when we were on a page
            // boundary, i.e starting on a new page. So we just spin till we observe data that is not
            // stale.
            while (tdesc->magic != GDR_MAGIC)
                ;
            tdesc->magic = 0;

            // Packets are small, unlike the redirect ring we don't care about truly async copies
            CUDA_CHECK(cudaMemcpyAsync(packet, tdesc->gpu_va, tdesc->length, cudaMemcpyDeviceToHost, tx_memcpy_stream));
            CUDA_CHECK(cudaStreamSynchronize(tx_memcpy_stream));

            tx_recent_cnt++;

            struct iphdr* ip = (struct iphdr*)packet;
            struct tcphdr* tcp = (struct tcphdr*)(ip + 1);
            struct sockaddr_in dest;

            dest.sin_family = AF_INET;
            dest.sin_port = tcp->dest;
            dest.sin_addr.s_addr = ip->daddr;

            if (prev_ack == 0) {
                prev_ack = ntohl(tcp->ack_seq);
            } else {
                curr_ack = ntohl(tcp->ack_seq);
                cpu_stats.bytes_acked += (uint32_t)(curr_ack - prev_ack);
                prev_ack = curr_ack;
            }

            if (verify_ip_tcp_checksums(packet, tdesc->length)) {
                cpu_stats.invalid_tx_checksum++;
            }

            assert(sendto(cpu_env->fd_raw_socket, packet, tdesc->length,
                       MSG_DONTWAIT, (struct sockaddr*)&dest, sizeof(dest))
                == tdesc->length);
            cpu_stats.tx_cnt++;

            ttail = (ttail + 1) % tsz;
            tx_ring->tail = ttail;
        }

        bool done = false;
        while (cpu_env->events_head != cpu_env->events_tail && cudaEventQuery(cpu_env->copy_events[cpu_env->events_tail]) == cudaSuccess) {
            redirect_ring->tail = (redirect_ring->tail + 2) % rsz;
            inject_ring->head = (inject_ring->head + 2) % isz;
            cpu_env->events_tail = (cpu_env->events_tail + 1) % events_ring_sz;
            done = true;
            cpu_stats.redirect_cnt++;
        }

        int ready = (rhead - rtail + rsz) % rsz;
        if (ready == 0) {
            if (!polling && nothing_done && cpu_env->events_head == cpu_env->events_tail) {
                assert(read(cpu_env->fd_inject, NULL, 0) == 0);
            }
            continue;
        }

        uint32_t inext = (ihead + 1) % isz;
        if (inext == itail) {
            pr_error("inject ring full!\n");
            continue;
        }

        uint32_t enext = (cpu_env->events_head + 1) % events_ring_sz;
        if (enext == cpu_env->events_tail) {
            pr_error("cuda events ring full!\n");
            continue;
        }

        volatile pkt_desc_t* rdesc = (volatile pkt_desc_t*)((char*)cpu_env->redirect_mem + CPU_PAGE_SIZE + rtail * redirect_ring->slot_sz);
        volatile pkt_desc_t* idesc = (volatile pkt_desc_t*)((char*)inject_ring->userspace_va + ihead * inject_ring->slot_sz);
        volatile void* inject_data_mem_start = ((char*)cpu_env->inject_mem + CPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ);
        volatile void* data_addr = (volatile void*)((char*)inject_data_mem_start + ihead * PACKET_SZ);

        idesc->offset = CPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ + ihead * PACKET_SZ;
        idesc->length = rdesc->length;
        memcpy((void*)idesc->nic_info, (void*)rdesc->nic_info, sizeof(idesc->nic_info));
        idesc->magic = rdesc->magic;

        while (rdesc->magic != GDR_MAGIC)
            ;

        if (idesc->magic != GDR_MAGIC) {
            printf("invalid magic on idesc\n");
            fflush(stdout);
            exit(1);
        }

        iteration++;
        cudaError_t err = cudaMemcpyAsync((void*)data_addr, rdesc->gpu_va, rdesc->length, cudaMemcpyDeviceToHost,
            cpu_env->copy_streams[iteration % config::COPY_ENGINES_CNT]);
        if (err != cudaSuccess) {
            printf("cudaMemcpy failed with error %s\n", cudaGetErrorString(err));
            exit(1);
        }

        redirect_recent_cnt++;

        if (iteration % 2 == 0) {
            assert(cudaEventRecord(cpu_env->copy_events[cpu_env->events_head],
                       cpu_env->copy_streams[iteration % config::COPY_ENGINES_CNT])
                == cudaSuccess);
            cpu_env->events_head = (cpu_env->events_head + 1) % events_ring_sz;
        }
        rtail = (rtail + 1) % rsz;
        ihead = (ihead + 1) % isz;

        if (iteration % config::COPY_ENGINES_CNT == 0) {
            iteration = 0;
        }
    }

    return NULL;
}

__device__ __forceinline__ void* spsc_ring_offset(volatile spsc_ring_t* ring, int idx)
{
    uint64_t ret = (uint64_t)(ring->gpu_va);
    ret += idx * ring->slot_sz;
    return (void*)ret;
}

__device__ static double now_sec(double clock_freq_hz)
{
    return clock64() / clock_freq_hz;
}

__device__ void recv_warp(int lane, handle_t handle)
{
    volatile gdr_env_t* gdr = handle.gdr_env;
    tcp_env_t* tcp_env = handle.tcp_env;

    // If drop_shared[lane] is set, then that lane must drop its packet (no redirect, no tcp)
    __shared__ bool drop_shared[WARP_SZ];

    __shared__ int num_pkts_processed;

    // belongs_to_gpu[lane] is true if the packet belonging to the lane must be processed by gpu tcp stack
    __shared__ bool belongs_to_gpu[WARP_SZ];

    // if belongs_to_gpu[lane] == true, then connections[lane] is the connection_t the packet belongs to
    __shared__ connection_t* connections[WARP_SZ];

    // Data in packet is [seq_start, seq_end), i.e seq_end = tcp->seq + payload_length
    __shared__ uint32_t seq_start[WARP_SZ];
    __shared__ uint32_t seq_end[WARP_SZ];
    __shared__ uint32_t ack_seq_shared[WARP_SZ];

    __shared__ uint32_t seq_start_rel[WARP_SZ]; // seq relative to conn->last_ack_sent

    volatile spsc_ring_t* gdr_rx_ring = &gdr->rx_ring;
    volatile spsc_ring_t* gdr_redirect_ring = &gdr->redirect_ring;

    const int conn_table_sz = sizeof(tcp_env->conn_table) / sizeof(tcp_env->conn_table[0]);

    // Lane-local variables
    volatile pkt_desc_t* desc;
    struct ethhdr* eth_raw;
    struct iphdr* ip_raw;
    struct tcphdr* tcp_raw;

    struct gpu_ethhdr eth;
    struct gpu_iphdr ip;
    struct gpu_tcphdr tcp;

    socket_t* sock;
    uint32_t payload_length;
    volatile uint8_t* payload;
    uint32_t seq, ack_seq; // Careful, use uint32_t. Rollover mod 2^32 needed for seq no. manipulation
    uint32_t rx_ring_offset;

    int gdr_rhead, gdr_rtail, gdr_rsz;
    int gdr_ihead, gdr_itail, gdr_isz;

    gdr_rsz = gdr_rx_ring->num_slots;
    gdr_isz = gdr_redirect_ring->num_slots;

    __shared__ struct {
        long long dest_is_gpu;
        int invalid_checksum;
        long long ooo_cnt;

        long long rx_ring_used;
        long long rx_ring_capacity;

        double start_time;
        double last_report;
    } recv_warp_stats;
    if (lane == 0) {
        recv_warp_stats.dest_is_gpu = 0;
        recv_warp_stats.invalid_checksum = 0;
        recv_warp_stats.ooo_cnt = 0;
        recv_warp_stats.rx_ring_used = 0;
        recv_warp_stats.rx_ring_capacity = 0;
        recv_warp_stats.last_report = now_sec(handle.gpu_freq_hz);
        recv_warp_stats.start_time = recv_warp_stats.last_report;
        recv_warp_stats.rx_ring_capacity = gdr_rsz;
    }

    while (!atomicAdd(&handle.tcp_env->exiting, 0)) {
        gdr_rhead = gdr_rx_ring->head, gdr_rtail = gdr_rx_ring->tail;
        gdr_ihead = gdr_redirect_ring->head, gdr_itail = gdr_redirect_ring->tail;

        belongs_to_gpu[lane] = false;
        drop_shared[lane] = false;

        /* Part 1: Wait till there are enough packets so that each thread in the warp can process one,
         * or if we have a non zero number of packets to process and have waited for MAX_WAIT_ITERATIONS */
        if (lane == 0) {
            while (gdr_rhead == gdr_rtail)
                gdr_rhead = gdr_rx_ring->head;

            int wait_iterations = MAX_WAIT_ITERATIONS;
            while (wait_iterations-- && (((gdr_rhead - gdr_rtail + gdr_rsz) % gdr_rsz) < WARP_SZ))
                gdr_rhead = gdr_rx_ring->head;

            num_pkts_processed = (gdr_rhead - gdr_rtail + gdr_rsz) % gdr_rsz;
            if (num_pkts_processed > WARP_SZ)
                num_pkts_processed = WARP_SZ;

            for (int i = num_pkts_processed; i < WARP_SZ; i++) {
                drop_shared[i] = true;
            }

            int available = (gdr_isz - 1) - ((gdr_ihead - gdr_itail + gdr_isz) % gdr_isz);
            if (available < WARP_SZ) {
                printf("redirect ring full!\n");
                for (int i = 0; i < WARP_SZ; i++)
                    // drop everything
                    drop_shared[i] = true;
            }
        }

        __syncwarp();
        /* Part 2: Filter the packet, figure out if it should be put in redirect ring or if it
         * belongs to GPU. If it belongs to a GPU socket, do some basic parsing and work */

        sock = NULL;
        if (!drop_shared[lane]) {
            desc = (pkt_desc_t*)spsc_ring_offset(gdr_rx_ring, (gdr_rtail + lane) % gdr_rsz);
            eth_raw = (struct ethhdr*)desc->gpu_va;
            ip_raw = (struct iphdr*)(eth_raw + 1);

            assert(desc->length >= sizeof(struct ethhdr));
            eth_to_gpu(eth_raw, &eth);

            // NOTE: If there are weird bugs, check if ethernet FCS is being stripped by hardware or not
            // (and it should NOT be included in packet length!)
            if (ntohs_d(eth.h_proto) == ETH_P_IP && desc->length >= sizeof(ethhdr) + sizeof(iphdr)) {
                ip_to_gpu(ip_raw, &ip);
                if (ip.protocol == IPPROTO_TCP && desc->length >= sizeof(ethhdr) + sizeof(iphdr) + sizeof(tcphdr)) {
                    // IPv4 packet, TCP
                    tcp_raw = (struct tcphdr*)(((char*)ip_raw) + 4 * ip_ihl(&ip));
                    tcp_to_gpu(tcp_raw, &tcp);
                    for (int i = 0; i < conn_table_sz; i++) {
                        connection_t* conn = &tcp_env->conn_table[i];
                        if ((conn->established || conn->syn_sent || conn->fin_wait_1) && conn->peer_ip == ip.saddr
                            && conn->local_ip == ip.daddr && conn->peer_port == tcp.source && conn->local_port == tcp.dest) {
                            if (!desc->checksum_verified) {
                                atomicAdd(&recv_warp_stats.invalid_checksum, 1);
                                drop_shared[lane] = true;
                            }

                            if (conn->syn_sent) {
                                assert(!tcp_has_flag(&tcp, TCP_FLAG_RST) && tcp_has_flag(&tcp, TCP_FLAG_SYN)
                                    && tcp_has_flag(&tcp, TCP_FLAG_ACK)
                                    && "Peer likely in TIME_WAIT state! Try again after waiting");

                                drop_shared[lane] = true; // SYN/ACK is completely processed in this if block
                                conn->peer_isn = ntohl_d(tcp.seq);
                                conn->last_ack_sent = (conn->peer_isn + 1);
                                conn->last_ack_recv = ntohl_d(tcp.ack_seq);
                                assert(conn->last_ack_recv == conn->local_isn + 1);

                                conn->syn_sent = false;
                                conn->established = true;
                                conn->send_doorbell = true;
                                // TODO: atomicCAS on conn->syn_sent etc (multiple SYN/ACKs in one batch)
                                printf("Connection established\n");

                                op_desc_t cq_desc;
                                cq_desc.id = conn->pending_op_id;
                                cq_desc.opcode = opcode_t::SUCCESS;
                                op_write(&tcp_env->completion_queue, cq_desc);
                            } else if (conn->fin_wait_1 && tcp_has_flag(&tcp, TCP_FLAG_FIN)) {
                                assert(!tcp_has_flag(&tcp, TCP_FLAG_RST) && "Received RST from peer!");
                                drop_shared[lane] = true; // FIN is completely processed in this if block

                                // Drop the FIN if there are previous segments which we have not yet processed
                                // Let peer retransmit FIN then
                                if (ntohl_d(tcp.seq) <= conn->last_ack_sent) {
                                    conn->fin_wait_1 = false;
                                    conn->fin_wait_2 = true;

                                    conn->last_ack_sent++;
                                    conn->send_doorbell = true;

                                    op_desc_t cq_desc;
                                    cq_desc.id = conn->pending_op_id;
                                    cq_desc.opcode = opcode_t::SUCCESS;
                                    op_write(&tcp_env->completion_queue, cq_desc);
                                }
                            } else if (conn->established || conn->fin_wait_1) {
                                assert(!tcp_has_flag(&tcp, TCP_FLAG_RST) && "Received RST from peer!");
                                belongs_to_gpu[lane] = true;
                                sock = &conn->socket;
                                connections[lane] = conn;
                                payload_length = ntohs_d(ip.tot_len) - (4 * ip_ihl(&ip)) - (4 * tcp_doff(&tcp));
                                payload = (uint8_t*)(desc->gpu_va) + sizeof(struct ethhdr) + (ntohs_d(ip.tot_len) - payload_length);

                                assert(!tcp_has_flag(&tcp, TCP_FLAG_RST) && "Peer sent RST! Crashing");
                                if (tcp_has_flag(&tcp, TCP_FLAG_SYN)) {
                                    drop_shared[lane] = true;
                                }

                                seq = ntohl_d(tcp.seq);
                                ack_seq = ntohl_d(tcp.ack_seq);

                                // last_ack_sent is the seq of the byte which will be written to rx_ring.head
                                uint32_t gap = (seq + payload_length - conn->last_ack_sent - 1); // [rx_ring_offset, rx_ring.head + gap] will be written to

                                // After this, the ring must be able to store at least (gap + 1) bytes
                                gap += (uint32_t)((sock->rx_ring.head - sock->rx_ring.tail + sock->rx_ring.length) % sock->rx_ring.length);
                                if ((gap + 1) > (sock->rx_ring.length - 1)) { // since true length is one byte less than rx_ring.length
                                    drop_shared[lane] = true;
                                    belongs_to_gpu[lane] = false;
                                }

                                seq_start[lane] = seq;
                                seq_end[lane] = seq + payload_length;
                                ack_seq_shared[lane] = ack_seq;
                                seq_start_rel[lane] = seq - conn->last_ack_sent;

                                rx_ring_offset = (seq - (conn->peer_isn + 1)); // SYN consumes 1 byte
                                rx_ring_offset %= sock->rx_ring.length;
                            }
                            break;
                        }
                    }
                }
            }
        }
        belongs_to_gpu[lane] = drop_shared[lane] ? false : belongs_to_gpu[lane];

        __syncwarp();
        /* Part 3: For all packets that belong to some gpu socket, copy them to the calculated offsets
         * in rx_ring. This is the part that is the bottleneck, hence parallelizing this will help.
         * Rest of the parts are anyway either branch heavy or serial processing, so there probably aren't
         * a lot of performance gains in the rest of the parts compared to CPU processing, if any */

        if (!drop_shared[lane] && sock) {
            int i = rx_ring_offset;
            int rx_ring_len = sock->rx_ring.length;

            // NOTE: Byte by byte copy, can be optimized to copying say 8 bytes at a time. Currently hitting
            // line rate anyway so letting it remain
            for (int j = 0; j < payload_length; j++) {
                sock->rx_ring.buffer[i] = payload[j];
                i = (i + 1) % rx_ring_len;
            }
        }

        __syncwarp();
        /* Part 4: Add packet descriptors for packets not belonging to gpu to redirect ring.
         * Calculate cumulative ack, advance sock->rx_ring, gdr->rx_ring.
         * Update conn->last_ack_recv etc.
         * Doing this serially, since parallelizing this stuff is not trivial. This is unlikely to
         * be the bottleneck still, Part 3 is the bottleneck */

        if (lane == 0) {
            for (int i = 0; i < num_pkts_processed; i++) {
                if (belongs_to_gpu[i])
                    recv_warp_stats.dest_is_gpu++;
            }

            for (int i = 0; i < num_pkts_processed; i++) {
                if (!belongs_to_gpu[i] && !drop_shared[i]) {
                    device_memcpy(spsc_ring_offset(gdr_redirect_ring, gdr_ihead),
                        spsc_ring_offset(gdr_rx_ring, gdr_rtail), sizeof(pkt_desc_t));
                    gdr_ihead = (gdr_ihead + 1) % gdr_isz;
                }
                gdr_rtail = (gdr_rtail + 1) % gdr_rsz;
            }

            gdr_redirect_ring->head = gdr_ihead;
            gdr_rx_ring->tail = gdr_rtail;

            // Insertion sort, we only have 32 elements, should be good enough
            for (int i = 1; i < num_pkts_processed; i++) {
                if (!belongs_to_gpu[i])
                    continue;

                connection_t* conn = connections[i];
                uint32_t start = seq_start[i];
                uint32_t end = seq_end[i];
                uint32_t ack_seq = ack_seq_shared[i];
                uint32_t start_rel = seq_start_rel[i];

                int j = i - 1;
                while (j >= 0 && (!belongs_to_gpu[j] || seq_start_rel[j] > start_rel)) {
                    belongs_to_gpu[j + 1] = belongs_to_gpu[j];
                    connections[j + 1] = connections[j];
                    seq_start[j + 1] = seq_start[j];
                    seq_end[j + 1] = seq_end[j];
                    ack_seq_shared[j + 1] = ack_seq_shared[j];
                    seq_start_rel[j + 1] = seq_start_rel[j];
                    j--;
                }

                belongs_to_gpu[j + 1] = true;
                connections[j + 1] = conn;
                seq_start[j + 1] = start;
                seq_end[j + 1] = end;
                ack_seq_shared[j + 1] = ack_seq;
                seq_start_rel[j + 1] = start_rel;
            }

            for (int u = 0; u < num_pkts_processed; u++) {
                if (!belongs_to_gpu[u])
                    break;

                connection_t* conn = connections[u];

                uint32_t new_ack_sent = conn->last_ack_sent;
                int last = 0;
                // TODO: Now that we are sorting by seq_start_rel, this could
                // break for multiple connections :-(
                for (last = 0; last < WARP_SZ; last++) {
                    if (!belongs_to_gpu[last] || seq_start[last] != new_ack_sent)
                        break;

                    if (connections[last] != conn)
                        continue;

                    new_ack_sent = seq_end[last];
                }

                if (last < WARP_SZ && belongs_to_gpu[last]) {
                    // Add OOO packets to OOO buffer
                    for (; last < WARP_SZ; last++) {
                        if (!belongs_to_gpu[last])
                            break;

                        if (connections[last] != conn)
                            continue;

                        conn->ooo_seq_start[conn->ooo_cnt] = seq_start[last];
                        conn->ooo_seq_end[conn->ooo_cnt] = seq_end[last];
                        conn->ooo_ack_seq[conn->ooo_cnt++] = ack_seq_shared[last];

                        recv_warp_stats.ooo_cnt++;
                    }

                    // Insertion sort
                    for (int i = 1; i < conn->ooo_cnt; i++) {
                        uint32_t start = conn->ooo_seq_start[i];
                        uint32_t end = conn->ooo_seq_end[i];
                        uint32_t ack_seq = conn->ooo_ack_seq[i];

                        int j = i - 1;
                        while (j >= 0 && (conn->ooo_seq_start[j] - conn->last_ack_sent) > (start - conn->last_ack_sent)) {
                            conn->ooo_seq_start[j + 1] = conn->ooo_seq_start[j];
                            conn->ooo_seq_end[j + 1] = conn->ooo_seq_end[j];
                            conn->ooo_ack_seq[j + 1] = conn->ooo_ack_seq[j];
                            j--;
                        }
                        conn->ooo_seq_start[j + 1] = start;
                        conn->ooo_seq_end[j + 1] = end;
                        conn->ooo_ack_seq[j + 1] = ack_seq;
                    }
                }

                for (last = 0; last < conn->ooo_cnt; last++) {
                    if (conn->ooo_seq_start[last] != new_ack_sent)
                        break;

                    new_ack_sent = conn->ooo_seq_end[last];
                }

                int new_ooo_cnt = 0;
                for (int i = 0; last < conn->ooo_cnt; i++, last++) {
                    conn->ooo_seq_start[i] = conn->ooo_seq_start[last];
                    conn->ooo_seq_end[i] = conn->ooo_seq_end[last];
                    conn->ooo_ack_seq[i] = conn->ooo_ack_seq[last];
                    new_ooo_cnt++;
                }
                if (OOO_USABLE < new_ooo_cnt)
                    new_ooo_cnt = OOO_USABLE;
                conn->ooo_cnt = new_ooo_cnt;
                if (conn->ooo_cnt) {
                    conn->ooo_ticks++;
                } else {
                    conn->ooo_ticks = 0;
                }
                if (conn->ooo_ticks >= OOO_FLUSH_FREQ) {
                    conn->ooo_cnt = 0;
                }

                uint32_t highest_ack_recv = conn->last_ack_recv;
                for (int i = 0; i < num_pkts_processed; i++) {
                    if (!belongs_to_gpu[i])
                        break;
                    if (connections[i] != conn)
                        continue;

                    uint32_t new_ack_seq = ack_seq_shared[i];
                    ;
                    if (new_ack_seq > highest_ack_recv || highest_ack_recv > conn->local_isn && new_ack_seq < conn->local_isn)
                        highest_ack_recv = new_ack_seq;
                }

                uint32_t to_advance = new_ack_sent - conn->last_ack_sent;
                conn->socket.rx_ring.head = (conn->socket.rx_ring.head + to_advance) % conn->socket.rx_ring.length;

                conn->last_ack_recv = highest_ack_recv;
                bool updated = false;
                while (conn->retransmit_head != conn->retransmit_tail && conn->retransmit_queue[conn->retransmit_tail].seq_end < highest_ack_recv) {
                    conn->retransmit_tail = (conn->retransmit_tail + 1) % RETRANSMIT_QUEUE_SZ;
                    updated = true;
                }
                if (updated)
                    conn->rto_start = now_sec(handle.gpu_freq_hz);

                conn->last_ack_sent = new_ack_sent;

                assert(conn->rwnd >= to_advance);
                conn->rwnd -= to_advance;

                conn->send_doorbell = true;

                // Jugaad of sorts. Let the first packet belonging to each connection do the processing
                for (int v = u + 1; v < num_pkts_processed; v++) {
                    if (connections[v] == connections[u])
                        belongs_to_gpu[v] = false;
                }
            }

            // Lets print some stats
            recv_warp_stats.rx_ring_used = (gdr_rhead - gdr_rtail + gdr_rsz) % gdr_rsz;
            double now = now_sec(handle.gpu_freq_hz);
            if ((now - recv_warp_stats.last_report) > STATS_INTERVAL_SEC) {
                printf(
                    "======= Recv Warp Stats [%.2f sec] =======\n"
                    "%-25s : %lld\n"
                    "%-25s : %d\n"
                    "%-25s : %lld\n"
                    "%-25s : %lld\n"
                    "%-25s : %lld\n\n",
                    now - recv_warp_stats.start_time,
                    "dest_is_gpu", recv_warp_stats.dest_is_gpu,
                    "invalid_checksum", recv_warp_stats.invalid_checksum,
                    "ooo_cnt", recv_warp_stats.ooo_cnt,
                    "rx_ring_used", recv_warp_stats.rx_ring_used,
                    "rx_ring_capacity", recv_warp_stats.rx_ring_capacity);

                recv_warp_stats.last_report = now;
            }
        }

        __syncwarp();
    }
}

__device__ void send_thread(int lane, handle_t handle)
{
    assert(lane == 0);

    volatile gdr_env_t* gdr_env = handle.gdr_env;
    tcp_env_t* tcp_env = handle.tcp_env;

    uint16_t ip_id = 13;

    __shared__ struct {
        long long retransmit_cnt;

        double start_time;
        double last_report;
    } send_thread_stats;
    if (lane == 0) {
        send_thread_stats.retransmit_cnt = 0;
        send_thread_stats.start_time = now_sec(handle.gpu_freq_hz);
        send_thread_stats.last_report = send_thread_stats.start_time;
    }

    while (!atomicAdd(&handle.tcp_env->exiting, 0)) {
    iteration_start:
        bool to_send = false;
        void* send_pkt_gpu_va;
        size_t send_pkt_length;
        bool send_pkt_rto_needed = false;
        uint32_t send_pkt_seq_end; // For tracking RTO
        int send_cnt = 1; // no of times to send this pkt

        /* Part 1: Wait for any of the following events to happen:
         * (1) send_doorbell is rung on a connection
         * (2) an operation is submitted on the sq
         * (3) RTO fires for some connection
         */
        const size_t conn_table_sz = sizeof(tcp_env->conn_table) / sizeof(tcp_env->conn_table[0]);

        bool event_doorbell = false;
        bool event_sq = false;
        bool event_rto = false;

        int retransmit_tail;

        connection_t* conn = NULL;
        connection_t* conn_table = tcp_env->conn_table;
        op_desc_t op_desc;
        while (!atomicAdd(&handle.tcp_env->exiting, 0)) {
            for (int i = 0; i < conn_table_sz; i++) {
                if (conn_table[i].established && conn_table[i].send_doorbell) {
                    event_doorbell = true;
                    conn = &conn_table[i];
                    conn->send_doorbell = false;
                }
            }
            if (event_doorbell)
                break;

            // HACK: Process sq entries after doorbell entries. This means before sending a
            // FIN we would've sent other packet data at least once.
            // This also means that a connection sending data can hog another thread trying
            // to create a new socket, etc.
            if (!is_empty(&tcp_env->submission_queue)) {
                op_desc = op_read(&tcp_env->submission_queue);
                event_sq = true;
                break;
            }

            double now = now_sec(handle.gpu_freq_hz);
            for (int i = 0; i < conn_table_sz; i++) {
                // save a copy in case recv_warp modifies it after we have read it
                retransmit_tail = conn_table[i].retransmit_tail;
                if (conn_table[i].rto_start != 0 && (now - conn_table[i].rto_start) > RTO_SEC
                    && conn_table[i].retransmit_head != retransmit_tail) {
                    event_rto = true;
                    conn = &conn_table[i];
                    conn_table[i].rto_start = now_sec(handle.gpu_freq_hz);
                }
            }

            if (event_rto)
                break;
        }

        /* Part 2: Process the event */
        if (event_sq) {
            assert(op_desc.opcode == opcode_t::CONNECT || op_desc.opcode == opcode_t::CLOSE);

            socket_t* sock;
            device_memcpy(&sock, op_desc.buffer, sizeof(socket_t*));

            op_desc_t cq_desc;
            cq_desc.id = op_desc.id;

            send_pkt_gpu_va = &tcp_env->pmem[tcp_env->alloc_idx];
            tcp_env->alloc_idx = (tcp_env->alloc_idx + TCP_PMEM_SLOT_SZ) % TCP_PMEM_SZ;

            conn = sock->conn;

            if (op_desc.opcode == opcode_t::CONNECT) {
                struct sockaddr_in peer_addr;
                device_memcpy(&peer_addr, &op_desc.buffer[8], sizeof(peer_addr));

                if (conn->established || conn->syn_sent) {
                    cq_desc.opcode = opcode_t::FAIL;
                    op_write(&tcp_env->completion_queue, cq_desc);
                    goto iteration_start;
                }
                conn->syn_sent = true;

                conn->peer_ip = peer_addr.sin_addr.s_addr;
                conn->local_ip = handle.nic_ip.s_addr;
                conn->peer_port = peer_addr.sin_port;

                static uint16_t ephemeral_port = EPHEMERAL_PORT_START;
                conn->local_port = htons_d(ephemeral_port++);
                conn->local_isn = (uint32_t)rand();
                conn->curr_local_seq = conn->local_isn + 1;
                conn->rwnd = sock->rx_ring.length;

                struct gpu_iphdr ip;
                struct gpu_tcphdr tcp;
                device_memset(&ip, 0, sizeof(ip));
                device_memset(&tcp, 0, sizeof(tcp));

                volatile struct iphdr* ip_raw = (struct iphdr*)send_pkt_gpu_va;
                volatile struct tcphdr* tcp_raw = (struct tcphdr*)(ip_raw + 1);

                ip_set_version(&ip, 4);
                ip_set_ihl(&ip, 5);
                ip.tos = 0;

                send_pkt_length = sizeof(struct iphdr) + sizeof(struct tcphdr) + 8;
                ip.tot_len = htons_d(send_pkt_length);
                ip.id = ip_id++;
                ip.frag_off = htons_d(IP_FRAG_OFF);
                ip.ttl = IP_TTL2;
                ip.protocol = IPPROTO_TCP;
                ip.check = 0; // compute later
                ip.saddr = conn->local_ip;
                ip.daddr = conn->peer_ip;

                tcp.source = conn->local_port;
                tcp.dest = conn->peer_port;
                tcp.seq = htonl_d(conn->local_isn);
                send_pkt_seq_end = conn->local_isn;

                tcp.window = htons_d(conn->rwnd / TCP_RWND_SCALE);
                tcp_set_doff(&tcp, (sizeof(struct tcphdr) + 8) / 4);
                tcp_set_flag(&tcp, TCP_FLAG_SYN);

                uint8_t* options = (uint8_t*)(tcp_raw + 1);

                uint16_t* mss = (uint16_t*)(options + 2);
                options[0] = 2;
                options[1] = 4;
                *mss = htons_d(TCP_ADVERTISED_MSS);

                uint8_t* rwnd_scaling = (uint8_t*)(options + 4);
                rwnd_scaling[0] = 3;
                rwnd_scaling[1] = 3;
                rwnd_scaling[2] = TCP_RWND_SCALE_LOG2;
                rwnd_scaling[3] = 0;

                ip_from_gpu(&ip, (struct iphdr*)ip_raw);
                tcp_from_gpu(&tcp, (struct tcphdr*)tcp_raw);

                iphdr_update_checksum(ip_raw);
                update_tcp_checksum(ip_raw);

                printf("SYN sent!\n");

                conn->pending_op_id = op_desc.id;
                to_send = true;
                send_cnt = 1;
                send_pkt_rto_needed = true;
            } else if (op_desc.opcode == opcode_t::CLOSE) {
                if (!conn->established || conn->fin_wait_1 || conn->syn_sent || conn->fin_wait_2) {
                    cq_desc.opcode = opcode_t::FAIL;
                    op_write(&tcp_env->completion_queue, cq_desc);
                    goto iteration_start;
                }

                conn->established = false;
                conn->syn_sent = false;
                conn->fin_wait_1 = true;

                struct gpu_iphdr ip;
                struct gpu_tcphdr tcp;
                device_memset(&ip, 0, sizeof(ip));
                device_memset(&tcp, 0, sizeof(tcp));

                struct iphdr* ip_raw = (struct iphdr*)send_pkt_gpu_va;
                struct tcphdr* tcp_raw = (struct tcphdr*)(ip_raw + 1);

                ip_set_version(&ip, 4);
                ip_set_ihl(&ip, 5);
                ip.tos = 0;

                send_pkt_length = sizeof(struct iphdr) + sizeof(struct tcphdr);
                ip.tot_len = htons_d(send_pkt_length);
                ip.id = ip_id++;
                ip.frag_off = htons_d(IP_FRAG_OFF);
                ip.ttl = IP_TTL2;
                ip.protocol = IPPROTO_TCP;
                ip.check = 0;
                ip.saddr = conn->local_ip;
                ip.daddr = conn->peer_ip;

                tcp.source = conn->local_port;
                tcp.dest = conn->peer_port;
                tcp.seq = htonl_d(conn->curr_local_seq);
                send_pkt_seq_end = conn->curr_local_seq;

                tcp.ack_seq = htonl_d(conn->last_ack_sent);
                tcp.window = htons_d(conn->rwnd / TCP_RWND_SCALE);
                tcp_set_doff(&tcp, sizeof(struct tcphdr) / 4);
                tcp_set_flag(&tcp, TCP_FLAG_FIN);
                tcp_set_flag(&tcp, TCP_FLAG_ACK);

                ip_from_gpu(&ip, ip_raw);
                tcp_from_gpu(&tcp, tcp_raw);

                iphdr_update_checksum(ip_raw);
                update_tcp_checksum((void*)ip_raw);

                conn->pending_op_id = op_desc.id;
                to_send = true;
                send_cnt = TCP_FIN_REPEAT_CNT;
            }
        } else if (event_doorbell) {
            if (!conn->established && !conn->fin_wait_1 && !conn->fin_wait_2)
                goto iteration_start;

            volatile tx_ring_t* sock_tx_ring = &conn->socket.tx_ring;
            size_t payload_length = (sock_tx_ring->head - sock_tx_ring->tail + sock_tx_ring->length)
                % sock_tx_ring->length;
            void* payload = NULL;
            if (payload_length > 0) {
                if (payload_length > TCP_MIN_MSS_POW2) {
                    payload_length = TCP_MIN_MSS_POW2;
                    conn->send_doorbell = true;
                }
                payload = (void*)&sock_tx_ring->buffer[sock_tx_ring->tail];
            }

            struct gpu_iphdr ip;
            struct gpu_tcphdr tcp;
            device_memset(&ip, 0, sizeof(ip));
            device_memset(&tcp, 0, sizeof(tcp));

            volatile struct iphdr* ip_raw = (struct iphdr*)send_pkt_gpu_va;
            volatile struct tcphdr* tcp_raw = (struct tcphdr*)(ip_raw + 1);
            void* payload_raw = (void*)(tcp_raw + 1);

            ip_set_version(&ip, 4);
            ip_set_ihl(&ip, 5);
            ip.tos = 0;

            size_t header_length = sizeof(struct tcphdr);
            send_pkt_length = sizeof(iphdr) + header_length + payload_length;
            ip.tot_len = htons_d(send_pkt_length);
            ip.id = ip_id++;
            ip.frag_off = htons_d(IP_FRAG_OFF);
            ip.ttl = IP_TTL2;
            ip.protocol = IPPROTO_TCP;
            ip.check = 0;
            ip.saddr = conn->local_ip;
            ip.daddr = conn->peer_ip;

            tcp.source = conn->local_port;
            tcp.dest = conn->peer_port;
            tcp.seq = htonl_d(conn->curr_local_seq);
            conn->curr_local_seq += payload_length;
            send_pkt_seq_end = conn->curr_local_seq - 1;

            tcp.ack_seq = htonl_d(conn->last_ack_sent);
            tcp.window = htons_d(conn->rwnd / TCP_RWND_SCALE);

            tcp_set_doff(&tcp, header_length / 4);
            tcp_set_flag(&tcp, TCP_FLAG_ACK);

            ip_from_gpu(&ip, (struct iphdr*)ip_raw);
            tcp_from_gpu(&tcp, (struct tcphdr*)tcp_raw);

            if (payload_length) {
                device_memcpy(payload_raw, payload, payload_length);
                sock_tx_ring->tail = (sock_tx_ring->tail + payload_length) % sock_tx_ring->length;
            }

            __threadfence_system();

            iphdr_update_checksum(ip_raw);
            update_tcp_checksum(ip_raw);

            if (conn->fin_wait_2) {
                // We are sending the ACK for the server's FIN
                conn->fin_wait_2 = false;
            }

            to_send = true;
            send_cnt = 1;
            send_pkt_rto_needed = true;
        } else if (event_rto) {
            volatile retransmit_frame_t* frame = &conn->retransmit_queue[retransmit_tail];

            send_pkt_gpu_va = frame->desc.gpu_va;
            send_pkt_length = frame->desc.length;
            to_send = true;
            send_cnt = 1;
        }

        /* Part 3: Finally! Send the packet out onto the tx ring */
        if (to_send) {
            for (int i = 0; i < send_cnt; i++) {
                volatile pkt_desc_t* desc = (volatile pkt_desc_t*)spsc_ring_offset(&gdr_env->tx_ring,
                    gdr_env->tx_ring.head);
                int next = (gdr_env->tx_ring.head + 1) % gdr_env->tx_ring.num_slots;
                int next_retransmit = (conn->retransmit_head + 1) % RETRANSMIT_QUEUE_SZ;
                if (next == gdr_env->tx_ring.tail) {
                    pr_error("gdr tx ring full!\n");
                } else if (!event_rto && next_retransmit == retransmit_tail) {
                    pr_error("conn->retransmit_queue is full, increase RETRANSMIT_QUEUE_SZ\n");
                } else {
                    desc->gpu_va = (void*)send_pkt_gpu_va;
                    desc->length = send_pkt_length;
                    desc->magic = GDR_MAGIC;

                    // NOTE: We need a fence here to ensure that head is not updated before the packet
                    // desc is written to global memory. Volatile is not enough.
                    // Despite this fence, there are cases when the desc magic is invalid, the tcp/ip
                    // checksum is invalid etc. So essentially this fence doesn't do its job very well
                    // for some reason.
                    __threadfence_system();

                    gdr_env->tx_ring.head = next;

                    if (conn->rto_start == 0)
                        conn->rto_start = now_sec(handle.gpu_freq_hz);

                    if (send_pkt_rto_needed) {
                        // add packet to retransmit queue, if it was not already a retransmission
                        volatile retransmit_frame_t* frame = &conn->retransmit_queue[conn->retransmit_head];
                        device_memcpy((void*)&frame->desc, (void*)desc, sizeof(frame->desc));
                        frame->seq_end = send_pkt_seq_end;
                        conn->retransmit_head = next_retransmit;
                    }

                    if (event_rto) {
                        send_thread_stats.retransmit_cnt++;
                    }
                }
            }
        }

        // lets print some stats
        double now = now_sec(handle.gpu_freq_hz);
        if ((now - send_thread_stats.last_report) > STATS_INTERVAL_SEC) {
            printf(
                "======= Send Thread Stats [%.2f sec] =======\n"
                "%-25s : %lld\n\n",
                now - send_thread_stats.start_time,
                "retransmit_cnt", send_thread_stats.retransmit_cnt);

            send_thread_stats.last_report = now;
        }
    }
}

// Small kernel to initialize structs held in device memory
__global__ void gdrtcp_init(handle_t handle)
{
    tcp_env_t* tcp_env = handle.tcp_env;
    tcp_env->exiting = 0;
    tcp_env->alloc_idx = 0;

    tcp_env->submission_queue.head = 0;
    tcp_env->submission_queue.tail = 0;
    tcp_env->submission_queue.buffer_length = CMD_QUEUE_SZ;
    tcp_env->submission_queue.slot_sz = OP_DESC_SLOT_SZ;
    tcp_env->submission_queue.num_slots = CMD_QUEUE_SZ / OP_DESC_SLOT_SZ;

    tcp_env->completion_queue.head = 0;
    tcp_env->completion_queue.tail = 0;
    tcp_env->completion_queue.buffer_length = CMD_QUEUE_SZ;
    tcp_env->completion_queue.slot_sz = OP_DESC_SLOT_SZ;
    tcp_env->completion_queue.num_slots = CMD_QUEUE_SZ / OP_DESC_SLOT_SZ;

    int conn_table_sz = sizeof(tcp_env->conn_table) / sizeof(tcp_env->conn_table[0]);
    for (int i = 0; i < conn_table_sz; i++) {
        connection_t* conn = &tcp_env->conn_table[i];
        conn->is_free = true;
        conn->syn_sent = false;
        conn->established = false;
        conn->fin_wait_1 = false;
        conn->fin_wait_2 = false;
        conn->send_doorbell = false;
        conn->ooo_cnt = 0;
        conn->ooo_ticks = 0;

        conn->retransmit_head = 0;
        conn->retransmit_tail = 0;
        conn->rto_start = 0;

        socket_t* socket = &conn->socket;
        socket->send_rst_hack = false;
        socket->rx_ring.length = RX_BUFFER_SZ;
        socket->tx_ring.length = TX_BUFFER_SZ;
    }
}

__device__ void benchmark_client(handle_t handle, struct sockaddr_in server_addr, size_t test_size)
{
    static_assert(sizeof(test_size) == 8);

    const size_t bytes_per_thread = 512;
    const size_t bytes_per_iteration = bytes_per_thread * blockDim.x;
    const long long num_iterations = test_size / bytes_per_iteration;

    __shared__ socket_t* sock;
    if (threadIdx.x == 0) {
        printf("Hello from benchmark client kernel, test size %lu, num_iterations %lld!\n", test_size, num_iterations);
        sock = socket_create(&handle, AF_INET, SOCK_STREAM);
        assert(sock != NULL);
        assert(socket_connect(&handle, sock, server_addr) == error_t::SUCCESS);

        slice_t slice = send_reserve(sock, sizeof(test_size), sizeof(test_size));
        assert(slice.length != 0);
        device_memcpy((void*)slice.addr, &test_size, sizeof(test_size));
        assert(send_complete(sock, slice) == error_t::SUCCESS);
    }

    __syncthreads();

    uint32_t offset = bytes_per_thread * threadIdx.x;
    uint32_t pos = offset;
    __shared__ slice_t slice;
    __shared__ uint32_t csums[cpu_env_t::block_dimension];

    if (threadIdx.x == 0) {
        for (int i = 0; i < sizeof(csums) / sizeof(csums[0]); i++) {
            csums[i] = 0;
        }
    }

    __syncthreads();

    for (int i = 0; i < num_iterations; i++) {
        if (threadIdx.x == 0) {
            do {
                slice = recv_slice(sock, bytes_per_iteration, bytes_per_iteration);
            } while (slice.length == 0);
        }
        __syncthreads();

        volatile uint8_t* addr = (volatile uint8_t*)slice.addr + offset;

        for (uint32_t j = 0; j < bytes_per_thread; j++) {
            uint32_t mul = pos + j;
            mul = mul ? mul : 1;
            csums[threadIdx.x] += ((uint32_t)(addr[j])) * mul;
        }

        pos += bytes_per_iteration;

        __syncthreads();

        if (threadIdx.x == 0) {
            assert(recv_release(sock, slice) == error_t::SUCCESS);
        }

        __syncthreads();
    }

    __syncthreads();

    if (threadIdx.x == 0) {
        uint32_t final_csum = 0;
        for (int i = 0; i < sizeof(csums) / sizeof(csums[0]); i++)
            final_csum += csums[i];

        printf("Benchmark complete, final checksum = %u\n", final_csum);

        slice_t slice = send_reserve(sock, sizeof(final_csum), sizeof(final_csum));
        assert(slice.length != 0);
        device_memcpy((void*)slice.addr, &final_csum, sizeof(final_csum));
        assert(send_complete(sock, slice) == error_t::SUCCESS);

        assert(socket_close(&handle, sock) == error_t::SUCCESS);
        assert(socket_destroy(&handle, sock) == error_t::SUCCESS);

        printf("Bye!\n");

        atomicAdd(&handle.tcp_env->exiting, 1);
    }

    __syncthreads();
}

__global__ void gdrtcp_main(handle_t handle,
    bool hack_launch_workload, struct sockaddr_in hack_server_addr, size_t hack_test_size)
{
    if (blockIdx.x == 0) {
        if (threadIdx.x < 32) {
            recv_warp(threadIdx.x, handle);
        } else if (threadIdx.x < 64) {
            if (threadIdx.x == 32)
                send_thread(threadIdx.x - 32, handle);
        }
    } else {
        if (hack_launch_workload)
            benchmark_client(handle, hack_server_addr, hack_test_size);
    }
}

// NOTE: hack_* is a temporary hack to control the launch of the gpu workload kernel.
// This is because we have hardcoded the user's kernel here, due to the issues faced with launching
// concurrent kernels.
error_t init(handle_t* handle, const char* network_interface,
    bool hack_launch_workload, struct sockaddr_in hack_server_addr,
    size_t hack_test_size)
{
    CUDA_CHECK(cudaSetDevice(0));

    error_t err = error_t::UNKNOWN;

    handle->cpu_env = (cpu_env_t*)calloc(1, sizeof(cpu_env_t));
    cpu_env_t* cpu_env = handle->cpu_env;
    if (!cpu_env) {
        fprintf(stderr, "Failed to allocate memory for cpu env\n");
        fflush(stderr);
        return error_t::FAILURE;
    }

    cpu_env->exiting = false;
    cpu_env->events_head = 0;
    cpu_env->events_tail = 0;

    CUDA_CHECK(cudaMalloc64KBAligned(&cpu_env->tcp_mem_unaligned, &cpu_env->tcp_mem_aligned, sizeof(tcp_env_t), GPU_PAGE_SIZE));

    if (strlen(network_interface) >= sizeof(cpu_env->interface)) {
        fprintf(stderr, "network interface name too long\n");
        err = error_t::INVAL;
        goto clean;
    }
    strcpy(handle->nic_interface, network_interface);
    strcpy(cpu_env->interface, network_interface);

    struct ifaddrs* ifap;
    if (getifaddrs(&ifap)) {
        perror("getifaddrs");
        err = error_t::FAILURE;
        goto clean;
    }

    bool valid_interface_found;
    valid_interface_found = false;
    for (; ifap != NULL; ifap = ifap->ifa_next) {
        if (!strcmp(ifap->ifa_name, network_interface)) {
            if (ifap->ifa_addr == NULL) {
                continue;
            }
            if (ifap->ifa_addr->sa_family != AF_INET) {
                continue;
            }
            struct sockaddr_in* addr = (struct sockaddr_in*)ifap->ifa_addr;
            handle->nic_ip = addr->sin_addr;
            valid_interface_found = true;
        }
    }

    if (!valid_interface_found) {
        fprintf(stderr, "No interface %s exists, or there is no IPv4 address assigned to this interface!\n", network_interface);
        err = error_t::FAILURE;
        goto clean;
    }

    snprintf(cpu_env->devname_setup, sizeof(cpu_env->devname_setup), "/dev/%s_setup", network_interface);
    snprintf(cpu_env->devname_redirect, sizeof(cpu_env->devname_redirect), "/dev/%s_redirect", network_interface);
    snprintf(cpu_env->devname_inject, sizeof(cpu_env->devname_inject), "/dev/%s_inject", network_interface);
    snprintf(cpu_env->devname_tx, sizeof(cpu_env->devname_tx), "/dev/%s_tx", network_interface);

    int len;

    CUDA_CHECK(cudaStreamCreate(&cpu_env->gdr_stream));
    len = sizeof(cpu_env->copy_streams) / sizeof(cpu_env->copy_streams[0]);
    for (int i = 0; i < len; i++) {
        CUDA_CHECK(cudaStreamCreate(&cpu_env->copy_streams[i]));
    }

    len = sizeof(cpu_env->copy_events) / sizeof(cpu_env->copy_events[0]);
    for (int i = 0; i < len; i++) {
        CUDA_CHECK(cudaEventCreate(&cpu_env->copy_events[i]));
    }

    CUDA_CHECK(cudaMalloc64KBAligned(&cpu_env->cmem_unaligned, &cpu_env->cmem_aligned, CMEM_SZ, GPU_PAGE_SIZE));
    CUDA_CHECK(cudaMalloc64KBAligned(&cpu_env->pmem_unaligned, &cpu_env->pmem_aligned, PMEM_SZ, GPU_PAGE_SIZE));
    CUDA_CHECK(cudaMemset(cpu_env->cmem_aligned, 0, CMEM_SZ));

    // NOTE: These functions are the driver api, not the runtime api. We can safely use the runtime api
    // across multiple host threads since the cuda context stuff is transparently managed, but need to be careful
    // when using driver api functions across differing host threads. Since these are the only driver api functions
    // we are using and the memory was allocated in this thread, there shouldn't be any problems here.
    unsigned int flag;
    flag = 1;
    CU_CHECK(cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS, (CUdeviceptr)cpu_env->cmem_aligned));
    flag = 1;
    CU_CHECK(cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS, (CUdeviceptr)cpu_env->pmem_aligned));

    cpu_env->fd_setup = open(cpu_env->devname_setup, O_RDWR);
    if (cpu_env->fd_setup < 0) {
        fprintf(stderr, "Is the modified NIC driver loaded on interface %s?\n", cpu_env->interface);
        perror("open setup");
        err = error_t::INVAL;
        goto clean;
    }

    gdr_mem_setup_t setup;
    setup.cmem_addr = cpu_env->cmem_aligned;
    setup.cmem_length = CMEM_SZ;
    setup.pmem_addr = cpu_env->pmem_aligned;
    setup.pmem_length = PMEM_SZ;
    setup.magic = GDR_MAGIC;

    if (write(cpu_env->fd_setup, &setup, sizeof(setup)) != sizeof(setup)) {
        fprintf(stderr, "Failed to write memory setup to char dev %s\n", cpu_env->devname_setup);
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->fd_redirect = open(cpu_env->devname_redirect, O_RDWR);
    if (cpu_env->fd_redirect < 0) {
        perror("open redirect");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->fd_inject = open(cpu_env->devname_inject, O_RDWR);
    if (cpu_env->fd_inject < 0) {
        perror("open inject");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->fd_tx = open(cpu_env->devname_tx, O_RDWR);
    if (cpu_env->fd_tx < 0) {
        perror("open tx");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->redirect_mem = mmap(0, cpu_env_t::REDIRECT_MEM_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, cpu_env->fd_redirect, 0);
    if (cpu_env->redirect_mem == MAP_FAILED) {
        perror("mmap redirect");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->inject_mem = mmap(0, cpu_env_t::INJECT_MEM_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, cpu_env->fd_inject, 0);
    if (cpu_env->inject_mem == MAP_FAILED) {
        perror("mmap inject");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->tx_mem = mmap(0, cpu_env_t::TX_MEM_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, cpu_env->fd_tx, 0);
    if (cpu_env->tx_mem == MAP_FAILED) {
        perror("mmap tx");
        err = error_t::FAILURE;
        goto clean;
    }

    cpu_env->fd_raw_socket = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
    if (cpu_env->fd_raw_socket < 0) {
        perror("socket");
        err = error_t::FAILURE;
        goto clean;
    }

    int one;
    one = 1;
    if (setsockopt(cpu_env->fd_raw_socket, IPPROTO_IP, IP_HDRINCL, &one, sizeof(one)) < 0) {
        perror("setsockopt");
        err = error_t::FAILURE;
        goto clean;
    }
    assert(setsockopt(cpu_env->fd_raw_socket, SOL_SOCKET, SO_BINDTODEVICE, network_interface, 4) >= 0);
    int tos;
    tos = IPTOS_LOWDELAY;
    assert(setsockopt(cpu_env->fd_raw_socket, IPPROTO_IP, IP_TOS, &tos, sizeof(tos)) >= 0);
    int prio;
    prio = 6;
    assert(setsockopt(cpu_env->fd_raw_socket, SOL_SOCKET, SO_PRIORITY, &prio, sizeof(prio)) >= 0);

    // Pins the memory. Allows for GPU's copy engine to directly dma into host buffers instead of staging copy in
    // some intermediate buffer
    CUDA_CHECK(cudaHostRegister((void*)cpu_env->inject_mem, cpu_env_t::INJECT_MEM_SZ, cudaHostRegisterDefault));

    volatile spsc_ring_t *redirect_ring, *inject_ring, *tx_ring;
    redirect_ring = (volatile spsc_ring_t*)cpu_env->redirect_mem + 1;
    inject_ring = (volatile spsc_ring_t*)cpu_env->inject_mem;
    tx_ring = (volatile spsc_ring_t*)cpu_env->tx_mem + 2;
    if (redirect_ring->magic != GDR_MAGIC) {
        fprintf(stderr, "Invalid magic in redirect ring!\n");
        err = error_t::FAILURE;
        goto clean;
    }
    if (inject_ring->magic != GDR_MAGIC) {
        fprintf(stderr, "Invalid magic on inject ring!\n");
        err = error_t::FAILURE;
        goto clean;
    }
    if (tx_ring->magic != GDR_MAGIC) {
        fprintf(stderr, "Invalid magic on tx ring!\n");
        err = error_t::FAILURE;
        goto clean;
    }

    cudaDeviceProp device_properties;
    CUDA_CHECK(cudaGetDeviceProperties_v2(&device_properties, 0));

    handle->gpu_freq_hz = device_properties.clockRate * 1000.0;

    volatile gdr_env_t* gdr_env;
    gdr_env = (volatile gdr_env_t*)cpu_env->cmem_aligned;

    tcp_env_t* tcp_env;
    tcp_env = (tcp_env_t*)cpu_env->tcp_mem_aligned;

    handle->tcp_env = tcp_env;
    handle->gdr_env = gdr_env;

    cpu_env->exiting = false;

    gdrtcp_init<<<1, 1, 0, cpu_env->gdr_stream>>>(*handle);
    cudaStreamSynchronize(cpu_env->gdr_stream);

    if (pthread_create(&cpu_env->gdr_thread, NULL, gdr_thread, cpu_env)) {
        fprintf(stderr, "Failed to create gdr thread\n");
        err = error_t::FAILURE;
        goto clean;
    }

    // NIC takes time to reset after gdr has been enabled
    sleep(NIC_RESET_SEC);

    cpu_stats.start_time = now_sec();
    cpu_stats.last_report = now_sec();

    // TODO: Check for errors after kernel launch? (peek error or smth)
    gdrtcp_main<<<cpu_env_t::grid_dimension, cpu_env_t::block_dimension, 0, cpu_env->gdr_stream>>>(*handle,
        hack_launch_workload, hack_server_addr, hack_test_size);

    return error_t::SUCCESS;

clean:
    // TODO: Ah screw freeing cuda memory, too much casework
    free(cpu_env);
    fflush(stdout);
    fflush(stderr);
    return err;
}

error_t destroy(handle_t* handle)
{
    handle->cpu_env->exiting = true;
    assert(!pthread_join(handle->cpu_env->gdr_thread, NULL));
    return error_t::SUCCESS;
}

__device__ socket_t* socket_create(handle_t* handle, int domain, int type)
{
    // BUG: Need a lock in the connection table, or some other design.
    // What if multiple threads concurrently call socket()?
    if (domain != AF_INET || type != SOCK_STREAM)
        return NULL;

    tcp_env_t* env = handle->tcp_env;
    int sz = sizeof(env->conn_table) / sizeof(env->conn_table[0]);
    for (int i = 0; i < sz; i++) {
        if (env->conn_table[i].is_free) {
            env->conn_table[i].is_free = false;
            env->conn_table[i].socket.conn = &env->conn_table[i];

            return &env->conn_table[i].socket;
        }
    }
    return NULL;
}

__device__ error_t socket_destroy(handle_t* handle, socket_t* socket)
{
    connection_t* conn = socket->conn;
    if (conn->established)
        return error_t::INVAL;

    conn->is_free = true;
    return error_t::SUCCESS;
}

__device__ error_t socket_connect(handle_t* handle, socket_t* socket, struct sockaddr_in addr)
{
    tcp_env_t* env = handle->tcp_env;
    if (is_full(&env->submission_queue))
        return error_t::TRYAGAIN;

    op_desc_t desc;
    desc.opcode = opcode_t::CONNECT;
    desc.id = atomicAdd(&library_op_id, 1);

    char* ptr = (char*)desc.buffer;
    device_memcpy(ptr, &socket, sizeof(socket_t*));
    ptr += sizeof(socket_t*);

    device_memcpy(ptr, &addr, sizeof(struct sockaddr_in));

    op_write(&env->submission_queue, desc);

    desc = op_read_id(&env->completion_queue, desc.id);
    if (desc.opcode != opcode_t::SUCCESS)
        return error_t::FAILURE;

    return error_t::SUCCESS;
}

__device__ error_t socket_close(handle_t* handle, socket_t* socket)
{
    tcp_env_t* env = handle->tcp_env;
    if (is_full(&env->submission_queue))
        return error_t::TRYAGAIN;
    assert(is_empty(&env->completion_queue));

    op_desc_t desc;
    desc.opcode = opcode_t::CLOSE;
    desc.id = atomicAdd(&library_op_id, 1);

    char* ptr = (char*)desc.buffer;
    device_memcpy(ptr, &socket, sizeof(socket_t*));

    op_write(&env->submission_queue, desc);

    desc = op_read_id(&env->completion_queue, desc.id);
    if (desc.opcode != opcode_t::SUCCESS)
        return error_t::FAILURE;
    return error_t::SUCCESS;
}

__device__ slice_t recv_slice(socket_t* socket, int min_len, int max_len)
{
    slice_t slice;
    slice.length = 0;

    if (min_len >= socket->rx_ring.length)
        return slice;

    volatile rx_ring_t* rx_ring = &socket->rx_ring;
    int ring_sz = rx_ring->length;

    if (__builtin_popcount(min_len) != 1
        || __builtin_popcount(max_len) != 1)
        return slice;

    int ready = (rx_ring->head - socket->rx_effective_tail + ring_sz) % ring_sz;
    ready = 1 << (31 - __builtin_clz(ready));

    if (ready < min_len)
        return slice;

    if (max_len < ready)
        ready = max_len;

    slice.addr = &rx_ring->buffer[socket->rx_effective_tail];
    socket->rx_effective_tail = (socket->rx_effective_tail + ready) % ring_sz;
    slice.length = ready;

    return slice;
}

__device__ error_t recv_release(socket_t* socket, slice_t slice)
{
    volatile rx_ring_t* rx_ring = &socket->rx_ring;
    int ring_sz = rx_ring->length;
    int offset = (volatile uint8_t*)slice.addr - rx_ring->buffer;

    if (offset >= ring_sz)
        return error_t::INVAL;

    int new_tail = (offset + slice.length) % ring_sz;
    int old_tail = rx_ring->tail;
    int head = rx_ring->head;

    int new_ready = (head - new_tail + ring_sz) % ring_sz;
    int old_ready = (head - old_tail + ring_sz) % ring_sz;

    if (new_ready < old_ready)
        rx_ring->tail = new_tail;

    socket->conn->rwnd += slice.length;

    return error_t::SUCCESS;
}

__device__ slice_t send_reserve(socket_t* socket, int min_len, int max_len)
{
    slice_t slice;
    slice.length = 0;

    volatile tx_ring_t* tx_ring = &socket->tx_ring;
    int ring_sz = tx_ring->length;

    if (__builtin_popcount(min_len) != 1 || __builtin_popcount(max_len) != 1)
        return slice;

    int available = (ring_sz - 1) - ((socket->tx_effective_head - tx_ring->tail + ring_sz) % ring_sz);
    available = 1 << (31 - __builtin_clz(available));
    if (available < min_len)
        return slice;

    if (max_len < available)
        available = max_len;

    slice.addr = &tx_ring->buffer[socket->tx_effective_head];
    slice.length = available;
    socket->tx_effective_head = (socket->tx_effective_head + available) % ring_sz;

    return slice;
}

__device__ error_t send_complete(socket_t* socket, slice_t slice)
{
    volatile tx_ring_t* tx_ring = &socket->tx_ring;
    int ring_sz = tx_ring->length;
    int offset = (volatile uint8_t*)slice.addr - tx_ring->buffer;

    if (offset >= ring_sz)
        return error_t::INVAL;

    int new_head = (offset + slice.length) % ring_sz;
    int old_head = tx_ring->head;
    int tail = tx_ring->tail;

    int new_ready = (new_head - tail + ring_sz) % ring_sz;
    int old_ready = (old_head - tail + ring_sz) % ring_sz;
    if (new_ready > old_ready) {
        tx_ring->head = new_head;
        socket->conn->send_doorbell = true;
    }

    return error_t::SUCCESS;
}

}
