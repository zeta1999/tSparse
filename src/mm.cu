/*
 * mm.cu
 *
 *  Created on: Mar 26, 2019
 *      Author: ore
 */

#include "mm.h"

#include <iostream>
#include <iomanip>

#include "cuda.h"
#include <mma.h>
//#include <cooperative_groups.h>

#include <list>

#include <cusp/coo_matrix.h>
#include <cusp/sort.h>

#include <cusp/detail/temporary_array.h>

#include "cusp/timer.h"

#include <thrust/fill.h>
#include <thrust/gather.h>
//#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/scatter.h>
//#include <thrust/transform.h>
#include <thrust/inner_product.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <thrust/copy.h>
#include <thrust/remove.h>

#include <thrust/mr/allocator.h>
#include <thrust/mr/new.h>
#include <thrust/mr/pool.h>
#include <thrust/mr/disjoint_pool.h>

#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/transform_output_iterator.h>
#include <thrust/iterator/permutation_iterator.h>
#include <thrust/functional.h>

#include <bb_segsort/bb_segsort.h>


#define WARP_SIZE 32
#define HALF_WARP_SIZE WARP_SIZE / 2
#define M 16
#define N 16
#define K 16

using namespace nvcuda;
//namespace cg = cooperative_groups;


union bitmap
{
	uint64_t bmp;
	uint32_t half_bmp_start[2];
};

inline __device__ void mma(half const a[], half const b[], float const C[], float D[]) {
    unsigned const *A = reinterpret_cast<unsigned const *>(a);
    unsigned const *B = reinterpret_cast<unsigned const *>(b);

    asm volatile("mma.sync.aligned.m8n8k4.row.row.f32.f16.f16.f32 {%0,%1,%2,%3,%4,%5,%6,%7}, {%8,%9}, {%10,%11}, "
            "{%12,%13,%14,%15,%16,%17,%18,%19};"
            : "=f"(D[0]), "=f"(D[1]), "=f"(D[2]), "=f"(D[3]), "=f"(D[4]), "=f"(D[5]), "=f"(D[6]), "=f"(D[7])
            : "r"(A[0]), "r"(A[1]), "r"(B[0]), "r"(B[1]),
              "f"(C[0]), "f"(C[1]), "f"(C[2]), "f"(C[3]), "f"(C[4]), "f"(C[5]), "f"(C[6]), "f"(C[7]));
}

inline __device__ void mma_half(half const a[], half const b[], half const c[], half d[]) {
    unsigned const *A = reinterpret_cast<unsigned const *>(a);
    unsigned const *B = reinterpret_cast<unsigned const *>(b);
    unsigned const *C = reinterpret_cast<unsigned const *>(c);
    unsigned *D = reinterpret_cast<unsigned *>(d);

    asm volatile("mma.sync.aligned.m8n8k4.row.row.f16.f16.f16.f16 {%0,%1,%2,%3}, {%4,%5}, {%6,%7}, "
            "{%8,%9,%10,%11};"
            : "=r"(D[0]), "=r"(D[1]), "=r"(D[2]), "=r"(D[3])
            : "r"(A[0]), "r"(A[1]), "r"(B[0]), "r"(B[1]),
              "r"(C[0]), "r"(C[1]), "r"(C[2]), "r"(C[3]));
}

__global__ void count_c_elems_noTCU_nT(uint32_t * offset_tile, int * A_gather_locations,
        const uint64_t * A_tiles, int * B_gather_locations, const uint64_t * B_tiles, uint32_t * result) {

    __shared__ float A[BMP_DIM * BMP_DIM];
    __shared__ float B[BMP_DIM * BMP_DIM];
    __shared__ float C[BMP_DIM * BMP_DIM];

    int tx = threadIdx.x;

    uint32_t start = offset_tile[blockIdx.x];
    uint32_t num_tile = offset_tile[blockIdx.x + 1] - start;

    for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
        *((float *)(&(A[i]))) = 0.0f; //TODO vector transfers are better probably

    for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
        *((float *)(&(B[i]))) = 0.0f;

    for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
        *((float *)(&(C[i]))) = 0.0f;

    __syncthreads();

    bitmap A_bmp, B_bmp;

    // For each tile of C, we have a loop to add all required products of A*B.
    for (int i = start; i < start + num_tile; ++i) {
        if (tx < BMP_DIM * BMP_DIM) {
            // We get the uint64 bmp for the tiles of A and B
            A_bmp.bmp = A_tiles[A_gather_locations[i]];
            B_bmp.bmp = B_tiles[B_gather_locations[i]];

            // Here each thread will check bits of the bmps. The bits that are 1 will be
            // converted to 1 or 0 otherwise
            float A_val, B_val;
            A_val = (A_bmp.bmp & (1ULL<<tx))>0;
            B_val = (B_bmp.bmp & (1ULL<<tx))>0;

            // stored in shared memory
            A[(tx / BMP_DIM) * BMP_DIM + tx % BMP_DIM] = A_val;
            B[(tx / BMP_DIM) * BMP_DIM + tx % BMP_DIM] = B_val;
        }

        __syncthreads();

        for (int t = 0; t < BMP_DIM; ++t) {
            C[tx] += A[(tx/BMP_DIM)*BMP_DIM+t] * B[t*BMP_DIM+(tx%BMP_DIM)];
        }

        __syncthreads();

    }

    float2 count;
    count.x = 0.f;
    count.y = 0.f;
    if (tx < BMP_DIM * BMP_DIM / 2) {
        count = *( (float2 *)C + (tx / (BMP_DIM / 2)) * BMP_DIM/2 + tx % (BMP_DIM / 2) );
//    }
#define BALLOT_MASK 0xffffffff
    uint32_t count1 = __ballot_sync(BALLOT_MASK, count.x);
    uint32_t count2 = __ballot_sync(BALLOT_MASK, count.y);

    if (tx == 0){
        result[blockIdx.x] = __popc(count1) + __popc(count2);
    }
    }
}

/* Removed bank conflicts when load/store TCU + 2 tiles per TCU  + more warps per block + remove shared memory for A and B
 *  by using direct fragment access */
__global__ void count_c_elems11_nT(uint32_t * offset_tile, int * A_gather_locations, const uint64_t * A_tiles,
        int * B_gather_locations, const uint64_t * B_tiles, uint32_t * result, uint32_t num_C_tiles) {

    int wid = threadIdx.x / WARP_SIZE;
    int lid = threadIdx.x % WARP_SIZE;

    int bx1 =
            blockIdx.x * TILES_BLOCK + wid * TILES_WARP < num_C_tiles ?
                    blockIdx.x * TILES_BLOCK + wid * TILES_WARP : blockIdx.x * TILES_BLOCK;
    int bx2 = bx1 + 1 < num_C_tiles ? bx1 + 1 : bx1;

    uint32_t start[2];
    uint32_t num_tile[2];

    start[0] = offset_tile[bx1];
    num_tile[0] = offset_tile[bx1 + 1] - start[0];

    start[1] = offset_tile[bx2];
    num_tile[1] = offset_tile[bx2 + 1] - start[1];

    wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::row_major> b;
    wmma::fragment<wmma::accumulator, M, N, K, half> acc;

    wmma::fill_fragment(acc, 0.0f);

    bitmap A_bmp1, B_bmp1;
    bitmap A_bmp2, B_bmp2;

    // For each tile of C, we have a loop to add all required products of A*B. Each tile product is calculated with TCUs
    for (int i1 = start[0], i2 = start[1] ; ; ++i1, ++i2) {
        bool end1 = i1 >= start[0] + num_tile[0];
        bool end2 = i2 >= start[1] + num_tile[1];

        // It is necessary to zero the locations of the inactive tile or else the previous result will be added
        // destroying the final result. Maybe I could just store the result before starting MAC for the active
        // tile

        // Zeroing is needed for initializing the fragment, as well as for stopping the accumulation with 2 tiles per warp
        wmma::fill_fragment(a, 0.0f); //Maybe there is a smarter way to zero only what I need to zero, but it doesn't
        wmma::fill_fragment(b, 0.0f); //seem to affect the performance.


        if (!end1 && !end2) {
            // We get the uint64 bmp for the tiles of A and B
            A_bmp1.bmp = A_tiles[A_gather_locations[i1]];
            B_bmp1.bmp = B_tiles[B_gather_locations[i1]];

            A_bmp2.bmp = A_tiles[A_gather_locations[i2]];
            B_bmp2.bmp = B_tiles[B_gather_locations[i2]];

            // The bits of the pair that are 1 will be converted to a half with value of 1 or 0 otherwise.

            a.x[0] = (A_bmp1.bmp & (1ULL<<lid*2)) > 0;
            a.x[8] = a.x[0]; //Setting the values of the second 8 values of the fragment doesn't seem to affect the multiplication
            a.x[1] = (A_bmp1.bmp & (2ULL<<lid*2)) > 0;
            a.x[9] = a.x[1];

            uint32_t bi = lid%4*16 + lid/4;
            b.x[0] = (B_bmp1.bmp & (1ULL<<bi)) > 0;
            b.x[8] = b.x[0];
            bi += 8;
            b.x[1] = (B_bmp1.bmp & (1ULL<<bi)) > 0;
            b.x[9] = b.x[1];

            a.x[6] = (A_bmp2.bmp & (1ULL<<lid*2)) > 0;
            a.x[14] = a.x[6];
            a.x[7] = (A_bmp2.bmp & (2ULL<<lid*2)) > 0;
            a.x[15] = a.x[7];

            bi = lid%4*16 + lid/4;
            b.x[6] = (B_bmp2.bmp & (1ULL<<bi)) > 0;
            b.x[14] = b.x[6];
            bi += 8;
            b.x[7] = (B_bmp2.bmp & (1ULL<<bi)) > 0;
            b.x[15] = b.x[7];

            wmma::mma_sync(acc, a, b, acc);
        } else if (!end1) {
            // We get the uint64 bmp for the tiles of A and B
            A_bmp1.bmp = A_tiles[A_gather_locations[i1]];
            B_bmp1.bmp = B_tiles[B_gather_locations[i1]];

            // The bits of the pair that are 1 will be converted to a half with value of 1 or 0 otherwise.

            a.x[0] = (A_bmp1.bmp & (1ULL<<lid*2)) > 0;
            a.x[8] = a.x[0]; //Setting the values of the second 8 values of the part doesn't seem to affect the multiplication
            a.x[1] = (A_bmp1.bmp & (2ULL<<lid*2)) > 0;
            a.x[9] = a.x[1];

            uint32_t bi = lid%4*16 + lid/4;
            b.x[0] = (B_bmp1.bmp & (1ULL<<bi)) > 0;
            b.x[8] = b.x[0];
            bi += 8;
            b.x[1] = (B_bmp1.bmp & (1ULL<<bi)) > 0;
            b.x[9] = b.x[1];

            wmma::mma_sync(acc, a, b, acc);
        } else if (!end2) {
            // We get the uint64 bmp for the tiles of A and B
            A_bmp2.bmp = A_tiles[A_gather_locations[i2]];
            B_bmp2.bmp = B_tiles[B_gather_locations[i2]];

            // The bits of the pair that are 1 will be converted to a half with value of 1 or 0 otherwise.

            a.x[6] = (A_bmp2.bmp & (1ULL<<lid*2)) > 0;
            a.x[14] = a.x[6];
            a.x[7] = (A_bmp2.bmp & (2ULL<<lid*2)) > 0;
            a.x[15] = a.x[7];

            uint32_t bi = lid%4*16 + lid/4;
            b.x[6] = (B_bmp2.bmp & (1ULL<<bi)) > 0;
            b.x[14] = b.x[6];
            bi += 8;
            b.x[7] = (B_bmp2.bmp & (1ULL<<bi)) > 0;
            b.x[15] = b.x[7];

            wmma::mma_sync(acc, a, b, acc);
        } else {
            break;
        }

    }

    half2 count1, count2;

    count1.x = acc.x[0];
    count1.y = acc.x[1];
    count2.x = acc.x[6];
    count2.y = acc.x[7];

#define BALLOT_MASK 0xffffffff
    uint32_t countA1 = __ballot_sync(BALLOT_MASK, count1.x);
    uint32_t countB1 = __ballot_sync(BALLOT_MASK, count1.y);
    uint32_t countA2 = __ballot_sync(BALLOT_MASK, count2.x);
    uint32_t countB2 = __ballot_sync(BALLOT_MASK, count2.y);


    if (lid == 0){
        if (bx1 < num_C_tiles) result[bx1] = __popc(countA1) + __popc(countB1);
        if (bx2 < num_C_tiles) result[bx2] = __popc(countA2) + __popc(countB2);
    }

}

