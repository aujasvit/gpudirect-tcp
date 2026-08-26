// benchmark_client.cu
// GPUDirect TCP - Hello123
// created on 13/4/26

#include "gdrtcp.h"

#include <cuda_runtime_api.h>

using namespace gdrtcp;

#define SERVER_IP "172.27.27.17"
#define SERVER_PORT 6970

const size_t test_size = (1LL << 32);

int main(int argc, char** argv)
{
    CUDA_CHECK(cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync));

    if (argc != 2) {
        printf("Usage: %s <0/1>\n", argv[0]);
        printf("Pass 0 to run the GPU workload kernel which connects to the benchmark server\n");
        printf("Pass 1 if you just want to enable GPUDirect TCP, i.e for bench_redirect\n");
        return 1;
    }

    // NOTE: All hack_* variables are because of the user kernel being hardcoded inside
    // gdrtcp, due to issues faced with launching concurrent kernels

    bool hack_launch_workload = false;
    if (argv[1][0] == '0') // Yes, I know but eh
        hack_launch_workload = true;

    struct sockaddr_in hack_server_addr;
    hack_server_addr.sin_family = AF_INET;
    hack_server_addr.sin_port = htons(SERVER_PORT);
    assert(inet_pton(AF_INET, SERVER_IP, &hack_server_addr.sin_addr) == 1);

    handle_t handle;
    assert(init(&handle, "eno1", hack_launch_workload, hack_server_addr, test_size)
        == error_t::SUCCESS);

    // NOTE: Ideally here the user would launch their own kernel and use other gdrtcp APIs,
    // but due to the issue we were facing with running concurrent kernels on the GPU, for the
    // time being we have hardcoded the launch of a benchmark user kernel from within gdrtcp::init.
    // See benchmark_client() in gdrtcp.cu for the actual benchmark kernel which uses the
    // socket APIs provided by GPUDirect TCP.

    CUDA_CHECK(cudaDeviceSynchronize());
    assert(destroy(&handle) == error_t::SUCCESS);

    return 0;
}
