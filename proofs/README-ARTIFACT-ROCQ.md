# Rocq Artifact — *Mind The Heap: Preventing Capability Leakage Across CHERI Compartments*

ACM CCS 2026 · mechanized formalization

This directory is a **self-contained Rocq artifact** for the formal-model section of the
paper. It has no dependencies beyond the Rocq standard library, no references to anything
outside this directory, builds and self-audits with a single `make`, and contains **no
admitted proofs and no axioms of any kind**: every headline result is closed under the global
context.

```
make
```

That is the whole thing: it compiles the three source files in dependency order, then runs the
full audit and prints `ARTIFACT VALIDATED`. A non-zero exit status means the artifact did not
validate. Expect it to take about five seconds.

The artifact is self-contained: it needs Rocq and the files in this directory, nothing else.
The two CASL framework files, `CASL_Model.v` and `CASL_ProofRules.v`, are the artifact's own
copies of the CASL model and proof rules, with comments of their own.

---

## Table of contents

1. [What this artifact is](#1-what-this-artifact-is)
2. [Requirements and installing Rocq](#2-requirements-and-installing-rocq)
3. [Building and checking](#3-building-and-checking)
4. [What `make check` verifies](#4-what-make-check-verifies)
5. [Mapping to the paper](#5-mapping-to-the-paper)
6. [File-by-file breakdown](#6-file-by-file-breakdown)
7. [Scope and known limitations](#7-scope-and-known-limitations)
8. [Directory contents](#8-directory-contents)

---

## 1. What this artifact is

The paper's CompartHeap logic is an instantiation of **CASL** (Concurrent Adversarial
Separation Logic) for reasoning about *capability leakage across CHERI compartments*. The
logic reasons **under-approximately**: a derivation exhibits a concrete execution, so an
*error* derivation is a genuine witness of a bug rather than a failure to prove safety.

The artifact mechanizes that instantiation end to end:

1. A **concrete PCM** (partial commutative monoid) of compartment-tagged capability heaps,
   with every PCM law proved rather than assumed, and with *decidable* composition.
2. The **CompartHeap proof rules** — the safe rule set, the deliberately-unsafe rule set, and
   the pointer invariant `INV` — as Rocq `Inductive` types, one constructor per rule of the
   paper's figures.
3. The **headline metatheorem**: all twenty safe rules preserve `INV`, unconditionally.
4. The **nginx/OpenSSL worked example**, in both its safe and its buggy form, as two fully
   chained machine-checked derivations.

### Claims this artifact supports

| # | Claim | Where it is discharged |
|---|-------|------------------------|
| C1 | The CompartHeap state model is a genuine separation-logic PCM (commutative, associative, unital, cancellative, with *decidable* composition). | `CHERI_compartheap.v`, `Module CASLche_PCM` (7 `Qed`), plus `disjoint_dec_full` and `CHEState_eq_dec` |
| C2 | Every rule of the safe rule set takes an `INV`-satisfying state to an `INV`-satisfying state — no excluded rule, no side hypothesis. | `che_axioms_preserve_INV` |
| C3 | The unsafe call/return rules alone **cannot** break `INV`; the unsafe *assignment* rule can. This is why the paper's unsafe rule set includes `UNSAFE-Assign`. | `che_unsafe_axioms_preserve_INV`, `unsafe_assign_violates_INV` |
| C4 | The safe nginx/OpenSSL program is derivable and its final state satisfies `INV`. | `nginx_openssl_safe_derivation`, `P9_satisfies_INV` |
| C5 | The same program under the unsafe rules is derivable to an **error** triple whose final state violates `INV` — a machine-checked witness of the capability leak. | `nginx_openssl_error_derivation`, `E9_violates_INV` |

Each claim is `Check`ed and audited by `Artifact_Check.v`; see §4.

**Proof budget:** 3 663 lines, **165 `Qed`**, **0 `Admitted`**, **0 `Axiom`**. No axiom is
used at all, not even a standard-library one: `Print Assumptions` reports every headline result
closed under the global context; see §4.

---

## 2. Requirements and installing Rocq

| Component | Version used | Notes |
|-----------|--------------|-------|
| Rocq Prover | **9.2** | Also verified under 9.1.1. Coq 8.20 and earlier will **not** work: the sources use `From Stdlib Require Import`, which Rocq 9 introduced. |
| GNU Make | any | For the one-line build |
| Disk | < 5 MB | |
| RAM | < 1 GB | |
| Build + check time | **≈ 5 seconds** | Single-threaded, commodity x86-64 Linux host |

No external Rocq libraries are required. Everything comes from `Stdlib`: `List`, `Arith`,
`Bool`, `PeanoNat`, `Lia`, `ListDec`, `Eqdep_dec`, `Setoid`, `Morphisms`. None of them
introduces an axiom.

### Do you already have it?

```bash
rocq --version        # want: The Rocq Prover, version 9.2  (9.1.x also fine)
```

If `rocq` exists but is not on `PATH`, every target below accepts an override:

```bash
make ROCQ=/path/to/rocq
```

### Installing Rocq from scratch

**OS prerequisites.** Building the OCaml compiler from source needs a few packages that bare
container images lack:

```bash
# RHEL / Fedora / CentOS
sudo yum install -y patch unzip gmp-devel gcc m4 diffutils bubblewrap
# Debian / Ubuntu
sudo apt-get install -y patch unzip libgmp-dev gcc m4 diffutils bubblewrap
```

**opam.** If you do not have opam 2.x:

```bash
curl -fsSL "https://github.com/ocaml/opam/releases/download/2.2.1/opam-2.2.1-x86_64-linux" \
  -o /usr/local/bin/opam
chmod +x /usr/local/bin/opam
opam --version        # 2.2.1
```

**Rocq.** Roughly 15–30 minutes, mostly spent compiling OCaml:

```bash
opam init --bare --no-setup            # skip if opam is already initialised
opam switch create rocq --packages=ocaml-base-compiler.5.2.1
eval $(opam env --switch=rocq)
opam install rocq-prover
rocq --version                         # The Rocq Prover, version 9.2
```

Remember to `eval $(opam env --switch=rocq)` in each new shell, or pass `make ROCQ=...`.

---

## 3. Building and checking

### The one-liner

```bash
make
```

Output on success:

```
  ROCQ  CASL_Model.v
  ROCQ  CASL_ProofRules.v
  ROCQ  CHERI_compartheap.v

==> [1/3] No admitted proofs, no axioms
    OK: 0 Admitted, 0 Axiom
    ...
==> [2/3] Completed proof count
    OK: 165 Qed across 3 files

==> [3/3] Axiom base of the headline results
    OK: all 7 headline results are closed under the global context
    ...

  ================================================================
   ARTIFACT VALIDATED
   3 source files compiled, 165 proofs completed,
   0 admitted, 0 axioms.
  ================================================================
```

Rocq itself prints nothing during compilation and emits **no warnings**. Any output from
`rocq` is a problem.

### All targets

| Target | Effect |
|--------|--------|
| `make` | Build, then run the full audit. The default. |
| `make build` | Compile the three source files only |
| `make check` | Run the audit (builds first if needed) |
| `make clean` | Remove every build product |
| `make dist` | `clean`, then write a source-only `../proof_compartheap.tgz` |
| `make help` | Print the target list |

`make -j` is safe: the Makefile declares `.NOTPARALLEL:` so checking cannot start before the
build finishes.

### Build order

The three files **must** be compiled in this order, and the Makefile encodes it explicitly:

```
CASL_Model.v  →  CASL_ProofRules.v  →  CHERI_compartheap.v
```

All files live in the logical directory `CASL`, hence `-Q . CASL` throughout.

### Compiling by hand, without make

```bash
rocq compile -Q . CASL CASL_Model.v      && \
rocq compile -Q . CASL CASL_ProofRules.v && \
rocq compile -Q . CASL CHERI_compartheap.v
```

### Interactive use

`_CoqProject` already carries `-Q . CASL` and the file list, so rocqide, VS Code (VsRocq) and
Proof General pick up the load path with no further configuration:

```bash
rocqide CHERI_compartheap.v
```

### A note on toolchain changes

A `.vo` file produced by one Rocq version cannot be loaded by another. The Makefile therefore
stamps the Rocq version in `.rocq-version` and makes every `.vo` depend on it, so switching
toolchains — or unpacking a tarball that happens to contain stale `.vo` files — forces a
clean recompile rather than a confusing mid-build failure.

---

## 4. What `make check` verifies

The audit has three stages, all of which must pass.

**[1/3] No gaps in the proofs.** Fails if `Admitted` or a standalone `Axiom` appears anywhere
in the three source files. Equivalent by hand:

```bash
grep -n 'Admitted'  CASL_Model.v CASL_ProofRules.v CHERI_compartheap.v
grep -n '^ *Axiom ' CASL_Model.v CASL_ProofRules.v CHERI_compartheap.v
```

Both produce no output. `Parameter` **does** occur — 8 in `CASL_Model.v`, 1 in
`CASL_ProofRules.v`, 4 in `CHERI_compartheap.v` — but exclusively inside `Module Type`
signatures. Those are functor arguments, every one of which is instantiated concretely inside
this artifact; see §7.1.

**[2/3] Proof count.** Fails unless the three files contain exactly **165** completed proofs:

```bash
cat CASL_Model.v CASL_ProofRules.v CHERI_compartheap.v | grep -c 'Qed\.'
```

**[3/3] Axiom base.** `Artifact_Check.v` runs `Check` and `Print Assumptions` on every
headline result. `make check` parses the output and fails unless **every one** of them reports
`Closed under the global context`, i.e. depends on no axiom whatsoever:

- `che_axioms_preserve_INV`, `che_unsafe_axioms_preserve_INV`, `unsafe_assign_violates_INV`
- `nginx_openssl_safe_derivation`, `P9_satisfies_INV`
- `nginx_openssl_error_derivation`, `E9_violates_INV`

Two design choices keep the development axiom-free, mirroring the main CASL development:

- `CHEState` carries its sortedness certificate as a **boolean equation**
  `cap_sortedb che_capmap = true`. Any two such certificates are equal by `UIP_dec` on `bool`
  (`Eqdep_dec`), so `chestate_eq` needs no proof irrelevance.
- Assertions are compared up to **pointwise equivalence** (`sset_equiv`, `wset_equiv`) rather
  than by rewriting with equations between predicates. `derives` is proved invariant under
  that equivalence (`derives_Proper`, via the rule of consequence), so the derivations still
  use ordinary `rewrite`, but through setoid rewriting. Functional and propositional
  extensionality are never needed.

**Nothing about CHERI, compartments, capabilities or sealing is assumed.**

Compiling `Artifact_Check.v` is itself meaningful: `Require Import CHERI_compartheap`
type-checks every definition and every proof term in the development. The full `Check` /
`Print Assumptions` transcript is left in `Artifact_Check.log` for inspection:

```bash
make check && less Artifact_Check.log
```

To run just that file by hand:

```bash
rocq compile -Q . CASL Artifact_Check.v
```

---

## 5. Mapping to the paper

Figure numbers are those of the submitted version; LaTeX labels are given alongside because
appendix figure numbers can shift between revisions.

| Paper element | Figure | Rocq |
|---------------|--------|------|
| Atom grammar `RGAtoms_che` | Fig. 8 (top) | `CASLche_ATOM.CHEAtom` — 12 constructors |
| Minimal CHERI rule set | Fig. 8 (top) | the 8-rule subset of `che_axioms`: `CHE_Alloc`, `CHE_Assert`, `CHE_Assign`, `CHE_CompartEnter`, `CHE_CallUnseal`, `CHE_RetSeal`, `CHE_CallMixed`, `CHE_RetMixed` |
| Pointer invariant `INV` | Fig. 8 caption | `INV_state` / `INV_set` / `INV_holds` |
| Safe nginx+OpenSSL proof | Fig. 8 (bottom) | `P1`, `P1a`, `P2`…`P9`; `step1_derives`, `step1a_derives`, `step2_derives`…`step9_derives`; `nginx_openssl_safe_derivation` |
| The argument `ctx` of `SSL_new` and its parameter `ct` | Fig. 3, Fig. 8 (bottom) | two capabilities, `cap_ctx` and `cap_ct`, related by CHERI-Assign `ct := ctx` (see the note below) |
| Extended (safe) rule set | appendix, `fig:full_rules` | `Inductive che_axioms` — **20 constructors**, one per rule, each annotated with the rule as printed |
| Unsafe rule set | appendix, `fig:bad_rules` | `Inductive che_unsafe_axioms` (4 call/return rules) + `Inductive che_unsafe_assign_axioms` (`UNSAFE-Assign`) |
| Error proof | appendix, `fig:errorex` | `E1`, `E1a`, `E2`…`E9`; `estep1_derives`, `estep1a_derives`, `estep2_derives`…`estep9_derives`; `nginx_openssl_error_derivation` |
| `holder(p)` metafunction | Fig. 8 caption | `CHERI_FUNC_SPACE.holder`; instantiated by `NginxFS.holder` |
| `F_int` / `F_ext` / `F(τ)` | Fig. 8 caption | `F_int`, `F_ext` parameters; `F_all τ f := F_int τ f \/ F_ext τ f` is **defined**, not assumed |
| CASL frame rule (inherited) | Fig. 8 caption | `RFrame` (with `RAtomLocal`) in `CASL_ProofRules.v` — not restated in `che_axioms` |

### A note on `ctx` / `ct`

Throughout the logic, a *cell* is a **capability**, not a memory cell: the assertion
`p ↦ (A,σ,τ)` describes the capability `p`, where `τ` owns the object `p` designates and
`holder(p)` owns the storage `p` itself sits in.

The paper's worked proof uses two names around the call `conn = SSL_new(ctx)`: `ctx`, the
argument (P1, P4, P7), and `ct`, `SSL_new`'s parameter (P2, P3), matching Figure 3. The
formalization models them as **two capabilities**:

- `cap_ctx`, the argument slot, with `holder cap_ctx = tau_ssl` (`NginxFS.holder`; it is an
  argument slot of an OpenSSL entry point). `CHERI-Call-Unseal` unseals it on entry; that
  rule's `holder(x) = τ₂` premise is why the argument slot must be OpenSSL storage.
- `cap_ct`, `SSL_new`'s parameter, also OpenSSL storage. On entry `SSL_new` binds it,
  `ct := ctx`, and `CHERI-Assign` leaves the copy unsealed, because `holder(ct) = τ_ssl` is
  the owner of the context.

The paper's step 1, annotated *CallUnseal + Frame + Assign*, is therefore two Rocq steps:

```
P1:   ctx ↦ (A,S,τ_ssl) * ct = -              --CHERI-Call-Unseal (step1_derives)-->
P1a:  ctx ↦ (A,U,τ_ssl) * ct = -              --CHERI-Assign ct := ctx (step1a_derives)-->
P2:   ctx ↦ (A,U,τ_ssl) * ct ↦ (A,U,τ_ssl)
```

and `P2` is the paper's P2, `ct ↦ (A,U,τ_ssl) ∧ τ_cur = τ_ssl`, with the other cells framed.
The error derivation runs the same program, so it binds `ct` too (`estep1a_derives`, with
`UNSAFE-Assign`, which yields the same cell here).

Nothing re-seals `ctx` after step 1, so the Rocq states matching the paper's P4 and P7
contain `ctx ↦ (A,U,τ_ssl)` where the paper writes `ctx ↦ (A,S,τ_ssl)`. `INV` holds either
way, since `holder(ctx) = τ_ssl`.

### Two defects the mechanization found

The `INV`-preservation induction is not decorative. Attempting it surfaced two real problems
in earlier drafts of the figures, both now fixed in the paper:

1. **`CHERI-Ret-Unseal` was missing its `holder(x) = τ₂` premise**, which its siblings
   `CHERI-Call-Unseal` and `CHERI-IndCall-Unseal` both carry. Without it, the rule produced an
   unsealed cell with nothing pinning its holder to its owner, and it was the single rule that
   broke `INV`. The counterexample is recorded in a comment at `CHERI_compartheap.v:2220`.
   With the premise restored, `che_axioms_preserve_INV` holds unconditionally.
2. **The printed unsafe rule set was vacuous.** All four unsafe call/return rules only move
   `τ_cur`, and `INV` never mentions `τ_cur` — so they all *preserve* `INV`
   (`che_unsafe_axioms_preserve_INV`), and the error derivation could not go through. The
   missing ingredient was a capability copy that propagates the seal state verbatim instead of
   recomputing it from `holder(x)`; `UNSAFE-Assign` supplies it, and
   `unsafe_assign_violates_INV` shows it genuinely breaks the invariant.

Neither omission was visible from reading the figures.

---

## 6. File-by-file breakdown

| File | Lines | `Qed` | Role |
|------|-------|-------|------|
| `CASL_Model.v` | 334 | 15 | The CASL model: PCM signature, worlds, rely/guarantee action maps, traces, well-formedness, stability |
| `CASL_ProofRules.v` | 208 | 0 | The CASL proof rules as `Inductive derives` (19 constructors), including the frame rule the paper restates as CASL-Frame |
| `CHERI_compartheap.v` | 3 121 | 150 | The CompartHeap instantiation: PCM, rules, `INV`, both worked derivations |
| **Total** | **3 663** | **165** | |

Files 1–2 are the CASL metatheory and are *logic-independent*: they know nothing about CHERI.
They are the artifact's own copies of the CASL model and proof rules of the separate CASL
development (not part of this artifact), where CASL's soundness is proved against exactly this
code; only the comments and module names differ. File 3 is the paper's contribution.

---

### `CASL_Model.v` — 334 lines, 15 `Qed`, 8 `Parameter`

The CASL model, parametric in the underlying state algebra.

- **Top level, PCM-independent:** `Tag` (`Ok` / `Err n`, the exit condition that makes the
  logic *under-approximate*), `UID`, and traces `STrace` / `STraceSet` with concatenation,
  prefixing, union, intersection and powers.
- **`Module Type PCM`** — the state-algebra signature (8 `Parameter`s): carrier `State`,
  partial `compose`, `is_unit`, and the laws `compose_comm` (an equation),
  `compose_assoc`, `unit_exists`, `unit_compose`, and `compose_cancel` (cancellativity, which
  the CASL soundness proof needs). *This is the module type that `CASLche_PCM` discharges with
  real proofs in file 3.*
- **`Module CASLModel (P : PCM)`** — everything CASL needs on top of a PCM:
  - `World` — a pair (local, shared) of states, with well-formedness `wf_world` (the two are
    compatible) kept as a separate predicate; `WorldSet` / `StateSet` are the assertion types.
  - `UMap` — rely/guarantee action maps from UIDs to `(pre, tag, post)` triples, with
    `umap_union`, `umap_inter`, `umap_leq`, `umap_disjoint`.
  - `state_sep` (`p * q` on states) and `world_sep` (`P * Q` on worlds, via `wcomp`);
    `local_shared p f` says the shared state splits into a `p`-piece and an `f`-piece; `lift_state p` is a purely local assertion.
  - `stable`, `well_formed` (disjointness, frame preservation and precision of rely
    post-conditions), `rely_consistent`, `traces_in_guar`: the side conditions of the rules.
  - 15 proved helper lemmas (derived PCM facts, unit collapse, trace-concatenation
    identities).

### `CASL_ProofRules.v` — 208 lines, 1 `Parameter`

- **`Module Type ATOM`** — a single `Parameter Atom : Type`, the type of atomic commands.
  Instantiated in file 3 by `CHEAtom`.
- **`Comm`** — the command grammar: atoms, `skip`, `;`, `+` (choice), `*` (Kleene star),
  `||` (parallel).
- **`Axioms := StateSet -> Atom -> Tag -> StateSet -> Prop`** — the per-logic small-axiom
  interface. `che_axioms` in file 3 is exactly an inhabitant of this.
- **`Inductive derives`** — the CASL judgement `R,G,Θ ⊢ [P] C [ε : Q]` as 19 constructors
  covering the 17 named rules (`Choice` and `ParEr` each split into L and R forms): `RSkip`,
  `RSeq`, `RSeqEr`, `RAtom`, `RAtomLocal`, `RLoop1`, `RLoop2`, `RBackwardsVariant`,
  `RChoiceL/R`, `RComb`, `REnvL`, `REnvR`, `REnvEr`, `RFrame`, `RPar`, `RParErL/R`, `RCons`.
  The axiom set is a `Section Variable`, so the whole relation is parametric in it — this is
  what lets the same rules be replayed against `che_axioms` and against `che_error_axioms`.

### `CHERI_compartheap.v` — 3 121 lines, 150 `Qed`, 4 `Parameter`

The paper's formalization proper. Section by section, with line ranges and proof counts:

| Lines | Section | `Qed` | Content |
|-------|---------|-------|---------|
| 33–96 | **Types** | 0 | `CompartID`, `Cap`, `FuncID` (all `nat`); `AllocState` = `Allocated`/`Freed`; `SealState` = `Sealed`/`Unsealed`; `CapVal := (AllocState * SealState * CompartID)` — the paper's per-capability triple (allocation state, seal state, owner of the designated object). Decidable equality throughout. |
| 97–546 | **State model** | 25 | `CapMap` as a **sorted association list** `list (Cap * CapVal)`, with `cap_lookup`, `cap_sorted_insert`, `cap_union`, the `CapMapSorted` predicate, and the algebra: `cap_lookup_ext` (extensionality), insertion preserves sortedness and commutes, `cap_union_comm`, `cap_union_assoc_eq`, `cap_union_sorted`. Plus `compart_merge`: the current compartment is *exclusively* owned, so at most one of two composed states may pin `τ_cur`; with its commutativity, associativity and cancellativity. *A sorted list rather than a function `Cap -> option CapVal` is what makes composition constructively decidable.* |
| 547–640 | **`CHEState`** | 3 | `cap_sortedb`, a boolean sortedness check, with the reflection lemmas `cms_of_b` / `cms_to_b` against `CapMapSorted`. `Record CHEState := { che_capmap; che_compart : option CompartID; che_sortedb : cap_sortedb che_capmap = true }`. Every state carries its own sortedness certificate, so sortedness survives composition; because the certificate is a boolean equation, `chestate_eq` shows it is irrelevant to equality by `UIP_dec` on `bool`, with no proof-irrelevance axiom. `CHEState_eq_dec` derives decidable state equality. |
| 641–735 | **Decidability** | 3 | `disjoint_bool` with soundness *and* completeness reflection lemmas, then `disjoint_dec_full` — a genuine decision procedure for "these two states compose". |
| 736–916 | **`Module CASLche_PCM <: PCM`** | 7 | **Claim C1.** All eight PCM obligations of `CASL_Model.PCM` discharged: `compose` (disjoint capability-map union + exclusive compartment merge), `compose_success` inversion, `compose_comm` (an equation, from `compose_comm_some`), `compose_assoc`, `unit_exists`, `unit_compose`, `compose_cancel`. No axioms. |
| 917–971 | **`Module CASLche_ATOM <: ATOM`** | 0 | `CHEAtom`, 12 constructors in one-to-one correspondence with the paper's atom grammar: `CHECompartEnter`, `CHECall`, `CHECallPair`, `CHEIndCall`, `CHERet`, `CHERetPair`, `CHEAlloc`, `CHEFree`, `CHELoad`, `CHEStore`, `CHEAssign`, `CHEAssert`. Note `CHEAssign` (`x := y`, a capability copy) is deliberately a *distinct* atom from `CHEStore`/`CHELoad` — it is the operation whose resealing is governed by `holder`. |
| 972–979 | **Instantiation** | 0 | `CASLche_Rules := CASLProofRules CASLche_PCM CASLche_ATOM`, exported. This is the point where generic CASL becomes CompartHeap. |
| 980–1061 | **Assertions** | 3 | `cpt x a σ τ` (the paper's `x ↦ (a,σ,τ)`), `cur_compart τ` (`τ_cur = τ`), `cpt_any`, `cpt_alloc_any`, `cap_uninit y` (`y = -`), `che_emp`, `che_pure`, `is_sealed`, `is_unsealed`; `che_emp` is a unit for `*` (`state_sep_che_emp`, pointwise). |
| 1062–1239 | **Inhabitants & separation** | 22 | Concrete witness states (`st_emp`, `st_cur`, `st_cell`) plus inhabitation lemmas. These matter: they are what make the `INV` counterexamples *constructive* rather than vacuous. Also `compart_free` (an assertion that does not constrain `τ_cur`), pointwise `state_sep_assoc` / `state_sep_comm`, and `sset_equiv` (pointwise equivalence of assertions) with its congruence lemmas. |
| 1240–1273 | **`Module Type CHERI_FUNC_SPACE`** | 0 | The 4 functor parameters: `F_ext`, `F_int`, `caller : FuncID -> FuncID`, and **`holder : Cap -> CompartID`**. The header comment spells out the three distinct compartment notions the paper keeps apart — `τ_cur` (who is executing), `τ_p` (who owns the *pointee*), and `holder p` (who owns the *slot holding the capability*). `INV` is indexed by the third. |
| 1274–2046 | **`Module CHERILogic (FS : CHERI_FUNC_SPACE)`** | 15 | The heart of the artifact: |
| | ↳ `F_all`, `assign_seal` | | `F(τ)` is *defined* as `F_int ∪ F_ext`. `assign_seal x τ := if holder x =? τ then Unsealed else Sealed` — the side condition of `CHERI-Assign`. |
| | ↳ `Inductive che_axioms` | | **20 constructors**, one per safe rule, each with the paper's rule quoted above it: `CHE_Alloc`, `CHE_Free`, `CHE_Load`, `CHE_Store`, `CHE_Assign`, `CHE_Assert`, `CHE_AssertFailed`, `CHE_LoadFail`, `CHE_StoreFail`, `CHE_CompartEnter`, `CHE_CallSeal`, `CHE_CallUnseal`, `CHE_IndCallSeal`, `CHE_IndCallUnseal`, `CHE_CallMixed`, `CHE_RetMixed`, `CHE_CallNoSeal`, `CHE_RetNoSeal`, `CHE_RetSeal`, `CHE_RetUnseal`. |
| | ↳ `Inductive che_unsafe_axioms` | | The 4 unsafe call/return rules, in a **separate** inductive so a derivation cannot silently mix them with the safe set. |
| | ↳ `Inductive che_unsafe_assign_axioms` | | `UNSAFE_Assign`: a copy that propagates `σ` verbatim instead of recomputing it from `holder`. `che_error_axioms` is the union of all three sets and is what the error derivation runs against. |
| | ↳ `INV_state` / `INV_holds` | | `∀ p. p ↦ (-,σ,τ_p) ∧ holder(p) ≠ τ_p ⟹ σ = Sealed`. Note the wildcard in the allocation slot: `INV` constrains `Freed` cells too, which is exactly what makes `CHERI-Alloc` preserving. |
| | ↳ `INV` infrastructure | | ~10 lemmas: `INV_sep` (`INV` distributes over `*`, being a pointwise cell condition), `INV_cpt_sealed`, `INV_cpt_holder`, `INV_cur_irrelevant`, and the four `INV_forces_holder_*` lemmas that extract a `holder` fact *from* an `INV`-satisfying precondition. |
| | ↳ **`che_axioms_preserve_INV`** | | **Claim C2.** One case per rule, twenty cases, unconditional. Each case is (i) an identity rule, (ii) a rule producing only sealed cells, (iii) a rule with an explicit `holder` premise, (iv) a rule whose unsealed output already appears unsealed in the precondition, or (v) `Assign`, where the seal state is computed by `assign_seal`. |
| | ↳ **`che_unsafe_axioms_preserve_INV`** | | **Claim C3 (negative half).** The four unsafe rules touch only `τ_cur`, so they cannot break an invariant that never mentions it. |
| 2047–2173 | **nginx/OpenSSL setup** | 12 | Concrete instantiation. Compartments `τ_ngx = 0`, `τ_ssl = 1`. Capabilities `c`, `ctx`, `conn`, `s`, `s.ex_data`, `data`, `ct` (0–6). Functions `SSL_new`, `SSL_set_ex_data`, `ngx_ssl_create_conn`. `Module NginxFS <: CHERI_FUNC_SPACE` gives `F_ext`/`F_int` as inductive relations and `holder` as a concrete match: `c` and `conn` live in nginx storage, everything else in OpenSSL storage. `Module NginxCHERI := CHERILogic NginxFS`. Nothing here is a parameter or an axiom. |
| 2174–2266 | **Counterexamples** | 4 | **Claim C3 (positive half).** `unsafe_assign_violates_INV`: copying the OpenSSL-owned unsealed capability `s` into nginx's `conn` slot without resealing yields `conn ↦ (A,U,τ_ssl)` while `holder conn = τ_ngx`. Fully constructive — the violating state is exhibited. A long comment at line 2220 records the now-fixed `CHERI-Ret-Unseal` counterexample. |
| 2267–2355 | **`sep_list`** | 10 | Bookkeeping: a program state is a list of cell assertions, `sep_list [p₁;…;pₙ] = p₁ * (… * (pₙ * emp))`, and `sep_move1`…`sep_move7` rotate a cell to the front (as `sset_equiv` facts) so the frame rule can be applied to it. |
| 2356–2553 | **CASL plumbing** | 14 | Assertions are thread-local: a state assertion `p` is used as the world assertion `lift_state p`. `derives_wf`, `wset_equiv`, and the setoid instances `sset_equiv_Equivalence`, `wset_equiv_Equivalence`, `lift_state_Proper`, `derives_Proper` (triples are invariant under equivalent pre/postconditions, by `RCons`), so permutations are applied with `rewrite`. Then `stable_lift_state`, `lift_state_sep_l/r`, `casl_seq_left_ok` (chain two steps), `casl_atom_frame` (`RAtomLocal` + `RFrame` + `RCons`), `casl_frame_sep2` / `casl_frame_sep3` (apply an axiom to the first 2 or 3 cells and frame the rest), and `casl_atom_err_whole` (an error atom over the whole local state, via `RAtom` and a guarantee action on the empty shared resource). |
| 2554–2612 | **Cell abbreviations** | 4 | `Kc_AU`, `Kconn_AS`, `Ks_AU`, … — readable names for the cells of the worked example. Plus the four `assign_seal` side conditions the safe derivation needs (`ct := ctx` stays unsealed; the other three copies are sealed). |
| 2613–2871 | **SAFE derivation** | 12 | **Claim C4.** `P1`, `P1a`, `P2`…`P9` (the paper's `P1`…`P7`, with three intermediate states made explicit), the ten step theorems, `P9_satisfies_INV`, and `nginx_openssl_safe_derivation : derives che_axioms … (lift_state P1) prog_safe (lift_state P9)`. The states genuinely **chain** — the postcondition of step *N* *is* the precondition of step *N+1*, so this is one connected derivation rather than ten disconnected lemmas. |
| 2872–3121 | **ERROR derivation** | 16 | **Claim C5.** `E1`, `E1a`, `E2`…`E9`, ten step theorems using `che_error_axioms`, `E9_violates_INV`, and `nginx_openssl_error_derivation` — the *same program* `prog_safe`, run under the unsafe rules, ending in an `Err 1` triple whose step is recorded by the guarantee `error_G`. In `E9`, three cells (`conn`, `data`, `s.ex_data`) hold unsealed capabilities to objects owned by the other compartment: the leak, machine-checked. |

---

## 7. Scope and known limitations

Stated plainly, so reviewers do not have to discover them.

**7.1 The `Parameter`s are functor arguments, not axioms.** Three module types declare
parameters, and all three are instantiated concretely *within this artifact*:

| Module type | Parameters | Instantiated by |
|-------------|-----------|-----------------|
| `PCM` (`CASL_Model.v`) | 8 | `CASLche_PCM` — every law proved, 7 `Qed` |
| `ATOM` (`CASL_ProofRules.v`) | 1 | `CASLche_ATOM` — the concrete `CHEAtom` type |
| `CHERI_FUNC_SPACE` (`CHERI_compartheap.v`) | 4 (`F_ext`, `F_int`, `caller`, `holder`) | `NginxFS` — inductive relations and a concrete `match` |

`F_ext`, `F_int`, `caller` and `holder` are abstract inside `CHERILogic` so that the metatheory
holds for *any* function space; `NginxFS` then supplies an axiom-free instance. This is why
`Print Assumptions` on the worked derivations reports no CHERI-specific assumptions.

**7.2 `CompartID`, `Cap` and `FuncID` are all definitionally `nat`**, so the type checker
cannot catch one being passed where another is expected. This is flagged in a `KNOWN DEFECT`
note at `CHERI_compartheap.v:44`. It once masked a real signature bug in `CHE_RetSeal` (a
`CompartID` fed to a `FuncID` argument); the signature is now correct
(`caller : FuncID -> FuncID`), but making the three types genuinely distinct would cascade
through ~50 PCM proofs and is left as future work.

**7.3 The worked examples are sequential.** They are CASL `derives` derivations with an
empty rely and keep every resource in the thread-local component of the world
(`lift_state`). The safe derivation uses an empty guarantee; the error derivation's guarantee
`error_G` holds the single action that records its `Err 1` step. The rules that do the work
are `RAtomLocal`, `RAtom`, `RFrame`, `RSeq` and `RCons`; the concurrent rules (`RPar`,
`REnvL/R/Er`, `RParErL/R`) are formalized here but are not exercised by these two examples.

**7.4 `INV` preservation is a rule-level result** — one case per axiom of the rule set. It is
not an end-to-end soundness theorem relating the rules to an operational CHERI semantics.
Soundness of CASL itself is established in the separate CASL development (not part of this
artifact), against the same code as `CASL_Model.v` / `CASL_ProofRules.v`.
It is not re-proved here: applying it to CompartHeap would additionally need a machine
semantics for `CHEAtom` (a `CASL_SEM` instance), which this artifact does not provide. This artifact establishes that
CompartHeap is a correct *instantiation* of that framework and that its rule set preserves the
paper's pointer invariant.

**7.5 This artifact covers the paper's formal-model section only.** The LLVM analysis and
instrumentation passes, and the per-application sealing manifests, are packaged separately.

---

## 8. Directory contents

```
README-ARTIFACT-ROCQ.md   this file
Makefile                  one-line build + audit; see `make help`
_CoqProject               load path (-Q . CASL) and file list, for IDEs
CASL_Model.v              CASL model                       (334 lines,  15 Qed)
CASL_ProofRules.v         CASL proof rules                 (208 lines,   0 Qed)
CHERI_compartheap.v       CompartHeap instantiation       (3121 lines, 150 Qed)
Artifact_Check.v          audit harness: Check + Print Assumptions
.gitignore                keeps build products out of version control
```

Everything else that may appear (`*.vo`, `*.glob`, `.*.aux`, `.lia.cache`, `.rocq-version`,
`Artifact_Check.log`) is a build product and is removed by `make clean`.

### Regenerating a stock Rocq Makefile

The `Makefile` here is hand-written so that the artifact does not depend on `rocq makefile` or
on a generated dependency file. If you prefer the standard generated build:

```bash
rocq makefile -f _CoqProject -o Makefile.rocq && make -f Makefile.rocq
```

That builds the sources but does **not** run the audit of §4.

---

## Reference

CASL, the logic the paper's formal model builds on, is the paper's reference [CASL]: Azalea
Raad, Julien Vanegue, Josh Berdine and Peter O'Hearn, *A General Approach to Under-approximate
Reasoning about Concurrent Programs*, CONCUR 2023.
<https://doi.org/10.4230/LIPIcs.CONCUR.2023.25>