__global__ void multiply_elems_noTCU_nT(uint32_t * offset_tile, int * A_gather_locations, const uint64_t * A_tiles,
        const float * A_elems, const uint32_t * A_idx, const int * A_row_indices, int * B_gather_locations,
        const uint64_t * B_tiles, const float * B_elems, const uint32_t * B_idx, const int * B_column_indices,
        uint64_t * C_tiles, float * C_elems, uint32_t * C_idx, int * C_row_indices, int * C_column_indices, uint32_t * idx,
        uint32_t block_offset) {

    int bx = blockIdx.x + block_offset;

    uint32_t num_counted_elems = idx[bx + 1] - idx[bx];
    // Do work iff the counting kernel showed > 0 elements. There is no divergence here because a C tile is processed by a whole block.
    // num_counted_elems == 0 means that all nnz of tiles in the sum of products of tiles were multiplied only with zero.
    // It is a form of cancellation, which happens when tiles are very sparse and nnz just don't happen to get multiplied
    // with other nnz. Such form of cancellation can be detected by the counting kernel. But the counting kernel, which
    // doesn't load any value, doesn't take into consideration cancellation because of adding opposite numbers.
    if (num_counted_elems > 0) {

        __shared__ float A[BMP_DIM * BMP_DIM];
        __shared__ float B[BMP_DIM * BMP_DIM];
        __shared__ float C[BMP_DIM * BMP_DIM];

        int tx = threadIdx.x;

        uint32_t start = offset_tile[bx];
        uint32_t num_tile = offset_tile[bx + 1] - start;

        for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
            *((float *)(&(A[i]))) = 0.0f; //TODO vector transfers are better probably

        for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
            *((float *)(&(B[i]))) = 0.0f;

        for (int i = threadIdx.x; i < BMP_DIM * BMP_DIM; i += blockDim.x)
            *((float *)(&(C[i]))) = 0.0f;

        __syncthreads();

        bitmap A_bmp, B_bmp;

        // For each tile of C, we have a loop to add all required products of A*B.
        for (int i = start; i < start + num_tile; ++i) {
            if (tx < BMP_DIM * BMP_DIM) {
                // We get the uint64 bmp for the tiles of A and B
                A_bmp.bmp = A_tiles[A_gather_locations[i]];
                B_bmp.bmp = B_tiles[B_gather_locations[i]];

                float A_val = 0, B_val = 0;

                // Here each thread will load the elements of the bmps.
                if ((A_bmp.bmp & (1ULL<<tx))>0){
                    A_val = *(A_elems + A_idx[A_gather_locations[i]] + __popcll(A_bmp.bmp << (BMP_DIM*BMP_DIM - tx)));
                }
                if ((B_bmp.bmp & (1ULL<<tx))>0){
                    B_val = *(B_elems + B_idx[B_gather_locations[i]] + __popcll(B_bmp.bmp << (BMP_DIM*BMP_DIM - tx)));
                }

                // stored in shared memory
                A[(tx / BMP_DIM) * BMP_DIM + tx % BMP_DIM] = A_val;
                B[(tx / BMP_DIM) * BMP_DIM + tx % BMP_DIM] = B_val;

            }

            __syncthreads();

            for (int t = 0; t < BMP_DIM; ++t) {
                C[tx] += A[(tx/BMP_DIM)*BMP_DIM+t] * B[t*BMP_DIM+(tx%BMP_DIM)];
            }

            __syncthreads();
        }

        float2 C_result = make_float2(0.f, 0.f);

        //C_result.x will contain the 1st 32 results and C_result.y will contain the next 32. This is
        //necessary in order to mark proper positions in bmp
        if (tx < BMP_DIM * BMP_DIM / 2) { //TODO in non-TCU version I could use all 64 threads instead
            C_result.x = C[(tx / BMP_DIM) * BMP_DIM + tx % BMP_DIM];
            C_result.y = C[((tx + WARP_SIZE) / BMP_DIM) * BMP_DIM + tx % BMP_DIM];


    #define BALLOT_MASK_MUL 0xffffffff

        bitmap C_bmp;
        C_bmp.half_bmp_start[0] = __ballot_sync(BALLOT_MASK_MUL, C_result.x != 0.f);
        C_bmp.half_bmp_start[1] = __ballot_sync(BALLOT_MASK_MUL, C_result.y != 0.f);

        uint32_t num_elems = __popcll(C_bmp.bmp);

        //The real number of nnz elements may be different than what was calculated by the counting kernel due to
        //cancellation (adding opposite products or the product was too small to fit in fp16 range - the latter doesn't
        //apply to mixed precision).
        if (num_elems > 0) {

            // Since C_elems is initialized to 0 (outside the kernel), if there is cancellation the elements which are not
            // accessed will be 0, and thus they will be removed when compacting.
            if ((C_bmp.bmp & (1 << tx))>0){
                C_elems[idx[bx] + num_elems - __popcll(C_bmp.bmp >> tx)] = C_result.x; // Implicit conversion to float
            }
            if ((C_bmp.bmp & (1ULL << tx + WARP_SIZE))>0){
                C_elems[idx[bx] + num_elems - __popcll(C_bmp.bmp >> tx + WARP_SIZE)] = C_result.y;
            }

            if (tx==0){
                C_tiles[bx] = C_bmp.bmp;

                C_row_indices[bx] = A_row_indices[ A_gather_locations[start] ];
                C_column_indices[bx] = B_column_indices[ B_gather_locations[start] ];
                // The "idx" part of the [idx,bmp] with the following assignement will hold the count of elements in
                // the respective tile. To make it work properly we  first remove empty tiles, then use scan of num_elems
                // of all tiles and finally compact element array (after this kernel finishes its execution). Better than
                // scanning the population count of the bitmaps which are 64-bit or more.
                C_idx[bx] = num_elems;
            }
        } else { // num_elems == 0
            // Tell the compaction routine that it needs to remove some values from C_tiles
            if (tx==0)
                C_idx[bx] = UINT32_MAX;
        }
        }
    } else { // Cancellation because of no nnz multiplied with each other
        // Tell the compaction routine that it needs to remove some values from C_tiles
        if (threadIdx.x==0)
            C_idx[bx] = UINT32_MAX;
    }

}

