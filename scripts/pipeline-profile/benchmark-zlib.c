/*
 * Standalone macOS benchmark used for docs/zlib-options-2026-10-11.md.
 * Input is synthetic; this does not capture the desktop or run the server.
 * Compression and scratch-buffer copying are timed; decoding is outside timing.
 * Each rectangle must round-trip through Apple's system decoder, including when
 * this executable is linked against a zlib-ng compatibility-mode static library.
 * The compressor and decoder streams persist across all frames in each case.
 * Optional filters: BENCH_WORKLOAD=document|noise, BENCH_CASE=<case below>,
 * BENCH_RECTS=1|26. See the report for compilation and reproduction commands.
 */
#include <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
#define W 1728
#define H 1118
#define SIZE ((size_t)W*H*4)
static uint64_t wall(void){return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
static uint64_t cpu(void){return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);}
static int cmp(const void *a,const void*b){double x=*(const double*)a,y=*(const double*)b;return(x>y)-(x<y);}
struct config {const char *name;int level,strategy,mem,chunk,tune;};
static struct config cases[]={
 {"level0",0,Z_DEFAULT_STRATEGY,8,16384,0},
 {"level1",1,Z_DEFAULT_STRATEGY,8,16384,0},
 {"level2",2,Z_DEFAULT_STRATEGY,8,16384,0},
 {"level3",3,Z_DEFAULT_STRATEGY,8,16384,0},
 {"level1-rle",1,Z_RLE,8,16384,0},
 {"level1-huffman",1,Z_HUFFMAN_ONLY,8,16384,0},
 {"level1-fixed",1,Z_FIXED,8,16384,0},
 {"level1-mem7",1,Z_DEFAULT_STRATEGY,7,16384,0},
 {"level1-mem9",1,Z_DEFAULT_STRATEGY,9,16384,0},
 {"level1-chain1",1,Z_DEFAULT_STRATEGY,8,16384,1},
 {"level1-chunk64k",1,Z_DEFAULT_STRATEGY,8,65536,0},
 {"level1-chunk256k",1,Z_DEFAULT_STRATEGY,8,262144,0}
};
static unsigned char *frames[8],*scratch,*encoded,*decoded;
static int (*systemInit)(z_streamp,const char*,int);
static int (*systemInflate)(z_streamp,int);
static int (*systemEnd)(z_streamp);
static const char *(*systemVersion)(void);
static void run(int kind,int rects,struct config c){
 z_stream z={0},d={0};
 if(deflateInit2(&z,c.level,Z_DEFLATED,15,c.mem,c.strategy)!=Z_OK||systemInit(&d,systemVersion(),sizeof(d))!=Z_OK)abort();
 if(c.tune&&deflateTune(&z,4,4,8,1)!=Z_OK)abort();
 double ws[32],cs[32];size_t total=0;int n=kind?12:28,warm=4;
 for(int iter=0;iter<n;iter++){
  double wsum=0,csum=0;size_t bytes=0;
  for(int r=0;r<rects;r++){
   int y0=H*r/rects,y1=H*(r+1)/rects;size_t inBytes=(size_t)(y1-y0)*W*4;
   unsigned char *src=frames[iter%8]+(size_t)y0*W*4;size_t outBytes=0;
   z.next_in=src;z.avail_in=(uInt)inBytes;
   uint64_t t=wall(),ct=cpu();
   do{
    z.next_out=scratch;z.avail_out=c.chunk;
    if(deflate(&z,Z_SYNC_FLUSH)!=Z_OK)abort();
    size_t got=c.chunk-z.avail_out;memcpy(encoded+outBytes,scratch,got);outBytes+=got;
   }while(z.avail_out==0);
   uint64_t done=wall(),cdone=cpu();wsum+=(done-t)/1e6;csum+=(cdone-ct)/1e6;
   bytes+=outBytes;
   d.next_in=encoded;d.avail_in=(uInt)outBytes;d.next_out=decoded;d.avail_out=(uInt)inBytes+1;
   int status=systemInflate(&d,Z_SYNC_FLUSH);
   if(status!=Z_OK||d.avail_in||d.avail_out!=1||memcmp(src,decoded,inBytes)){fprintf(stderr,"decode mismatch %s %d %d\n",c.name,iter,r);abort();}
  }
  if(iter>=warm){ws[iter-warm]=wsum;cs[iter-warm]=csum;total+=bytes;}
 }
 qsort(ws,n-warm,sizeof(double),cmp);qsort(cs,n-warm,sizeof(double),cmp);
 printf("%s,%s,%d,%d,%.4f,%.4f,%.4f,%zu\n",kind?"noise":"document",c.name,rects,n-warm,ws[(n-warm)/2],ws[(n-warm)*95/100],cs[(n-warm)/2],total/(n-warm));fflush(stdout);
 deflateEnd(&z);systemEnd(&d);
}
int main(void){
 void *lib=dlopen("/usr/lib/libz.1.dylib",RTLD_NOW|RTLD_LOCAL);if(!lib)abort();
 systemInit=dlsym(lib,"inflateInit_");systemInflate=dlsym(lib,"inflate");systemEnd=dlsym(lib,"inflateEnd");systemVersion=dlsym(lib,"zlibVersion");
 if(!systemInit||!systemInflate||!systemEnd||!systemVersion)abort();
 Dl_info info={0};dladdr((void*)systemInflate,&info);fprintf(stderr,"decoder=%s version=%s\n",info.dli_fname,systemVersion());
 scratch=malloc(262144);encoded=malloc(SIZE*2);decoded=malloc(SIZE+1);for(int i=0;i<8;i++)frames[i]=malloc(SIZE);
 printf("workload,config,rectangles,n,median_ms,p95_ms,cpu_median_ms,mean_bytes\n");
 for(int kind=0;kind<2;kind++){
  const char *work=getenv("BENCH_WORKLOAD");if(work&&strcmp(work,kind?"noise":"document"))continue;
  uint32_t seed=123456789;
  for(int f=0;f<8;f++)for(int y=0;y<H;y++)for(int x=0;x<W;x++){
   size_t p=((size_t)y*W+x)*4;
   if(!kind){int row=y+f*13;int ink=row%24<12&&x%9<6&&x>100&&x<1500;unsigned char v=ink?40+(x/90+row/24)%80:238+(x/70+row/80)%18;frames[f][p]=frames[f][p+1]=frames[f][p+2]=v;}
   else for(int k=0;k<3;k++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;frames[f][p+k]=seed&255;}
   frames[f][p+3]=0;
  }
  for(int rects=1;rects<=26;rects+=25)for(size_t c=0;c<sizeof(cases)/sizeof(cases[0]);c++){
   const char *sel=getenv("BENCH_CASE"),*rc=getenv("BENCH_RECTS");
   if(sel&&strcmp(sel,cases[c].name))continue;
   if(rc&&atoi(rc)!=rects)continue;
   if(!sel&&kind&&(rects!=1||(c!=0&&c!=1&&c!=4&&c!=5)))continue;
   run(kind,rects,cases[c]);
  }
 }
 fprintf(stderr,"zlib=%s; all persistent-stream round trips verified\n",zlibVersion());
}
