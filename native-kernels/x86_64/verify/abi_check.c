/* TEST TOOL (not part of libpqkernels): calls every kernel of every variant via
 * abi_trampoline.S, which seeds rbx/rbp/r12-r15 with magic values, passes the 7th
 * argument on a 16-byte aligned stack and afterwards checks callee-saved
 * registers, rsp, the direction flag and XINUSE (upper YMM/ZMM state must be
 * clean, i.e. vzeroupper was executed). Build: see run.sh. */
#include "pq_kernels_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
uint64_t abi_call(void *fn, const uint64_t args[7], uint64_t out[2]);
#define U(x) ((uint64_t)(uintptr_t)(x))
int main(void){
  const char *vars[]={"x86_scalar","x86_avx2","x86_avx512"}; int bad=0;
  size_t N=1000; int64_t *d=malloc(N*8+8),*d2=malloc(N*8+8),*o64=malloc(N*8+64); uint8_t *val=malloc(N/8+2), *bo=malloc(N+64); uint32_t *idx=malloc(N*4+64), *gid=malloc(N*4);
  for(size_t i=0;i<N;i++){d[i]=(int64_t)(i*7919)%201-100; d2[i]=(int64_t)(i*104729)%201-100; idx[i]=(uint32_t)((i*31)%N); gid[i]=(uint32_t)(i%10);} memset(val,0x5b,N/8+2);
  int64_t sums[16],counts[16],mn,mx; double fmn,fmx;
  for(int vi=0;vi<3;vi++){ pqk_table t; if(!pqk_variant_table(vars[vi],&t)) continue;
    size_t ns[]={0,1,7,63,64,65,200,1000};
    for(size_t k=0;k<sizeof ns/sizeof*ns;k++){ size_t n=ns[k];
      for(int withv=0;withv<2;withv++){ uint8_t *v=withv?val:NULL; uint64_t out[2];
        struct { const char *nm; void *fn; uint64_t a[7]; } calls[] = {
          {"filter_i64",(void*)t.filter_i64,{U(d),U(v),n,6,U(-50),50,U(idx)}},
          {"filter_i64_bitmap",(void*)t.filter_i64_bitmap,{U(d),U(v),n,2,0,0,U(bo)}},
          {"count_i64",(void*)t.count_i64,{U(d),U(v),n,1,3,0,0}},
          {"sum_i64",(void*)t.sum_i64,{U(d),U(v),n,U(&mn),0,0,0}},
          {"sum_f64",(void*)t.sum_f64,{U(d),U(v),n,0,0,0,0}},
          {"minmax_i64",(void*)t.minmax_i64,{U(d),U(v),n,U(&mn),U(&mx),0,0}},
          {"minmax_f64",(void*)t.minmax_f64,{U(d),U(v),n,U(&fmn),U(&fmx),0,0}},
          {"bitmap_and",(void*)t.bitmap_and,{U(d),U(d2),U(bo),n,0,0,0}},
          {"bitmap_or",(void*)t.bitmap_or,{U(d),U(d2),U(bo),n,0,0,0}},
          {"bitmap_andnot",(void*)t.bitmap_andnot,{U(d),U(d2),U(bo),n,0,0,0}},
          {"bitmap_popcount",(void*)t.bitmap_popcount,{U(d),n*8,0,0,0,0,0}},
          {"hash_i64",(void*)t.hash_i64,{U(d),n,99,U(o64),0,0,0}},
          {"compare_i64",(void*)t.compare_i64,{U(d),U(d2),n,4,U(bo),0,0}},
          {"compare_fixed",(void*)t.compare_fixed,{U(d),U(d2),7,n,U(bo),0,0}},
          {"group_sum_i64",(void*)t.group_sum_i64,{U(gid),U(d),U(v),n,U(sums),U(counts),16}},
          {"gather_i64",(void*)t.gather_i64,{U(d),U(idx),n,U(o64),0,0,0}},
          {"filter_i64(bad op)",(void*)t.filter_i64,{U(d),U(v),n,77,0,0,U(idx)}},
        };
        for(size_t c=0;c<sizeof calls/sizeof*calls;c++){ uint64_t r=abi_call(calls[c].fn,calls[c].a,out);
          if(r){ bad++; printf("ABI VIOLATION %s %s n=%zu v=%d: 0x%llx\n",vars[vi],calls[c].nm,n,withv,(unsigned long long)r);} }
      } }
    printf("abi %s: %s\n",vars[vi],bad?"FAIL":"ok"); }
  return bad!=0; }