__global__ void multiply_elemsMixed12_nT(uint32_t * offset_tile, int * A_gather_locations, const uint64_t * A_tiles,
        const float * A_elems, const uint32_t * A_idx, const int * A_row_indices, int * B_gather_locations,
        const uint64_t * B_tiles, const float * B_elems, const uint32_t * B_idx, const int * B_column_indices,
        uint64_t * C_tiles, float * C_elems, uint32_t * C_idx, int * C_row_indices, int * C_column_indices, uint32_t * idx,
        uint32_t num_C_tiles) {

    __shared__ float  C[M * N * WARPS_BLOCK];

    int wid = threadIdx.x / WARP_SIZE;
    int lid = threadIdx.x % WARP_SIZE;

    int bx1 = blockIdx.x * TILES_BLOCK + wid*TILES_WARP < num_C_tiles ? blockIdx.x * TILES_BLOCK + wid*TILES_WARP : blockIdx.x * TILES_BLOCK;
    int bx2 = bx1 + 1 < num_C_tiles ? bx1 + 1 : bx1;

    uint32_t start[2];
    uint32_t num_tile[2];

    start[0] = offset_tile[bx1];
    num_tile[0] = offset_tile[bx1 + 1] - start[0];

    start[1] = offset_tile[bx2];
    num_tile[1] = offset_tile[bx2 + 1] - start[1];

    wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::row_major> b;
    wmma::fragment<wmma::accumulator, M, N, K, float> acc;

    wmma::fill_fragment(acc, 0.0f);

    bitmap A_bmp[2], B_bmp[2];

    // For each tile of C, we have a loop to add all required products of A*B. Each tile product is calculated with TCUs
    for (int i1 = start[0], i2 = start[1] ; ; ++i1, ++i2) {
        bool end1 = i1 >= start[0] + num_tile[0];
        bool end2 = i2 >= start[1] + num_tile[1];

        if (end1 && end2) break;

        // It is necessary to zero the locations of the inactive tile or else the previous result will be added
        // destroying the final result.

        // Zeroing is needed for initializing the fragment, as well as for stopping the accumulation with 2 tiles per warp
        wmma::fill_fragment(a, 0.0f);
        wmma::fill_fragment(b, 0.0f);

        // Tile 1
        if (!end1){
            // We get the uint64 bmp for the tiles of A and B
            A_bmp[0].bmp = A_tiles[A_gather_locations[i1]];
            B_bmp[0].bmp = B_tiles[B_gather_locations[i1]];

            // Here each thread will load the elements corresponding to 2 consecutive bits of the bmps.
            // Implicit conversion to fp16
            if ((A_bmp[0].bmp & (1ULL<<lid*2))>0){
                a.x[0] = *(A_elems + A_idx[A_gather_locations[i1]] + __popcll(A_bmp[0].bmp << (BMP_DIM*BMP_DIM - 2*lid)));
                a.x[8] = a.x[0]; //Setting the values of the second 8 values of the fragment doesn't seem to affect the multiplication
            }
            if ((A_bmp[0].bmp & (2ULL<<lid*2))>0){
                a.x[1] = *(A_elems + A_idx[A_gather_locations[i1]] + __popcll(A_bmp[0].bmp << (BMP_DIM*BMP_DIM - 2*lid -1)));
                a.x[9] = a.x[1];
            }

            uint32_t bi = lid%4*16 + lid/4;
            if ((B_bmp[0].bmp & (1ULL<<bi))>0){
                b.x[0] = *(B_elems + B_idx[B_gather_locations[i1]] + __popcll(B_bmp[0].bmp << (BMP_DIM*BMP_DIM - bi)));
                b.x[8] = b.x[0];
            }
            bi += 8;
            if ((B_bmp[0].bmp & (1ULL<<bi))>0){
                b.x[1] = *(B_elems + B_idx[B_gather_locations[i1]] + __popcll(B_bmp[0].bmp << (BMP_DIM*BMP_DIM - bi)));
                b.x[9] = b.x[1];
            }
        }

        // Tile 2
        if (!end2){
            A_bmp[1].bmp = A_tiles[A_gather_locations[i2]];
            B_bmp[1].bmp = B_tiles[B_gather_locations[i2]];

            if ((A_bmp[1].bmp & (1ULL<<lid*2))>0){
                a.x[6] = *(A_elems + A_idx[A_gather_locations[i2]] + __popcll(A_bmp[1].bmp << (BMP_DIM*BMP_DIM - 2*lid)));
                a.x[14] = a.x[6];
            }
            if ((A_bmp[1].bmp & (2ULL<<lid*2))>0){
                a.x[7] = *(A_elems + A_idx[A_gather_locations[i2]] + __popcll(A_bmp[1].bmp << (BMP_DIM*BMP_DIM - 2*lid -1)));
                a.x[15] = a.x[7];
            }

            uint32_t bi = lid%4*16 + lid/4;
            if ((B_bmp[1].bmp & (1ULL<<bi))>0){
                b.x[6] = *(B_elems + B_idx[B_gather_locations[i2]] + __popcll(B_bmp[1].bmp << (BMP_DIM*BMP_DIM - bi)));
                b.x[14] = b.x[6];
            }
            bi += 8;
            if ((B_bmp[1].bmp & (1ULL<<bi))>0){
                b.x[7] = *(B_elems + B_idx[B_gather_locations[i2]] + __popcll(B_bmp[1].bmp << (BMP_DIM*BMP_DIM - bi)));
                b.x[15] = b.x[7];
            }
        }

        wmma::mma_sync(acc, a, b, acc);
    }

    wmma::store_matrix_sync(&C[wid * M*N], acc, M, wmma::mem_row_major);

    __syncwarp();


    float2 C_result1, C_result2;


#define BALLOT_MASK_MUL 0xffffffff
    bitmap C_bmp1, C_bmp2;
    uint32_t num_elems1, num_elems2;

    // Tile 1
    C_result1 = make_float2(0.f, 0.f);

    //C_result.x will contain the 1st 32 results and C_result.y will contain the next 32. This is
    //necessary in order to mark proper positions in bmp
    C_result1.x = C[(lid / BMP_DIM) * M + lid % BMP_DIM + wid*(M * N)];
    C_result1.y = C[((lid + WARP_SIZE) / BMP_DIM) * M + lid % BMP_DIM + wid*(M * N)];
    C_bmp1.half_bmp_start[0] = __ballot_sync(BALLOT_MASK_MUL, C_result1.x != 0.f);
    C_bmp1.half_bmp_start[1] = __ballot_sync(BALLOT_MASK_MUL, C_result1.y != 0.f);

    num_elems1 = __popcll(C_bmp1.bmp);

    // Since C_elems is initialized to 0 (outside the kernel), if there is cancellation the elements which are not
    // accessed will be 0, and thus they will be removed when compacting.

    if (num_elems1){
        if ((C_bmp1.bmp & (1 << lid))>0){
            C_elems[idx[bx1] + num_elems1 - __popcll(C_bmp1.bmp >> lid)] = C_result1.x; // Implicit conversion to float
        }
        if ((C_bmp1.bmp & (1ULL << lid + WARP_SIZE))>0){  // XXX Disable to test with small tiles
            C_elems[idx[bx1] + num_elems1 - __popcll(C_bmp1.bmp >> lid + WARP_SIZE)] = C_result1.y;
        }

        if (lid ==0) {
            C_tiles[bx1] = C_bmp1.bmp;

            C_row_indices[bx1] = A_row_indices[ A_gather_locations[start[0]] ];
            C_column_indices[bx1] = B_column_indices[ B_gather_locations[start[0]] ];

            // The "idx" part of the [idx,bmp] with the following assignment will hold the count of elements in
            // the respective tile. To make it work properly we  first remove empty tiles, then use scan of num_elems
            // of all tiles and finally compact element array (after this kernel finishes its execution). Better than
            // scanning the population count of the bitmaps which are 64-bit or more.
            C_idx[bx1] = num_elems1;
        }
    } else {
        //The real number of nnz elements may be different than what was calculated by the counting kernel due to
        //cancellation (adding opposite products or the product was too small to fit in fp16 range - the latter doesn't
        //apply to mixed precision). (num_elems == 0)
        // Tell the compaction routine that it needs to remove some values from C_tiles
        if (lid==0)
            C_idx[bx1] = UINT32_MAX;
    }


    // Tile 2
    C_result2 = make_float2(0.f, 0.f);

    C_result2.x = C[(lid / BMP_DIM) * M + lid % BMP_DIM + (M*N/2 + BMP_DIM) + wid*(M * N)];
    C_result2.y = C[((lid + WARP_SIZE) / BMP_DIM) * M + lid % BMP_DIM + (M*N/2 + BMP_DIM) + wid*(M * N)];

    C_bmp2.half_bmp_start[0] = __ballot_sync(BALLOT_MASK_MUL, C_result2.x != 0.f);
    C_bmp2.half_bmp_start[1] = __ballot_sync(BALLOT_MASK_MUL, C_result2.y != 0.f);

    num_elems2 = __popcll(C_bmp2.bmp);

    if (num_elems2){
        if ((C_bmp2.bmp & (1 << lid))>0){
            C_elems[idx[bx2] + num_elems2 - __popcll(C_bmp2.bmp >> lid)] = C_result2.x; // Implicit conversion to float
        }
        if ((C_bmp2.bmp & (1ULL << lid + WARP_SIZE))>0){
            C_elems[idx[bx2] + num_elems2 - __popcll(C_bmp2.bmp >> lid + WARP_SIZE)] = C_result2.y;
        }

        if (lid==0){
            C_tiles[bx2] = C_bmp2.bmp;

            C_row_indices[bx2] = A_row_indices[ A_gather_locations[start[1]] ];
            C_column_indices[bx2] = B_column_indices[ B_gather_locations[start[1]] ];

            // The "idx" part of the [idx,bmp] with the following assignment will hold the count of elements in
            // the respective tile. To make it work properly we  first remove empty tiles, then use scan of num_elems
            // of all tiles and finally compact element array (after this kernel finishes its execution). Better than
            // scanning the population count of the bitmaps which are 64-bit or more.
            C_idx[bx2] = num_elems2;
        }
    } else {
        // Tell the compaction routine that it needs to remove some values from C_tiles
        if (lid==0)
            C_idx[bx2] = UINT32_MAX; // Maybe it's better checking idx instead of bmp, which is 64-bits
    }

}

