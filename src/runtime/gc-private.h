/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

/* Include this header only in files that are _really_ part of GC
   or intimately tied to GC like 'raceroot'. */

#ifndef _GC_PRIVATE_H_
#define _GC_PRIVATE_H_

#include "genesis/instance.h"
#include "genesis/weak-pointer.h"
#include "immobile-space.h"
#include "code.h"

#ifdef LISP_FEATURE_GENCGC
#include "gencgc-alloc-region.h"
static inline void *
gc_general_alloc(sword_t nbytes, int page_type_flag)
{
    void *gc_alloc_with_region(struct alloc_region*,sword_t,int);
    if (1 <= page_type_flag && page_type_flag <= 3)
        return gc_alloc_with_region(&gc_alloc_region[page_type_flag-1],
                                    nbytes, page_type_flag);
    lose("bad page type flag: %d", page_type_flag);
}
#else
extern void *gc_general_alloc(sword_t nbytes,int page_type_flag);
#endif

#define CHECK_COPY_PRECONDITIONS(object, nwords) \
    gc_dcheck(is_lisp_pointer(object)); \
    gc_dcheck(from_space_p(object)); \
    gc_dcheck((nwords & 0x01) == 0)

#define CHECK_COPY_POSTCONDITIONS(copy, lowtag) \
    gc_dcheck(lowtag_of(copy) == lowtag); \
    gc_dcheck(!from_space_p(copy));

#define note_transported_object(old, new) /* do nothing */

extern uword_t gc_copied_nwords;
static inline lispobj
gc_general_copy_object(lispobj object, size_t nwords, int page_type_flag)
{
    CHECK_COPY_PRECONDITIONS(object, nwords);

    /* Allocate space. */
    lispobj *new = gc_general_alloc(nwords*N_WORD_BYTES, page_type_flag);

    /* Copy the object. */
    gc_copied_nwords += nwords;
    memcpy(new,native_pointer(object),nwords*N_WORD_BYTES);

    note_transported_object(object, new);

    return make_lispobj(new, lowtag_of(object));
}

// Like above but copy potentially fewer words than are allocated.
// ('old_nwords' can be, but does not have to be, smaller than 'nwords')
static inline lispobj
gc_copy_object_resizing(lispobj object, long nwords, int page_type_flag,
                        int old_nwords)
{
    CHECK_COPY_PRECONDITIONS(object, nwords);
    lispobj *new = gc_general_alloc(nwords*N_WORD_BYTES, page_type_flag);
    gc_copied_nwords += old_nwords;
    memcpy(new, native_pointer(object), old_nwords*N_WORD_BYTES);
    note_transported_object(object, new);
    return make_lispobj(new, lowtag_of(object));
}

extern sword_t (*const scavtab[256])(lispobj *where, lispobj object);
extern struct cons *weak_vectors; /* in gc-common.c */
extern struct hash_table *weak_hash_tables; /* in gc-common.c */

// These next two are prototyped for both GCs
// but only gencgc will ever call them.
void gc_mark_range(lispobj*start, long count);
void gc_mark_obj(lispobj);
void gc_dispose_private_pages();
void add_to_weak_vector_list(lispobj* vector, lispobj header);

extern void heap_scavenge(lispobj *start, lispobj *limit);
extern sword_t scavenge(lispobj *start, sword_t n_words);
extern void scavenge_interrupt_contexts(struct thread *thread);
extern void scav_binding_stack(lispobj*, lispobj*, void(*)(lispobj));
extern void scan_binding_stack(void);
extern void cull_weak_hash_tables(int (*[4])(lispobj,lispobj));
extern void smash_weak_pointers(void);
extern boolean scan_weak_hashtable(struct hash_table *hash_table,
                                   int (*)(lispobj,lispobj),
                                   void (*)(lispobj*));
