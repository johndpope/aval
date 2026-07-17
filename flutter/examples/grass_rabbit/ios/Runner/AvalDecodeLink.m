// Forces the linker to pull aval_decode C ABI symbols from libaval_decode.a
// into the Runner binary so Dart DynamicLibrary.process() can resolve them.
// Without this, dead-strip drops the static archive (nothing in Swift/ObjC
// references those symbols).

#import <Foundation/Foundation.h>
#import <stdint.h>

extern void *aval_decode_session_create(void);
extern void aval_decode_session_destroy(void *);
extern int32_t aval_decode_configure(void *, const void *);
extern int32_t aval_decode_activate_generation(void *, uint64_t);
extern int32_t aval_decode_submit_chunk(void *, uint64_t, const void *, void *);
extern int32_t aval_decode_take_frame(void *, void *);
extern int32_t aval_decode_release_frame(void *, uint64_t);
extern int32_t aval_decode_dispose(void *);

// A local (stack) array of these function pointers is not enough to keep the
// archive members linked in: Clang proved the array was never read after its
// last write and dead-store-eliminated the whole thing at compile time, even
// though it was declared `volatile` — so no undefined-symbol reference ever
// reached the object file, and the linker never pulled in the Rust code.
// A `used` global with external linkage survives both that compile-time DCE
// and the link-time `-dead_strip` pass, so the relocations to these symbols
// are guaranteed to remain and must be resolved against libaval_decode.a.
__attribute__((used))
void *const aval_decode_link_symbols[] = {
    (void *)aval_decode_session_create,
    (void *)aval_decode_session_destroy,
    (void *)aval_decode_configure,
    (void *)aval_decode_activate_generation,
    (void *)aval_decode_submit_chunk,
    (void *)aval_decode_take_frame,
    (void *)aval_decode_release_frame,
    (void *)aval_decode_dispose,
};

__attribute__((used, visibility("default")))
void aval_decode_force_link(void) {
  (void)aval_decode_link_symbols;
}

@interface AvalDecodeLinkBootstrap : NSObject
@end

@implementation AvalDecodeLinkBootstrap
+ (void)load {
  aval_decode_force_link();
}
@end
