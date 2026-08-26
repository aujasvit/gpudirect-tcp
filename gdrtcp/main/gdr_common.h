// gdr_common.h
// Hello123

#ifndef _GPU_DMA_COMMON_H
#define _GPU_DMA_COMMON_H

#include <stdint.h>

#define GDR_MAGIC 0x12345678

typedef struct __attribute__((packed)) gdr_mem_setup {
	void *cmem_addr; // control mem addr, GPU VA
	size_t cmem_length;

	void *pmem_addr; // packet mem addr, GPU VA
	size_t pmem_length;

	uint32_t magic;
} gdr_mem_setup_t;
#define GDR_MEM_SETUP_T_SZ (8 + 8 + 8 + 8 + 4)
static_assert(sizeof(gdr_mem_setup_t) == GDR_MEM_SETUP_T_SZ);

#define NIC_INFO_SZ 32

typedef struct __attribute__((packed)) pkt_desc {
	// depending on where the memory for descriptors belongs
	union {
		void* gpu_va; 
		uint64_t offset; // useful when communicating b/w controller <-> e1000e
	};
	size_t length;

	// for use by NIC driver to store info needed to re-insert packets into kernel networking stack
	uint8_t nic_info[NIC_INFO_SZ]; 

	uint32_t checksum_verified;

	uint32_t magic;
} pkt_desc_t;
#define PKT_DESC_T_SZ (8 + 8 + NIC_INFO_SZ + 4 + 4)
static_assert(sizeof(pkt_desc_t) == PKT_DESC_T_SZ);

// producer writes to head, consumer consumes from tail
// memory for descriptors is assumed to be in [*_va, *_va + length_bytes)
// so the i'th slot would be at va_start + i*slot_sz
typedef struct __attribute__((packed)) spsc_ring {
	// Ptr to start of descriptor memory
	union {
		void *gpu_va;
		void *userspace_va;
	};
	// Another ptr to the start of descriptor memory
	// Can be used when producer/consumer are in different address spaces, and the ring 
	// has been mapped into both
	union {
		void *kernel_va;
	} va2;
	size_t length_bytes;

	// head/tail should be aligned even with the struct being packed.
	// without alignment, I believe tearing could occur during reads/writes on x86_64, which could cause 
	// weird issues.
	volatile int head;
	volatile int tail;
	int num_slots;
	int slot_sz;

	uint32_t magic;
} spsc_ring_t;
#define SPSC_RING_T_SZ (8 + 8 + 8 + 4 + 4 + 4 + 4 + 4)
static_assert(sizeof(spsc_ring_t) == SPSC_RING_T_SZ);

// TODO: How come there is no issue here when GPU is accessing unaligned addresses??
// spsc_ring_t size is 44, so redirect_ring initial members are unaligned...
typedef struct __attribute__((packed)) gdr_config {
	spsc_ring_t rx_ring; // rx to GPU
	spsc_ring_t redirect_ring; // packets to be redirected towards cpu
	spsc_ring_t tx_ring; // packets GPU stack wants to tx
} gdr_env_t;

#define GDR_CONFIG_T_SZ (3 * SPSC_RING_T_SZ)
static_assert(sizeof(gdr_env_t) == GDR_CONFIG_T_SZ);

#define GPU_PAGE_SIZE (1 << 16)
#define CPU_PAGE_SIZE (1 << 12)

// All queues - rx, redirect, inject, tx - use pkt_desc_t as their entries, and each of them have a size of 
// NUM_SLOTS. 
#define QUEUE_ENTRY_SZ 64 // roundup_pow_of_two(sizeof(pkt_desc_t))
static_assert(sizeof(pkt_desc_t) < QUEUE_ENTRY_SZ);
#define NUM_SLOTS 4096

#define PACKET_SZ 2048 // Ethernet max size in e1000e ~1522
#define PMEM_SZ (NUM_SLOTS * PACKET_SZ) // PMEM has enough space to hold NUM_SLOTS packets

#define CMEM_QUEUE_CNT 3 // rx, redirect, tx
// first page is used for gdr_config
// CMEM has space for rx, redirect, tx rings
#define CMEM_SZ (GPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ * CMEM_QUEUE_CNT)

// imem = [spsc_ring_t][descriptors][data memory]
// first page is used for spsc_ring_t
#define IMEM_SZ (CPU_PAGE_SIZE + NUM_SLOTS * QUEUE_ENTRY_SZ + NUM_SLOTS * PACKET_SZ)

#endif // _GPU_DMA_COMMON_H
