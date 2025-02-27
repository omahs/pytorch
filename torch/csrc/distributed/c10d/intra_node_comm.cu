#include <torch/csrc/distributed/c10d/intra_node_comm.hpp>

#include <ATen/Dispatch.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>

namespace c10d {
namespace intra_node_comm {

static constexpr size_t kBytesPerThread = 16;
static constexpr size_t kMaxAllReduceBlocks = 24;
static constexpr size_t kThreadsPerBlock = 1024;
static constexpr size_t kWarpSize = 32;

static constexpr size_t kHcmThreshBytes = 256 * 1024;
static constexpr size_t kOneShotThreshBytes = 256 * 1024;
static constexpr size_t kTwoShotThreshBytes = 10 * 1024 * 1024;

#if defined(USE_ROCM)
using __nv_bfloat162 = uint32_t;
#endif

struct __align__(16) bf16x8 {
  __nv_bfloat162 vals[4];
};

#define DEVICE_INLINE __device__ inline __attribute__((always_inline))

DEVICE_INLINE __nv_bfloat162
bf16hadd2(const __nv_bfloat162 x, const __nv_bfloat162 y) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  return __hadd2(x, y);
#endif
}

DEVICE_INLINE bf16x8 add_bf16x8(bf16x8 a, bf16x8 b) {
  bf16x8 c;
  c.vals[0] = bf16hadd2(a.vals[0], b.vals[0]);
  c.vals[1] = bf16hadd2(a.vals[1], b.vals[1]);
  c.vals[2] = bf16hadd2(a.vals[2], b.vals[2]);
  c.vals[3] = bf16hadd2(a.vals[3], b.vals[3]);
  return c;
}

/**
 * NOTE [cross device memory synchronization]
 *
 * The multi-stage algorithms (e.g. two-shot, hcm allreduce) require the writes
 * of a thread to be visible by threads with the same block/thread ID on other
 * devices. To satisfy CUDA's memory consistency model, every thread has to
 * release its writes at the system scope, and the consuming thread has to
 * acquire the writes at the system scope. This incurs high overhead and
 * attempts in optmizing this process can be prone to race condition.
 *
 * Instead, we go around caching by having each thread:
 *
 * - Directly write to global memory via st.cs (cache-streaming).
 * - Synchronize with threads within the block.
 * - Perform cross device synchronization at block level (via system scope
 *   atomic ops).
 * - Synchronize with threads within the block.
 * - Directly read from global memory via ld.nc (non-coherent/non-cached).
 */
template <typename T>
DEVICE_INLINE void streamLoad128(bf16x8& val, const T* addr) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  unsigned long long int low, high;
  asm("ld.global.nc.v2.u64 {%0, %1}, [%2];"
      : "=l"(low), "=l"(high)
      : "l"(addr));
  reinterpret_cast<unsigned long long int*>(&val)[0] = low;
  reinterpret_cast<unsigned long long int*>(&val)[1] = high;
#endif
}

__device__ inline void streamStore128(at::BFloat16* addr, const bf16x8& val) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  unsigned long long int low, high;
  low = reinterpret_cast<const unsigned long long int*>(&val)[0];
  high = reinterpret_cast<const unsigned long long int*>(&val)[1];
  asm("st.global.cs.v2.u64 [%0], {%1, %2};" : : "l"(addr), "l"(low), "l"(high));
#endif
}

template <typename T>
DEVICE_INLINE void load128(bf16x8& val, const T* addr) {
  *reinterpret_cast<uint4*>(&val) = reinterpret_cast<const uint4*>(addr)[0];
}

template <typename T>
DEVICE_INLINE void store128(T* addr, const bf16x8& val) {
  *reinterpret_cast<uint4*>(addr) = reinterpret_cast<const uint4*>(&val)[0];
}

DEVICE_INLINE void releaseSignal(uint32_t* addr) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  atomicAdd_system(addr, 1);
#endif
}