extern int (*weak_ht_alivep_funs[4])(lispobj,lispobj);
extern void gc_scav_pair(lispobj where[2]);
extern void gc_common_init();
extern boolean test_weak_triggers(int (*)(lispobj), void (*)(lispobj));

lispobj  copy_unboxed_object(lispobj object, sword_t nwords);
lispobj  copy_object(lispobj object, sword_t nwords);
lispobj  copy_possibly_large_object(lispobj object, sword_t nwords, int page_type_flag);

lispobj *search_read_only_space(void *pointer);
lispobj *search_static_space(void *pointer);
lispobj *search_dynamic_space(void *pointer);

extern int properly_tagged_p_internal(lispobj pointer, lispobj *start_addr);
static inline int properly_tagged_descriptor_p(void *pointer, lispobj *start_addr) {
  return is_lisp_pointer((lispobj)pointer) &&
    properly_tagged_p_internal((lispobj)pointer, start_addr);
}

extern void scavenge_control_stack(struct thread *th);
extern void scrub_control_stack(void);
extern void scrub_thread_control_stack(struct thread *);

// for code ojects, this bit signifies that this object is in the remembered set.
// KLUDGE: this constant needs to be autogenerated. It is currently hardcoded into
// the CODE-HEADER-SET assembly routine for x86 and x86-64.
#define OBJ_WRITTEN_FLAG 0x40
#ifdef LISP_FEATURE_LITTLE_ENDIAN
#define CLEAR_WRITTEN_FLAG(obj) ((unsigned char*)obj)[3] &= ~OBJ_WRITTEN_FLAG
#define SET_WRITTEN_FLAG(obj)   ((unsigned char*)obj)[3] |= OBJ_WRITTEN_FLAG
#else
#define CLEAR_WRITTEN_FLAG(obj) *obj &= ~(OBJ_WRITTEN_FLAG<<24)
#define SET_WRITTEN_FLAG(obj)   *obj |=  (OBJ_WRITTEN_FLAG<<24)
#endif
static inline int header_rememberedp(lispobj header) {
  return (header & (OBJ_WRITTEN_FLAG << 24)) != 0;
}

static inline boolean filler_obj_p(lispobj* obj) {
    return widetag_of(obj) == CODE_HEADER_WIDETAG && obj[1] == 0;
}

#ifdef LISP_FEATURE_IMMOBILE_SPACE

extern void enliven_immobile_obj(lispobj*,int);

#define IMMOBILE_OBJ_VISITED_FLAG    0x10

// Immobile object header word:
//                 generation byte --|    |-- widetag
//                                   v    v
//                       0xzzzzzzzz GGzzzzww
//         arbitrary data  --------   ---- length in words
//
// An an exception to the above, FDEFNs omit the length:
//                       0xzzzzzzzz zzzzGGww
//         arbitrary data  -------- ----
// so that there are 6 consecutive bytes of arbitrary data.
// The length of an FDEFN is implicitly fixed at 4 words.

// There is a hard constraint on NUM_GENERATIONS, which is currently 8.
// (0..5=normal, 6=pseudostatic, 7=scratch)
// Shifting a 1 bit left by the contents of the generation byte
// must not overflow a register.

// Mask off the VISITED flag to get the generation number
#define immobile_obj_generation(x) (immobile_obj_gen_bits(x) & 0xf)

