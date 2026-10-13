// LD_PRELOAD interposer: counts C++ exception objects allocated (__cxa_allocate_exception) and released
// (__cxa_free_exception) and writes "<allocated> <released>" to $EXCOUNT_OUT at exit.
// A caught exception is released by __cxa_end_catch when its handler is left normally. An exception whose handler
// is left by longjmp (luaL_error called inside a C++ catch block, with Lua built as C) is never released.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned long n_alloc;
static unsigned long n_free;
static void *(*real_alloc)(size_t);
static void (*real_free)(void *);

void *__cxa_allocate_exception(size_t n) {
    if (real_alloc == NULL) {
        real_alloc = (void *(*) (size_t)) dlsym(RTLD_NEXT, "__cxa_allocate_exception");
    }
    n_alloc++;
    return real_alloc(n);
}

void __cxa_free_exception(void *p) {
    if (real_free == NULL) {
        real_free = (void (*)(void *)) dlsym(RTLD_NEXT, "__cxa_free_exception");
    }
    n_free++;
    real_free(p);
}

__attribute__((destructor)) static void report(void) {
    const char *path = getenv("EXCOUNT_OUT");
    FILE *f = path != NULL ? fopen(path, "w") : NULL;
    if (f != NULL) {
        fprintf(f, "%lu %lu\n", n_alloc, n_free);
        fclose(f);
    }
}