DEVICE_INLINE void acquireSignal(uint32_t* addr) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  volatile uint32_t* signal = addr;
  uint32_t val;
  do {
    val = *signal;
  } while (val == 0 || atomicCAS_system(addr, val, val - 1) != val);
#endif
}

////////////////////////////////////////////////////////////////////////////////
// Fully Connected Algos
////////////////////////////////////////////////////////////////////////////////

struct P2pState {
  uint32_t signals0[kMaxAllReduceBlocks][kMaxDevices];
  uint32_t signals1[kMaxAllReduceBlocks][kMaxDevices];
};

template <uint32_t kWorldSize, bool kAligned>
static __global__ void oneShotAllReduceKernel(
    at::BFloat16* input,
    size_t N,
    size_t N_aligned,
    std::array<P2pState*, kMaxDevices> p2pStates,
    std::array<at::BFloat16*, kMaxDevices> buffers,
    size_t rank) {
  const size_t numelPerThread = kBytesPerThread / sizeof(at::BFloat16);
  const size_t offset =
      (blockDim.x * blockIdx.x + threadIdx.x) * numelPerThread;
  const size_t stride = blockDim.x * gridDim.x * numelPerThread;

  // Wait for all other ranks to enter the kernel
  if (threadIdx.x < kWorldSize) {
    auto targetRank = threadIdx.x;
    releaseSignal(&p2pStates[targetRank]->signals0[blockIdx.x][rank]);
    acquireSignal(&p2pStates[rank]->signals0[blockIdx.x][targetRank]);
  }
  __syncthreads();

  // The source pointers. Distributed round-robin for the different warps
  const at::BFloat16* srcs[kWorldSize];
#pragma unroll kWorldSize
  for (int ii = 0; ii < kWorldSize; ++ii) {
    int srcRank = (rank + ii) % kWorldSize;
    srcs[ii] = buffers[srcRank];
  }

  for (size_t i = offset; i < N_aligned; i += stride) {
    bf16x8 vals[kWorldSize];
#pragma unroll kWorldSize
    for (size_t ii = 0; ii < kWorldSize; ++ii) {
      streamLoad128(vals[ii], &srcs[ii][i]);
    }

    bf16x8 sums;
    memset(reinterpret_cast<void*>(&sums), 0, sizeof(sums));

#pragma unroll kWorldSize
    for (size_t ii = 0; ii < kWorldSize; ++ii) {
      sums = add_bf16x8(sums, vals[ii]);
    }
    if constexpr (kAligned) {
      streamStore128(&input[i], sums);
    } else {
      for (size_t ii = 0; ii < numelPerThread; ++ii) {
        if (i + ii < N) {
          input[i + ii] = reinterpret_cast<at::BFloat16*>(&sums)[ii];
        }
      }
    }
  }
}

