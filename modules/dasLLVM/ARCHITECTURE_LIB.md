# dasLLVM Architecture - the emitted library

Companion to `ARCHITECTURE.md` in this folder; section numbers are unique across both files.

### 1.3 A library's runtime is process-global, its environment is per-thread {#lib-runtime-scope}

An exe owns its process: one thread runs `main`, registers the modules, and drains them on the way
out. A library owns none of that, and three consequences shape its entry points.

**A library's process state lives in the library, not in the runtime.** `inject_lib` emits three
private globals - the init guard, the environment it bound, and the text of a create that returned
no instance - and passes them to the runtime shims by pointer. So the shim layer holds no state of
its own, two libraries in one process share none, and nothing needs a per-library table.

**The environment is thread-local** (`daScriptEnvironment::bound` / `owned`,
`include/daScript/ast/ast.h`), but the module registration behind it happens once. So
`jit_lib_run_once(guard, env, init)` does both jobs: the first caller registers and records its
environment, and every later caller - on any thread - is BOUND to that recording. Without the
binding a second thread's `<P>_create` dereferences a null `getBound()->modules` inside
`jit_init_extern_function`. The create-failure text sits in the library's slot for the same reason
read from the other side: a C host reads it through `<P>_last_error(nullptr)`, which has no
instance to ask, and a thread-local copy would answer null on every thread but the failing one.

**One daslang runtime fits in a process, and every artifact in it shares that one.**
`jit_register_Module_*` (`REGISTER_MODULE_IN_NAMESPACE`) carries no already-created guard and
aborts on a second call, so every emitted registration goes through
`jit_register_module_once(dasName, reg)`, which registers only when `Module::require(dasName)`
finds nothing and otherwise hands back the module already there. EVERY site means both of them -
the require walk and the extern collector's `ensure_module`, which reaches a module no `require`
names (an `ast_core` extern called from a library aborted the host until it did). A library that finds a populated
environment is a GUEST, and the guard records which it is - 1 for the library that registered the
runtime, 2 for one that joined a populated one, decided in `jit_lib_run_once` before the init call.
A guest skips `Module::Initialize` so `g_envTotal` stays balanced, and it never drains what it did
not create. Both facts are read back off the guard: `jit_initialize_modules_done` and
`jit_lib_shutdown` take its value, so ownership needs no second flag and a library arriving later
cannot erase an earlier one's.

**A guest reports a failed dynamic module; it does not abort.** `jit_finalize_dynamic_modules`
fatals on anything still unloadable, which is right for an exe that owns its process and wrong for
a library: the pending list it inherits is the HOST's, and a module the host could not load is not
this library's to kill the process over. A guest calls `jit_lib_finalize_dynamic_modules` instead -
retry, report, carry on - and a module this library actually needs still surfaces, as a null
`<P>_create` carrying the reason.

**Nothing calls the shutdown functions for a library.** A jitted `SimFunction` gets a zeroed
`FuncInfo` (`jit_lib`'s `registerJitFunction`, `src/builtin/module_jit.cpp`), so
`Context::runShutdownScript` - which selects on `FuncInfo::flag_shutdown`, set only by the
interpreter's debug-info builder - finds none. `<P>_destroy` therefore emits the program's
`[finalize]` / `[shutdown]` calls itself, the same way `<P>_create` emits its `[init]` calls. The
process-level drain is the host's explicit, final `<P>_shutdown_runtime()` - never automatic, since
a library cannot know whether the process is done with daslang, and an `atexit` hook would need
process-global state to decide. It is a no-op unless this library's guard says it owns the runtime.

Every linked artifact leaves through one emitter, `write_artifact` (`llvm_jit_common.das`): the
`JitArtifact` kind picks the file name, the linker flavor (an archiver for a static library, no
`-shared` for an exe) and the target CPU. A `jit_dll` always targets this host - it only ever runs
on the box that emitted it - while a shipped artifact takes the caller's `use_host_cpu`: generic
and redistributable by default, host-specific only when the build carries `[llvm_code]` kernels,
whose tuner-generated IR a generic target refuses to legalize.

A library for a cross triple (`--jit-target`) is the one exception: `write_cross_lib` writes a
single object for that triple, `<out>.o`, never an archive, and for every triple but wasm links
nothing (a wasm library goes on to an ES module, `#lib-wasm-module`). The consumer's link - emcc
for wasm, the target's clang (the Android NDK's, say) otherwise - brings the runtime archive built
for that target anyway, and a host archiver need not index a foreign object, so an archive would
add a tool dependency and no content. The object's target machine carries the features the intrinsic tables
were gated on: the wasm runtime archive's set, or the arch's forced features. Only 64-bit triples
are accepted (wasm64, aarch64, x86_64): the host bakes its 8-byte pointer layouts into the object,
and a 32-bit runtime would read them as 4. `--jit-static` and `--jit-lib-bindings` have no meaning
there and are ignored with a warning. The header's link note (`lib_link_note`) names the link: for
every cross triple, a runtime built for the same target with the same C++ standard library, whose
layouts the host baked in; for wasm also the emcc flags the wasm64 runtime archive is built with -
wasm exceptions, simd128, memory64, `-pthread` under `--jit-threads` - because an object linked
with different ones fails at link or traps at run time.

