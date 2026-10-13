/* Harness for devices-1: create an UNREPRODUCIBLE machine with a virtio-console
   device, load the bare-metal driver into RAM, and run it under a watchdog.
   The driver programs a cyclic virtqueue descriptor chain and notifies the
   device; if the host loops forever in virtq::get_desc_rw_avail_len, cm_run
   never returns and the watchdog kills the child.

   Usage: ./harness <driver.bin>
   Prints BUG REPRODUCED + exit 1 on hang; NO HANG + exit 0 if cm_run returns. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <cm.h>

#define CHK(x) do { cm_error e_ = (x); if (e_ != CM_ERROR_OK) { \
    fprintf(stderr, "%s:%d %s -> %d: %s\n", __FILE__, __LINE__, #x, e_, cm_get_last_error_message()); \
    _exit(2);} } while (0)

static uint8_t *slurp(const char *path, size_t *n){
    FILE *f=fopen(path,"rb"); if(!f){perror("fopen");exit(2);}
    fseek(f,0,SEEK_END); long s=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t *b=malloc(s); if(fread(b,1,s,f)!=(size_t)s){perror("fread");exit(2);}
    fclose(f); *n=s; return b;
}

static void run_machine(const char *binpath){
    size_t n; uint8_t *prog = slurp(binpath,&n);
    /* iunrep=1 => unreproducible machine (required for virtio).
       virtio[0] = console so a virtio device exists at 0x40010000. */
    const char *cfg =
        "{\"ram\":{\"length\":4194304},"
        "\"processor\":{\"registers\":{\"iunrep\":1}},"
        "\"virtio\":[{\"type\":\"console\"}]}";
    cm_machine *m = NULL;
    CHK(cm_create_new(cfg, NULL, NULL, &m));
    CHK(cm_write_memory(m, 0x80000000UL, prog, n));
    fprintf(stderr, "[child] running cm_run(UINT64_MAX)...\n");
    cm_break_reason br;
    CHK(cm_run(m, UINT64_MAX, &br));
    uint64_t tohost=0; CHK(cm_read_reg(m, CM_REG_HTIF_TOHOST, &tohost));
    fprintf(stderr, "[child] cm_run returned: break=%d exit_code=%" PRIu64 "\n",
        br, (tohost & 0xffffffff) >> 1);
    cm_delete(m);
    _exit(0);
}

int main(int argc, char **argv){
    if(argc<2){ fprintf(stderr,"usage: %s driver.bin\n",argv[0]); return 2; }
    const int timeout_s = 8;
    pid_t pid = fork();
    if(pid==0){ run_machine(argv[1]); _exit(0); }
    for(int i=0;i<timeout_s*10;i++){
        int st; pid_t r = waitpid(pid,&st,WNOHANG);
        if(r==pid){
            if(WIFEXITED(st)){
                int ec=WEXITSTATUS(st);
                if(ec==0){ printf("NO HANG: cm_run returned normally (bug appears fixed)\n"); return 0; }
                printf("child exited with code %d (setup/other error)\n", ec); return ec;
            }
            printf("child terminated by signal %d\n", WTERMSIG(st)); return 3;
        }
        usleep(100000);
    }
    kill(pid, SIGKILL);
    int st; waitpid(pid,&st,0);
    printf("BUG REPRODUCED: emulator hung >%ds inside virtio queue processing "
           "(cyclic descriptor chain, no cycle/length bound in "
           "virtq::get_desc_rw_avail_len)\n", timeout_s);
    return 1;
}