#ifdef LISP_FEATURE_LITTLE_ENDIAN
// Return the generation bits which means the generation number
// in the 4 low bits (there's 1 excess bit) and the VISITED flag.
static inline int immobile_obj_gen_bits(lispobj* obj) // native pointer
{
    // When debugging, assert that we're called only on a headered object
    // whose header contains a generation byte.
    gc_dcheck(!embedded_obj_p(widetag_of(obj)));
    char gen;
    switch (widetag_of(obj)) {
    default:
        gen = ((generation_index_t*)obj)[3]; break;
    case FDEFN_WIDETAG:
        gen = ((generation_index_t*)obj)[1]; break;
    }
    return gen & 0x1F;
}
// Turn a grey node black.
static inline void set_visited(lispobj* obj)
{
    gc_dcheck(widetag_of(obj) != SIMPLE_FUN_WIDETAG);
    gc_dcheck(immobile_obj_gen_bits(obj) == new_space);
    int byte = widetag_of(obj) == FDEFN_WIDETAG ? 1 : 3;
    ((generation_index_t*)obj)[byte] |= IMMOBILE_OBJ_VISITED_FLAG;
}
static inline void assign_generation(lispobj* obj, generation_index_t gen)
{
    gc_dcheck(widetag_of(obj) != SIMPLE_FUN_WIDETAG);
    int byte = widetag_of(obj) == FDEFN_WIDETAG ? 1 : 3;
    generation_index_t* ptr = (generation_index_t*)obj + byte;
    // Clear the VISITED flag, assign a new generation, preserving the three
    // high bits which include the OBJ_WRITTEN flag as well as two
    // opaque flag bits for use by Lisp.
    *ptr = (*ptr & 0xE0) | gen;
}
#else
#error "Need to define immobile_obj_gen_bits() for big-endian"
#endif /* little-endian */

#endif /* immobile space */

#define WEAK_POINTER_CHAIN_END (void*)(intptr_t)-1
#define WEAK_POINTER_NWORDS ALIGN_UP(WEAK_POINTER_SIZE,2)

static inline boolean weak_pointer_breakable_p(struct weak_pointer *wp)
{
    lispobj pointee = wp->value;
    // A broken weak-pointer's value slot has unbound-marker
    // which does not satisfy is_lisp_pointer().
    return is_lisp_pointer(pointee) && (from_space_p(pointee)
#ifdef LISP_FEATURE_IMMOBILE_SPACE
         || (immobile_space_p(pointee) &&
             immobile_obj_gen_bits(base_pointer(pointee)) == from_space)
#endif
            );
}

static inline void add_to_weak_pointer_chain(struct weak_pointer *wp) {
    /* Link 'wp' into weak_pointer_chain using its 'next' field.
     * We ensure that 'next' is always NULL when the weak pointer isn't
     * in the chain, and not NULL otherwise. The end of the chain
     * is denoted by WEAK_POINTER_CHAIN_END which is distinct from NULL.
     * The test of whether the weak pointer has been placed in the chain
     * is performed in 'scav_weak_pointer' for gencgc.
     * In cheneygc, chaining is performed in 'trans_weak_pointer'
     * which works just as well, since an object is transported
     * at most once per GC cycle */
    wp->next = weak_pointer_chain;
    weak_pointer_chain = wp;
}

#include "genesis/layout.h"
struct bitmap { sword_t *bits; unsigned int nwords; };
static inline struct bitmap get_layout_bitmap(struct layout* layout)
{
    struct bitmap bitmap;
    const int layout_id_vector_fixed_capacity = 7;
#ifdef LISP_FEATURE_64_BIT
    sword_t depthoid = layout->flags;
    // Depthoid is stored in the upper 4 bytes of 'flags', as a fixnum.
    depthoid >>= (32 + N_FIXNUM_TAG_BITS);
    int extra_id_words =
      (depthoid > layout_id_vector_fixed_capacity) ?
      ALIGN_UP(depthoid - layout_id_vector_fixed_capacity, 2) / 2 : 0;
#else
    sword_t depthoid = layout->depthoid;
    depthoid >>= N_FIXNUM_TAG_BITS;
    int extra_id_words = (depthoid > layout_id_vector_fixed_capacity) ?
      depthoid - layout_id_vector_fixed_capacity : 0;
#endif
    // The 2 bits for stable address-based hashing can't ever bet set.
    const int baseline_payload_words = (sizeof (struct layout) / N_WORD_BYTES) - 1;
    int payload_words = ((unsigned int)layout->header >> INSTANCE_LENGTH_SHIFT) & 0x3FFF;
    bitmap.bits = (sword_t*)((char*)layout + sizeof (struct layout)) + extra_id_words;
    bitmap.nwords = payload_words - baseline_payload_words - extra_id_words;
    return bitmap;
}

