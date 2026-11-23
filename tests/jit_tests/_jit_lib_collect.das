options gen2
options gc
options persistent_heap

require daslib/export_c

var g_names : array<string>

[export_c]
def keep_names(n : int) : int {
    g_names |> reserve(length(g_names) + n)
    for (i in range(n)) {
        g_names |> push("name {i}")
    }
    unsafe(heap_collect(true, false))
    return length(g_names)
}

[export_c]
def names_length() : int {
    var total = 0
    for (name in g_names) {
        total += length(name)
    }
    return total
}