template <uint32_t kWorldSize>
static __launch_bounds__(1024) __global__ void twoShotAllReduceKernel(
    at::BFloat16* input,
    size_t N_aligned,
    std::array<P2pState*, kMaxDevices> p2pStates,
    std::array<at::BFloat16*, kMaxDevices> buffers,
    size_t rank) {
  const size_t numelPerThread = kBytesPerThread / sizeof(at::BFloat16);
  const size_t offset =
      (blockDim.x * blockIdx.x + threadIdx.x) * numelPerThread;
  const size_t stride = blockDim.x * gridDim.x * numelPerThread;
  const size_t N_per_rank = N_aligned / kWorldSize;
  const size_t N_start = N_per_rank * rank;

  // Wait for all other ranks to enter the kernel
  if (threadIdx.x < kWorldSize) {
    auto targetRank = threadIdx.x;
    releaseSignal(&p2pStates[targetRank]->signals0[blockIdx.x][rank]);
    acquireSignal(&p2pStates[rank]->signals0[blockIdx.x][targetRank]);
  }
  __syncthreads();

  // The source pointers. Distributed round-robin for the different warps
  at::BFloat16* srcs[kWorldSize];
  size_t srcRanks[kWorldSize];
#pragma unroll kWorldSize
  for (int ii = 0; ii < kWorldSize; ++ii) {
    int srcRank = (rank + ii) % kWorldSize;
    srcs[ii] = buffers[srcRank];
    srcRanks[ii] = srcRank;
  }

  for (size_t i = offset; i < N_per_rank; i += stride) {
    bf16x8 vals[kWorldSize];
#pragma unroll kWorldSize
    for (size_t ii = 0; ii < kWorldSize; ++ii) {
      streamLoad128(vals[ii], &srcs[ii][N_start + i]);
    }

    bf16x8 sums;
    memset(reinterpret_cast<void*>(&sums), 0, sizeof(sums));

#pragma unroll kWorldSize
    for (size_t ii = 0; ii < kWorldSize; ++ii) {
      sums = add_bf16x8(sums, vals[ii]);
    }
    streamStore128(&srcs[0][N_start + i], sums);
    // Store local sums into input now so we can avoid
    // a global memory access later for it.
    streamStore128(&input[N_start + i], sums);
  }
  __syncthreads();

  if (threadIdx.x < kWorldSize) {
    auto targetRank = threadIdx.x;
    releaseSignal(&p2pStates[targetRank]->signals1[blockIdx.x][rank]);
    acquireSignal(&p2pStates[rank]->signals1[blockIdx.x][targetRank]);
  }
  __syncthreads();

  for (size_t i = offset; i < N_per_rank; i += stride) {
#pragma unroll kWorldSize - 1
    for (size_t ii = 1; ii < kWorldSize; ++ii) {
      size_t k = N_start + i + (srcRanks[ii] - rank) * N_per_rank;
      bf16x8 val;
      streamLoad128(val, &srcs[ii][k]);
      streamStore128(&input[k], val);
    }
  }
}

////////////////////////////////////////////////////////////////////////////////
// Hybrid Cube Mesh Algos
////////////////////////////////////////////////////////////////////////////////

/**
 * NOTE [hybrid cube mesh]
 *
 * In a hybrid cube mesh topology, every device has exactly 4 neighbors
 * (directly connected via NVLink). For every device X, it has exactly 1
 * neighbor Y that is a neighbor of the 3 non-neighbor of X. We call Y the
 * relay neighbor of X. This property is symmetrical: X is also guaranteed to
 * be the relay neighbor of Y.
 *
 * With this property, we can perform a variant of one-shot allreduce algo that
 * only moves data across NVLinks:
 *
 * - Each device one-shot allreduce among itself and 3 non-relay neighbors.
 * - Each device exchange data with its relay neighbor.
 *
 * HybridCubeMesh is a data structure for describing the topology:
 *
 * - hcm[X][0:3] are the 3 neighbors of X.
 * - hcm[X][3] is the relay neighbor of X.
 * - For load balancing purpose, we also ensure that if hcm[X][k] = Y,
 *   hcm[Y][k] = X.
 */
