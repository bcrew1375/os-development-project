# Zig Code Structure: File Length, Function Size, Interfaces & Decomposition

A focused follow-up on *micro*-level code structure in Zig — as opposed to the previous document's macro-level (subsystem/directory) organization. Draws primarily on the official Zig style guide, TigerBeetle's `TIGER_STYLE.md` (one of the most detailed public style guides for systems-level Zig, written by the team building a financial-transactions database in Zig), and community writing on Zig's interface patterns.

---

## 1. File length & file organization

**Zig has a language-level convention that shapes file size: every source file is implicitly a struct.**

Every Zig source file is implicitly a struct, with the keyword `struct` and curly braces omitted — meaning you can literally `@import("tea.zig")` and use the result as a struct type. The community convention that follows from this: **one file generally corresponds to one primary type or one cohesive namespace of related functionality**, not an arbitrary bucket of loosely related functions. The official style guide even splits file-naming into two cases — `TitleCase` when the file has top-level fields (i.e. it's "a struct with data"), and `snake_case`/lowercase when it's a namespace of functions with no fields.

**Justification**: because `@import` returns the file-as-struct directly, a file that tries to hold multiple unrelated types forces awkward nested access patterns and makes the file's "identity" ambiguous to a reader opening it cold. Keeping one primary type per file makes the import graph double as a fairly accurate dependency/ownership graph — you can often guess what a file contains just from its name, the same way you'd guess what a class does in a single-class-per-file OOP codebase.

**On line length specifically**: TigerBeetle hard-limits all lines to at most 100 columns, without exception, for a good typographic "measure" — the reasoning given is physical: **100 columns is just enough to fit two files side-by-side on a screen**, so nothing is ever hidden by a horizontal scrollbar. `zig fmt` combined with a trailing comma on a wrapped list, struct, or call will auto-format to respect this.

There's no equivalent hard *file*-length rule in these sources — the discipline comes indirectly, from keeping functions short (below) and keeping one type per file, which naturally caps how large a file gets before it's screaming for a split.

---

## 2. Function size — including "can a function be too small?"

This is where TigerStyle is most concrete and most opinionated, and it directly engages with your question of whether there's a lower bound as well as an upper one.

### The upper bound: a hard 70-line limit, and why

There's a sharp discontinuity between a function fitting on a screen and having to scroll to see how long it is — for this physical reason, TigerBeetle enforces **a hard limit of 70 lines per function**. The justification is deliberately non-abstract: it's about what a reader can hold in view (and therefore in working memory) at once, not an aesthetic preference.

Rules of thumb offered for *how* to split a large function once you hit that limit:

- **Good function shape is often the inverse of an hourglass**: a few parameters, a simple return type, and a lot of meaty logic in between.
- **Centralize control flow.** When splitting a large function, keep all `switch`/`if` statements in the "parent" function, and move non-branchy logic fragments out to helper functions — all control flow should be handled by *one* function, and the rest shouldn't care about control flow at all. This is summarized elsewhere as ["push `if`s up and `for`s down."](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html)
- **Centralize state manipulation similarly**: let the parent function hold all relevant state in local variables, and use helper functions to *compute* what needs to change rather than applying the change directly — keep leaf functions pure.

### Is there such a thing as "too small"?

The sources don't set a hard lower-bound line count, but they do articulate real costs to over-fragmenting, which functions as a practical floor:

- **Splitting for its own sake fights the "centralize control flow" rule above.** If you extract a fragment that contains its *own* branching decision, you've now spread control flow across two functions instead of one, which is explicitly what TigerStyle says to avoid — the goal of decomposition is to *concentrate* decision-making in one place, not scatter it.
- **Dimensionality is viral.** Use simpler function signatures and return types to reduce the number of branches that need to be handled at the call site — `void` beats `bool`, `bool` beats `u64`, `u64` beats `?u64`, and `?u64` beats `!u64`. A function extracted purely to shrink line count, but which now needs to communicate a new error or optional state back to its caller, pushes complexity *outward* to every call site instead of removing it — often a net loss even though the original function got shorter.
- **Over-abstraction has a real, non-zero cost in Zig's own design philosophy.** Abstractions are never zero-cost, and every abstraction introduces the risk of a leaky abstraction — so the guidance is to use only a minimum of excellent abstractions, and only where they make the best sense of the domain. A function extracted with no real conceptual identity of its own (it's not "a thing," it's just "the second half of a bigger thing") is exactly this kind of low-value abstraction: it adds an indirection and a name to remember without adding a boundary that means anything.
- **Practically**, in compiled, systems-level Zig this also has a mechanical dimension: very small functions that are called across a module boundary or through a function pointer/vtable can't be inlined by the optimizer, so fragmenting hot code into many tiny cross-boundary calls can cost real cycles (see the "Be explicit" performance guidance below). Zig's `inline fn` exists specifically to let you force inlining when you do want a small helper to disappear at the call site, precisely because the compiler doesn't always do this automatically for every call, especially through pointers.

**Net synthesis**: the floor for function size isn't a line count — it's *conceptual*. Split when the resulting piece has its own name-worthy responsibility and doesn't require re-exporting new branching or error states to its caller. Don't split merely to satisfy a line-count aesthetic; that just relocates complexity instead of removing it.

---

## 3. Should interfaces be used as much as possible? (No — and Zig is built to make you feel that cost)

This is probably the single biggest divergence from mainstream OOP-language advice, and it's a deliberate language design choice, not just a style preference.

**Zig has no `interface` keyword at all.** Where other languages hand you an abstraction for free, Zig requires you to build it yourself out of three distinct mechanisms, each with different costs:

| Mechanism | What it's for | Cost |
|---|---|---|
| **Comptime duck typing / generics (`anytype`)** | Static polymorphism — the concrete type is known at compile time | Zero runtime cost, fully inlinable |
| **Tagged unions** | A *closed*, known set of implementing types | Compile-time exhaustiveness checking, no indirection, but the type set can't grow without touching the union |
| **Vtables (fat pointers: `*anyopaque` + function-pointer struct)** | True runtime polymorphism across an *open*, heterogeneous set of types | Indirect call (no inlining), 2-pointer-per-value memory overhead, more boilerplate |

The standard library itself is built almost entirely on vtable interfaces for the few places it truly needs runtime dispatch — `std.mem.Allocator`, `std.Io.Reader`, and `std.Io.Writer` are the canonical examples, each storing a *pointer* to a static, read-only vtable (not the vtable inline) specifically so that every interface value stays exactly two machine words regardless of how many methods the vtable grows to.

### The explicit "when should I reach for one" test

For callers known at compile time, comptime duck typing is preferred for zero runtime cost and full inlining — vtables are reserved for genuine runtime dispatch. A concrete decision framework distilled from community guidance:

Ask yourself, before reaching for a vtable interface:
1. Do multiple types genuinely share the same behavior?
2. Do I need to decide *between* them at runtime (not just at compile time)?
3. Do I want to hide implementation details from the caller?

If the answer is yes to all three, an interface may be appropriate. If not, keep it concrete. Avoid interfaces when there's only one implementation, when the call sits in a hot inner loop, or when compile-time dispatch would do the job — in those cases, prefer generics, tagged unions, direct function pointers, or just a concrete type.

**Justification, in the language's own terms**: Zig makes the cost of dispatch fully visible at the call site — `allocator.vtable.alloc(allocator.ptr, ...)` — rather than hiding it behind an implicit interface keyword the way Go or Java do. This is a deliberate design stance: the language doesn't want you to reach for polymorphism casually, because every abstraction is a real, paid cost (extra indirection, lost inlining opportunities, more boilerplate, and lifetime/ownership bookkeeping that Zig would otherwise let the compiler ignore). It's not "avoid abstraction," it's "be honest about what abstraction costs, and only pay it where you get real value back" — which tracks directly with TigerStyle's broader principle that abstractions are never zero cost and should be used only where they make the best sense of the domain, with only a minimum of excellent ones.

---

## 4. How much should a single concern be broken down?

This question spans several TigerStyle principles that all push toward the same answer: **decompose along data/scope boundaries, not along arbitrary size boundaries — and keep decomposed pieces small enough to reason about in isolation.**

- **Shrink the scope.** Declare variables at the smallest possible scope and minimize the number of variables in scope at once, to reduce the probability that a variable is misused — a direct, mechanical rule for how "big" a unit of code should be allowed to get before it's broken up: as soon as a variable's necessary lifetime ends, its scope should too.
- **Calculate or check values close to where they're used.** Don't introduce variables before they're needed, and don't leave them lingering after. This reduces the "semantic gap" between where a value is validated and where it's used — a wider gap (in either time or code distance) is harder to verify correct and is explicitly called out as a bug-prone pattern (a distant cousin of TOCTOU).
- **Assertion density as a proxy for "is this concern well-scoped."** The assertion density of the code must average a minimum of two assertions per function, checking pre/postconditions and invariants — a function that can't be meaningfully assigned two assertions about its own inputs/outputs is often a signal that it's either doing too little to be worth being its own function, or doing too much to state a clean contract about.
- **Split compound conditions and compound assertions.** Prefer `assert(a); assert(b);` over `assert(a and b)`, and split complex `else if` chains into nested `if { }` trees — the stated reason is that this makes it possible to verify all cases are handled, and gives more precise failure information than a single blob. This is the same "decompose along independently-verifiable boundaries" logic applied at the statement level, not just the function level.
- **All memory statically allocated at startup** (no dynamic allocation/free after init) is presented as more than a safety rule — as a second-order effect, this constraint tends to produce more efficient, simpler designs because it forces you to consider all possible memory usage patterns upfront, as part of decomposing the design, rather than deferring that decomposition to runtime.

**Overall justification tying this together**: TigerStyle explicitly ranks its priorities as *safety, then performance, then developer experience, in that order* — and states plainly that style is not pursued for its own sake but only because it advances those three goals. Applied to "how much should I break a concern down": break it down exactly as far as it takes to (a) make every piece independently assertable/verifiable, and (b) keep each piece's scope and lifetime as short as its actual use requires — and no further, because each additional abstraction boundary is a place where a leaky abstraction or an indirect call can hide a bug or cost a cycle.

---

## Sources

- [TigerStyle — `TIGER_STYLE.md`, tigerbeetle/tigerbeetle (main branch)](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [TigerStyle Guidelines — DeepWiki summary of tigerbeetle/tigerbeetle](https://deepwiki.com/tigerbeetle/tigerbeetle/5.5-tigerstyle-guidelines)
- [The Tiger Style — Backend.how](https://backend.how/posts/the-tiger-style/)
- [Documentation — The Zig Programming Language (official docs, "every file is implicitly a struct")](https://ziglang.org/documentation/master/)
- [File naming conventions — Ziggit (Zig community forum)](https://ziggit.dev/t/file-naming-conventions/10751)
- [Zig Quirks — openmymind.net (files-as-structs explanation)](https://www.openmymind.net/Zig-Quirks/)
- [Learning Zig - Style Guide — openmymind.net](https://www.openmymind.net/learning_zig/style_guide/)
- [Interfaces and Vtables — LearningZig.org](https://learningzig.org/lessons/22-interfaces-and-vtables)
- [Interfaces in Zig — BradCypert.com](https://www.bradcypert.com/interfaces-in-zig/)
- [Zig Interface Revisited — Software Fragments (William Wong)](https://williamw520.github.io/2025/07/13/zig-interface-revisited.html)
- [Interfaces in Zig: Five Patterns You Should Know — Medium (Alabi Temitope David)](https://medium.com/@trinitietp/interfaces-in-zig-five-patterns-you-should-know-5600acf3cfad)
- [Interfaces in Zig — Gist (fidelicura)](https://gist.github.com/fidelicura/9b1f55d312ae6fc3974cf45848285b2a)
- [Interfaces in ziglang — GitHub (yglcode/zig_interfaces)](https://github.com/yglcode/zig_interfaces)
- [comptime interfaces · Issue #1268 — ziglang/zig](https://github.com/ziglang/zig/issues/1268)
- [Push ifs up and fors down — matklad.github.io](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html)
- [Understand best Practices in Zig Development — StudyRaid](https://app.studyraid.com/en/read/2423/48952/best-practices-in-zig-development)