struct tile_is_empty_noTuple
{
  __host__ __device__
  bool operator()(uint32_t x) //TODO does that x is passed by value affects performance?
  {                                                   // probably not, instead of passing two iterators we pass two values
    return x == UINT32_MAX;
  }
};

struct mm_test_noTuple : public thrust::binary_function<int,int,uint32_t>
{
    const uint64_t * tileA_, * tileB_;

    mm_test_noTuple(const uint64_t *tileA, const uint64_t *tileB): tileA_(tileA), tileB_(tileB) {}

    __host__ __device__
    uint32_t operator()(const int& a, const int& b)
    {
        uint64_t a_mask = 0x8080808080808080;
        uint64_t b_mask = 0xff00000000000000;
        uint32_t result = 0;
        for (int i = 0; i < BMP_DIM; ++i) {
            result = ((tileA_[a] & a_mask)
                   && (tileB_[b] & b_mask)) || result;
            if (result) break;
            a_mask >>= 1;
            b_mask >>= BMP_DIM;
        }
        return result;
    }
};

struct tile_reduction // : public thrust::binary_function<uint64_t,uint64_t,uint64_t>
{
    using BMPType = uint64_t;

    __host__ __device__
    thrust::tuple<BMPType, int> operator()(const thrust::tuple<const BMPType, const int> a, const thrust::tuple<const BMPType, const int> b)
    {
        thrust::tuple<BMPType, int> out;
        out.get<0>() = a.get<0>() | b.get<0>();
        out.get<1>() = a.get<1>() + b.get<1>();

        return out;
    }
};

struct bmp_popcount_gpu
{
    using BMPType = uint64_t;

  __device__
  thrust::tuple<BMPType, int> operator()(const thrust::tuple<const BMPType, const int> rhs)
  {
      thrust::tuple<BMPType, int> out;
      out.get<0>() = __popcll( rhs.get<0>() );
      out.get<1>() = rhs.get<1>();

      return out; //TODO not CPU compatible
  }
};

struct sub_mean
{
    float mean_;

    sub_mean(float mean) : mean_(mean) {}

  __host__ __device__
  float operator()(const float &x)
  {
      return (float) (x - mean_) * (x - mean_);
  }
};

struct greater_1664
{
  __host__ __device__
  bool operator()(uint32_t x)
  {
    return x > 1664;
  }
};


__host__ __device__ uint32_t is_power_of_2(uint32_t number){

    return (number & (number-1)) == 0; //This will also count 0 as a power of 2.
}

__host__ __device__ uint32_t log_2(uint32_t v){

    //    unsigned int v;          // 32-bit value to find the log2 of
    register unsigned int r; // result of log2(v) will go here
    register unsigned int shift;

    r =     (v > 0xFFFF) << 4; v >>= r;
    shift = (v > 0xFF  ) << 3; v >>= shift; r |= shift;
    shift = (v > 0xF   ) << 2; v >>= shift; r |= shift;
    shift = (v > 0x3   ) << 1; v >>= shift; r |= shift;
                                            r |= (v >> 1);
    return r +1;
}

template <typename DerivedPolicy,
          typename MatrixType1,
          typename MatrixType2,
          typename MatrixType3,
          typename ArrayType1,
          typename ArrayType2>
void coo_spmm_helper_noTuple(cusp::cuda::execution_policy<DerivedPolicy>& exec,
                     size_t workspace_size,
                     size_t begin_row,
                     size_t end_row,
                     size_t begin_segment,
                     size_t end_segment,
                     const MatrixType1& A,
                     const thrust::device_vector<float>& A_elems,
                     const thrust::device_vector<uint32_t>& A_idx,
                     const MatrixType2& B,
                     const thrust::device_vector<float>& B_elems,
                     const thrust::device_vector<uint32_t>& B_idx,
                     MatrixType3& C,
                     thrust::device_vector<float>& C_elems,
                     thrust::device_vector<uint32_t>& C_idx,
                     const ArrayType1& B_row_offsets,
                     const ArrayType1& segment_lengths, //contains with how many values each value of A must be multiplied (in the same order/positions as A.column_indices)
                     const ArrayType1& output_ptr, //The exclusive scan of segment_lengths
                     ArrayType1& I,
                     ArrayType1& J,
                     ArrayType2& V)
{
    thrust::system::cuda::memory_resource cuMemRes;
    thrust::mr::new_delete_resource memRes;

    typedef thrust::mr::disjoint_unsynchronized_pool_resource<
            thrust::system::cuda::memory_resource,
            thrust::mr::new_delete_resource
    > Pool;
    Pool pool(&cuMemRes, &memRes);

    typedef thrust::mr::allocator<int, Pool> Alloc;
    Alloc alloc(&pool);
//    typedef thrust::mr::allocator<int, thrust::system::cuda::memory_resource> Alloc;
//    Alloc alloc(&cuMemRes);

    typedef typename ArrayType1::value_type IndexType;
    typedef typename ArrayType2::value_type ValueType;

    thrust::device_vector<IndexType> A_gather_locations;
    thrust::device_vector<IndexType> B_gather_locations;

    PUSH_RANGE("task_list_creation",3)

    A_gather_locations.resize(workspace_size);
    B_gather_locations.resize(workspace_size);

    // nothing to do
    if (workspace_size == 0)
    {
        C.resize(A.num_rows, B.num_cols, 0);
        return;
    }

    // compute gather locations of intermediate format
    //Each value of each row of A is multiplied with as many values as each corresponding row of B has. output_ptr shows
    //how many values. We create A_gather_locations which holds, for each entry of A (in the same order/positions),
    //a segment wherein the index in entries of A is repeated as many times as the length of each segment.
    thrust::fill(thrust::cuda::par(alloc), A_gather_locations.begin(), A_gather_locations.end(), 0);
    thrust::scatter_if(thrust::cuda::par(alloc),
                       thrust::counting_iterator<IndexType>(begin_segment), thrust::counting_iterator<IndexType>(end_segment),
                       output_ptr.begin() + begin_segment,
                       segment_lengths.begin() + begin_segment,
                       A_gather_locations.begin() - output_ptr[begin_segment]);
    thrust::inclusive_scan(thrust::cuda::par(alloc), A_gather_locations.begin(), A_gather_locations.end(), A_gather_locations.begin(), thrust::maximum<IndexType>());

    // compute gather locations of intermediate format
    // The B_row_offset that corresponds to each value of A.column_indices is initially placed to the start of each segment
    // of B_gather_locations. The start is given by output_ptr, which contains the scan of segment lengths. Because
    // B_gather_locations entries are initialized to 1, the scan by key, essentially increases offset (and offset is equal
    // to the index in entries of B) by 1 in each consecutive place of a segment in B_gather_locations. Essentially, a
    // a segment contains the indices in entries of B of all the consecutive values of the corresponding row of B. As a key
    // to the scan by key we use A_gather_locations as it contains the same repeated value in each segment.
    // In conclusion, B_gather_locations holds the indices in entries of B that correspond to A_gather_locations.
    thrust::fill(thrust::cuda::par(alloc), B_gather_locations.begin(), B_gather_locations.end(), 1);
    thrust::scatter_if(thrust::cuda::par(alloc),
                       thrust::make_permutation_iterator(B_row_offsets.begin(), A.column_indices.begin()) + begin_segment,
                       thrust::make_permutation_iterator(B_row_offsets.begin(), A.column_indices.begin()) + end_segment,
                       output_ptr.begin() + begin_segment,
                       segment_lengths.begin() + begin_segment,
                       B_gather_locations.begin() - output_ptr[begin_segment]);
    thrust::inclusive_scan_by_key(thrust::cuda::par(alloc),
                                  A_gather_locations.begin(), A_gather_locations.end(),
                                  B_gather_locations.begin(),
                                  B_gather_locations.begin());

    POP_RANGE

    PUSH_RANGE("Remove_unnecessary_mm",4)

    uint32_t valid_count = workspace_size;

    // We create a tile even for 1 element. Tiles represent a large BMP_DIM*BMP_DIM area, and they are selected as
    // intermediate multiplicands independently of how many elements they actually contain. So it's more possible
    // that a tile will be selected as an intermediate multiplicand, in comparison to an algorithm which works on single
    // elements. For this reason we check inside the two intermediate multiplicands if there are any elements that will
    // actually be multiplied. We remove the tiles if there are not, so that the rest of the algorithm will have to work
    // on fewer tiles. The savings are usually better when we have sparser tiles.
    const uint64_t * raw_A_tiles_gather =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&A.values[0]) );
    const uint64_t * raw_B_tiles_gather =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&B.values[0]) );
    thrust::device_vector<uint32_t> valid_mm(A_gather_locations.size());
    thrust::transform(thrust::cuda::par(alloc), A_gather_locations.begin(), A_gather_locations.end(), B_gather_locations.begin(),
            valid_mm.begin(), mm_test_noTuple(raw_A_tiles_gather, raw_B_tiles_gather));
    auto gather_end = thrust::remove_if(thrust::cuda::par(alloc),
                    thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.begin(), B_gather_locations.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.end(), B_gather_locations.end())),
                    valid_mm.begin(), thrust::logical_not<uint32_t>());
    valid_count = gather_end
            - thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.begin(), B_gather_locations.begin()));
