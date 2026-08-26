# Directory Structure

 - `e1000e.patch` is the patch file.
 - If you don't want to directly apply the patch file, `e1000e` contains the three files which must be added to the source tree of your linux build (*after* installing the linux kernel). `netdev.c` already exists and must be replaced with the provided version.
 - `e1000e_complete` contains the full e1000e code along with our modifications.
 - `gdrtcp` contains the CUDA Library code inside `main`, and some benchmark programs inside `benchmarks`. 
 - `scripts` contain some helper scripts.

# Setup Instructions

## Hardware Required

We tested on a single lab machine, and this README proceeds in a fashion which is similar to our test setup: two NICs and a GPU on the machine. One of the NICs uses e1000e as its driver, and the other must NOT use e1000e. If your setup is different, you may have to adapt the below steps.

All IP addresses and interface names below are from our test setup and are placeholders — substitute your own.

For reference, the hardware we have used is:

```
NIC1 = Intel I219-LM (e1000e)
NIC2 = Intel I210 (igb)
GPU = NVIDIA Quadro P620
```

## Linux Kernel compilation instructions

(Time taken: however long it takes to build the linux kernel on your machine)

Install 6.1.4 on the host machine - we have not tested on VMs. During `make menuconfig`, ensure the following: "Device Drivers>Network Device Support>Ethernet Driver Support>Intel(R) PRO/1000 PCI-Express Gigabit Ethernet support" must be set to `<M>`.

## GRUB