/* Return true if the INDEXth bit is set in BITMAP.
 * Index 0 corresponds to the word just after the instance header.
 * So index 0 may be the layout pointer if #-compact-instance-header,
 * or a user data slot if #+compact-instance-header
 */
static inline boolean bitmap_logbitp(unsigned int index, struct bitmap bitmap)
{
    unsigned int word_index = index / N_WORD_BITS;
    unsigned int bit_index  = index % N_WORD_BITS;
    if (word_index >= bitmap.nwords) return bitmap.bits[bitmap.nwords-1] < 0;
    return (bitmap.bits[word_index] >> bit_index) & 1;
}

/* Keep in sync with 'target-hash-table.lisp' */
#define hashtable_kind(ht) ((ht->flags >> (4+N_FIXNUM_TAG_BITS)) & 3)
#define hashtable_weakp(ht) (ht->flags & (8<<N_FIXNUM_TAG_BITS))
#define hashtable_weakness(ht) (ht->flags >> (6+N_FIXNUM_TAG_BITS))

#if defined(LISP_FEATURE_GENCGC)

/* Define a macro to avoid a detour through the write fault handler.
 *
 * It's usually more efficient to do these extra tests than to receive
 * a signal. And it leaves the page protected, which is a bonus.
 * The downside is that multiple operations on the same page ought to
 * be batched, so that there is at most one unprotect/reprotect per page
 * rather than per write operation per page.
 *
 * This also should fix -fsanitize=thread which makes handling of SIGSEGV
 * during GC difficult. Not impossible, but definitely broken.
 * It has to do with the way the sanitizer intercepts calls
 * to sigaction() - it mucks with your sa_mask :-(.
 *
 * This macro take an arbitrary expression as the 'operation' rather than
 * an address and value to assign, for two reasons:
 * 1. there may be more than one store operation that has to be
 *    within the scope of the lifted write barrier,
 *    so a single lvalue and rvalue is maybe inadequate.
 * 2. it might need to use a sync_fetch_and_<frob>() gcc intrinsic,
 *    so it's not necessarily just going to be an '=' operator
 *
 * KLUDGE: assume that faults do not occur in immobile space.
 * for the most part. (This is pretty obviously not true,
 * but seems only to be a problem in fullcgc)
 */

extern char* gc_card_mark;
#ifdef LISP_FEATURE_SOFT_CARD_MARKS
#define NON_FAULTING_STORE(operation, addr) { operation; }
#else
#define NON_FAULTING_STORE(operation, addr) { \
  page_index_t page_index = find_page_index(addr); \
  if (page_index < 0 || !PAGE_WRITEPROTECTED_P(page_index)) { operation; } \
  else { unprotect_page_index(page_index); \
         operation; \
         protect_page(page_address(page_index), page_index); }}
#endif

#ifdef LISP_FEATURE_DARWIN_JIT
#define OS_VM_PROT_JIT_READ OS_VM_PROT_READ
#define OS_VM_PROT_JIT_ALL OS_VM_PROT_READ | OS_VM_PROT_WRITE
#else
#define OS_VM_PROT_JIT_READ OS_VM_PROT_READ | OS_VM_PROT_EXECUTE
#define OS_VM_PROT_JIT_ALL OS_VM_PROT_ALL
#endif

/* This is used by the fault handler, and potentially during GC */
static inline void unprotect_page_index(page_index_t page_index)
{
#ifdef LISP_FEATURE_SOFT_CARD_MARKS
    int card = page_to_card_index(page_index);
    if (gc_card_mark[card] == 1) gc_card_mark[card] = 0; // NEVER CHANGE '2' to '0'
#else
    os_protect(page_address(page_index), GENCGC_CARD_BYTES, OS_VM_PROT_JIT_ALL);
    unsigned char *pflagbits = (unsigned char*)&page_table[page_index].gen - 1;
    __sync_fetch_and_or(pflagbits, WP_CLEARED_FLAG);
    SET_PAGE_PROTECTED(page_index, 0);
#endif
}