#if DEBUG
    std::cout << "***** C before " << A_gather_locations.size() << std::endl;
    std::cout << "***** C after " << valid_count << std::endl;
#endif
    A_gather_locations.resize(valid_count);
    B_gather_locations.resize(valid_count);

    I.resize(valid_count);
    J.resize(valid_count);

    POP_RANGE

    thrust::gather(thrust::cuda::par(alloc),
                   A_gather_locations.begin(), A_gather_locations.end(),
                   A.row_indices.begin(),
                   I.begin());
    thrust::gather(thrust::cuda::par(alloc),
                   B_gather_locations.begin(), B_gather_locations.end(),
                   B.column_indices.begin(),
                   J.begin());

    // parameter [A,B]_gather_locations: absolute index in row_indices, column_indices and values arrays of matrices
    // [A,B] (here value=tile). For each entry of A, for each valid multiplication with a value of B it keeps the index
    // in the aforementioned arrays.
    // parameter I,J: The [row,column] index of the value indicated by [A,B]_gather_locations respectively. Since I only
    //  contains the y-coordinate in A it is not possible to find which element of the specific row it is. Similarly for
    //  J and B. They are useful as indices for C, nonetheless.

    PUSH_RANGE("Sorting",5)
#if TIMING_VERBOSE
    timer t_sort;
#endif

    thrust::counting_iterator<uint32_t> iter(0);
    thrust::device_vector<uint32_t> sorted_indices(I.size());
    thrust::copy(thrust::cuda::par(alloc), iter, iter + sorted_indices.size(), sorted_indices.begin());

    PUSH_RANGE("Pure sorting",6)

    cusp::sort_by_row_and_column(exec, I, J, sorted_indices); //By sorting the counting iterator instead of the values I
    //can execute sort before multiplication, so that I can have multiplication and addition in the same kernel. I store
    //the result of sort in a buffer in order to reuse it later without re-sorting, as sorting is costly.
    //Sorting like in bmp2coo routine doesn't seem to help
    POP_RANGE

    // Rearrange gather location to include the sort by (I,J) info // TODO with permutation iterator and copy
    cusp::detail::temporary_array<IndexType, DerivedPolicy> A_gather_locations_sorted(exec, A_gather_locations.size());
    cusp::detail::temporary_array<IndexType, DerivedPolicy> B_gather_locations_sorted(exec, B_gather_locations.size());
    thrust::gather(thrust::cuda::par(alloc), sorted_indices.begin(), sorted_indices.end(),
            A_gather_locations.begin(), A_gather_locations_sorted.begin());
    thrust::gather(thrust::cuda::par(alloc), sorted_indices.begin(), sorted_indices.end(),
            B_gather_locations.begin(), B_gather_locations_sorted.begin());

#if TIMING_VERBOSE
    float time_elapsed_sort = t_sort.milliseconds_elapsed();
    printf("**** Sorting time: %9.2f ms\n", time_elapsed_sort);
#endif
    POP_RANGE

    // Count the addends needed by each value of C ( (I,J) is sorted )
//    thrust::device_vector<uint32_t> keys(A.row_indices.size()); it's discarded currently, but it should be initialized with tuple, not uint32...
    thrust::device_vector<uint32_t> keys_count(I.size() +1); //+1 for the unlikely case that there are no accumulations (that would cause problems with last value with the following scan)
    auto new_end = thrust::reduce_by_key(thrust::cuda::par(alloc),
            thrust::make_zip_iterator(thrust::make_tuple(I.begin(), J.begin())),
            thrust::make_zip_iterator(thrust::make_tuple(I.end(), J.end())),
            thrust::make_constant_iterator(1), thrust::make_discard_iterator(),
            keys_count.begin());

    // Count is good for knowing how many values I need to accumulate, which in turn also helps with calculating
    // how many elements will be in each tile of C

    uint32_t num_C_tiles = new_end.second - keys_count.begin();

    // allocate space for output //for (bmp) only
    C.resize(A.num_rows, B.num_cols, num_C_tiles);
    C_idx.resize(num_C_tiles);

    //Now offset_tile will contain the scan of keys_count, and therefore the indices in the intermediate buffer to the first bmp
    //tile of each unique set of indices I,J
    thrust::device_vector<uint32_t> offset_tile(num_C_tiles + 1);
    thrust::exclusive_scan(thrust::cuda::par(alloc), keys_count.begin(), new_end.second + 1, offset_tile.begin(), uint32_t(0));

    int gridDim = num_C_tiles;
    int gridDim2 = (num_C_tiles + 2-1) / 2; // 2 tiles per warp
    int gridDim3 = (num_C_tiles + TILES_BLOCK -1) / TILES_BLOCK; // 4 tiles / 2 warps
    int blockDim1 = WARP_SIZE;
    int blockDim2 = BMP_DIM * BMP_DIM;
    int blockDim3 = WARP_SIZE * WARPS_BLOCK;

#if DEBUG
    std::cout << "Grid size (= num_C_tiles) " << gridDim << std::endl;
#endif

    uint32_t * raw_sorted_indices = thrust::raw_pointer_cast(&sorted_indices[0]);
    int * raw_A_gather_uns = thrust::raw_pointer_cast(&A_gather_locations[0]);
    int * raw_B_gather_uns = thrust::raw_pointer_cast(&B_gather_locations[0]);

    uint32_t * raw_offset_tile = thrust::raw_pointer_cast(&offset_tile[0]);
    int * raw_A_gather = thrust::raw_pointer_cast(&A_gather_locations_sorted[0]);
    int * raw_B_gather = thrust::raw_pointer_cast(&B_gather_locations_sorted[0]);
    const uint64_t * raw_A_tiles =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&A.values[0]) );
    const uint64_t * raw_B_tiles =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&B.values[0]) );

    // Contains how many elements there are in each tile of C
    thrust::device_vector<uint32_t> counts(num_C_tiles +1); //+1 so that I can get last entry of exclusive scan without problems
    uint32_t * raw_counts = thrust::raw_pointer_cast(&counts[0]);

    PUSH_RANGE("Counting kernel",6)
#if TIMING_VERBOSE
    timer t_count;
#endif
    // offset_tile: offset to A_gather and B_gather, indicating where unique (I,J) pairs begin.
    //Returns raw_counts: each value of raw_counts holds the number of elements each tile of C will contain (without counting for cancellations)
//    count_c_elems_noTCU_nT<<<gridDim, blockDim2>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_B_gather, raw_B_tiles,
//            raw_counts);
    count_c_elems11_nT<<<gridDim3, blockDim3>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_B_gather, raw_B_tiles,
            raw_counts, num_C_tiles);

#if TIMING_VERBOSE
    float time_elapsed_count = t_count.milliseconds_elapsed();
    printf("**** Count kernel: %9.2f ms\n", time_elapsed_count);
#endif
    POP_RANGE

#if DEBUG_API
    gpuErrchk( cudaPeekAtLastError() );
    gpuErrchk( cudaDeviceSynchronize() );
#endif

    // The offset in the element array of C, that indicates the starting position of each tile of C
    thrust::device_vector<uint32_t> idx(num_C_tiles + 1);
    thrust::exclusive_scan(thrust::cuda::par(alloc), counts.begin(), counts.end(), idx.begin(), uint32_t(0));

    uint32_t NNZ_Elem = idx[num_C_tiles];
    C_elems.resize(NNZ_Elem);
    //The zeros will not be accessed if there is cancellation, and thus we can compact
    thrust::fill(C_elems.begin(), C_elems.end(), 0.f);

    uint64_t * raw_C_tiles =  reinterpret_cast<uint64_t *>( thrust::raw_pointer_cast(&C.values[0]) );
    const float *raw_A_elems = thrust::raw_pointer_cast(&A_elems[0]);
    const uint32_t *raw_A_idx = thrust::raw_pointer_cast(&A_idx[0]);
    const int * raw_A_row_indices =  thrust::raw_pointer_cast(&A.row_indices[0]);
    const float *raw_B_elems = thrust::raw_pointer_cast(&B_elems[0]);
    const uint32_t *raw_B_idx = thrust::raw_pointer_cast(&B_idx[0]);
    const int * raw_B_column_indices =  thrust::raw_pointer_cast(&B.column_indices[0]);
    float *raw_C_elems = thrust::raw_pointer_cast(&C_elems[0]);
    uint32_t *raw_C_idx = thrust::raw_pointer_cast(&C_idx[0]);
    int * raw_C_row_indices =  thrust::raw_pointer_cast(&C.row_indices[0]);
    int * raw_C_column_indices =  thrust::raw_pointer_cast(&C.column_indices[0]);
    uint32_t *raw_idx = thrust::raw_pointer_cast(&idx[0]);

    PUSH_RANGE("Multiplication kernel",7)
#if TIMING_VERBOSE
    timer t_mul;
