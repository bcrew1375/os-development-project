# Kernel / OS Dev Code Organization: Best Practices & Justifications

A synthesis of best practices for organizing operating system / kernel source code, drawn from Linux kernel documentation, the OSDev wiki, and microkernel design literature (seL4).

---

## 1. Separate architecture-independent code from architecture/machine-specific code

The most consistent piece of advice across kernel projects is to draw a hard line between generic logic and hardware-targeted code early. Separating sources so targeted functions live in a different location than generic ones creates an abstraction layer between hardware drivers and pure software, so porting to a new platform only requires rewriting the targeted functions while generic code runs on top unchanged.

This is usually split two ways:

- **Architecture-specific**: differs between processor architectures — e.g. I/O, trap dispatching, and paging.
- **Machine-specific**: differs between machines sharing the same architecture — e.g. IRQ controllers, system timers, real-time clocks, multiprocessor information. Often consolidated into a **Hardware Abstraction Layer (HAL)**, a pattern the NT kernel formalized as a dedicated module.

**Justification**: Linux embodies this via its `arch/` directory, which isolates per-CPU code from the rest of the tree. Where something spans both (e.g. memory management), each architecture provides a set of functions with the same name across all archs that arch-independent code can call — e.g. scheduling algorithms are hardware-independent, but timer configuration is not. The payoff: portability without a rewrite, and bugs in generic logic get fixed once instead of once per platform.

## 2. Interface/implementation separation is structural, not optional

The interface must be completely independent of the implementation, so a second HAL implementation for a different platform can be written later without changing the interface. The kernel's interface should avoid depending on fixed-width types directly — if a fixed width is genuinely required, it should go through a platform-specific typedef rather than leaking into shared code.

**Justification**: This is what makes the abstraction load-bearing rather than cosmetic. If "generic" code secretly depends on a specific platform's struct layout or word size, you don't have real portability — porting will break the moment it's attempted.

## 3. Organize by subsystem, not by file type

Linux's tree structure maps top-level directories to subsystems (`mm/`, `net/`, `fs/`, `drivers/`, `kernel/`, `arch/`) rather than to code "kind." Each directory has a clear purpose, and `Documentation/` holds design guidelines, subsystem overviews, and best practices alongside the code they describe.

**Justification**: Subsystem-based organization matches how contributors actually reason about kernel code — a networking bug and a filesystem bug are cognitively unrelated even though both are "C files." Grouping by domain minimizes the context a contributor needs to hold in their head, and it's a prerequisite for clean ownership boundaries (see #4).

## 4. Ownership boundaries should mirror code boundaries (distributed maintainership)

Linux pairs its directory structure with a `MAINTAINERS` file mapping subsystems to responsible people. It's impossible for a single person to keep up with something as complex as an OS kernel — the distributed model assigns portions (networking, wireless, device drivers, etc.) to individuals based on domain familiarity, enabling review and integration across thousands of areas without compromising stability.

**Justification**: This is a direct consequence of #3 — clean subsystem boundaries are what make distributed ownership possible. Without them, every change requires global context and no one can meaningfully "own" a slice of the code.

## 5. A strict, low-personal-preference coding style, applied uniformly

Linux enforces an opinionated style (8-character tabs, short functions, kernel-doc comments) for scale, not taste. Because the number of developers who read the code is very large, a consistent style guideline makes it easier to understand for a first-time reader and for the original author revisiting old code months later — and lets others read, fix, and enhance the code, which is one of open source's core strengths. This is grounded in research showing that knowledge of programming conventions significantly affects program comprehension.

Style is a tool, not dogma: the coding style document isn't absolute law — if a rule makes code meaningfully less readable in a specific case, you break it. But at kernel scale, uniform style is required for developers to quickly understand any part of the codebase; there's no longer room for idiosyncratically formatted code, and non-conforming contributions typically get bounced before review even starts.

**Justification**: Kernel code has an unusually long lifetime and many more readers than authors, so optimizing for read-time comprehension over write-time convenience is the rational trade.

## 6. Concurrency/locking discipline must be designed in, not bolted on

Any resource — data structures, hardware registers — that could be accessed concurrently by more than one thread must be protected by a lock, and new code should be written with this in mind, since retrofitting locking after the fact is much harder than designing for it upfront.

**Justification**: This argues for organizing modules around clear ownership of shared state (who locks what, in what order) as a first-class part of code layout, not just a function-level concern — ambiguous ownership of shared state is disproportionately expensive to fix later.

## 7. Minimality as an architectural stance (microkernel philosophy)

At the far end of the spectrum from Linux's monolithic-but-modular approach is the microkernel principle, exemplified by seL4. Minimality and policy freedom combined with high performance have been the defining design principle of the L4 microkernel family since the mid-1990s. seL4 pushes this further than most: it doesn't manage physical memory itself — it has no heap, and user-level managers must supply the kernel with memory for its own metadata, meaning userland memory-partitioning policy extends into the kernel and makes isolation easier to reason about. Functionally, the microkernel provides only minimal core functionality — threads, IPC, virtual memory, capability-based access control, and interrupt control — leaving device drivers and filesystems to run in user space.

