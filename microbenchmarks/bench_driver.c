// Copyright 2026 Bloomberg Finance L.P.
// Distributed under the terms of the MIT license.

#include "common.h"
#include "gen/comp_dispatch.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include <limits.h>

typedef struct {
    uint32_t comp;
    uint32_t size;
    uint64_t start;
    uint64_t end;
} alloc_rec_t;

static const char* g_alloc_log_prefix = NULL;
static int g_simple_alloc = 0; // --simple-alloc 0|1

static inline void alloc_log_write(FILE* f, uint32_t comp, void* ptr, size_t sz) {
    if (!f || !ptr || sz == 0) return;
    alloc_rec_t r;
    r.comp = comp;
    r.size = (uint32_t)(sz > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)sz);
    r.start = (uint64_t)(uintptr_t)ptr;
    r.end   = (uint64_t)(uintptr_t)ptr + (uint64_t)sz;
    (void)fwrite(&r, sizeof(r), 1, f);
}

// 64-bit hash mix for trace fingerprinting (cheap + stable)
static inline uint64_t trace_mix_u64(uint64_t h, uint64_t v) {
    // FNV-1a style
    h ^= v;
    h *= 1099511628211ULL;
    return h;
}

static inline uint64_t trace_tag(uint32_t op_type, uint32_t comp,
                                 uint32_t slot_or_victim, uint32_t aux) {
    // Pack into 64 bits: [op_type:8][comp:16][slot/victim:20][aux:20]
    uint64_t t = 0;
    t |= ((uint64_t)(op_type & 0xFFu)) << 56;
    t |= ((uint64_t)(comp & 0xFFFFu)) << 40;
    t |= ((uint64_t)(slot_or_victim & 0xFFFFFu)) << 20;
    t |= ((uint64_t)(aux & 0xFFFFFu));
    return t;
}

typedef struct {
    void** items;
    uint32_t cap;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
    pthread_mutex_t mu;
} inbox_t;

// Rename local RNG to avoid collision with any rng_t in headers.
typedef struct {
    uint64_t s;
} rng2_t;