std::optional<HybridCubeMesh> getHybridCubeMesh(NvlMesh nvlMesh) {
  std::array<std::unordered_set<size_t>, kMaxDevices> neighbors = {};
  std::array<size_t, kMaxDevices> neighborMasks = {};
  for (size_t i = 0; i < kMaxDevices; ++i) {
    for (size_t j = 0; j < kMaxDevices; ++j) {
      if (nvlMesh[i][j] > 0) {
        neighbors[i].insert(j);
        neighborMasks[i] |= (1ul << j);
      }
    }
  }
  HybridCubeMesh hcm = {};
  for (auto& row : hcm) {
    row.fill(-1);
  }
  // A topology is an HCM if:
  // - Every device has exactly 4 neighbors.
  // - For every device, it has exactly 1 relay neighbor that is
  //   a neighbor of the 3 non-neighbor of the device.
  for (size_t i = 0; i < kMaxDevices; ++i) {
    if (neighbors[i].size() != 4) {
      return std::nullopt;
    }
    // Condition 1: check the number of neighbors
    std::vector<size_t> relayNeighbors;
    for (size_t j = 0; j < kMaxDevices; ++j) {
      if ((neighborMasks[i] & neighborMasks[j]) == 0) {
        relayNeighbors.push_back(j);
      }
    }
    // Condition 2: check the number of relay neighbors
    if (relayNeighbors.size() != 1) {
      return std::nullopt;
    }
    neighbors[i].erase(relayNeighbors[0]);
    hcm[i][3] = relayNeighbors[0];
  }

  for (size_t i = 0; i < kMaxDevices; ++i) {
    for (size_t k = 0; k < 3; ++k) {
      // We can only fill hcm[i][k] with j if hcm[j][k] is not filled
      for (size_t j : neighbors[i]) {
        if (hcm[j][k] == -1) {
          hcm[i][k] = j;
          hcm[j][k] = i;
          break;
        }
      }
      TORCH_CHECK(hcm[i][k] != -1);
      neighbors[i].erase(hcm[i][k]);
    }
  }
  return hcm;
}

template <bool kAligned>
static __global__ void hybridCubeMeshAllReduceKernel(
    at::BFloat16* input,
    size_t N,
    size_t N_aligned,
    std::array<P2pState*, kMaxDevices> p2pStates,
    std::array<at::BFloat16*, kMaxDevices> buffers,
    int hcmInfo[4],
    size_t rank) {
  const size_t numelPerThread = kBytesPerThread / sizeof(at::BFloat16);
  const size_t offset =
      (blockDim.x * blockIdx.x + threadIdx.x) * numelPerThread;
  const size_t stride = blockDim.x * gridDim.x * numelPerThread;
  const int relayRank = hcmInfo[3];

  // Wait for HCM neigbors to enter the kernel
  if (threadIdx.x < 3) {
    auto targetRank = hcmInfo[threadIdx.x];
    releaseSignal(&p2pStates[targetRank]->signals0[blockIdx.x][rank]);
    acquireSignal(&p2pStates[rank]->signals0[blockIdx.x][targetRank]);
  }
  __syncthreads();

  const at::BFloat16* srcs[4] = {
      buffers[rank],
      buffers[hcmInfo[0]],
      buffers[hcmInfo[1]],
      buffers[hcmInfo[2]],
  };
  at::BFloat16* localRelay = buffers[rank] + kMaxIntraNodeSize / 2;
  at::BFloat16* remoteRelay = buffers[relayRank] + kMaxIntraNodeSize / 2;

  for (size_t i = offset; i < N_aligned; i += stride) {
    bf16x8 vals[4];

#pragma unroll 4
    for (size_t ii = 0; ii < 4; ++ii) {
      streamLoad128(vals[ii], &srcs[ii][i]);
    }

    bf16x8 sums;
    memset(reinterpret_cast<void*>(&sums), 0, sizeof(sums));

#pragma unroll 4
    for (size_t ii = 0; ii < 4; ++ii) {
      sums = add_bf16x8(sums, vals[ii]);
    }
    // Cached store for local sums
    store128(&localRelay[i], sums);
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    releaseSignal(&p2pStates[relayRank]->signals0[blockIdx.x][rank]);
    acquireSignal(&p2pStates[rank]->signals0[blockIdx.x][relayRank]);
  }
  __syncthreads();

  for (size_t i = offset; i < N_aligned; i += stride) {
    bf16x8 localSum, remoteSum;
    // Cached load for local sums
    load128(localSum, &localRelay[i]);
    streamLoad128(remoteSum, &remoteRelay[i]);
    localSum = add_bf16x8(localSum, remoteSum);
    if constexpr (kAligned) {
      streamStore128(&input[i], localSum);
    } else {
      for (size_t ii = 0; ii < numelPerThread; ++ii) {
        if (i + ii < N) {
          input[i + ii] = reinterpret_cast<at::BFloat16*>(&localSum)[ii];
        }
      }
    }
  }
}