#endif
//    multiply_elems_noTCU_nT<<<gridDim, blockDim2>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_A_elems, raw_A_idx,
//            raw_A_row_indices, raw_B_gather, raw_B_tiles, raw_B_elems, raw_B_idx, raw_B_column_indices, raw_C_tiles,
//            raw_C_elems, raw_C_idx, raw_C_row_indices, raw_C_column_indices, raw_idx, 0);
    multiply_elemsMixed12_nT<<<gridDim3, blockDim3>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_A_elems, raw_A_idx,
            raw_A_row_indices, raw_B_gather, raw_B_tiles, raw_B_elems, raw_B_idx, raw_B_column_indices, raw_C_tiles,
            raw_C_elems, raw_C_idx, raw_C_row_indices, raw_C_column_indices, raw_idx, num_C_tiles);

#if TIMING_VERBOSE
    float time_elapsed_mul = t_mul.milliseconds_elapsed();
    printf("**** Multiply kernel: %9.2f ms\n", time_elapsed_mul);
#endif
    POP_RANGE

#if DEBUG_API
    gpuErrchk( cudaPeekAtLastError() );
    gpuErrchk( cudaDeviceSynchronize() );
#endif

    /* Remove empty tiles */

    PUSH_RANGE("Compact",8)

    int num_zeros = thrust::count_if(thrust::cuda::par(alloc), C_idx.begin(), C_idx.end(), tile_is_empty_noTuple());

    if(num_zeros != 0)
    {
        int num_reduced_entries =
            thrust::remove_if(thrust::cuda::par(alloc),
                thrust::make_zip_iterator(
                  thrust::make_tuple(C.row_indices.begin(), C.column_indices.begin(), C.values.begin(), C_idx.begin())),
                thrust::make_zip_iterator(
                  thrust::make_tuple(C.row_indices.end(),   C.column_indices.end(), C.values.end(), C_idx.end())),
                C_idx.begin(),
                tile_is_empty_noTuple()) -
            thrust::make_zip_iterator(
                thrust::make_tuple(C.row_indices.begin(), C.column_indices.begin(), C.values.begin(), C_idx.begin()));

        C.resize(C.num_rows, C.num_cols, num_reduced_entries);
        C_idx.resize(num_reduced_entries);
    }

#if DEBUG
    std::cout << "Number of empty tiles of C: " << num_zeros << std::endl;
#endif

    /* The "idx" of the tuple in C.values after the multiply_elems kernel holds the count of elements in each valid
     * tile. We need to scan the "idx" array in order to get the offsets in elem_array */

    thrust::exclusive_scan(thrust::cuda::par(alloc), C_idx.begin(), C_idx.end(), C_idx.begin());


    /* Remove elements that are zero to produce a strictly valid COO matrix */

    auto new_end_C_elems = thrust::remove(C_elems.begin(), C_elems.end(), 0.f);

#if DEBUG
    std::cout << "Number of elements that are 0 due to cancellation in elements array of C: "
            << C_elems.end() - new_end_C_elems << std::endl;
#endif

    C_elems.resize(new_end_C_elems - C_elems.begin());

    POP_RANGE

}

/* Sorting optimizations */
template <typename DerivedPolicy,
          typename MatrixType1,
          typename MatrixType2,
          typename MatrixType3,
          typename ArrayType1,
          typename ArrayType2>
void coo_spmm_helper_noTuple_sort(cusp::cuda::execution_policy<DerivedPolicy>& exec,
                     size_t workspace_size,
                     size_t begin_row,
                     size_t end_row,
                     size_t begin_segment,
                     size_t end_segment,
                     const MatrixType1& A,
                     const thrust::device_vector<float>& A_elems,
                     const thrust::device_vector<uint32_t>& A_idx,
                     const MatrixType2& B,
                     const thrust::device_vector<float>& B_elems,
                     const thrust::device_vector<uint32_t>& B_idx,
                     MatrixType3& C,
                     thrust::device_vector<float>& C_elems,
                     thrust::device_vector<uint32_t>& C_idx,
                     const ArrayType1& B_row_offsets,
                     const ArrayType1& segment_lengths, //contains with how many values each value of A must be multiplied (in the same order/positions as A.column_indices)
                     const ArrayType1& output_ptr, //The exclusive scan of segment_lengths
                     ArrayType1& I,
                     ArrayType1& J,
                     ArrayType2& V)
{
    typedef typename ArrayType1::value_type IndexType;
    typedef typename ArrayType2::value_type ValueType;

    thrust::device_vector<IndexType> A_gather_locations;
    thrust::device_vector<IndexType> B_gather_locations;

    PUSH_RANGE("task_list_creation",3)

    A_gather_locations.resize(workspace_size);
    B_gather_locations.resize(workspace_size);

    // nothing to do
    if (workspace_size == 0)
    {
        C.resize(A.num_rows, B.num_cols, 0);
        return;
    }

    // compute gather locations of intermediate format
    //Each value of each row of A is multiplied with as many values as each corresponding row of B has. output_ptr shows
    //how many values. We create A_gather_locations which holds, for each entry of A (in the same order/positions),
    //a segment wherein the index in entries of A is repeated as many times as the length of each segment.
    thrust::fill(exec, A_gather_locations.begin(), A_gather_locations.end(), 0);
    thrust::scatter_if(exec,
                       thrust::counting_iterator<IndexType>(begin_segment), thrust::counting_iterator<IndexType>(end_segment),
                       output_ptr.begin() + begin_segment,
                       segment_lengths.begin() + begin_segment,
                       A_gather_locations.begin() - output_ptr[begin_segment]);
    thrust::inclusive_scan(exec, A_gather_locations.begin(), A_gather_locations.end(), A_gather_locations.begin(), thrust::maximum<IndexType>());

    // compute gather locations of intermediate format
    // The B_row_offset that corresponds to each value of A.column_indices is initially placed to the start of each segment
    // of B_gather_locations. The start is given by output_ptr, which contains the scan of segment lengths. Because
    // B_gather_locations entries are initialized to 1, the scan by key, essentially increases offset (and offset is equal
    // to the index in entries of B) by 1 in each consecutive place of a segment in B_gather_locations. Essentially, a
    // a segment contains the indices in entries of B of all the consecutive values of the corresponding row of B. As a key
    // to the scan by key we use A_gather_locations as it contains the same repeated value in each segment.
    // In conclusion, B_gather_locations holds the indices in entries of B that correspond to A_gather_locations.
    thrust::fill(exec, B_gather_locations.begin(), B_gather_locations.end(), 1);
    thrust::scatter_if(exec,
                       thrust::make_permutation_iterator(B_row_offsets.begin(), A.column_indices.begin()) + begin_segment,
                       thrust::make_permutation_iterator(B_row_offsets.begin(), A.column_indices.begin()) + end_segment,
                       output_ptr.begin() + begin_segment,
                       segment_lengths.begin() + begin_segment,
                       B_gather_locations.begin() - output_ptr[begin_segment]);
    thrust::inclusive_scan_by_key(exec,
                                  A_gather_locations.begin(), A_gather_locations.end(),
                                  B_gather_locations.begin(),
                                  B_gather_locations.begin());

    POP_RANGE

    PUSH_RANGE("Remove_unnecessary_mm",4)

    uint32_t valid_count = workspace_size;

    // We create a tile even for 1 element. Tiles represent a large BMP_DIM*BMP_DIM area, and they are selected as
    // intermediate multiplicands independently of how many elements they actually contain. So it's more possible
    // that a tile will be selected as an intermediate multiplicand, in comparison to an algorithm which works on single
    // elements. For this reason we check inside the two intermediate multiplicands if there are any elements that will
    // actually be multiplied. We remove the tiles if there are not, so that the rest of the algorithm will have to work
    // on fewer tiles. The savings are usually better when we have sparser tiles.
    const uint64_t * raw_A_tiles_gather =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&A.values[0]) );
    const uint64_t * raw_B_tiles_gather =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&B.values[0]) );
    thrust::device_vector<uint32_t> valid_mm(A_gather_locations.size());
    thrust::transform(exec, A_gather_locations.begin(), A_gather_locations.end(), B_gather_locations.begin(),
            valid_mm.begin(), mm_test_noTuple(raw_A_tiles_gather, raw_B_tiles_gather));
    auto gather_end = thrust::remove_if(exec,
                    thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.begin(), B_gather_locations.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.end(), B_gather_locations.end())),
                    valid_mm.begin(), thrust::logical_not<uint32_t>());
    valid_count = gather_end
            - thrust::make_zip_iterator(thrust::make_tuple(A_gather_locations.begin(), B_gather_locations.begin()));
#if DEBUG
    std::cout << "***** C before " << A_gather_locations.size() << std::endl;
    std::cout << "***** C after " << valid_count << std::endl;
