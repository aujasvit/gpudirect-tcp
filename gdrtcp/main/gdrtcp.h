// gdrtcp.h
// GPUDirect TCP - Hello123
// created on 7/4/26

#ifndef _GDRTCP_CUH
#define _GDRTCP_CUH

#include "helpers.cuh"
#include "gdr_common.h"

#include <cstdio>
#include <cuda_runtime_api.h>
#include <driver_types.h>
#include <fcntl.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/types.h>
#include <net/if.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

namespace gdrtcp {

#define WARP_SZ 32

#define STATS_INTERVAL_SEC 5
#define NIC_RESET_SEC 3

#define MAX_WAIT_ITERATIONS 20

#define EPHEMERAL_PORT_START 6969
#define LOCAL_ISN 12345 // should ideally be randomized, but this is OK for our purposes
#define IP_FRAG_OFF (0x4000 | 0) // Don't fragment
#define IP_TTL2 64

#define TCP_RWND_SCALE_LOG2 5
#define TCP_RWND_SCALE (1 << TCP_RWND_SCALE_LOG2)
#define TCP_ADVERTISED_MSS 1460
#define TCP_FIN_REPEAT_CNT 3

#define RETRANSMIT_QUEUE_SZ 512
#define RTO_SEC 2

// We use the minimum MSS which must be supported by all links instead of
// doing path MTU discovery etc.
#define TCP_MIN_MSS 536
// As our buffers are ring buffers, we don't want to deal with segments which are partially
// at the end and partially in the start. Lets do everything in powers of 2
#define TCP_MIN_MSS_POW2 512

#define OOO_FLUSH_FREQ 8
#define OOO_SIZE 96
#define OOO_USABLE (OOO_SIZE - WARP_SZ) // Buffer these many OOO packets per connection

#define pr_error(fmt, ...) \
    printf("\033[31m" fmt "\033[0m", ##__VA_ARGS__)

// Add those constants here which can be tuned/changed (within reasonable limits ofc)
// without modifying actual gdrtcp code
namespace config {
    // no. of copy engines on GPU
    // TODO: quadro p620 has 2, but looks like they are not bidirectional, i.e one for
    // D2H and one for H2D, so this should be 1?
    constexpr int COPY_ENGINES_CNT = 2;
    constexpr int COPY_EVENT_RING_SZ = 32;
}

enum class error_t {
    UNKNOWN = 0,
    SUCCESS,
    FAILURE,
    TRYAGAIN,
    INVAL,
};

enum class opcode_t : int {
    UNKNOWN = 0,
    CONNECT,
    CLOSE,
    SUCCESS,
    FAIL
};

__device__ static inline long long rand() 
{
    // Good enough xD
    return clock64();
}

template <size_t LEN, size_t SLOT_SZ>
struct mpmc_ring_t {
    // Use atomic*() functions to read/write from head/tail
    // If using as SPSC, check if PTX memory model ensures no tears
    // with normal reads/writes on a volatile int
    // BUG: Just using volatile for now, switch to proper atomics when actually 
    // working with multiple producers/consumers
    volatile int head;
    volatile int tail;

    size_t buffer_length;
    size_t slot_sz;
    int num_slots;

    uint8_t buffer[LEN];
};

#define OP_DESC_SZ 24
struct op_desc_t {
    opcode_t opcode;
    uint32_t id;
    uint8_t buffer[OP_DESC_SZ];
};
#define OP_DESC_SLOT_SZ 32
static_assert(sizeof(void*) + sizeof(struct sockaddr_in) <= OP_DESC_SZ);
static_assert(sizeof(op_desc_t) == OP_DESC_SLOT_SZ);

#define CMD_QUEUE_SZ 64
using op_queue_t = mpmc_ring_t<CMD_QUEUE_SZ, OP_DESC_SLOT_SZ>;

__device__ static inline bool is_full(op_queue_t* queue)
{
    return ((queue->head + 1) % queue->num_slots) == queue->tail;
}

__device__ static inline bool is_empty(op_queue_t* queue)
{
    return (queue->head == queue->tail);
}

__device__ static inline void op_write(op_queue_t* queue, op_desc_t desc)
{
    int idx = queue->head;
    device_memcpy(&queue->buffer[queue->slot_sz * idx], &desc, sizeof(desc));
    queue->head = (idx + 1) % queue->num_slots;
}

__device__ static inline op_desc_t op_read(op_queue_t* queue)
{
    op_desc_t desc;
    int idx = queue->tail;
    device_memcpy(&desc, &queue->buffer[queue->slot_sz * idx], sizeof(desc));
    queue->tail = (idx + 1) % queue->num_slots;
    return desc;
}

// Blocking
__device__ static inline op_desc_t op_read_id(op_queue_t* queue, uint32_t id) {
    op_desc_t desc;
    int idx;
    do {
        while (is_empty(queue))
            ;

        idx = queue->tail;
        device_memcpy(&desc, &queue->buffer[queue->slot_sz * idx], sizeof(desc));
    } while (desc.id != id);
    atomicAdd((int*)&queue->tail, 1);
    return desc;
}

template <int LEN>
struct ring_buffer_t {
    int head;
    int tail;

    int length;
    uint8_t buffer[LEN];
};

#define RX_BUFFER_SZ (1 << 19) 
#define TX_BUFFER_SZ (1 << 12) 
using rx_ring_t = ring_buffer_t<RX_BUFFER_SZ>;
using tx_ring_t = ring_buffer_t<TX_BUFFER_SZ>;

struct connection_t;

struct socket_t {
    volatile bool send_rst_hack;

    volatile rx_ring_t rx_ring;
    int rx_effective_tail;

    volatile tx_ring_t tx_ring;
    int tx_effective_head;

    connection_t* conn;
};

struct retransmit_frame_t {
    pkt_desc_t desc;
    uint32_t seq_end;
};

struct connection_t {
    volatile bool is_free;
    volatile bool syn_sent;
    volatile bool established;
    volatile bool fin_wait_1;
    volatile bool fin_wait_2;

    volatile uint32_t pending_op_id;

    __be32 peer_ip;
    __be32 local_ip;
    __be16 peer_port;
    __be16 local_port;

    // Need to use uint32_t, not int! sequence no. rolls over
    uint32_t peer_isn;
    uint32_t local_isn;
    volatile uint32_t last_ack_sent;
    volatile uint32_t last_ack_recv;
    volatile uint32_t curr_local_seq;

    volatile uint32_t rwnd; // when creating set rwnd = rx ring size

    volatile bool send_doorbell;

    socket_t socket;

    volatile retransmit_frame_t retransmit_queue[RETRANSMIT_QUEUE_SZ];
    volatile int retransmit_head, retransmit_tail;

    volatile double rto_start;

    uint32_t ooo_seq_start[OOO_SIZE];
    uint32_t ooo_seq_end[OOO_SIZE];
    uint32_t ooo_ack_seq[OOO_SIZE];
    uint32_t ooo_ticks;
    int ooo_cnt;
};

#define CONNECTION_TABLE_SZ 1
#define TCP_PMEM_SLOT_SZ 2048
#define TCP_PMEM_NUM_SLOTS 1024
#define TCP_PMEM_SZ (TCP_PMEM_NUM_SLOTS * TCP_PMEM_SLOT_SZ)

struct tcp_env_t {
    uint8_t pmem[TCP_PMEM_SZ];
    int alloc_idx;

    op_queue_t submission_queue;
    op_queue_t completion_queue;

    connection_t conn_table[CONNECTION_TABLE_SZ];

    int exiting;
};

// NOTE: Naming of the environment structs.
// (1) cpu_env_t: holds data in ram, mostly relevant to relaying info b/w gpu and nic
// (2) gdr_env_t: holds data in gpu memory, relevant for nic <-> gpu and gpu <-> cpu
//      communications, i.e for gpudirect transfer of packets (rx ring, redirect ring)
// (3) tcp_env_t: holds data in gpu memory, maintains data relevant to tcp operation

// NOTE: Memory for the various structs is allocated using some sort of malloc.. dont rely on
// default initialization of member variables, cpp style.

struct cpu_env_t {
    pthread_t gdr_thread;
    cudaStream_t gdr_stream;
    volatile bool exiting;

    char interface[IFNAMSIZ];

    char devname_setup[IFNAMSIZ + 16];
    char devname_redirect[IFNAMSIZ + 16];
    char devname_inject[IFNAMSIZ + 16];
    char devname_tx[IFNAMSIZ + 16];

    int fd_setup;
    int fd_redirect;
    int fd_inject;
    int fd_tx;

    void* cmem_aligned; // control memory, 64KB aligned
    void* pmem_aligned; // packet memory, 64KB aligned

    // unaligned pointers, to pass to cudaFree
    void* cmem_unaligned;
    void* pmem_unaligned;

    static constexpr int REDIRECT_MEM_SZ = (CPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ);
    volatile void* redirect_mem; // MMIO mapped to GPU memory

    static constexpr int TX_MEM_SZ = (CPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ);
    volatile void* tx_mem; // MMIO mapped to GPU memory

    static constexpr int INJECT_MEM_SZ = IMEM_SZ;
    volatile void* inject_mem; // Mapped to kernel vmalloc'd memory

    cudaStream_t copy_streams[config::COPY_ENGINES_CNT];
    cudaEvent_t copy_events[config::COPY_EVENT_RING_SZ];
    int events_head, events_tail;

    int fd_raw_socket;

    // NOTE: We only need one thread block for gdrtcp. However because of the concurrent kernel launch issue 
    // we are hardcoding the benchmark client kernel launch, so lets do that on a separate thread block.
    static constexpr int grid_dimension = 2;
    static constexpr int block_dimension = 64;

    void* tcp_mem_aligned;
    void* tcp_mem_unaligned;
};

struct handle_t {
    char nic_interface[IFNAMSIZ];
    struct in_addr nic_ip;
    double gpu_freq_hz;

    // Host pointers
    cpu_env_t* cpu_env;

    // Device pointers
    volatile gdr_env_t* gdr_env;
    tcp_env_t* tcp_env;
};

typedef struct _slice {
    volatile void* addr; // MUST point to global memory
    int length; // MUST be zero (empty slice) or a power of two (to divide buffer length to avoid invalid addr, its a ring buffer)
} slice_t;

// NOTE: GPUDirect TCP and the user will live in different kernels. Be careful not to share pointers to memory
// which is not global (which is basically everything not explicitly allocated in host).

// NOTE: hack_* is a temporary hack to control the launch of the gpu workload kernel.
// This is because we have hardcode the user's kernel here, due to the issues faced with launching 
// concurrent kernels.
error_t init(handle_t* handle, const char* network_interface, 
        bool hack_launch_workload, struct sockaddr_in hack_server_addr, size_t hack_test_size);
error_t destroy(handle_t* handle);

__device__ socket_t* socket_create(handle_t* handle, int domain, int type);
__device__ error_t socket_destroy(handle_t* handle, socket_t* socket);

__device__ error_t socket_connect(handle_t* handle, socket_t* socket, struct sockaddr_in addr);
__device__ error_t socket_close(handle_t* handle, socket_t* socket);

// min_len, max_len must be powers of 2. Slice sizes are always powers of two
__device__ slice_t recv_slice(socket_t* socket, int min_len, int max_len);
//__device__ error_t recv_slice(socket_t* socket, slice_t* slice, int min_len, int max_len);
// NOTE: release() releases all memory till the end of the slice, even if there was a slice preceding
// the passed slice which was not explicitly freed
__device__ error_t recv_release(socket_t* socket, slice_t slice);

// min_len, max_len must be powers of two
__device__ slice_t send_reserve(socket_t* socket, int min_len, int max_len);
// NOTE: send_complete() sends all data till end of the slice, even if there was a slice preceding
// the passed slice which was not explicitly completed
__device__ error_t send_complete(socket_t* socket, slice_t slice);

}

#endif // _GDRTCP_CUH