**Justification**: A smaller trusted core is dramatically easier to verify, audit, and reason about. With truly small kernels it becomes possible to guarantee the absence of bugs via formal, machine-checked verification — structurally impossible at monolithic-kernel scale. This is a direct tradeoff against Linux's approach: monolithic organization optimizes for driver/subsystem development velocity and in-kernel performance (no IPC overhead), while microkernel organization optimizes for isolation and provable correctness at the cost of more IPC and userspace complexity. The right choice depends on whether the priority is throughput/ecosystem breadth (Linux) or assurance/attack-surface minimization (seL4, and similarly Zircon/Fuchsia, QNX).

## 8. Configuration and build structure should mirror feature boundaries

Linux couples its directory layout to its build/config system directly: Makefiles define build rules while Kconfig files define configuration options selectable via tools like `make menuconfig`, so a subsystem's buildability and optionality live next to its code rather than in a separate global config.

**Justification**: This keeps "can this feature be compiled in/out" decisions local to the feature's owner, rather than requiring central coordination every time a subsystem wants to add a config knob — another instance of structure enabling distributed ownership.

---

## The underlying thread

Almost every practice above reduces to one idea: **make the code's physical/directory structure reflect its logical ownership and coupling boundaries.** Generic vs. hardware-specific, subsystem vs. subsystem, interface vs. implementation, even kernel-core vs. everything-else in the microkernel case — in each one, the organizational boundary exists so that changes on one side don't require anyone to understand or touch the other side. The specific choices (monolithic vs. micro, strict style vs. flexible) differ by project priorities, but the goal of minimizing the context a contributor or reviewer needs to hold in their head at once is constant.

### Practical starting checklist for a new kernel project

1. Separate `arch/`-style hardware code from generic logic on day one — retrofitting this later is painful.
2. Define stable interfaces before writing multiple implementations against them.
3. Organize directories by subsystem, not file type.
4. Decide early where you sit on the monolithic-vs-microkernel spectrum, since it determines almost everything else about how modules relate to each other.
5. Design locking/ownership of shared state into the module boundaries from the start.
6. Tie build/config options (Kconfig-style) to the subsystem they belong to.

---

## Sources

- [Linux Kernel Development Best Practices — Packt_Pub (Medium)](https://medium.com/@Packt_Pub/linux-kernel-development-best-practices-11c1474704d6)
- [Linux Kernel Source Tree Explained — DEV Community](https://dev.to/darshan_rathod/anatomy-of-the-linux-kernel-source-tree-3hnb)
- [Kernel Source Code and Organization — bootlin/training-materials (DeepWiki)](https://deepwiki.com/bootlin/training-materials/3.1-kernel-source-code-and-organization)
- [How do you organize your kernel's code? — OSDev.org forum](https://forum.osdev.org/viewtopic.php?f=1&t=30351)
- [Documentation/CodingStyle and Beyond — Greg Kroah-Hartman (kernel.org)](https://www.kernel.org/doc/ols/2002/ols2002-pages-250-259.pdf)
- [Proper Linux Kernel Coding Style — Linux Journal](https://www.linuxjournal.com/article/5780)
- [4. Getting the code right — The Linux Kernel documentation](https://dri.freedesktop.org/docs/drm/development-process/4.Coding.html)
- [Linux kernel coding style — kernel.org docs](https://www.kernel.org/doc/html/v4.10/process/coding-style.html)
- [Linux kernel coding style — docs.kernel.org](https://docs.kernel.org/process/coding-style.html)
- [Re: [PATCH] 0/3 coding standards documentation/code updates — Linus Torvalds (LKML)](https://lkml.iu.edu/hypermail/linux/kernel/0709.3/2404.html)
- [Portability — OSDev Wiki](https://wiki.osdev.org/Portability)
- [Code Management — OSDev Wiki](https://wiki.osdev.org/Code_Management)
- [Separating Architecture Specific Code — OSDev.org forum](https://forum.osdev.org/viewtopic.php?t=15836)
- [On Hardware Abstraction Layers — OSDev.org forum](https://forum.osdev.org/viewtopic.php?f=15&t=18628)
- [Hardware Abstraction Layer — OSDev.org forum](https://f.osdev.org/viewtopic.php?t=27450)
- [Hardware Abstraction Layer — OSDev Wiki](https://wiki.osdev.org/Hardware_Abstraction_Layer)
- [Abstraction layer — Wikipedia](https://en.wikipedia.org/wiki/Abstraction_layer)
- [seL4 in Australia — Communications of the ACM](https://cacm.acm.org/research/sel4-in-australia/)
- [seL4: Formal Verification of an OS Kernel (PDF)](https://plsyssec.github.io/cse227-spring25/papers/sel4.pdf)
- [seL4 Design Principles — microkerneldude](https://microkerneldude.org/2020/03/11/sel4-design-principles/)
- [It's Time: OS Mechanisms for Enforcing Asymmetric Temporal Integrity (arXiv)](https://arxiv.org/pdf/1606.00111)
- [seL4 Microkernel for virtualization use-cases (arXiv)](https://arxiv.org/pdf/2210.04328)
- [seL4 - Open Source RTOS](https://osrtos.com/rtos/sel4/)
- [From L3 to seL4: What Have We Learnt in 20 Years of L4 Microkernels? (PDF)](https://flint.cs.yale.edu/cs428/doc/L3toseL4.pdf)
- [HYDRA: HYbrid Design for Remote Attestation Using a Formally Verified Microkernel (arXiv)](https://arxiv.org/pdf/1703.02688)
- [PARseL: Towards a Verified Root-of-Trust over seL4 (arXiv)](https://arxiv.org/pdf/2308.11921)