static inline size_t divUp(uint32_t a, uint32_t b) {
  return (a + b - 1) / b;
}

static inline size_t alignUp(uint32_t a, uint32_t b) {
  return divUp(a, b) * b;
}

static void checkInput(const at::Tensor& input, size_t rank) {
  TORCH_CHECK(
      input.dtype() == at::kBFloat16,
      "oneShotAllReduce only supports bf16 for now");
  TORCH_CHECK(input.is_non_overlapping_and_dense());
  TORCH_CHECK(input.device().is_cuda());
  TORCH_CHECK(static_cast<size_t>(input.get_device()) == rank);
}

static void getLaunchConfig(
    size_t N_aligned,
    size_t elemSize,
    dim3& blocks,
    dim3& threads) {
  blocks = dim3(0, 1, 1);
  threads = dim3(0, 1, 1);

  const auto numelPerThread = kBytesPerThread / elemSize;
  const auto numelPerWarp = numelPerThread * kWarpSize;
  TORCH_CHECK(N_aligned % numelPerThread == 0);
  TORCH_CHECK(N_aligned % numelPerWarp == 0);
  if (N_aligned < numelPerThread * kThreadsPerBlock) {
    threads.x = N_aligned / numelPerWarp * kWarpSize;
    blocks.x = 1;
  } else {
    auto warpsRequired = N_aligned / numelPerWarp;
    auto threadsRequired = N_aligned / numelPerThread;
    blocks.x =
        std::min(divUp(threadsRequired, kThreadsPerBlock), kMaxAllReduceBlocks);
    auto warpsPerBlock = divUp(warpsRequired, blocks.x);
    threads.x = std::min(kThreadsPerBlock, warpsPerBlock * kWarpSize);
  }
}

template <typename T>
static auto castArr(std::array<void*, kMaxDevices> arr) {
  std::array<T, kMaxDevices> arr_;
  for (size_t i = 0; i < kMaxDevices; ++i) {
    arr_[i] = reinterpret_cast<T>(arr[i]);
  }
  return arr_;
}

bool isIntraNodeCommSupported() {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  return false;
#else
  return true;
#endif
}

void* initP2pState() {
  void* state = nullptr;
  AT_CUDA_CHECK(cudaMalloc(&state, sizeof(P2pState)));
  AT_CUDA_CHECK(cudaMemset(state, 0, sizeof(P2pState)));
  return state;
}

void* initTopoInfo(Topology topology, NvlMesh nvlMesh, size_t rank) {
  void* topoInfo = nullptr;
  if (topology != Topology::HYBRID_CUBE_MESH) {
    return topoInfo;
  }
  auto hcm = getHybridCubeMesh(nvlMesh);
  int hcmInfo[4];
  std::copy((*hcm)[rank].begin(), (*hcm)[rank].begin() + 4, hcmInfo);
  AT_CUDA_CHECK(cudaMalloc(&topoInfo, sizeof(hcmInfo)));
  AT_CUDA_CHECK(
      cudaMemcpy(topoInfo, hcmInfo, sizeof(hcmInfo), cudaMemcpyHostToDevice));
  return topoInfo;
}

