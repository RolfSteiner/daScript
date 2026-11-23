options gen2

require _jit_lib_collect_c

[export]
def main() : int {
    var ctx = jit_lib_collect_create()
    if (ctx == null) {
        print("create failed: {jit_lib_collect_last_error(null)}\n")
        return 1
    }
    var bad = 0
    for (round in range(1, 3)) {
        let kept = jit_lib_collect_keep_names(ctx, 10)
        let measure = jit_lib_collect_names_length(ctx)
        if (kept != round * 10 || measure != round * 60) {
            print("round {round}: {kept} names measuring {measure} after the collection\n")
            bad++
        }
    }
    jit_lib_collect_destroy(ctx)
    return bad
}
