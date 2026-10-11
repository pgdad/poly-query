/* TEST TOOL (not part of libpqkernels): edge cases the stock tests do not reach:
 * compare_fixed widths up to 300 bytes, group_sum with ngroups = 0, 3 and 2^33,
 * counts == NULL, large n (300001) with extreme sums / ranges and BETWEEN with
 * a > b; the 128-bit kernels at large n (extreme, alternating, monotonic
 * columns, exact-sum boundaries INT128_MAX / INT128_MIN and one beyond).
 * Build with -DSUM_CHUNK_ROWS=24 -DSUM_CHUNK_BLOCKS=1 -DSUM128_CHUNK_ROWS=64
 * to exercise the sum_i64 / sum_i128 chunk-fold paths. Build: see run.sh. */
#include "pq_kernels_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint64_t rs = 777;
static uint64_t rnd(void){uint64_t z=(rs+=0x9E3779B97F4A7C15ULL);z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL;z=(z^(z>>27))*0x94D049BB133111EBULL;return z^(z>>31);}
static int fails;
#define CK(c, ...) do{ if(!(c)){ fails++; if(fails<30){fprintf(stderr,"FAIL %s: ",vn);fprintf(stderr,__VA_ARGS__);fputc('\n',stderr);} } }while(0)
int main(void){
  pqk_table ref, v; pqk_variant_table("reference",&ref);
  const char *vars[] = {"x86_scalar","x86_avx2","x86_avx512"};
  for (int vi=0; vi<3; vi++){ const char *vn = vars[vi]; if (!pqk_variant_table(vn,&v)) continue;
    /* compare_fixed: wide records */
    for (int it=0; it<400; it++){ size_t w = rnd()%300, m = 1 + rnd()%20; uint8_t *a=malloc(w*m+1),*b=malloc(w*m+1); int8_t o1[32],o2[32];
      for(size_t i=0;i<w*m;i++){a[i]=(uint8_t)rnd(); b[i]=a[i];}
      for(size_t r=0;r<m;r++) if (w && rnd()%4) b[r*w + rnd()%w] = (uint8_t)rnd();
      ref.compare_fixed(a,b,w,m,o1); v.compare_fixed(a,b,w,m,o2); CK(!memcmp(o1,o2,m),"cfixed w=%zu",w); free(a); free(b); }
    /* group_sum special ngroups */
    for (int it=0; it<200; it++){ size_t n = rnd()%200; uint32_t *g=malloc(n*4+4); int64_t *x=malloc(n*8+8); uint8_t val[32]; for(int i=0;i<32;i++) val[i]=(uint8_t)rnd();
      for(size_t i=0;i<n;i++){ g[i]=(uint32_t)rnd(); x[i]=(int64_t)rnd()>>(rnd()%64); }
      int64_t s1[4]={0},s2[4]={0},c1[4]={0},c2[4]={0};
      int r1=ref.group_sum_i64(g,x,(it&1)?val:NULL,n,s1,c1,0), r2=v.group_sum_i64(g,x,(it&1)?val:NULL,n,s2,c2,0); CK(r1==r2,"ng=0 n=%zu %d %d",n,r1,r2);
      /* ngroups huge: ids all valid; need big arrays -> use ids < 4 but ngroups = 2^33 */
      for(size_t i=0;i<n;i++) g[i]&=3;
      r1=ref.group_sum_i64(g,x,(it&1)?val:NULL,n,s1,(it&2)?NULL:c1,(size_t)1<<33); r2=v.group_sum_i64(g,x,(it&1)?val:NULL,n,s2,(it&2)?NULL:c2,(size_t)1<<33);
      CK(r1==r2 && !memcmp(s1,s2,32) && !memcmp(c1,c2,32),"ng=2^33 n=%zu",n);
      /* ngroups = 3 -> some ids==3 invalid */
      r1=ref.group_sum_i64(g,x,(it&1)?val:NULL,n,s1,c1,3); r2=v.group_sum_i64(g,x,(it&1)?val:NULL,n,s2,c2,3); CK(r1==r2,"ng=3 n=%zu %d %d",n,r1,r2);
      free(g); free(x); }
    /* big n with validity, sums at extremes */
    size_t n = 300001; int64_t *d=malloc(n*8); uint8_t *val=malloc(n/8+1);
    for (int mode=0; mode<4; mode++){
      for(size_t i=0;i<n;i++) d[i] = mode==0? INT64_MAX : mode==1 ? INT64_MIN : mode==2 ? (int64_t)rnd() : ((i&1)?INT64_MAX:INT64_MIN+1);
      for(size_t i=0;i<n/8+1;i++) val[i]=(uint8_t)(mode==3?0xff:rnd());
      for (int k=0;k<2;k++){ uint8_t *vv = k?val:NULL; int64_t s1=0,s2=0; int r1=ref.sum_i64(d,vv,n,&s1), r2=v.sum_i64(d,vv,n,&s2); CK(r1==r2&&(r1||s1==s2),"bigsum mode=%d k=%d",mode,k);
        int64_t l1,h1,l2,h2; size_t c1=ref.minmax_i64(d,vv,n,&l1,&h1), c2=v.minmax_i64(d,vv,n,&l2,&h2); CK(c1==c2&&l1==l2&&h1==h2,"bigminmax");
        for(int op=0;op<7;op++){ CK(ref.count_i64(d,vv,n,op,0,INT64_MAX)==v.count_i64(d,vv,n,op,0,INT64_MAX),"bigcount op=%d",op);
          CK(ref.count_i64(d,vv,n,op,INT64_MIN,INT64_MAX)==v.count_i64(d,vv,n,op,INT64_MIN,INT64_MAX),"bigcount2 op=%d",op);
          CK(ref.count_i64(d,vv,n,op,5,-5)==v.count_i64(d,vv,n,op,5,-5),"bigcount3 op=%d",op); } } }
    free(d); free(val);
    /* 128-bit kernels at large n: extreme / random / alternating / monotonic
     * columns, exact-sum boundaries, a > b, a and b aliasing data. */
    { const __int128 MAX = (__int128)(((unsigned __int128)1 << 127) - 1), MIN = -MAX - 1;
      size_t m = 300001; pqk_i128 *w = malloc(m*16); uint8_t *vb = malloc(m/8+1);
      for (int mode=0; mode<8; mode++){
        for (size_t i=0;i<m;i++){ __int128 x;
          switch (mode){ case 0: x = MAX; break; case 1: x = MIN; break;
            case 2: x = (__int128)(((unsigned __int128)rnd() << 64) | rnd()); break;
            case 3: x = (i&1) ? MAX : MIN + 1; break;                     /* cancels exactly */
            case 4: x = (__int128)i - 150000; break;                       /* ascending */
            case 5: x = ((__int128)150000 - (__int128)i) << 64; break;     /* descending, hi limb */
            case 6: x = (__int128)(((unsigned __int128)(rnd()%3) << 64) | (rnd()%3 ? rnd() : UINT64_MAX)) - ((__int128)1 << 64); break;
            default: x = (i % 3 == 0) ? MAX : (i % 3 == 1) ? MAX : MIN; break; }
          w[i].lo = (uint64_t)x; w[i].hi = (int64_t)(x >> 64); }
        for (size_t i=0;i<m/8+1;i++) vb[i] = (uint8_t)(mode==3 ? 0xff : rnd());
        for (int k=0;k<3;k++){ uint8_t *vv = k==1 ? vb : NULL; size_t mm = k==2 ? m - 1 - rnd()%70 : m;
          pqk_i128 q1={1,1},q2={1,1},x1={2,2},x2={2,2};
          int r1=ref.sum_i128(w,vv,mm,&q1), r2=v.sum_i128(w,vv,mm,&q2); CK(r1==r2 && (r1 || !memcmp(&q1,&q2,16)),"bigsum128 mode=%d k=%d r=%d/%d",mode,k,r1,r2);
          size_t c1=ref.minmax_i128(w,vv,mm,&q1,&x1), c2=v.minmax_i128(w,vv,mm,&q2,&x2); CK(c1==c2 && !memcmp(&q1,&q2,16) && !memcmp(&x1,&x2,16),"bigminmax128 mode=%d k=%d",mode,k);
          pqk_i128 cs[4] = {w[rnd()%mm], w[rnd()%mm], {0, INT64_MIN}, {UINT64_MAX, INT64_MAX}};
          for (int op=0;op<7;op++) for (int ai=0; ai<4; ai++) for (int bi=0; bi<4; bi++){
            const pqk_i128 *ap = (ai==0) ? &w[mm/2] : &cs[ai], *bp = op==6 ? ((bi==0) ? &w[mm/3] : &cs[bi]) : NULL;
            if (op != 6 && bi) continue;
            CK(ref.count_i128(w,vv,mm,op,ap,bp)==v.count_i128(w,vv,mm,op,ap,bp),"bigcount128 mode=%d op=%d",mode,op); }
          uint32_t *o1 = malloc(mm*4), *o2 = malloc(mm*4);
          for (int op=0;op<7;op++){ size_t f1=ref.filter_i128(w,vv,mm,op,&w[mm/2],&cs[3],o1), f2=v.filter_i128(w,vv,mm,op,&w[mm/2],&cs[3],o2);
            CK(f1==f2 && !memcmp(o1,o2,f1*4),"bigfilter128 mode=%d op=%d",mode,op); }
          free(o1); free(o2); } }
      /* exact-sum boundaries: sums of exactly MAX / MIN are OK, one more overflows */
      pqk_i128 one = {1,0}, mone = {UINT64_MAX,-1};
      for (int t=0; t<2000; t++){ size_t k = 1 + rnd()%200; __int128 acc = 0;
        for (size_t i=0;i+1<k;i++){ __int128 x = (__int128)(((unsigned __int128)rnd() << 64) | rnd()) >> (rnd()%128); w[i].lo=(uint64_t)x; w[i].hi=(int64_t)(x>>64); acc += 0; (void)acc; }
        /* choose the last element so that the exact total hits a boundary */
        __int128 s = 0; int wraps = 0; for (size_t i=0;i+1<k;i++){ __int128 x = (__int128)(((unsigned __int128)(uint64_t)w[i].hi << 64) | w[i].lo); if (__builtin_add_overflow(s,x,&s)) wraps += x > 0 ? 1 : -1; }
        if (wraps) continue;
        __int128 target = (t&1) ? MAX : MIN, last;
        if (__builtin_sub_overflow(target, s, &last)) continue;
        w[k-1].lo=(uint64_t)last; w[k-1].hi=(int64_t)(last>>64);
        pqk_i128 q1, q2; int r1=ref.sum_i128(w,NULL,k,&q1), r2=v.sum_i128(w,NULL,k,&q2);
        CK(r1==0 && r2==0 && !memcmp(&q1,&q2,16), "sum128 boundary t=%d k=%zu", t, k);
        w[k] = (t&1) ? one : mone; r2=v.sum_i128(w,NULL,k+1,&q2); CK(r2==PQK_OVERFLOW, "sum128 boundary+1 t=%d k=%zu", t, k); }
      /* all rows invalid: count 0, outputs untouched */
      memset(vb, 0, m/8+1); pqk_i128 q={5,5}, x={6,6};
      CK(v.minmax_i128(w,vb,m,&q,&x)==0 && q.lo==5 && x.lo==6, "minmax128 all invalid");
      CK(v.sum_i128(w,vb,m,&q)==0 && q.lo==0 && q.hi==0, "sum128 all invalid");
      free(w); free(vb); }
    printf("edge %s: %s\n", vn, fails?"FAIL":"ok");
  }
  return fails!=0; }