at::Tensor oneShotAllReduce(
    const at::Tensor& input,
    std::array<void*, kMaxDevices> p2pStates,
    std::array<void*, kMaxDevices> buffers,
    size_t rank,
    size_t worldSize,
    at::cuda::CUDAStream& stream) {
  checkInput(input, rank);

  size_t numelPerWarp = kBytesPerThread / input.element_size() * kWarpSize;
  size_t N_aligned = alignUp(input.numel(), numelPerWarp);
  TORCH_CHECK(N_aligned <= kMaxIntraNodeSize / input.element_size());

  dim3 blocks, threads;
  getLaunchConfig(N_aligned, input.element_size(), blocks, threads);

  at::cuda::OptionalCUDAGuard guard(input.get_device());
  AT_CUDA_CHECK(cudaMemcpyAsync(
      buffers[rank],
      input.data_ptr(),
      input.numel() * input.element_size(),
      cudaMemcpyDeviceToDevice,
      stream));

#define X(kWorldSize, kAligned)                  \
  if (worldSize == kWorldSize) {                 \
    oneShotAllReduceKernel<kWorldSize, kAligned> \
        <<<blocks, threads, 0, stream>>>(        \
            input.data_ptr<at::BFloat16>(),      \
            input.numel(),                       \
            N_aligned,                           \
            castArr<P2pState*>(p2pStates),       \
            castArr<at::BFloat16*>(buffers),     \
            rank);                               \
    C10_CUDA_KERNEL_LAUNCH_CHECK();              \
  }

#define DISPATCH_ALL_WORLD_SIZES(kAligned) \
  X(2, kAligned);                          \
  X(3, kAligned);                          \
  X(4, kAligned);                          \
  X(5, kAligned);                          \
  X(6, kAligned);                          \
  X(7, kAligned);                          \
  X(8, kAligned);

  if (N_aligned == static_cast<size_t>(input.numel())) {
    DISPATCH_ALL_WORLD_SIZES(true);
  } else {
    DISPATCH_ALL_WORLD_SIZES(false);
  }

#undef DISPATCH_ALL_WORLD_SIZES
#undef X
  return input;
}

at::Tensor twoShotAllReduce(
    const at::Tensor& input,
    std::array<void*, kMaxDevices> p2pStates,
    std::array<void*, kMaxDevices> buffers,
    size_t rank,
    size_t worldSize,
    at::cuda::CUDAStream& stream) {
  checkInput(input, rank);

  size_t numelPerWarp = kBytesPerThread / input.element_size() * kWarpSize;
  size_t N_aligned = alignUp(input.numel(), worldSize * numelPerWarp);
  size_t N_per_rank = N_aligned / worldSize;
  TORCH_CHECK(N_aligned <= kMaxIntraNodeSize / input.element_size());

  dim3 blocks, threads;
  getLaunchConfig(N_per_rank, input.element_size(), blocks, threads);

  auto output = N_aligned == static_cast<size_t>(input.numel())
      ? input
      : input.new_empty(N_aligned);

  at::cuda::OptionalCUDAGuard guard(input.get_device());
  AT_CUDA_CHECK(cudaMemcpyAsync(
      buffers[rank],
      input.data_ptr(),
      input.numel() * input.element_size(),
      cudaMemcpyDeviceToDevice,
      stream));

#define X(kWorldSize)                                                   \
  if (worldSize == kWorldSize) {                                        \
    twoShotAllReduceKernel<kWorldSize><<<blocks, threads, 0, stream>>>( \
        output.data_ptr<at::BFloat16>(),                                \
        N_aligned,                                                      \
        castArr<P2pState*>(p2pStates),                                  \
        castArr<at::BFloat16*>(buffers),                                \
        rank);                                                          \
    C10_CUDA_KERNEL_LAUNCH_CHECK();                                     \
  }
  X(2);
  X(3);
  X(4);
  X(5);
  X(6);
  X(7);
  X(8);
#undef X

  if (output.data_ptr() != input.data_ptr()) {
    AT_CUDA_CHECK(cudaMemcpyAsync(
        input.data_ptr(),
        output.data_ptr(),
        input.numel() * input.element_size(),
        cudaMemcpyDeviceToDevice,
        stream));
  }
  return input;
}