#endif
    A_gather_locations.resize(valid_count);
    B_gather_locations.resize(valid_count);

    I.resize(valid_count);
    J.resize(valid_count);

    POP_RANGE

    thrust::gather(exec,
                   A_gather_locations.begin(), A_gather_locations.end(),
                   A.row_indices.begin(),
                   I.begin());
    thrust::gather(exec,
                   B_gather_locations.begin(), B_gather_locations.end(),
                   B.column_indices.begin(),
                   J.begin());

    // parameter [A,B]_gather_locations: absolute index in row_indices, column_indices and values arrays of matrices
    // [A,B] (here value=tile). For each entry of A, for each valid multiplication with a value of B it keeps the index
    // in the aforementioned arrays.
    // parameter I,J: The [row,column] index of the value indicated by [A,B]_gather_locations respectively. Since I only
    //  contains the y-coordinate in A it is not possible to find which element of the specific row it is. Similarly for
    //  J and B. They are useful as indices for C, nonetheless.


    // Calculates how many products each row of A will produce, i.e. how many intermediate products per C row
    thrust::device_vector<IndexType> A_row_interm_size(A.num_rows);
    thrust::reduce_by_key(exec, I.begin(), I.end(), thrust::make_constant_iterator(1), thrust::make_discard_iterator(),
            A_row_interm_size.begin());

    const int threads_for_blocksort = 128;
    const int items_per_thread = 13;
    uint32_t max_prods = 1;

    thrust::host_vector<IndexType> A_row_interm_size_h(A_row_interm_size.size());
    thrust::copy(A_row_interm_size.begin(), A_row_interm_size.end(), A_row_interm_size_h.begin());

    auto it = A_row_interm_size_h.begin();
    thrust::host_vector<uint32_t> partitions_h(A.num_rows);

    int pi = 0;
    const uint32_t max_items = threads_for_blocksort * items_per_thread;
    uint32_t mem_big = 0; //memory to allocate in CUDA heap
    do {
        partitions_h[pi] = *it;
        if (partitions_h[pi] > max_items)
            mem_big += partitions_h[pi];
        while (partitions_h[pi] < max_prods){
            it++;
            if (it >= A_row_interm_size_h.end()) break;
            partitions_h[pi] += *it;
        }
        it++;
        pi++;
    } while (it < A_row_interm_size_h.end());

    thrust::device_vector<uint32_t> partitions(pi + 1); //+1 for the offset later
    thrust::copy(partitions_h.begin(), partitions_h.begin() + pi, partitions.begin());

#if DEBUG
    std::cout << "Memory to be allocated in CUDA heap: " << mem_big << std::endl;

    thrust::sort(partitions_h.begin(), partitions_h.end());
    float partitions_median = partitions_h[partitions_h.size() / 2];

    uint32_t partitions_acc = thrust::reduce(partitions_h.begin(), partitions_h.end());
    float partitions_average = (float)partitions_acc / partitions_h.size();

    float partitions_std = thrust::transform_reduce(partitions_h.begin(), partitions_h.end(), sub_mean(partitions_average),
            0.f, thrust::plus<float>());
    partitions_std = sqrtf(partitions_std / partitions_h.size());

    std::cout << "Statistics of partitions. Median: " << partitions_median << " Average: " << partitions_average << " std: "
            << partitions_std << " Max: " << partitions_h[partitions_h.size() -1] << " Min: " << partitions_h[1] << std::endl;

    std::cout << "Number of values for each partition: " << partitions_h.size() << std::endl;
    for (int i = 0; i < (partitions_h.size() < 100 ? partitions_h.size() : 100 ); ++i) {
        std::cout << std::setfill(' ') << std::setw(3);
        std::cout << partitions_h[i] << " ";
    }
    std::cout << std::endl;
#endif

    thrust::device_vector<uint32_t> partition_offset(pi + 1);
    thrust::exclusive_scan(exec, partitions.begin(), partitions.end(), partition_offset.begin(), uint32_t(0));

    PUSH_RANGE("Sorting",5)
#if TIMING_VERBOSE
    timer t_sort;
#endif

    thrust::counting_iterator<uint32_t> iter(0);
    thrust::device_vector<uint32_t> sorted_indices(J.size());
    thrust::copy(exec, iter, iter + sorted_indices.size(), sorted_indices.begin());

    uint32_t * raw_sorted_indices = thrust::raw_pointer_cast(&sorted_indices[0]);
    const uint32_t * raw_partitions_off =  thrust::raw_pointer_cast(&partition_offset[0]);
    int * raw_J =  thrust::raw_pointer_cast(&J[0]);

    uint32_t end_bit = log_2(B.num_cols);
    uint32_t begin_bit = 0;

    PUSH_RANGE("Pure sorting",6)

    //*************************** bb_segsort **********************************
    bb_segsort<int, uint32_t>(raw_J, raw_sorted_indices, valid_count, (int *)raw_partitions_off, pi);

    POP_RANGE

    // Rearrange gather location to include the sort by (I,J) info
    cusp::detail::temporary_array<IndexType, DerivedPolicy> A_gather_locations_sorted(exec, A_gather_locations.size());
    cusp::detail::temporary_array<IndexType, DerivedPolicy> B_gather_locations_sorted(exec, B_gather_locations.size());
    thrust::gather(exec, sorted_indices.begin(), sorted_indices.end(),
            A_gather_locations.begin(), A_gather_locations_sorted.begin());
    thrust::gather(exec, sorted_indices.begin(), sorted_indices.end(),
            B_gather_locations.begin(), B_gather_locations_sorted.begin());

#if TIMING_VERBOSE
    float time_elapsed_sort = t_sort.milliseconds_elapsed();
    printf("**** Sorting time: %9.2f ms\n", time_elapsed_sort);
#endif
    POP_RANGE



    // Count the addends needed by each value of C ( (I,J) is sorted )
    thrust::device_vector<uint32_t> keys_count(I.size() +1); //+1 for the unlikely case that there are no accumulations (that would cause problems with last value with the following scan)
    auto new_end = thrust::reduce_by_key(exec,
            thrust::make_zip_iterator(thrust::make_tuple(I.begin(), J.begin())),
            thrust::make_zip_iterator(thrust::make_tuple(I.end(), J.end())),
            thrust::make_constant_iterator(1), thrust::make_discard_iterator(),
            keys_count.begin());

    // Count is good for knowing how many values I need to accumulate, which in turn also helps with calculating
    // how many elements will be in each tile of C

    uint32_t num_C_tiles = new_end.second - keys_count.begin();

    // allocate space for output //for (bmp) only
    C.resize(A.num_rows, B.num_cols, num_C_tiles);
    C_idx.resize(num_C_tiles);

    //Now offset_tile will contain the scan of keys_count, and therefore the indices in the intermediate buffer to the first bmp
    //tile of each unique set of indices I,J
    thrust::device_vector<uint32_t> offset_tile(num_C_tiles + 1);  //TODO can I avoid this allocation?
    thrust::exclusive_scan(exec, keys_count.begin(), new_end.second + 1, offset_tile.begin(), uint32_t(0));

    int gridDim = num_C_tiles;
    int gridDim2 = (num_C_tiles + 2-1) / 2; // 2 tiles per warp
    int gridDim3 = (num_C_tiles + TILES_BLOCK -1) / TILES_BLOCK; // 4 tiles / 2 warps
    int blockDim1 = WARP_SIZE;
    int blockDim2 = BMP_DIM * BMP_DIM;
    int blockDim3 = WARP_SIZE * WARPS_BLOCK;

#if DEBUG
    std::cout << "Grid size (= num_C_tiles) " << gridDim << std::endl;
#endif

    int * raw_A_gather_uns = thrust::raw_pointer_cast(&A_gather_locations[0]);
    int * raw_B_gather_uns = thrust::raw_pointer_cast(&B_gather_locations[0]);

    uint32_t * raw_offset_tile = thrust::raw_pointer_cast(&offset_tile[0]);
    int * raw_A_gather = thrust::raw_pointer_cast(&A_gather_locations_sorted[0]);
    int * raw_B_gather = thrust::raw_pointer_cast(&B_gather_locations_sorted[0]);
    const uint64_t * raw_A_tiles =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&A.values[0]) );
    const uint64_t * raw_B_tiles =  reinterpret_cast<const uint64_t *>( thrust::raw_pointer_cast(&B.values[0]) );

    // Contains how many elements there are in each tile of C
    thrust::device_vector<uint32_t> counts(num_C_tiles +1); //+1 so that I can get last entry of exclusive scan without problems
    uint32_t * raw_counts = thrust::raw_pointer_cast(&counts[0]);

    PUSH_RANGE("Counting kernel",6)
#if TIMING_VERBOSE
    timer t_count;
#endif
    // offset_tile: offset to A_gather and B_gather, indicating where unique (I,J) pairs begin.
    //Returns raw_counts: each value of raw_counts holds the number of elements each tile of C will contain (without counting for cancellations)
//    count_c_elems_noTCU_nT<<<gridDim, blockDim2>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_B_gather, raw_B_tiles,
//        raw_counts);
    count_c_elems11_nT<<<gridDim3, blockDim3>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_B_gather, raw_B_tiles,
            raw_counts, num_C_tiles);

#if TIMING_VERBOSE
    float time_elapsed_count = t_count.milliseconds_elapsed();
    printf("**** Count kernel: %9.2f ms\n", time_elapsed_count);
#endif
    POP_RANGE

#if DEBUG_API
    gpuErrchk( cudaPeekAtLastError() );
    gpuErrchk( cudaDeviceSynchronize() );
#endif

//    uint32_t NNZ_Elem = thrust::reduce(exec, counts.begin(), counts.end()); //This reduce is not necessary if there is the following scan

    // The offset in the element array of C, that indicates the starting position of each tile of C
    thrust::device_vector<uint32_t> idx(num_C_tiles + 1);
    thrust::exclusive_scan(exec, counts.begin(), counts.end(), idx.begin(), uint32_t(0));

    uint32_t NNZ_Elem = idx[num_C_tiles];
    C_elems.resize(NNZ_Elem);
    //The zeros will not be accessed if there is cancellation, and thus we can compact
    thrust::fill(C_elems.begin(), C_elems.end(), 0.f);

    uint64_t * raw_C_tiles =  reinterpret_cast<uint64_t *>( thrust::raw_pointer_cast(&C.values[0]) );
    const float *raw_A_elems = thrust::raw_pointer_cast(&A_elems[0]);
    const uint32_t *raw_A_idx = thrust::raw_pointer_cast(&A_idx[0]);
    const int * raw_A_row_indices =  thrust::raw_pointer_cast(&A.row_indices[0]);
    const float *raw_B_elems = thrust::raw_pointer_cast(&B_elems[0]);
    const uint32_t *raw_B_idx = thrust::raw_pointer_cast(&B_idx[0]);
    const int * raw_B_column_indices =  thrust::raw_pointer_cast(&B.column_indices[0]);
    float *raw_C_elems = thrust::raw_pointer_cast(&C_elems[0]);
    uint32_t *raw_C_idx = thrust::raw_pointer_cast(&C_idx[0]);
    int * raw_C_row_indices =  thrust::raw_pointer_cast(&C.row_indices[0]);
    int * raw_C_column_indices =  thrust::raw_pointer_cast(&C.column_indices[0]);
    uint32_t *raw_idx = thrust::raw_pointer_cast(&idx[0]);

    PUSH_RANGE("Multiplication kernel",7)