static inline void protect_page(void* page_addr,
                                __attribute__((unused)) page_index_t page_index)
{
#ifndef LISP_FEATURE_SOFT_CARD_MARKS
    os_protect((void *)page_addr, GENCGC_CARD_BYTES, OS_VM_PROT_JIT_READ);

    /* Note: we never touch the write_protected_cleared bit when protecting
     * a page. Consider two random threads that reach their SIGSEGV handlers
     * concurrently, each checking why it got a write fault. One thread wins
     * the race to remove the memory protection, and marks our shadow bit.
     * wp_cleared is set so that the other thread can conclude that the fault
     * was reasonable.
     * If GC unprotects and reprotects a page, it's probably OK to reset the
     * cleared bit 0 if it was 0 before. (Because the fault handler blocks
     * SIG_STOP_FOR_GC which is usually SIGUSR2, handling the wp fault is
     * atomic with respect to invocation of GC)
     * But nothing is really gained by resetting the cleared flag.
     * It is explicitly zeroed on pages marked as free though.
     */
#endif
    gc_card_mark[addr_to_card_index(page_addr)] = 1;
}

// Two helpers to avoid invoking the memory fault signal handler.
// For clarity, distinguish between words which *actually* need to frob
// physical (MMU-based) protection versus those which don't,
// but are forced to call mprotect() because it's the only choice.
// Unlike with NON_FAULTING_STORE, in this case we actually do want to record that
// the ensuing store toggles the WP bit without invoking the fault handler.
static inline void ensure_ptr_word_writable(void* addr) {
    page_index_t index = find_page_index(addr);
    gc_assert(index >= 0);
    if (PAGE_WRITEPROTECTED_P(index)) unprotect_page_index(index);
}
static inline void ensure_non_ptr_word_writable(__attribute__((unused)) void* addr)
{
  // don't need to do anything if not using hardware page protection
#ifndef LISP_FEATURE_SOFT_CARD_MARKS
    ensure_ptr_word_writable(addr);
#endif
}

#else

/* cheneygc */
#define ensure_ptr_word_writable(dummy)
#define ensure_non_ptr_word_writable(dummy)
#define NON_FAULTING_STORE(operation, addr) operation

#endif

#define KV_PAIRS_HIGH_WATER_MARK(kvv) fixnum_value(kvv[0])
#define KV_PAIRS_REHASH(kvv) kvv[1]

/* This is NOT the same value that lisp's %INSTANCE-LENGTH returns.
 * Lisp always uses the logical length (as originally allocated),
 * except when heap-walking which requires exact physical sizes */
static inline int instance_length(lispobj header)
{
    // * Byte 3 of an instance header word holds the immobile gen# and visited bit,
    //   so those have to be masked off.
    // * fullcgc uses bit index 31 as a mark bit, so that has to
    //   be cleared. Lisp does not have to clear bit 31 because fullcgc does not
    //   operate concurrently.
    // * If the object is in hashed-and-moved state and the original instance payload
    //   length was odd (total object length was even), then add 1.
    //   This can be detected by ANDing some bits, bit 10 being the least-significant
    //   bit of the original size, and bit 9 being the 'hashed+moved' bit.
    // * 64-bit machines do not need 'long' right-shifts, so truncate to int.

    int extra = ((unsigned int)header >> 10) & ((unsigned int)header >> 9) & 1;
    return (((unsigned int)header >> INSTANCE_LENGTH_SHIFT) & 0x3FFF) + extra;
}

