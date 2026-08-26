// helpers.cuh
// GPUDirect TCP - Hello123
// created on 8/4/26

#pragma once

#include <cstdint>
#include <cuda.h>
#include <stdio.h>
#include <cuda_runtime_api.h>
#include <cassert>
#include <arpa/inet.h>
#include <stdint.h>
#include <linux/ip.h>
#include <linux/tcp.h>

// gpt generated
static inline uint16_t checksum(uint16_t* ptr, int nbytes)
{
    uint32_t sum = 0;

    while (nbytes > 1) {
        sum += *ptr++;
        nbytes -= 2;
    }

    if (nbytes == 1) {
        sum += *((uint8_t*)ptr);
    }

    // fold 32 -> 16
    while (sum >> 16)
        sum = (sum & 0xffff) + (sum >> 16);

    return (uint16_t)(~sum);
}

// gpt generated
static inline int verify_ip_tcp_checksums(const void* packet, size_t len)
{
    if (len < sizeof(struct iphdr)) {
        fprintf(stderr, "Packet too small for IP header\n");
        return -1;
    }

    const struct iphdr* iph = (const struct iphdr*)packet;

    if (iph->version != 4) {
        fprintf(stderr, "Not IPv4\n");
        return -2;
    }

    size_t iphdr_len = iph->ihl * 4;

    if (len < iphdr_len + sizeof(struct tcphdr)) {
        fprintf(stderr, "Packet too small for TCP\n");
        return -3;
    }

    // ---------------- IP CHECKSUM ----------------
    uint16_t original_ip_check = iph->check;

    struct iphdr ip_copy;
    memcpy(&ip_copy, iph, iphdr_len);
    ip_copy.check = 0;

    uint16_t computed_ip_check = checksum((uint16_t*)&ip_copy, iphdr_len);

    if (original_ip_check != computed_ip_check) {
        fprintf(stderr,
            "IP checksum mismatch: got=0x%04x expected=0x%04x\n",
            ntohs(original_ip_check), ntohs(computed_ip_check));
        return -4;
    }

    // ---------------- TCP CHECKSUM ----------------
    const struct tcphdr* tcph = (const struct tcphdr*)((const uint8_t*)packet + iphdr_len);

    size_t tcp_len = ntohs(iph->tot_len) - iphdr_len;

    if (tcp_len < sizeof(struct tcphdr)) {
        fprintf(stderr, "Invalid TCP length\n");
        return -5;
    }

    uint16_t original_tcp_check = tcph->check;

    // Build pseudo-header
    struct pseudo_header {
        uint32_t src;
        uint32_t dst;
        uint8_t zero;
        uint8_t protocol;
        uint16_t len;
    } psh;

    psh.src = iph->saddr;
    psh.dst = iph->daddr;
    psh.zero = 0;
    psh.protocol = IPPROTO_TCP;
    psh.len = htons(tcp_len);

    size_t psize = sizeof(psh) + tcp_len;
    uint8_t* buf = (uint8_t*)malloc(psize);
    if (!buf) {
        perror("malloc");
        return -6;
    }

    memcpy(buf, &psh, sizeof(psh));
    memcpy(buf + sizeof(psh), tcph, tcp_len);

    // zero checksum field before computing
    struct tcphdr* tcph_copy = (struct tcphdr*)(buf + sizeof(psh));
    tcph_copy->check = 0;

    uint16_t computed_tcp_check = checksum((uint16_t*)buf, psize);

    free(buf);

    if (original_tcp_check != computed_tcp_check) {
        fprintf(stderr,
            "TCP checksum mismatch: got=0x%04x expected=0x%04x\n",
            ntohs(original_tcp_check), ntohs(computed_tcp_check));
        return -7;
    }

    return 0; // success
}