#if TIMING_VERBOSE
    timer t_mul;
#endif
//    multiply_elems_noTCU_nT<<<gridDim, blockDim2>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_A_elems, raw_A_idx,
//        raw_A_row_indices, raw_B_gather, raw_B_tiles, raw_B_elems, raw_B_idx, raw_B_column_indices, raw_C_tiles, raw_C_elems,
//        raw_C_idx, raw_C_row_indices, raw_C_column_indices, raw_idx, 0);
    multiply_elemsMixed12_nT<<<gridDim3, blockDim3>>>(raw_offset_tile, raw_A_gather, raw_A_tiles, raw_A_elems, raw_A_idx,
            raw_A_row_indices, raw_B_gather, raw_B_tiles, raw_B_elems, raw_B_idx, raw_B_column_indices, raw_C_tiles,
            raw_C_elems, raw_C_idx, raw_C_row_indices, raw_C_column_indices, raw_idx, num_C_tiles);

#if TIMING_VERBOSE
    float time_elapsed_mul = t_mul.milliseconds_elapsed();
    printf("**** Multiply kernel: %9.2f ms\n", time_elapsed_mul);
#endif
    POP_RANGE

#if DEBUG_API
    gpuErrchk( cudaPeekAtLastError() );
    gpuErrchk( cudaDeviceSynchronize() );
#endif

    /* Remove empty tiles */

    PUSH_RANGE("Compact",8)

    int num_zeros = thrust::count_if(exec, C_idx.begin(), C_idx.end(), tile_is_empty_noTuple());

    if(num_zeros != 0)
    {
        int num_reduced_entries =
            thrust::remove_if(exec,
                thrust::make_zip_iterator(
                  thrust::make_tuple(C.row_indices.begin(), C.column_indices.begin(), C.values.begin(), C_idx.begin())),
                thrust::make_zip_iterator(
                  thrust::make_tuple(C.row_indices.end(),   C.column_indices.end(), C.values.end(), C_idx.end())),
                C_idx.begin(),
                tile_is_empty_noTuple()) -
            thrust::make_zip_iterator(
                thrust::make_tuple(C.row_indices.begin(), C.column_indices.begin(), C.values.begin(), C_idx.begin()));

        C.resize(C.num_rows, C.num_cols, num_reduced_entries);
        C_idx.resize(num_reduced_entries);
    }

#if DEBUG
    std::cout << "Number of empty tiles of C: " << num_zeros << std::endl;
#endif

    /* The "idx" of the tuple in C.values after the multiply_elems kernel holds the count of elements in each valid
     * tile. We need to scan the "idx" array in order to get the offsets in elem_array */

    thrust::exclusive_scan(exec, C_idx.begin(), C_idx.end(), C_idx.begin());


    /* Remove elements that are zero to produce a strictly valid COO matrix */

    auto new_end_C_elems = thrust::remove(C_elems.begin(), C_elems.end(), 0.f);

#if DEBUG
    std::cout << "Number of elements that are 0 due to cancellation in elements array of C: "
            << C_elems.end() - new_end_C_elems << std::endl;
#endif

    C_elems.resize(new_end_C_elems - C_elems.begin());

    POP_RANGE

}

template <typename DerivedPolicy,
          typename MatrixType1,
          typename MatrixType2,
          typename MatrixType3>
void multiplyESC_noTuple(cusp::cuda::execution_policy<DerivedPolicy>& exec,
              const MatrixType1& A,
              const thrust::device_vector<float>& A_elems, const thrust::device_vector<uint32_t>& A_idx,
              const MatrixType2& B,
              const thrust::device_vector<float>& B_elems, const thrust::device_vector<uint32_t>& B_idx,
              MatrixType3& C,
              thrust::device_vector<float>& C_elems, thrust::device_vector<uint32_t>& C_idx)
{
    PUSH_RANGE("segment_length_scan",1)

    typedef typename MatrixType3::index_type   IndexType;
    typedef typename MatrixType3::value_type   ValueType;
    typedef typename MatrixType3::memory_space MemorySpace;

    // check whether matrices are empty
    if (A.num_entries == 0 || B.num_entries == 0)
    {
        C.resize(A.num_rows, B.num_cols, 0);
        return;
    }

    // compute row offsets for B
#if THRUST_VERSION >= 100800
    cusp::detail::temporary_array<IndexType, DerivedPolicy> B_row_offsets(exec, B.num_rows + 1);
#else
    cusp::array1d<IndexType, MemorySpace> B_row_offsets(B.num_rows + 1);
#endif

    cusp::indices_to_offsets(exec, B.row_indices, B_row_offsets);

    // compute row lengths for B
#if THRUST_VERSION >= 100800
    cusp::detail::temporary_array<IndexType, DerivedPolicy> B_row_lengths(exec, B.num_rows);
#else
    cusp::array1d<IndexType, MemorySpace> B_row_lengths(B.num_rows);
#endif

    thrust::transform(exec, B_row_offsets.begin() + 1, B_row_offsets.end(), B_row_offsets.begin(), B_row_lengths.begin(), thrust::minus<IndexType>());

    // for each element A(i,j) compute the number of nonzero elements in B(j,:)
#if THRUST_VERSION >= 100800
    cusp::detail::temporary_array<IndexType, DerivedPolicy> segment_lengths(exec, A.num_entries);
#else
    cusp::array1d<IndexType, MemorySpace> segment_lengths(A.num_entries);
#endif

    thrust::gather(exec,
                   A.column_indices.begin(), A.column_indices.end(),
                   B_row_lengths.begin(),
                   segment_lengths.begin());

    // output pointer
#if THRUST_VERSION >= 100800
    cusp::detail::temporary_array<IndexType, DerivedPolicy> output_ptr(exec, A.num_entries + 1);
#else
    cusp::array1d<IndexType, MemorySpace> output_ptr(A.num_entries + 1);
#endif

    thrust::exclusive_scan(exec,
                           segment_lengths.begin(), segment_lengths.end(),
                           output_ptr.begin(),
                           IndexType(0));
    output_ptr[A.num_entries] = output_ptr[A.num_entries - 1] + segment_lengths[A.num_entries - 1]; // XXX is this necessary?

    size_t coo_num_nonzeros = output_ptr[A.num_entries];

    // workspace arrays
#if THRUST_VERSION >= 100800
    cusp::detail::temporary_array<IndexType, DerivedPolicy> I(exec);
    cusp::detail::temporary_array<IndexType, DerivedPolicy> J(exec);
    cusp::detail::temporary_array<ValueType, DerivedPolicy> V(exec);
#else
    cusp::array1d<IndexType, MemorySpace> A_gather_locations;
    cusp::array1d<IndexType, MemorySpace> B_gather_locations;
    cusp::array1d<IndexType, MemorySpace> I;
    cusp::array1d<IndexType, MemorySpace> J;
    cusp::array1d<ValueType, MemorySpace> V;
#endif

    POP_RANGE

    // compute C = A * B in one step
    size_t begin_row      = 0;
    size_t end_row        = A.num_rows;
    size_t begin_segment  = 0;
    size_t end_segment    = A.num_entries;
    size_t workspace_size = coo_num_nonzeros;

//    coo_spmm_helper_noTuple(exec, workspace_size, begin_row, end_row, begin_segment, end_segment, A, A_elems, A_idx, B,
//            B_elems, B_idx, C, C_elems, C_idx, B_row_offsets, segment_lengths, output_ptr, I, J, V);
    coo_spmm_helper_noTuple_sort(exec, workspace_size, begin_row, end_row, begin_segment, end_segment, A, A_elems, A_idx, B,
            B_elems, B_idx, C, C_elems, C_idx, B_row_offsets, segment_lengths, output_ptr, I, J, V);

}


void multiplyBmp_noTuple(const cusp::coo_matrix<int, uint64_t, cusp::device_memory>& A,
    const thrust::device_vector<float>& A_elems, const thrust::device_vector<uint32_t>& A_idx,
    const cusp::coo_matrix<int, uint64_t, cusp::device_memory>& B,
    const thrust::device_vector<float>& B_elems, const thrust::device_vector<uint32_t>& B_idx,
    cusp::coo_matrix<int, uint64_t, cusp::device_memory>& C,
    thrust::device_vector<float>& C_elems, thrust::device_vector<uint32_t>& C_idx)
{
    using thrust::system::detail::generic::select_system;

    using MatrixType = cusp::coo_matrix<int, uint64_t,cusp::device_memory>;
    MatrixType::memory_space System;

    auto exec = thrust::detail::derived_cast(thrust::detail::strip_const(System));

    PUSH_RANGE("spGEMM",2)

    multiplyESC_noTuple(exec, A, A_elems, A_idx, B, B_elems, B_idx, C, C_elems, C_idx);

    POP_RANGE
}
