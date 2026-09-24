// Ask the one question the release verification used to skip.
//
// `spctl --assess` answers "would Gatekeeper let this be opened", which for a
// notarized bundle is yes. But a screen saver is never opened; it is dlopen'd
// into legacyScreenSaver, and that goes through a different gate — the one
// that produces
//
//     code signature ... not valid for use in process:
//     library load disallowed by system policy
//
// and, to the user, a dialog saying Apple could not verify the bundle is free
// of malware. A release can pass spctl and still fail this. So check this.
//
// Build: cc -o gatekeeper-probe gatekeeper-probe.c
// Usage: gatekeeper-probe <path to the Mach-O inside the bundle>
//        exit 0 = loaded, 1 = refused, 2 = bad invocation

#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mach-o>\n", argv[0]);
        return 2;
    }
    void *handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (handle != NULL) {
        printf("loaded\n");
        dlclose(handle);
        return 0;
    }
    printf("refused: %s\n", dlerror());
    return 1;
}