Change `/etc/default/grub` and then run `sudo update-grub` followed by a reboot.

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_pstate=no_hwp intel_iommu=on iommu=pt vfio_iommu_type1.allow_unsafe_interrupts=1"
GRUB_CMDLINE_LINUX="panic=5"
```

We use IOMMU set to passthrough for all benchmarks.

## Manual installation of NVIDIA Driver and CUDA Toolkit

(Time Required: Probably under 30 mins if everything goes well)

Uninstall any existing NVIDIA drivers, toolkits etc. to avoid conflicts. Below we provide steps we have used for our GPU; you may want to install different versions. We want to manually make and install the NVIDIA driver and CUDA toolkit as we link our e1000e module to nvidia.ko.

First, Download NVIDIA-Linux-<version>.run corresponding to the version suitable for your GPU. We are using version 535.

```
$ ./NVIDIA-Linux-x86_64-535.54.03.run -x
$ cd NVIDIA-Linux-x86_64-535.54.03/kernel 
```

**Caveat.** The modified `e1000e` uses GPL-only kernel APIs while also linking against `nvidia.ko`. With NVIDIA's proprietary driver the module licences do not permit this combination, so reproducing our results requires locally relabelling the modules below as GPL. We did this only to run the experiments on our own test machine. It is a licence violation, it produces a kernel you should not distribute or run in production, and it is recorded here for reproducibility rather than as a recommendation. On an open-source driver stack this step is unnecessary.

The files involved are:

```
./nvidia-modeset/nvidia-modeset-linux.c:  MODULE_LICENSE("GPL");
./nvidia-peermem/nvidia-peermem.c:MODULE_LICENSE("GPL");
./nvidia-uvm/uvm.c:MODULE_LICENSE("GPL");
./nvidia-drm/nvidia-drm-linux.c:  MODULE_LICENSE("GPL");
./nvidia/nv-frontend.c:MODULE_LICENSE("GPL");
```
Next, build the modules.

```
$ make -j$(nproc)
$ cd ..
$ sudo ./NVIDIA-Linux-x86_64-535.54.03.run --no-kernel-modules
```

Now we want to load the manually built kernel modules.

```
$ cd NVIDIA-Linux-x86_64-535.54.03/kernel 
$ sudo cp nvidia*.ko /lib/modules/6.1.4/extra/.
$ sudo modprobe nvidia
$ sudo modprobe nvidia-uvm
```

Verify using `lsmod` that the modules are loaded; the modules should get automatically loaded now, verify by running `lsmod` after a reboot. If any issues are being faced, try running `sudo depmod -a`.

Now, we want to install the CUDA Toolkit. Again, download the appropriate run file for your GPU; we are using `cuda_12.2.0_535.54.03_linux.run`. 

```
$ sudo ./cuda_12.2.0_535.54.03_linux.run --toolkit
```

Add lines similar to the following to your bashrc.

```
export PATH=/usr/local/cuda-12.2/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/lib64:$LD_LIBRARY_PATH
```

With this the setup should be complete. Try running `nvidia-smi` and running a sample cuda kernel on your GPU to verify this.


# Features, Functionalities, Assumptions, Unsupported Features

Please see the report for the same. Our implementation should not crash the system under any scenario. In the worst case, upon any buffer overflow standard output or `dmesg` will be spammed with error messages.

# Getting Started, Detailed Evaluation

See below sections in order to run the three benchmarks we have mentioned in the report. Results can be compared with those mentioned in the report, as well as the csv files we have captured and are included in `gdrtcp/data/exp*`.

The whole process should take less than 30 mins.

## Common terms

For the NIC which runs e1000e: Called NIC1, IPv4 address assigned = IP1, network namespace = ns1, network interface name = IF1.

For the other NIC, NOT running e1000e: Called NIC2, IPv4 address assigned = IP2, network namespace = ns2, network interface name = IF2.

In our setup:

```
IP1 = 172.27.21.249
ns1 = ns1
IF1 = eno1
IP2 = 172.27.27.17
ns2 = ns2 
IF2 = eno2
```

## Building and inserting the modified e1000e

(Time Required: 10 mins)

Apply the patch or simply copy the three files `netdev.c`, `gdr_common.h` and `nv-p2p.h` to the `e1000e` directory in your linux source tree, that is `linux-6.1.4/drivers/net/ethernet/intel/e1000e`.  

Copy `scripts/build_e1000e.sh` to the base directory in your linux source tree, that is within `linux-6.1.4/`. This script may have to modified based on the location of your driver install. For reference, the contents of the script are as follows:

```
make KBUILD_EXTRA_SYMBOLS=~/nvidia_driver/NVIDIA-Linux-x86_64-535.54.03/kernel/Module.symvers M=./drivers/net/ethernet/intel/e1000e/ modules
```

If IF1 is not `eno1`, please change the network interface name in lines 637-640 in `netdev.c`.

```
#define DEVNAME "eno1_setup"
#define DEVNAME_REDIRECT "eno1_redirect"
#define DEVNAME_INJECT "eno1_inject"
#define DEVNAME_TX "eno1_tx"
```

Now, run `build_e1000e.sh` and it should build the modified `e1000e.ko` which will be found inside the `e1000e` directory, that is `linux-6.1.4/drivers/net/ethernet/intel/e1000e/e1000e.ko`.

Next unload the e1000e module and insert this. Obviously do this while ssh'ing into the machine over NIC2.

```
$ sudo modprobe -r e1000e
$ sudo insmod ~/linux-6.1.4/drivers/net/ethernet/intel/e1000e/e1000e.ko 
```

To verify that the module is loaded correctly you can look at `dmesg` output, or the simplest test is to SSH in through the NIC using e1000e and check if that succeeds. GPUDirect TCP has to be enabled by writing to a character device, hence at this point the driver should function as normal.

## Building gdrtcp and the benchmarks

(Time Required: <10 mins)

If IF1 is not `eno1`, change the interface name at line 40 in `gdrtcp/main/gdrtcp.cu`.

```
    assert(init(&handle, "eno1", hack_launch_workload, hack_server_addr, test_size)
        == error_t::SUCCESS);
```
If you are not using our machine to perform the tests, that is IP2 is not 172.27.27.17, change the server IP (`#define SERVER_IP ...`) in each of the following files to IP2 (not IP1):