static inline uint64_t rng2_next(rng2_t* r) {
    // splitmix64
    uint64_t z = (r->s += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static inline uint32_t rng2_u32(rng2_t* r, uint32_t mod) {
    return (uint32_t)(rng2_next(r) % (uint64_t)mod);
}

static inline uint64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static size_t sample_size(rng2_t* r, size_profile_t prof) {
    if (prof == SIZE_SMALL) {
        static const size_t sizes[] = {
            16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768,
            1024, 1536, 2048, 3072, 4096
        };
        return sizes[rng2_u32(r, (uint32_t)(sizeof(sizes)/sizeof(sizes[0])))];
    } else {
        // mixed: 97% small (16..4096), 2% 64K, 1% 1M
        uint32_t p = rng2_u32(r, 1000);
        if (p < 970) {
            return sample_size(r, SIZE_SMALL);
        } else if (p < 990) {
            return 64 * 1024;
        } else {
            return 1024 * 1024;
        }
    }
}

static void build_zipf_cdf(double *cdf, uint32_t comps) {
    double sum = 0.0;
    for (uint32_t i = 0; i < comps; i++) {
        sum += 1.0 / (double)(i + 1);
    }
    double acc = 0.0;
    for (uint32_t i = 0; i < comps; i++) {
        acc += 1.0 / (double)(i + 1);
        cdf[i] = acc / sum;
    }
}

static inline uint32_t sample_zipf(rng2_t *rng, double *cdf, uint32_t comps) {
    double u = (double)rng2_u32(rng, 10000) / 10000.0;
    for (uint32_t i = 0; i < comps; i++) {
        if (u < cdf[i]) return i;
    }
    return comps - 1;
}

static void inbox_init(inbox_t* b, uint32_t cap) {
    b->items = (void**)calloc(cap, sizeof(void*));
    if (!b->items) { perror("calloc"); exit(2); }
    b->cap = cap;
    b->head = b->tail = b->count = 0;
    pthread_mutex_init(&b->mu, NULL);
}

static void inbox_destroy(inbox_t* b) {
    if (!b) return;
    free(b->items);
    pthread_mutex_destroy(&b->mu);
}

static int inbox_push(inbox_t* b, void* p) {
    int ok = 0;
    pthread_mutex_lock(&b->mu);
    if (b->count < b->cap) {
        b->items[b->tail] = p;
        b->tail = (b->tail + 1) % b->cap;
        b->count++;
        ok = 1;
    }
    pthread_mutex_unlock(&b->mu);
    return ok;
}

static void* inbox_pop(inbox_t* b) {
    void* p = NULL;
    pthread_mutex_lock(&b->mu);
    if (b->count > 0) {
        p = b->items[b->head];
        b->items[b->head] = NULL;
        b->head = (b->head + 1) % b->cap;
        b->count--;
    }
    pthread_mutex_unlock(&b->mu);
    return p;
}

typedef struct {
    uint32_t tid;
    bench_params_t p;

    inbox_t* inboxes;

    uint64_t checksum;
    uint64_t allocs;
    uint64_t frees;
    uint64_t remote_frees;

    // Trace descriptor
    uint64_t trace_digest;
    uint64_t count_64k;
    uint64_t count_1m;

    // Allocation logging (one file per thread; alloc-mode only)
    FILE* alloc_log_fp;
    char alloc_log_path[PATH_MAX];

    uint64_t start_ns;
    uint64_t end_ns;
} worker_ctx_t;

static inline uint32_t pick_comp(worker_ctx_t* w, uint64_t op_index,
                                  rng2_t *rng, double *zipf_cdf) {
    if (w->p.comps == 1) return 0;
    switch (w->p.pattern) {
    case PATTERN_RR:
        return (uint32_t)((op_index + (uint64_t)w->tid) % (uint64_t)w->p.comps);
    case PATTERN_BURST: {
        uint64_t b = (w->p.burst_len ? w->p.burst_len : 1);
        uint64_t burst = (op_index / b);
        return (uint32_t)((burst + (uint64_t)w->tid) % (uint64_t)w->p.comps);
    }
    case PATTERN_ZIPF:
        return sample_zipf(rng, zipf_cdf, w->p.comps);
    case PATTERN_PHASED: {
        double progress = (double)op_index / (double)w->p.ops_per_thread;
        if (progress < 0.3) {
            /* Phase 1: init -- mostly comp 0 */
            return (rng2_u32(rng, 100) < 80) ? 0 : (1 % w->p.comps);
        } else if (progress < 0.8) {
            /* Phase 2: steady state -- zipf across all */
            return sample_zipf(rng, zipf_cdf, w->p.comps);
        } else {
            /* Phase 3: cleanup -- mostly comp 0, some spread */
            if (rng2_u32(rng, 100) < 60) return 0;
            return rng2_u32(rng, w->p.comps);
        }
    }
    case PATTERN_PRODCON: {
        /* Rotate through producer compartments (even indices) */
        uint32_t num_pairs = (w->p.comps + 1) / 2;
        uint64_t b = (w->p.burst_len ? w->p.burst_len : 1);
        uint64_t burst = (op_index / b);
        uint32_t pair = (uint32_t)((burst + (uint64_t)w->tid) % num_pairs);
        return pair * 2;  /* even index = producer */
    }
    case PATTERN_SEQ: {
        /* Sequential: all ops for comp 0, then all for comp 1, etc. */
        uint64_t per_comp = w->p.ops_per_thread / (uint64_t)w->p.comps;
        if (per_comp == 0) per_comp = 1;
        uint32_t c = (uint32_t)(op_index / per_comp);
        if (c >= w->p.comps) c = w->p.comps - 1;
        return c;
    }
    }
    return 0;
}

static inline uint32_t pick_free_comp(worker_ctx_t* w, uint32_t alloc_comp) {
    if (w->p.pattern != PATTERN_PRODCON) return alloc_comp;
    uint32_t consumer = alloc_comp + 1;
    if (consumer >= w->p.comps) return alloc_comp;  /* last comp is both */
    return consumer;
}

static void* worker_call(void* arg) {
    worker_ctx_t* w = (worker_ctx_t*)arg;
    rng2_t rng = {.s = w->p.seed ^ (0xC0FFEEULL + (uint64_t)w->tid * 0x9E3779B97F4A7C15ULL)};
    uint64_t x = rng2_next(&rng);

    double *zipf_cdf = NULL;
    if (w->p.pattern == PATTERN_ZIPF || w->p.pattern == PATTERN_PHASED) {
        zipf_cdf = (double *)calloc(w->p.comps, sizeof(double));
        if (zipf_cdf) build_zipf_cdf(zipf_cdf, w->p.comps);
    }

    uint64_t h = 1469598103934665603ULL ^ (uint64_t)w->tid;

    w->start_ns = now_ns();
    for (uint64_t i = 0; i < w->p.ops_per_thread; i++) {
        uint32_t c = pick_comp(w, i, &rng, zipf_cdf);
        h = trace_mix_u64(h, trace_tag(10 /*call*/, c, (uint32_t)(i & 0xFFFFF), 0));
        x = comp_dispatch_ping((unsigned)c, x);
    }
    w->end_ns = now_ns();
    w->checksum = x;
    w->trace_digest = h;
    free(zipf_cdf);
    return NULL;
}

static void* simple_worker_alloc(void* arg) {
    worker_ctx_t* w = (worker_ctx_t*)arg;

    rng2_t rng = {.s = w->p.seed ^ (0x51A11C0CULL + (uint64_t)w->tid * 0x9E3779B97F4A7C15ULL)};

    double *zipf_cdf = NULL;
    if (w->p.pattern == PATTERN_ZIPF || w->p.pattern == PATTERN_PHASED) {
        zipf_cdf = (double *)calloc(w->p.comps, sizeof(double));
        if (zipf_cdf) build_zipf_cdf(zipf_cdf, w->p.comps);
    }

    // Open per-thread allocation log if enabled.
    w->alloc_log_fp = NULL;
    w->alloc_log_path[0] = '\0';
    if (g_alloc_log_prefix && g_alloc_log_prefix[0] != '\0') {
        (void)snprintf(w->alloc_log_path, sizeof(w->alloc_log_path),
                       "%s.t%u.bin", g_alloc_log_prefix, w->tid);
        w->alloc_log_fp = fopen(w->alloc_log_path, "wb");
        if (!w->alloc_log_fp) {
            fprintf(stderr, "WARN: could not open alloc log '%s': %s\n",
                    w->alloc_log_path, strerror(errno));
        } else {
            (void)setvbuf(w->alloc_log_fp, NULL, _IOFBF, 1 << 20);
        }
    }

    uint64_t h = 1469598103934665603ULL ^ (uint64_t)w->tid;
    uint64_t c64k = 0, c1m = 0;

    w->start_ns = now_ns();
    for (uint64_t i = 0; i < w->p.ops_per_thread; i++) {
        uint32_t c = pick_comp(w, i, &rng, zipf_cdf);

        size_t sz = (w->p.fixed_size != 0)
                        ? (size_t)w->p.fixed_size
                        : sample_size(&rng, w->p.size_profile);

        if (sz == 64 * 1024) c64k++;
        else if (sz == 1024 * 1024) c1m++;

        uint32_t aux = (uint32_t)((sz / 1024) & 0xFFFFFu);
        uint32_t op_tag = (w->p.alloc_fn == ALLOC_CALLOC) ? 7 /*calloc*/ : 1 /*malloc*/;
        h = trace_mix_u64(h, trace_tag(op_tag, c, (uint32_t)(i & 0xFFFFF), aux));

        void* p = NULL;
        if (w->p.alloc_fn == ALLOC_CALLOC) {
            p = comp_dispatch_calloc((unsigned)c, 1, sz);
        } else {
            p = comp_dispatch_malloc((unsigned)c, sz);
        }

        if (p) {
            ((volatile unsigned char*)p)[0] = (unsigned char)(rng2_next(&rng) & 0xFFu);
            // Optional: record allocation range for offline cross-compartment validation.
            if (w->alloc_log_fp) {
                alloc_rec_t rec;
                rec.comp = c;
                rec.size = (uint32_t)sz;
                rec.start = (uint64_t)(uintptr_t)p;
                rec.end = rec.start + (uint64_t)sz;
                (void)fwrite(&rec, sizeof(rec), 1, w->alloc_log_fp);
            }
        }

        // We do not free in this simplified mode.
        w->allocs++;
        w->checksum ^= (uint64_t)(uintptr_t)p;
    }
    w->end_ns = now_ns();

    w->trace_digest = h;
    w->count_64k = c64k;
    w->count_1m = c1m;

    if (w->alloc_log_fp) fclose(w->alloc_log_fp);
    free(zipf_cdf);
    return NULL;
}

static void* worker_alloc(void* arg) {
    worker_ctx_t* w = (worker_ctx_t*)arg;

    rng2_t rng = {.s = w->p.seed ^ (0xBADC0DEULL + (uint64_t)w->tid * 0xD1B54A32D192ED03ULL)};
    void** live = (void**)calloc(w->p.live, sizeof(void*));
    if (!live) { perror("calloc live"); exit(2); }

    double *zipf_cdf = NULL;
    if (w->p.pattern == PATTERN_ZIPF || w->p.pattern == PATTERN_PHASED) {
        zipf_cdf = (double *)calloc(w->p.comps, sizeof(double));
        if (zipf_cdf) build_zipf_cdf(zipf_cdf, w->p.comps);
    }

    // Open per-thread allocation log if enabled (best-effort; affects runtime if enabled).
    w->alloc_log_fp = NULL;
    w->alloc_log_path[0] = '\0';
    if (g_alloc_log_prefix && g_alloc_log_prefix[0] != '\0') {
        (void)snprintf(w->alloc_log_path, sizeof(w->alloc_log_path),
                       "%s.t%u.bin", g_alloc_log_prefix, w->tid);
        w->alloc_log_fp = fopen(w->alloc_log_path, "wb");
        if (!w->alloc_log_fp) {
            fprintf(stderr, "WARN: could not open alloc log '%s': %s\n",
                    w->alloc_log_path, strerror(errno));
        } else {
            // Use a large buffer to reduce write syscalls.
            (void)setvbuf(w->alloc_log_fp, NULL, _IOFBF, 1 << 20);
        }
    }


    uint64_t h = 1469598103934665603ULL ^ (uint64_t)w->tid;
    uint64_t c64k = 0, c1m = 0;

    w->start_ns = now_ns();
    for (uint64_t i = 0; i < w->p.ops_per_thread; i++) {
        // Process a few remote frees to keep inbox bounded.
        if (w->p.remote_free) {
            for (int k = 0; k < 2; k++) {
                void* rp = inbox_pop(&w->inboxes[w->tid]);
                if (!rp) break;
                uint32_t c = pick_comp(w, i + (uint64_t)k, &rng, zipf_cdf);
                uint32_t fc = pick_free_comp(w, c);
                h = trace_mix_u64(h, trace_tag(3 /*drain_free*/, fc,
                                               (uint32_t)w->tid, (uint32_t)k));

                comp_dispatch_free((unsigned)fc, rp);
                w->frees++;
                w->remote_frees++;
            }
        }

        uint32_t slot = rng2_u32(&rng, w->p.live);
        uint32_t c = pick_comp(w, i, &rng, zipf_cdf);

        /* Compute effective free_pct (phased pattern scales per phase) */
        uint32_t eff_free_pct = w->p.free_pct;
        if (w->p.pattern == PATTERN_PHASED) {
            double progress = (double)i / (double)w->p.ops_per_thread;
            if (progress < 0.3) {
                eff_free_pct = (uint32_t)(w->p.free_pct * 0.3);
            } else if (progress >= 0.8) {
                uint32_t scaled = (uint32_t)(w->p.free_pct * 1.5);
                eff_free_pct = scaled > 95 ? 95 : scaled;
            }
        }

        if (live[slot] != NULL) {
            uint32_t coin = rng2_u32(&rng, 100);
            if (coin < eff_free_pct) {
                void* p = live[slot];
                live[slot] = NULL;
                uint32_t fc = pick_free_comp(w, c);
                h = trace_mix_u64(h, trace_tag(2 /*free*/, fc, slot, 0));

                if (w->p.remote_free && w->p.threads > 1) {
                    uint32_t victim = rng2_u32(&rng, w->p.threads - 1);
                    if (victim >= w->tid) victim++;
                    h = trace_mix_u64(h, trace_tag(4 /*remote_free_intent*/, fc,
                                                   victim, slot));

                    if (inbox_push(&w->inboxes[victim], p)) {
                        // freed later by victim
                    } else {
                        comp_dispatch_free((unsigned)fc, p);
                        w->frees++;
                    }
                } else {
                    comp_dispatch_free((unsigned)fc, p);
                    w->frees++;
                }
                continue;
            }
        }

        size_t sz = (w->p.fixed_size != 0 )
                    ? (size_t)w->p.fixed_size
                    : sample_size(&rng, w->p.size_profile);

        if (w->p.size_profile == SIZE_MIXED) {
            if (sz == 64 * 1024) c64k++;
            else if (sz == 1024 * 1024) c1m++;
        }

        // aux packs (size_kb capped) so it stays compact
        uint32_t aux = (uint32_t)((sz / 1024) & 0xFFFFFu);

        // Distinguish malloc vs calloc in the trace tag.
        uint32_t op = (w->p.alloc_fn == ALLOC_CALLOC) ? 7 /*calloc*/ : 1 /*malloc*/;
        h = trace_mix_u64(h, trace_tag(op, c, slot, aux));

        void* p = NULL;
        if (w->p.alloc_fn == ALLOC_CALLOC) {
            p = comp_dispatch_calloc((unsigned)c, 1, sz);
        } else {
            p = comp_dispatch_malloc((unsigned)c, sz);
        }

        if (p) {
            // Touch (keeps allocations "real" and avoids dead-code elimination)
            ((volatile unsigned char*)p)[0] = (unsigned char)(rng2_next(&rng) & 0xFFu);
        }
        alloc_log_write(w->alloc_log_fp, c, p, sz);

        if (live[slot] != NULL) {
            void* old = live[slot];
            uint32_t fc = pick_free_comp(w, c);
            h = trace_mix_u64(h, trace_tag(5 /*evict*/, fc, slot, 0));
            if (w->p.remote_free && w->p.threads > 1) {
                uint32_t victim = rng2_u32(&rng, w->p.threads - 1);
                if (victim >= w->tid) victim++;
                h = trace_mix_u64(h, trace_tag(4 /*remote_free_intent*/, fc,
                                               victim, slot));
                if (!inbox_push(&w->inboxes[victim], old)) {
                    comp_dispatch_free((unsigned)fc, old);
                    w->frees++;
                }
            } else {
                comp_dispatch_free((unsigned)fc, old);
                w->frees++;
            }
        }

        live[slot] = p;
        w->allocs++;
    }

    // Stop timer BEFORE cleanup so cleanup frees don't affect throughput measurement
    w->end_ns = now_ns();

    // drain inbox
    if (w->p.remote_free) {
        for (;;) {
            void* rp = inbox_pop(&w->inboxes[w->tid]);
            if (!rp) break;
            uint32_t c = pick_comp(w, w->p.ops_per_thread, &rng, zipf_cdf);
            uint32_t fc = pick_free_comp(w, c);
            h = trace_mix_u64(h, trace_tag(3 /*drain_free*/, fc,
                                           (uint32_t)w->tid, 99));
            comp_dispatch_free((unsigned)fc, rp);
            w->frees++;
            w->remote_frees++;
        }
    }

    // cleanup live set
    for (uint32_t j = 0; j < w->p.live; j++) {
        if (live[j]) {
            uint32_t c = pick_comp(w, w->p.ops_per_thread + j, &rng, zipf_cdf);
            uint32_t fc = pick_free_comp(w, c);
            h = trace_mix_u64(h, trace_tag(6 /*final_free*/, fc, j, 0));
            comp_dispatch_free((unsigned)fc, live[j]);
            w->frees++;
        }
    }
    uint64_t chk = 0;
    for (uint32_t j = 0; j < w->p.comps; j++) {
        chk ^= (uint64_t)(j + 1) * 0x9e3779b97f4a7c15ULL;
}
    w->checksum = chk ^ (uint64_t)w->allocs ^ ((uint64_t)w->frees << 1);
    w->trace_digest = h;
    w->count_64k = c64k;
    w->count_1m = c1m;

    if (w->alloc_log_fp) {
        (void)fflush(w->alloc_log_fp);
        (void)fclose(w->alloc_log_fp);
        w->alloc_log_fp = NULL;
    }

    free(zipf_cdf);
    free(live);
    return NULL;
}

static void usage(const char* prog) {
    fprintf(stderr,
        "Usage: %s --mode alloc|call --comps N --threads T --ops OPS [options]\n"
        "Options (alloc mode):\n"
        "  --live L              live-set slots per thread (default 4096)\n"
        "  --free-pct P           probability (0..100) of free when slot occupied (default 50)\n"
        "  --remote-free 0|1      enable cross-thread frees (default 0)\n"
        "  --sizes small|mixed    size profile (default mixed)\n"
        "  --fixed-size N    force exact allocation size in bytes (overrides --sizes)\n"
        "  --alloc-fn malloc|calloc (default malloc)\n"
        "Options (call schedule):\n"
        "  --pattern rr|burst|zipf|phased|prodcon\n"
        "                         scheduling across DSOs (default rr)\n"
        "    rr       -- round-robin: comp 0,1,2,...,N-1,0,1,...\n"
        "    burst    -- stay in one comp for burst_len ops, then rotate\n"
        "    zipf     -- skewed Zipf(1) distribution (comp 0 hottest)\n"
        "    phased   -- 3-phase execution (init/steady/cleanup)\n"
        "    prodcon  -- producer-consumer: even comps alloc, odd comps free\n"
        "  --burst-len B          ops per DSO before switching (default 1024)\n"
        "General:\n"
        "  --seed S               RNG seed (default 1)\n",
        prog);
}

static int streq(const char* a, const char* b) { return strcmp(a,b)==0; }

int main(int argc, char** argv) {
    bench_params_t p;
    memset(&p, 0, sizeof(p));
    p.mode = MODE_ALLOC;
    p.comps = 1;
    p.threads = 1;
    p.ops_per_thread = 1000000;
    p.live = 4096;
    p.free_pct = 50;
    p.remote_free = 0;
    p.size_profile = SIZE_MIXED;
    p.pattern = PATTERN_RR;
    p.burst_len = 1024;
    p.seed = 1;
    p.alloc_fn = ALLOC_MALLOC;
    p.fixed_size = 0;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (streq(a, "--mode") && i+1 < argc) {
            const char* m = argv[++i];
            if (streq(m, "alloc")) p.mode = MODE_ALLOC;
            else if (streq(m, "call")) p.mode = MODE_CALL;
            else { usage(argv[0]); return 1; }
        } else if (streq(a, "--comps") && i+1 < argc) {
            p.comps = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (streq(a, "--threads") && i+1 < argc) {
            p.threads = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (streq(a, "--ops") && i+1 < argc) {
            p.ops_per_thread = (uint64_t)strtoull(argv[++i], NULL, 10);
        } else if (streq(a, "--live") && i+1 < argc) {
            p.live = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (streq(a, "--free-pct") && i+1 < argc) {
            p.free_pct = (uint32_t)strtoul(argv[++i], NULL, 10);
            if (p.free_pct > 100) p.free_pct = 100;
        } else if (streq(a, "--remote-free") && i+1 < argc) {
            p.remote_free = (uint32_t)strtoul(argv[++i], NULL, 10) ? 1 : 0;
        } else if (streq(a, "--sizes") && i+1 < argc) {
            const char* s = argv[++i];
            if (streq(s, "small")) p.size_profile = SIZE_SMALL;
            else if (streq(s, "mixed")) p.size_profile = SIZE_MIXED;
            else { usage(argv[0]); return 1; }
        } else if (streq(a, "--fixed-size") && i+1 < argc) {
            p.fixed_size = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (streq(a, "--pattern") && i+1 < argc) {
            const char* s = argv[++i];
            if (streq(s, "rr")) p.pattern = PATTERN_RR;
            else if (streq(s, "burst")) p.pattern = PATTERN_BURST;
            else if (streq(s, "zipf")) p.pattern = PATTERN_ZIPF;
            else if (streq(s, "phased")) p.pattern = PATTERN_PHASED;
            else if (streq(s, "prodcon")) p.pattern = PATTERN_PRODCON;
            else if (streq(s, "seq")) p.pattern = PATTERN_SEQ;
            else { usage(argv[0]); return 1; }
        } else if (streq(a, "--burst-len") && i+1 < argc) {
            p.burst_len = (uint32_t)strtoul(argv[++i], NULL, 10);
            if (p.burst_len == 0) p.burst_len = 1;
        } else if (streq(a, "--seed") && i+1 < argc) {
            p.seed = (uint64_t)strtoull(argv[++i], NULL, 10);
        } else if (streq(a, "--alloc-log") && i+1 < argc) {
            g_alloc_log_prefix = argv[++i];
        } else if (streq(a, "--alloc-fn") && i+1 < argc) {
            const char* s = argv[++i];
            if (streq(s, "malloc")) p.alloc_fn = ALLOC_MALLOC;
            else if (streq(s, "calloc")) p.alloc_fn = ALLOC_CALLOC;
            else { usage(argv[0]); return 1; }
        } else if (streq(a, "--simple-alloc") && i+1 < argc) {
            g_simple_alloc = (int)strtol(argv[++i], NULL, 10);
        }
        else if (streq(a, "--help") || streq(a, "-h")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown arg: %s\n", a);
            usage(argv[0]);
            return 1;
        }
    }

    if (p.comps < 1 || p.threads < 1 || p.ops_per_thread < 1) {
        usage(argv[0]);
        return 1;
    }
    if (p.comps > comp_max) {
        fprintf(stderr, "ERROR: --comps %u exceeds built MAX_COMPS=%u\n",
                p.comps, comp_max);
        return 2;
    }


    inbox_t* inboxes = NULL;
    if (p.mode == MODE_ALLOC && p.remote_free && p.threads > 1) {
        inboxes = (inbox_t*)calloc(p.threads, sizeof(inbox_t));
        if (!inboxes) { perror("calloc inboxes"); return 2; }
        for (uint32_t t = 0; t < p.threads; t++) inbox_init(&inboxes[t], 8192);
    }

        // Fast path: avoid pthread overhead when threads == 1.
    pthread_t* th = NULL;
    worker_ctx_t* ws = (worker_ctx_t*)calloc(p.threads, sizeof(worker_ctx_t));
    if (!ws) { perror("calloc worker"); return 2; }

    for (uint32_t t = 0; t < p.threads; t++) {
        ws[t].tid = t;
        ws[t].p = p;
        ws[t].inboxes = inboxes;
        ws[t].alloc_log_fp = NULL;
        ws[t].alloc_log_path[0] = '\0';
    }

    if (p.threads == 1) {
        if (p.mode == MODE_CALL) (void)worker_call(&ws[0]);
        else (void)(g_simple_alloc ? simple_worker_alloc(&ws[0]) : worker_alloc(&ws[0]));
    } else {
        th = (pthread_t*)calloc(p.threads, sizeof(pthread_t));
        if (!th) { perror("calloc threads"); return 2; }

        for (uint32_t t = 0; t < p.threads; t++) {
            int rc;
            if (p.mode == MODE_CALL) rc = pthread_create(&th[t], NULL, worker_call, &ws[t]);
            else rc = pthread_create(&th[t], NULL, worker_alloc, &ws[t]);

            if (rc != 0) {
                fprintf(stderr, "pthread_create: %s\n", strerror(rc));
                return 2;
            }
        }

        for (uint32_t t = 0; t < p.threads; t++) pthread_join(th[t], NULL);
    }

    // Aggregate
    uint64_t min_start = ws[0].start_ns, max_end = ws[0].end_ns;
    bench_result_t r;
    memset(&r, 0, sizeof(r));
    for (uint32_t t = 0; t < p.threads; t++) {
        if (ws[t].start_ns < min_start) min_start = ws[t].start_ns;
        if (ws[t].end_ns > max_end) max_end = ws[t].end_ns;
        r.checksum ^= ws[t].checksum;
        r.allocs += ws[t].allocs;
        r.frees += ws[t].frees;
        r.remote_frees += ws[t].remote_frees;
    }

    uint64_t trace_digest = 0;
    uint64_t count_64k = 0, count_1m = 0;
    for (uint32_t t = 0; t < p.threads; t++) {
        trace_digest ^= ws[t].trace_digest;
        count_64k += ws[t].count_64k;
        count_1m += ws[t].count_1m;
    }

    uint64_t elapsed_ns = (max_end - min_start);
    r.seconds = (double)elapsed_ns / 1e9;
    double total_ops = (double)p.ops_per_thread * (double)p.threads;
    r.ops_per_sec = total_ops / (r.seconds > 0.0 ? r.seconds : 1e-9);

    const char* alloc_fn_s =
        (p.alloc_fn == ALLOC_CALLOC ? "calloc" : "malloc");
    const char* alloc_log_s = (g_alloc_log_prefix && g_alloc_log_prefix[0]) ? "1" : "0";

    printf("RESULT mode=%s comps=%u threads=%u ops_per_thread=%" PRIu64
           " total_ops=%" PRIu64
           " pattern=%s burst_len=%u live=%u free_pct=%u remote_free=%u sizes=%s"
           " fixed_size=%u"
           " alloc_fn=%s alloc_log=%s"
           " seconds=%.9f ops_per_sec=%.3f allocs=%" PRIu64
           " frees=%" PRIu64 " remote_frees=%" PRIu64
           " trace_digest=%" PRIu64 " count_64k=%" PRIu64 " count_1m=%" PRIu64
           " checksum=%" PRIu64 "\n",
        (p.mode == MODE_CALL ? "call" : "alloc"),
        p.comps, p.threads, p.ops_per_thread,
        (uint64_t)(p.ops_per_thread * (uint64_t)p.threads),
        (p.pattern == PATTERN_RR ? "rr" :
         p.pattern == PATTERN_BURST ? "burst" :
         p.pattern == PATTERN_ZIPF ? "zipf" :
         p.pattern == PATTERN_PHASED ? "phased" :
         p.pattern == PATTERN_PRODCON ? "prodcon" :
         p.pattern == PATTERN_SEQ ? "seq" : "unknown"),
        p.burst_len, p.live, p.free_pct, p.remote_free,
        (p.size_profile == SIZE_SMALL ? "small" : "mixed"),
        p.fixed_size,
        alloc_fn_s,
        alloc_log_s,
        r.seconds, r.ops_per_sec,
        r.allocs, r.frees, r.remote_frees,
        trace_digest, count_64k, count_1m,
        r.checksum);

    if (inboxes) {
        for (uint32_t t = 0; t < p.threads; t++) inbox_destroy(&inboxes[t]);
        free(inboxes);
    }
    free(th);
    free(ws);
    return 0;
}
