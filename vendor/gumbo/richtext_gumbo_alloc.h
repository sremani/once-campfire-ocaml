#ifndef CAMPFIRE_RICHTEXT_GUMBO_ALLOC_H
#define CAMPFIRE_RICHTEXT_GUMBO_ALLOC_H
#include <setjmp.h>
#include <stddef.h>
typedef struct RTGumboBlock RTGumboBlock;
typedef struct RTGumboScope {
    jmp_buf escape;
    RTGumboBlock *blocks;
    size_t *bytes, limit;
    const char *error;
    struct RTGumboScope *previous;
} RTGumboScope;
void rt_gumbo_scope_begin(RTGumboScope *, size_t *, size_t);
void rt_gumbo_scope_end(RTGumboScope *);
void *rt_gumbo_alloc(size_t);
void *rt_gumbo_realloc(void *, size_t);
void rt_gumbo_free(void *);
#endif