`--jit-opt-level` (CLI, over `policies.jit_opt_level`, default 3) drives both the optimize
pipeline and the DLL path's codegen-side target machine. A shipped artifact and AOT-object
emission (`emit_object_only`) deliberately stay at codegen level 3: shipped artifacts are not
content-addressed, so a tier change there has no cache guard to catch it. At level 0 the
injected tune-policy default becomes `fallback` (`jit_cli_opt_level()` in `llvm_tune.das`):
tune winners are raced under O3 codegen, so an O0 run cannot represent them and must not block
on the tuner to mint them.

## A library entry runs its jitted function inside one frame of the context stack {#lib-entry-frame}

`jit_lib_invoke_guarded` (`src/builtin/jit_runtime.cpp`) pushes the frame around the call, sized
to the largest frame in the library (`lib_entry_frame_size`): jitted calls push none of their own,
and a block made in jitted code puts its argument slot in the frame on top of the stack. The frame
begins with a `Prologue` that names no function and carries the frame's size, as a compiled
frame's does. Every walk of the stack - a heap collection, a stack trace - reads a `Prologue` at
each frame to step to the next one, and a frame whose size reads zero is one the walk never
leaves.

## A wasm library goes on from its object to an ES module {#lib-wasm-module}

For a wasm triple `write_cross_lib` (`llvm_jit_common.das`) does not stop at the object:
`link_wasm_lib` runs emcc over it and the wasm64 runtime archive and leaves `<out>.mjs` and
`<out>.wasm`: an ES module factory (`-sMODULARIZE -sEXPORT_ES6`) with no `main`
(`--no-entry`). A wasm linker drops every function nothing reaches, and nothing in a library
reaches its own entry points, so the link names each of them in `-sEXPORTED_FUNCTIONS` - the four
fixed ones and the program's exports, from `lib_entry_point_names` (`llvm_exe.das`) - beside
`malloc` and `free`, which a JavaScript caller needs to hand a string or a structure across. The
module keeps its 8-byte pointers over a memory lowered to 32 bits, so a pointer crosses an entry
point as a BigInt. `-sDEFAULT_TO_CXX=1` keeps the C++ standard library in the link when the driver
is `emcc`, which newer Emscripten releases link as C. The link runs through the shell, as
`link_wasm` runs its own, so `emcc` resolves to `emcc.bat` or `emcc.exe` alike on Windows.

`wasm_lib_abi_flags` is the one spelling of the flags the object and the runtime archive must
share; the link passes them and the header's link note (`lib_link_note`) prints them, for a host
that links the object into a program of its own. Three knobs steer the link: `--jit-emit-object`
stops at the object and the header, `--jit-runtime-lib` names the archive, and
`--jit-linker-string` is appended last, where an emcc `-s` setting overrides the one the link
passes. A build that asked for the module and has no runtime archive, or whose emcc fails, exits
non-zero.
