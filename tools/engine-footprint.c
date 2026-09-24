/*
 * What one engine session costs, and what it gives back.
 *
 *   cc -O2 -o out/engine-footprint tools/engine-footprint.c
 *   out/engine-footprint                 # sweep canvas sizes
 *   out/engine-footprint 220 74 40       # one size, many sessions
 *
 * Calls ttfx_session_new / ttfx_session_free straight through the bundle's
 * exported C surface, so nothing here is Swift, AppKit or ScreenSaverView.
 * When the screen saver's footprint moves, this says whether the engine is
 * the reason.
 *
 * Reports phys_footprint, not resident_size: resident_size counts every mapped
 * page a process has touched, including framework text, so it climbs as new
 * code paths run and reads like a leak that is not there.
 *
 * What it found, and what the sweep is for: below about 9,000 canvas cells a
 * new/free pair costs +0.01 MB, flat over any number of sessions. Above it,
 * each pair leaves roughly 0.4 KB per cell behind — +6.7 MB per session at
 * 220x74 — and it does not plateau. `leaks` reports nothing and
 * malloc_zone_pressure_relief recovers nothing, because the memory is not
 * leaked: vmmap shows it as "Malloc Small (empty)", whole regions with no live
 * allocations left in them, still resident and still dirty. The engine frees
 * correctly; the allocator keeps the pages. The process is charged either way.
 */

#include <dlfcn.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>

static double footprint_mb(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint / 1048576.0;
}

typedef void *(*new_fn)(const char *, const char *, long long, long long, long long,
                        unsigned long long, unsigned char);
typedef const char *(*next_fn)(void *);
typedef void (*free_fn)(void *);

static new_fn s_new;
static next_fn s_next;
static free_fn s_free;

static const char *LOGO = "ttfx ttfx ttfx\nttfx ttfx ttfx\nttfx ttfx ttfx\n";

/* One new/advance/free pair. frames < 0 runs the effect to completion. */
static void cycle(int w, int h, int seed, int frames) {
    void *s = s_new("beams", LOGO, w, h, 60, seed, 0);
    if (!s) { fprintf(stderr, "session refused at %dx%d\n", w, h); exit(1); }
    if (frames < 0) { while (s_next(s)) {} }
    else { for (int i = 0; i < frames && s_next(s); i++) {} }
    s_free(s);
}

int main(int argc, char **argv) {
    void *lib = dlopen("ttfx.saver/Contents/MacOS/ttfx-saver", RTLD_LAZY);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    s_new = (new_fn)dlsym(lib, "ttfx_session_new");
    s_next = (next_fn)dlsym(lib, "ttfx_session_next_frame");
    s_free = (free_fn)dlsym(lib, "ttfx_session_free");
    if (!s_new || !s_next || !s_free) { fprintf(stderr, "missing symbol\n"); return 1; }

    if (argc >= 3) {
        int w = atoi(argv[1]), h = atoi(argv[2]);
        int n = argc > 3 ? atoi(argv[3]) : 24;
        printf("%dx%d (%d cells), %d sessions run to completion\n", w, h, w * h, n);
        printf("  start %6.1f MB\n", footprint_mb());
        for (int c = 1; c <= n; c++) {
            cycle(w, h, c, -1);
            malloc_zone_pressure_relief(NULL, 0);
            if (n < 8 || c % (n / 8) == 0) printf("  after %3d: %6.1f MB\n", c, footprint_mb());
        }
        return 0;
    }

    int sizes[][2] = {{80,27},{110,37},{130,44},{150,50},{170,57},{190,64},{220,74},{260,87},{300,100}};
    printf("  cols x rows   cells    per new/free cycle   after 12 cycles\n");
    for (unsigned k = 0; k < sizeof(sizes) / sizeof(sizes[0]); k++) {
        int w = sizes[k][0], h = sizes[k][1];
        cycle(w, h, 1, 0);                      /* first touch, not measured */
        malloc_zone_pressure_relief(NULL, 0);
        double before = footprint_mb();
        for (int c = 0; c < 12; c++) cycle(w, h, c + 2, 0);
        malloc_zone_pressure_relief(NULL, 0);
        double after = footprint_mb();
        printf("  %3d x %3d   %6d        %+7.2f MB        %+7.1f MB\n",
               w, h, w * h, (after - before) / 12, after - before);
    }
    return 0;
}