__device__ static inline uint16_t ip_checksum(const void* buf, size_t hdr_len)
{
    const uint16_t* data = (const uint16_t*)buf;
    uint32_t sum = 0;

    // Sum 16-bit words
    while (hdr_len > 1) {
        sum += *data++;
        hdr_len -= 2;
    }

    // Handle possible odd byte (shouldn't occur for IPv4 header, but safe)
    if (hdr_len == 1) {
        sum += *((const uint8_t*)data);
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (uint16_t)(~sum);
}

// gpt generated
__device__ static inline void iphdr_update_checksum(volatile struct iphdr* iph)
{
    iph->check = 0;
    iph->check = ip_checksum((void*)iph, iph->ihl * 4);
}

// For runtime api
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

// For driver api
#define CU_CHECK(expr)                                      \
    do {                                                    \
        CUresult result = (expr);                           \
        if (result != CUDA_SUCCESS) {                       \
            const char* errName = NULL;                     \
            const char* errStr = NULL;                      \
            cuGetErrorName(result, &errName);               \
            cuGetErrorString(result, &errStr);              \
            fprintf(stderr,                                 \
                "CUDA Driver Error: %s:%d: %s (%d) - %s\n", \
                __FILE__,                                   \
                __LINE__,                                   \
                errName ? errName : "UNKNOWN",              \
                result,                                     \
                errStr ? errStr : "No description");        \
            fflush(stderr);                                 \
            exit(1);                                        \
        }                                                   \
    } while (0)

// gpt generated
__device__ __forceinline__ void* device_memcpy(void* dst, const void* src, size_t n)
{
    unsigned char* d = static_cast<unsigned char*>(dst);
    const unsigned char* s = static_cast<const unsigned char*>(src);

    for (size_t i = 0; i < n; ++i)
        d[i] = s[i];

    return dst;
}

// gpt generate
__device__ __forceinline__ void* device_memset(void* ptr, int value, size_t num)
{
    unsigned char* p = static_cast<unsigned char*>(ptr);
    unsigned char v = static_cast<unsigned char>(value);

    for (size_t i = 0; i < num; ++i)
    {
        p[i] = v;
    }

    return ptr;
}

static inline cudaError_t cudaMalloc64KBAligned(void** rawPtr, void** alignedPtr, size_t size, size_t alignment)
{
    void* raw_ptr = nullptr;
    cudaError_t err = cudaMalloc(&raw_ptr, size + alignment);
    if (err != cudaSuccess)
        return err;

    uintptr_t addr = (uintptr_t)raw_ptr;
    uintptr_t aligned_addr = (addr + (alignment - 1)) & ~(alignment - 1);

    *rawPtr = (void*)addr;
    *alignedPtr = (void*)aligned_addr;
    return cudaSuccess;
}

// ntohs, ntohl, htons, htonl generated by gpt
__device__ __forceinline__
    uint16_t
    htons_d(uint16_t x)
{
    return (uint16_t)((x >> 8) | (x << 8));
}

__device__ __forceinline__
    uint16_t
    ntohs_d(uint16_t x)
{
    return htons_d(x);
}

__device__ __forceinline__
    uint32_t
    htonl_d(uint32_t x)
{
    return ((x & 0x000000FFu) << 24) | ((x & 0x0000FF00u) << 8) | ((x & 0x00FF0000u) >> 8) | ((x & 0xFF000000u) >> 24);
}

__device__ __forceinline__
    uint32_t
    ntohl_d(uint32_t x)
{
    return htonl_d(x);
}
// gpt generated
__device__ static inline void update_tcp_checksum(volatile void* packet)
{
    assert(packet != NULL);

    volatile struct iphdr* iph = (struct iphdr*)packet;

    /* ---- IPv4 validation ---- */
    assert(iph->version == 4);
    assert(iph->protocol == IPPROTO_TCP);

    size_t ip_header_len = iph->ihl * 4;
    assert(ip_header_len >= sizeof(struct iphdr));

    uint16_t total_len = ntohs_d(iph->tot_len);
    assert(total_len >= ip_header_len + sizeof(struct tcphdr));

    /* no fragmentation supported */
    //    assert((ntohs(iph->frag_off) & (IP_MF | IP_OFFMASK)) == 0);

    /* ---- Locate TCP header ---- */
    volatile struct tcphdr* tcph = (volatile struct tcphdr*)((uint8_t*)packet + ip_header_len);

    size_t tcp_len = total_len - ip_header_len;
    assert(tcp_len >= sizeof(struct tcphdr));
    assert(tcph->doff * 4 >= sizeof(struct tcphdr));
    assert(tcph->doff * 4 <= tcp_len);

    /* ---- Clear existing checksum ---- */
    tcph->check = 0;

    uint32_t sum = 0;

    /* ---- Pseudo-header ---- */

    /* Source IP */
    sum += (iph->saddr >> 16) & 0xFFFF;
    sum += (iph->saddr) & 0xFFFF;

    /* Destination IP */
    sum += (iph->daddr >> 16) & 0xFFFF;
    sum += (iph->daddr) & 0xFFFF;

    /* Protocol and TCP length */
    sum += htons_d(IPPROTO_TCP);
    sum += htons_d(tcp_len);

    /* ---- TCP header + payload ---- */

    volatile uint16_t* ptr = (volatile uint16_t*)tcph;
    size_t remaining = tcp_len;

    while (remaining > 1) {
        sum += *ptr++;
        remaining -= 2;
    }

    if (remaining == 1) {
        sum += *((volatile uint8_t*)ptr);
    }

    /* ---- Fold 32-bit sum to 16 bits ---- */
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    tcph->check = (uint16_t)(~sum);
}


// GPT generated

struct __align__(2) gpu_ethhdr {
    uint8_t  h_dest[6];
    uint8_t  h_source[6];
    uint16_t h_proto;
};


struct __align__(4) gpu_iphdr {
    uint8_t  version_ihl;
    uint8_t  tos;
    uint16_t tot_len;
    uint16_t id;
    uint16_t frag_off;
    uint8_t  ttl;
    uint8_t  protocol;
    uint16_t check;
    uint32_t saddr;
    uint32_t daddr;
};

struct __align__(4) gpu_tcphdr {
    uint16_t source;
    uint16_t dest;
    uint32_t seq;
    uint32_t ack_seq;
    uint8_t  doff_res;
    uint8_t  flags;
    uint16_t window;
    uint16_t check;
    uint16_t urg_ptr;
};

// ---------------------------------------------------------------------------
// Raw unaligned load/store helpers — NO byte swapping, just safe unaligned
// reads so we don't get UB on packed packet buffers.
// ---------------------------------------------------------------------------

__device__ __forceinline__
uint16_t load_u16(const uint8_t* p) {
    uint16_t v;
    memcpy(&v, p, 2);
    return v;
}

__device__ __forceinline__
uint32_t load_u32(const uint8_t* p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

__device__ __forceinline__
void store_u16(uint8_t* p, uint16_t v) {
    memcpy(p, &v, 2);
}

__device__ __forceinline__
void store_u32(uint8_t* p, uint32_t v) {
    memcpy(p, &v, 4);
}

// ---------------------------------------------------------------------------
// Struct conversions — copy bytes verbatim, no endianness change
// ---------------------------------------------------------------------------

__device__ __forceinline__
void eth_to_gpu(const struct ethhdr* in, gpu_ethhdr* out) {
    const uint8_t* p = reinterpret_cast<const uint8_t*>(in);

    #pragma unroll
    for (int i = 0; i < 6; i++) {
        out->h_dest[i]   = p[i];
        out->h_source[i] = p[i + 6];
    }

    out->h_proto = load_u16(p + 12);   // preserved in NBO
}

__device__ __forceinline__
void eth_from_gpu(const gpu_ethhdr* in, struct ethhdr* out) {
    uint8_t* p = reinterpret_cast<uint8_t*>(out);

    #pragma unroll
    for (int i = 0; i < 6; i++) {
        p[i]     = in->h_dest[i];
        p[i + 6] = in->h_source[i];
    }

    store_u16(p + 12, in->h_proto);    // preserved in NBO
}

__device__ __forceinline__
void ip_to_gpu(const struct iphdr* in, gpu_iphdr* out) {
    const uint8_t* p = reinterpret_cast<const uint8_t*>(in);

    out->version_ihl = p[0];
    out->tos         = p[1];
    out->tot_len     = load_u16(p + 2);   // NBO preserved
    out->id          = load_u16(p + 4);   // NBO preserved
    out->frag_off    = load_u16(p + 6);   // NBO preserved
    out->ttl         = p[8];
    out->protocol    = p[9];
    out->check       = load_u16(p + 10);  // NBO preserved
    out->saddr       = load_u32(p + 12);  // NBO preserved
    out->daddr       = load_u32(p + 16);  // NBO preserved
}

__device__ __forceinline__
void ip_from_gpu(const gpu_iphdr* in, struct iphdr* out) {
    uint8_t* p = reinterpret_cast<uint8_t*>(out);

    p[0] = in->version_ihl;
    p[1] = in->tos;
    store_u16(p + 2,  in->tot_len);   // NBO preserved
    store_u16(p + 4,  in->id);        // NBO preserved
    store_u16(p + 6,  in->frag_off);  // NBO preserved
    p[8] = in->ttl;
    p[9] = in->protocol;
    store_u16(p + 10, in->check);     // NBO preserved
    store_u32(p + 12, in->saddr);     // NBO preserved
    store_u32(p + 16, in->daddr);     // NBO preserved
}

__device__ __forceinline__
void tcp_to_gpu(const struct tcphdr* in, gpu_tcphdr* out) {
    const uint8_t* p = reinterpret_cast<const uint8_t*>(in);

    out->source  = load_u16(p + 0);   // NBO preserved
    out->dest    = load_u16(p + 2);   // NBO preserved
    out->seq     = load_u32(p + 4);   // NBO preserved
    out->ack_seq = load_u32(p + 8);   // NBO preserved
    out->doff_res = p[12];
    out->flags    = p[13];
    out->window  = load_u16(p + 14);  // NBO preserved
    out->check   = load_u16(p + 16);  // NBO preserved
    out->urg_ptr = load_u16(p + 18);  // NBO preserved
}

__device__ __forceinline__
void tcp_from_gpu(const gpu_tcphdr* in, struct tcphdr* out) {
    uint8_t* p = reinterpret_cast<uint8_t*>(out);

    store_u16(p + 0,  in->source);    // NBO preserved
    store_u16(p + 2,  in->dest);      // NBO preserved
    store_u32(p + 4,  in->seq);       // NBO preserved
    store_u32(p + 8,  in->ack_seq);   // NBO preserved
    p[12] = in->doff_res;
    p[13] = in->flags;
    store_u16(p + 14, in->window);    // NBO preserved
    store_u16(p + 16, in->check);     // NBO preserved
    store_u16(p + 18, in->urg_ptr);   // NBO preserved
}

// ---------------------------------------------------------------------------
// Bit-field accessors (unchanged, operate on host-local bytes)
// ---------------------------------------------------------------------------

__device__ __forceinline__
uint8_t ip_version(const gpu_iphdr* ip) { return ip->version_ihl >> 4; }

__device__ __forceinline__
uint8_t ip_ihl(const gpu_iphdr* ip) { return ip->version_ihl & 0x0F; }

__device__ __forceinline__
uint8_t tcp_doff(const gpu_tcphdr* tcp) { return tcp->doff_res >> 4; }

#define TCP_FLAG_FIN 0x01
#define TCP_FLAG_SYN 0x02
#define TCP_FLAG_RST 0x04
#define TCP_FLAG_PSH 0x08
#define TCP_FLAG_ACK 0x10
#define TCP_FLAG_URG 0x20
#define TCP_FLAG_ECE 0x40
#define TCP_FLAG_CWR 0x80

__device__ __forceinline__
uint8_t tcp_has_flag(const gpu_tcphdr* tcp, uint8_t mask) {
    return (tcp->flags & mask) != 0;
}

__device__ __forceinline__
void ip_set_version(gpu_iphdr* ip, uint8_t version) {
    ip->version_ihl = (ip->version_ihl & 0x0F) | (version << 4);
}

__device__ __forceinline__
void ip_set_ihl(gpu_iphdr* ip, uint8_t ihl) {
    ip->version_ihl = (ip->version_ihl & 0xF0) | (ihl & 0x0F);
}

__device__ __forceinline__
void tcp_set_doff(gpu_tcphdr* tcp, uint8_t doff) {
    tcp->doff_res = (tcp->doff_res & 0x0F) | (doff << 4);
}

__device__ __forceinline__
void tcp_set_flag(gpu_tcphdr* tcp, uint8_t mask) { tcp->flags |= mask; }

__device__ __forceinline__
void tcp_clear_flag(gpu_tcphdr* tcp, uint8_t mask) { tcp->flags &= ~mask; }