/// instance_layout() and layout_of() macros takes a lispobj* and are lvalues
#ifdef LISP_FEATURE_COMPACT_INSTANCE_HEADER

# ifdef LISP_FEATURE_LITTLE_ENDIAN
#  define instance_layout(native_ptr) ((uint32_t*)(native_ptr))[1]
# else
#  error "No instance_layout() defined"
# endif
# define funinstance_layout(native_ptr) instance_layout(native_ptr)
// generalize over either metatype, but not as general as SB-KERNEL:LAYOUT-OF
# define layout_of(native_ptr) instance_layout(native_ptr)

#else

// first 2 words of ordinary instance are: header, layout
# define instance_layout(native_ptr) ((lispobj*)native_ptr)[1]
// first 4 words of funcallable instance are: header, trampoline, layout, fin-fun
# define funinstance_layout(native_ptr) ((lispobj*)native_ptr)[2]
# define layout_of(native_ptr) \
  ((lispobj*)native_ptr)[1+((widetag_of(native_ptr)>>LAYOUT_SELECTOR_BIT)&1)]

#endif

static inline int layout_depth2_id(struct layout* layout) {
    int32_t* vector = (int32_t*)&layout->id_word0;
    return vector[0];
}
// Keep in sync with hardwired IDs in src/compiler/generic/genesis.lisp
#define WRAPPER_LAYOUT_ID 2
#define LAYOUT_LAYOUT_ID 3
#define LFLIST_NODE_LAYOUT_ID 4

/// Return true if 'thing' is a layout.
/// This predicate is careful, as is it used to verify heap invariants.
static inline boolean layoutp(lispobj thing)
{
    lispobj layout;
    if (lowtag_of(thing) != INSTANCE_POINTER_LOWTAG) return 0;
    if ((layout = instance_layout(INSTANCE(thing))) == 0) return 0;
    return layout_depth2_id(LAYOUT(layout)) == LAYOUT_LAYOUT_ID;
}
#ifdef LISP_FEATURE_METASPACE
static inline boolean wrapperp(lispobj thing)
{
    lispobj layout;
    if (lowtag_of(thing) != INSTANCE_POINTER_LOWTAG) return 0;
    if ((layout = instance_layout(INSTANCE(thing))) == 0) return 0;
    return layout_depth2_id(LAYOUT(layout)) == WRAPPER_LAYOUT_ID;
}
static inline int wrapper_id(lispobj wrapper)
{
    struct layout* layout = LAYOUT(WRAPPER(wrapper)->friend);
    return layout_depth2_id(layout);
}
#endif
/// Return true if 'thing' is the layout of any subtype of sb-lockless::list-node.
static inline boolean lockfree_list_node_layout_p(struct layout* layout) {
    return layout_depth2_id(layout) == LFLIST_NODE_LAYOUT_ID;
}

#ifdef LISP_FEATURE_METASPACE
#define METASPACE_START (READ_ONLY_SPACE_START+32768) /* KLUDGE */
// Keep in sync with the macro definitions in src/compiler/generic/early-vm.lisp
struct slab_header {
    short sizeclass;
    short capacity;
    short chunksize;
    short count;
    void* freelist;
    struct slab_header *next;
    struct slab_header *prev;
};
#endif

/* Check whether 'pointee' was forwarded. If it has been, update the contents
 * of 'cell' to point to it. Otherwise, set 'cell' to 'broken'.
 * Note that this macro has no braces around the body because one of the uses
 * of it needs to stick on another 'else' or two */
#define TEST_WEAK_CELL(cell, pointee, broken) \
    lispobj *native = native_pointer(pointee); \
    if (from_space_p(pointee)) \
        cell = forwarding_pointer_p(native) ? forwarding_pointer_value(native) : broken; \
    else if (immobile_space_p(pointee)) { \
        if (immobile_obj_gen_bits(base_pointer(pointee)) == from_space) cell = broken; \
    }

#endif /* _GC_PRIVATE_H_ */
