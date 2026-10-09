/* OCaml integration for the pinned Gumbo fork. Only Gumbo calls run inside
 * this scope; a failed allocation escapes to the OCaml stub's setjmp. */
#include "richtext_gumbo_alloc.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct RTGumboBlock {
  struct RTGumboBlock *prev, *next;
  size_t size;
  max_align_t align;
  unsigned char data[];
};

static _Thread_local RTGumboScope *active;

void rt_gumbo_scope_begin(RTGumboScope *scope, size_t *bytes, size_t limit) {
  memset(scope, 0, sizeof(*scope));
  scope->bytes = bytes;
  scope->limit = limit;
  scope->previous = active;
  active = scope;
}

static void fail(const char *error) {
  if (active) {
    active->error = error;
    longjmp(active->escape, 1);
  }
  abort();
}

void *rt_gumbo_alloc(size_t n) {
  if (!active) fail("Gumbo allocation outside bounded scope");
  if (n > SIZE_MAX - sizeof(RTGumboBlock) ||
      *active->bytes > active->limit ||
      sizeof(RTGumboBlock) + n > active->limit - *active->bytes)
    fail("rich-text parser allocation limit");
  RTGumboBlock *block = malloc(sizeof(*block) + n);
  if (!block) fail("rich-text parser allocation failed");
  block->prev = NULL;
  block->next = active->blocks;
  if (block->next) block->next->prev = block;
  active->blocks = block;
  block->size = sizeof(*block) + n;
  *active->bytes += block->size;
  return block->data;
}

void rt_gumbo_free(void *ptr) {
  if (!ptr) return;
  RTGumboBlock *block = (RTGumboBlock *)((unsigned char *)ptr - sizeof(RTGumboBlock));
  if (block->prev) block->prev->next = block->next;
  else active->blocks = block->next;
  if (block->next) block->next->prev = block->prev;
  *active->bytes -= block->size;
  free(block);
}

void *rt_gumbo_realloc(void *ptr, size_t n) {
  if (!ptr) return rt_gumbo_alloc(n);
  RTGumboBlock *block = (RTGumboBlock *)((unsigned char *)ptr - sizeof(RTGumboBlock));
  size_t old_size = block->size - sizeof(*block);
  void *new_ptr = rt_gumbo_alloc(n);
  memcpy(new_ptr, ptr, old_size < n ? old_size : n);
  rt_gumbo_free(ptr);
  return new_ptr;
}

void rt_gumbo_scope_end(RTGumboScope *scope) {
  while (scope->blocks) rt_gumbo_free(scope->blocks->data);
  active = scope->previous;
}