at::Tensor hybridCubeMeshAllReduce(
    const at::Tensor& input,
    std::array<void*, kMaxDevices> p2pStates,
    std::array<void*, kMaxDevices> buffers,
    int hcmInfo[4],
    size_t rank,
    size_t worldSize,
    at::cuda::CUDAStream& stream) {
  checkInput(input, rank);

  size_t numelPerWarp = kBytesPerThread / input.element_size() * kWarpSize;
  size_t N_aligned = alignUp(input.numel(), numelPerWarp);
  TORCH_CHECK(N_aligned <= kMaxIntraNodeSize / input.element_size());

  dim3 blocks, threads;
  getLaunchConfig(N_aligned, input.element_size(), blocks, threads);

  at::cuda::OptionalCUDAGuard guard(input.get_device());
  AT_CUDA_CHECK(cudaMemcpyAsync(
      buffers[rank],
      input.data_ptr(),
      input.numel() * input.element_size(),
      cudaMemcpyDeviceToDevice,
      stream));

#define X(kAligned)                                                        \
  hybridCubeMeshAllReduceKernel<kAligned><<<blocks, threads, 0, stream>>>( \
      input.data_ptr<at::BFloat16>(),                                      \
      input.numel(),                                                       \
      N_aligned,                                                           \
      castArr<P2pState*>(p2pStates),                                       \
      castArr<at::BFloat16*>(buffers),                                     \
      hcmInfo,                                                             \
      rank);                                                               \
  C10_CUDA_KERNEL_LAUNCH_CHECK();

  if (N_aligned == static_cast<size_t>(input.numel())) {
    X(true);
  } else {
    X(false);
  }
#undef X
  return input;
}

AllReduceAlgo selectAllReduceAlgo(
    const at::Tensor& input,
    Topology topology,
    size_t worldSize) {
  // Only support bf16 for now
  if (input.dtype() != at::kBFloat16 ||
      input.numel() * input.element_size() > kMaxIntraNodeSize) {
    return AllReduceAlgo::NONE;
  }
  const auto numel = input.numel();
  const auto numelPerWarp = kBytesPerThread / input.element_size() * kWarpSize;
  if (topology == Topology::HYBRID_CUBE_MESH) {
    TORCH_CHECK(
        worldSize == 8, "hyperCubeAllReduce only supports exactly 8 GPUs");
    if (alignUp(numel, numelPerWarp) <= kHcmThreshBytes) {
      return AllReduceAlgo::HCM;
    }
  }
  if (topology == Topology::FULLY_CONNECTED) {
    if (alignUp(numel, numelPerWarp) <= kOneShotThreshBytes) {
      return AllReduceAlgo::ONE_SHOT;
    }
    if (alignUp(numel, numelPerWarp * worldSize) <= kTwoShotThreshBytes) {
      return AllReduceAlgo::TWO_SHOT;
    }
  }
  return AllReduceAlgo::NONE;
}

at::Tensor allReduce(
    const at::Tensor& input,
    std::array<void*, kMaxDevices> p2pStates,
    std::array<void*, kMaxDevices> buffers,
    void* topoInfo,
    size_t rank,
    size_t worldSize,
    AllReduceAlgo algo,
    at::cuda::CUDAStream& stream) {
  switch (algo) {
    case AllReduceAlgo::ONE_SHOT:
      return oneShotAllReduce(
          input, p2pStates, buffers, rank, worldSize, stream);
    case AllReduceAlgo::TWO_SHOT:
      return twoShotAllReduce(
          input, p2pStates, buffers, rank, worldSize, stream);
    case AllReduceAlgo::HCM:
      return hybridCubeMeshAllReduce(
          input, p2pStates, buffers, (int*)topoInfo, rank, worldSize, stream);
    default:
      C10_THROW_ERROR(ValueError, "IntraNodeComm: invalid algo");
  }
}

} // namespace intra_node_comm
} // namespace c10d