```
gdrtcp/main/bench_gdrtcp.cu
gdrtcp/benchmarks/bench_host.cu
gdrtcp/benchmarks/bench_native.c
gdrtcp/benchmarks/bench_redirect.c
```

CMake is used and will build everything.

```
$ cd gdrtcp
$ mkdir build
$ cd build
$ cmake ..
$ make 
```

## Separating the NICs into different network namespaces

(Time Required: few mins?)

We need to separate the NICs into different network namespaces to force packets to go to wire and avoid linux optimizations.

SSH in through NIC1. Run `scripts/shift_eno2_to_namespace.sh`. Please modify the script based off the actual IPs and interface names corresponding to your setup.

Try ssh'ing in through NIC2 now. Often this fails, so re-run the last command in the script and wait for maybe 30 seconds.

```
$ sudo ip netns exec ns2 /usr/sbin/sshd
```

To confirm that the NICs are now in separate namespaces, running `ifconfig` when ssh'ing in through NIC1 will not show ns2, and vice-versa. Another test you can perform is to run `iperf3` between the two NICs, and the throughput should be limited by the line rate. Please ensure using this that your network connection is able to hit line rate, or else the subsequent benchmarks will obviously not be able to hit line rate either.

## Running the Benchmarks

(Compute Time: Depends on benchmark sizes. If you stick with 4GB which is the default, each benchmark should take about 40 seconds)

All commands shown in the benchmark sections are run when SSH'ing in through NIC2. NIC1 gets reset when GPUDirect TCP is enabled/disabled, which means downtime of a few seconds.

The following alias is used to run commands in ns1 despite SSH'ing in through NIC2.

```
alias ins1='sudo nsenter -t 1 -n'
```

As explained in the report, each benchmark consists of a server and a client. After completion of the benchmark, the server dumps statistics in the form of a csv file in the same folder. Save this file and use it to generate plots.

For each benchmark below, from one terminal, run `./bench_server` found in `gdrtcp/build/benchmarks` before any other steps.

### Benchmark 0

The client in this benchmark is `gdrtcp/build/benchmarks/bench_native`. Run `ins1 ./bench_native`. The test size is set to 4GB. If you'd like to test with other sizes, modify `test_size` on line 24 in `bench_native.c`.

### Benchmark 1

The client in this benchmark is `gdrtcp/build/main/bench_gdrtcp`. The default test size is 4GB, if you'd like to change this change `test_size` on Line 14 of `gdrtcp/main/bench_gdrtcp.cu`.

Run 

```
$ ins1 ./bench_gdrtcp 0
```

This benchmark will enable GPUDirect TCP automatically and disable it at the end of the test. To verify that the correct checksum was received at the end of the benchmark, look at the end of the output of the *server*, not the client. The client will print lines such as "TCP Checksum Mismatch" and "IP Checksum Mismatch" occasionally, which are described in the report (section IV.A).

```
Checksum verified! value = 2854076302
```

### Benchmark 2

Firstly, GPUDirect TCP must be enabled for this benchmark but it must not create a GPU connection. Run

```
$ ins1 ./bench_gdrtcp 1
```

Now, open up a third terminal (NIC2 again). Run 

```
$ ins1 ./bench_redirect
```

At the end of the benchmark, GPUDirect TCP will not automatically be disabled. Press Ctrl+C in the terminal running `./bench_gdrtcp` to terminate the program, which will also disable GPUDirect TCP.

If you'd like, this same test can be repeated with `iperf3` when GPUDirect TCP is enabled. We have written our own client and server since iperf3 does not report statistics on the CWND, RTT etc.


### Plots and Data

By this point you have seen that a lot of relevant data is dumped to standard output by the clients and servers. To make the plots shown in the report, use the following programs inside `gdrtcp/data`. We have also included the csv files we had captured and were used for the plots in the report.

```
cpu_plot.py
plot_rtt_cwnd.py
plot_tp_rtt_var.py
```

Each script is run as follows:

```
python3 script.py input.csv output.png
```

You can use these scripts to generate plots from the csv's the benchmark server dumps.

