/* TEST TOOL (not part of libpqkernels): guard-page harness. Every buffer handed
 * to a kernel ends exactly at a PROT_NONE page (mode 0) or starts right after one
 * (mode 1), for n = 0..maxn, with/without validity; results must equal the
 * reference. Catches any out-of-bounds read/write by the assembly, which
 * AddressSanitizer cannot see. Usage: guard_pages [maxn]. Build: see run.sh. */
/* Guard-page harness: every buffer handed to a kernel ends exactly at a PROT_NONE
 * page (mode 0) or starts exactly after one (mode 1); compares with reference. */
#define _GNU_SOURCE
#include "pq_kernels_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static size_t PG;
static uint64_t rs = 12345;
static uint64_t rnd(void){uint64_t z=(rs+=0x9E3779B97F4A7C15ULL);z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL;z=(z^(z>>27))*0x94D049BB133111EBULL;return z^(z>>31);}
typedef struct { void *map; size_t len; } gb;
static gb pool[512]; static int npool;
static void *gal(size_t bytes, int mode) {
  size_t body = (bytes + PG - 1) / PG * PG + PG;
  size_t len = body + 2 * PG;
  unsigned char *m = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  mprotect(m, PG, PROT_NONE);
  mprotect(m + PG + body, PG, PROT_NONE);
  pool[npool].map = m; pool[npool++].len = len;
  if (bytes == 0) return mode ? m + PG : m + PG + body;
  return mode ? m + PG : m + PG + body - bytes;
}
static void gfree(void){ for(int i=0;i<npool;i++) munmap(pool[i].map,pool[i].len); npool=0; }
static int fails;
#define CK(c, ...) do{ if(!(c)){ fails++; if(fails<30){fprintf(stderr,"FAIL %s: ",vn);fprintf(stderr,__VA_ARGS__);fputc('\n',stderr);} } }while(0)
int main(int argc, char **argv){
  PG = (size_t)sysconf(_SC_PAGESIZE);
  pqk_table ref, v; pqk_variant_table("reference",&ref);
  const char *vars[] = {"x86_scalar","x86_avx2","x86_avx512"};
  int maxn = argc > 1 ? atoi(argv[1]) : 300;
  for (int vi=0; vi<3; vi++){
    const char *vn = vars[vi];
    if (!pqk_variant_table(vn,&v) || !pqk_cpu_supports(vn)) continue;
    for (int mode=0; mode<2; mode++)
    for (int n=0; n<=maxn; n++) for (int withv=0; withv<2; withv++) {
      size_t nb=(n+7)/8;
      int64_t *d = gal(n*8, mode), *d2 = gal(n*8, mode);
      double *f = gal(n*8, mode);
      uint8_t *val = withv ? gal(nb, mode) : NULL;
      for (int i=0;i<n;i++){ d[i]=(int64_t)(rnd()%7)-3; if(rnd()%5==0) d[i]=(int64_t)rnd(); d2[i]=(rnd()&1)?d[i]:(int64_t)(rnd()%7)-3; f[i]=(double)(int64_t)(rnd()%2001-1000)/8.0; if (rnd()%4==0) f[i] = (rnd()&1) ? -0.0 : 0.0; if (n%3==0 && f[i] < 0) f[i] = -f[i]; if (n%3==1 && f[i] > 0) f[i] = -f[i]; }
      if (val) for (size_t i=0;i<nb;i++) val[i]=(uint8_t)rnd();
      uint32_t *o1 = calloc(n+1,4), *o2 = gal(n*4, mode);
      uint8_t *b1 = calloc(nb+1,1), *b2 = gal(nb, mode);
      for (int op=0; op<7; op++){
        int64_t a = (int64_t)(rnd()%7)-3, b = a + (int64_t)(rnd()%4);
        size_t c1 = ref.filter_i64(d,val,n,op,a,b,o1), c2 = v.filter_i64(d,val,n,op,a,b,o2);
        CK(c1==c2 && !memcmp(o1,o2,c1*4), "filter n=%d op=%d mode=%d v=%d",n,op,mode,withv);
        c1 = ref.filter_i64_bitmap(d,val,n,op,a,b,b1); c2 = v.filter_i64_bitmap(d,val,n,op,a,b,b2);
        CK(c1==c2 && !memcmp(b1,b2,nb), "bitmap n=%d op=%d",n,op);
        CK(ref.count_i64(d,val,n,op,a,b)==v.count_i64(d,val,n,op,a,b), "count n=%d op=%d v=%d",n,op,withv);
        if (op<6){ c1=ref.compare_i64(d,d2,n,op,b1); c2=v.compare_i64(d,d2,n,op,b2); CK(c1==c2&&!memcmp(b1,b2,nb),"cmp n=%d op=%d",n,op); }
      }
      int64_t s1=0,s2=0; int r1=ref.sum_i64(d,val,n,&s1), r2=v.sum_i64(d,val,n,&s2);
      CK(r1==r2 && (r1||s1==s2), "sum_i64 n=%d", n);
      double fs1=ref.sum_f64(f,val,n), fs2=v.sum_f64(f,val,n); CK(fs1==fs2, "sum_f64 n=%d %g %g", n, fs1, fs2);
      int64_t l1=0,h1=0,l2=0,h2=0; c1:; size_t k1=ref.minmax_i64(d,val,n,&l1,&h1), k2=v.minmax_i64(d,val,n,&l2,&h2);
      CK(k1==k2 && (!k1||(l1==l2&&h1==h2)), "minmax_i64 n=%d",n);
      double fl1=0,fh1=0,fl2=0,fh2=0; k1=ref.minmax_f64(f,val,n,&fl1,&fh1); k2=v.minmax_f64(f,val,n,&fl2,&fh2);
      CK(k1==k2 && (!k1||(!memcmp(&fl1,&fl2,8)&&!memcmp(&fh1,&fh2,8))), "minmax_f64 n=%d",n);
      uint64_t *h_1=calloc(n+1,8), *h_2=gal(n*8,mode); ref.hash_i64(d,n,7,h_1); v.hash_i64(d,n,7,h_2); CK(!memcmp(h_1,h_2,n*8),"hash n=%d",n);
      /* bitmaps: n bytes */
      uint8_t *x=gal(n,mode),*y=gal(n,mode),*z1=calloc(n+1,1),*z2=gal(n,mode);
      for(int i=0;i<n;i++){x[i]=(uint8_t)rnd();y[i]=(uint8_t)rnd();}
      ref.bitmap_and(x,y,z1,n); v.bitmap_and(x,y,z2,n); CK(!memcmp(z1,z2,n),"and %d",n);
      ref.bitmap_or(x,y,z1,n); v.bitmap_or(x,y,z2,n); CK(!memcmp(z1,z2,n),"or %d",n);
      ref.bitmap_andnot(x,y,z1,n); v.bitmap_andnot(x,y,z2,n); CK(!memcmp(z1,z2,n),"andnot %d",n);
      for (int t=0;t<8 && n;t++){ size_t nbits=(size_t)n*8-t; CK(ref.bitmap_popcount(x,nbits)==v.bitmap_popcount(x,nbits),"popcnt %zu",nbits); }
      /* compare_fixed: width w, m=n/4 records */
      for (size_t w=0; w<40; w+= (w<10?1:3)) { size_t m = (size_t)n/4; uint8_t *fa=gal(w*m,mode),*fb=gal(w*m,mode); int8_t *q1=calloc(m+1,1),*q2=gal(m,mode);
        for(size_t i=0;i<w*m;i++){fa[i]=(uint8_t)(rnd()%3); fb[i]=(rnd()%(w+1)==0)?(uint8_t)rnd():fa[i];}
        ref.compare_fixed(fa,fb,w,m,q1); v.compare_fixed(fa,fb,w,m,q2); CK(!memcmp(q1,q2,m),"cfixed w=%zu m=%zu",w,m); free(q1); }
      /* group sum */
      size_t ng = 1 + rnd()%20; uint32_t *g = gal(n*4,mode); for(int i=0;i<n;i++) g[i]=(uint32_t)(rnd()%ng);
      int64_t gs1[32]={0},gs2[32]={0},gc1[32]={0},gc2[32]={0};
      r1=ref.group_sum_i64(g,d,val,n,gs1,gc1,ng); r2=v.group_sum_i64(g,d,val,n,gs2,gc2,ng);
      CK(r1==r2 && !memcmp(gs1,gs2,sizeof gs1) && !memcmp(gc1,gc2,sizeof gc1), "group n=%d %d %d",n,r1,r2);
      if (n) { g[n-1] = (uint32_t)ng; r1=ref.group_sum_i64(g,d,val,n,gs1,NULL,ng); r2=v.group_sum_i64(g,d,val,n,gs2,NULL,ng); CK(r1==r2,"group einval n=%d",n); }
      /* gather */
      uint32_t *ix = gal(n*4,mode); for(int i=0;i<n;i++) ix[i]=(uint32_t)(rnd()%n);
      int64_t *g1=calloc(n+1,8),*g2=gal(n*8,mode); ref.gather_i64(d,ix,n,g1); v.gather_i64(d,ix,n,g2); CK(!memcmp(g1,g2,n*8),"gather %d",n);
      free(o1); free(b1); free(h_1); free(z1); free(g1); gfree();
    }
    printf("guard %s: %s\n", vn, fails? "FAIL":"ok");
  }
  return fails!=0;
}
