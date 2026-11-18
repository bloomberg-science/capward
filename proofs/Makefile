# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# ============================================================================
#  Artifact Makefile
#
#  "Mind The Heap: Preventing Capability Leakage Across CHERI Compartments"
#  ACM CCS 2026 -- Rocq formalization
#
#  ONE-LINE BUILD AND CHECK:
#
#      make
#
#  That compiles all three source files in dependency order and then runs the
#  full audit: no admitted proofs, no axioms, the expected number of completed
#  proofs, and every headline result closed under the global context.  A
#  non-zero exit status means the artifact did not validate.
#
#  The artifact is self-contained: it needs Rocq and the files in this
#  directory, nothing else.  CASL_Model.v and CASL_ProofRules.v are its own
#  copies of the CASL model and proof rules.
#
#  Other targets:  make build | make check | make clean | make dist | make help
# ============================================================================

# --- Configuration ----------------------------------------------------------

# The Rocq driver.  Override if it is not on PATH or is named differently:
#     make ROCQ=/opt/rocq/bin/rocq
ROCQ      ?= rocq
ROCQFLAGS ?= -Q . CASL

# Source files, in dependency order.  Do not reorder.
VFILES  := CASL_Model.v CASL_ProofRules.v CHERI_compartheap.v
VOFILES := $(VFILES:.v=.vo)

# The audit file.  Not part of the development; compiled only by `make check`.
CHECKV   := Artifact_Check.v
CHECKLOG := Artifact_Check.log

# Expected audit results.  If you edit the proofs, update these.
EXPECTED_QED := 165

# Sequential: `check` must not start before `build` finishes, even under -j.
.NOTPARALLEL:

.PHONY: all build check check-rocq check-admitted check-qed check-assumptions \
        clean dist help force

# --- Default target: build everything, then check everything ----------------

all: build check
	@echo ""
	@echo "  ================================================================"
	@echo "   ARTIFACT VALIDATED"
	@echo "   3 source files compiled, $(EXPECTED_QED) proofs completed,"
	@echo "   0 admitted, 0 axioms."
	@echo "  ================================================================"
	@echo ""

# --- Build ------------------------------------------------------------------

build: check-rocq $(VOFILES)

check-rocq:
	@command -v $(ROCQ) >/dev/null 2>&1 || { \
	  echo "ERROR: '$(ROCQ)' not found on PATH."; \
	  echo "       Install Rocq 9.x, or point this Makefile at it:"; \
	  echo "         make ROCQ=/path/to/rocq"; \
	  echo "       See README-ARTIFACT-ROCQ.md, section 2."; \
	  exit 1; }

# A .vo compiled by a different Rocq version cannot be loaded by this one.
# Stamping the version means a toolchain change forces a full rebuild instead
# of failing confusingly halfway through -- and means a stale .vo shipped in
# the tarball is always recompiled rather than silently trusted.
.rocq-version: force
	@$(ROCQ) --version 2>/dev/null | head -1 | cmp -s - $@ || \
	  $(ROCQ) --version 2>/dev/null | head -1 > $@

%.vo: %.v .rocq-version
	@echo "  ROCQ  $<"
	@$(ROCQ) compile $(ROCQFLAGS) $<

# Dependency order.  Written out rather than generated, so that this Makefile
# has no dependency on `rocq makefile` or on a .d file.
CASL_Model.vo:
CASL_ProofRules.vo:   CASL_Model.vo
CHERI_compartheap.vo: CASL_Model.vo CASL_ProofRules.vo

# --- Check ------------------------------------------------------------------

check: check-admitted check-qed check-assumptions

check-admitted: check-rocq
	@echo ""
	@echo "==> [1/3] No admitted proofs, no axioms"
	@if grep -n 'Admitted' $(VFILES); then \
	   echo "    FAIL: Admitted found (listed above)"; exit 1; fi
	@if grep -n '^ *Axiom ' $(VFILES); then \
	   echo "    FAIL: standalone Axiom found (listed above)"; exit 1; fi
	@echo "    OK: 0 Admitted, 0 Axiom"
	@echo "    ('Parameter' does occur, but only inside Module Type"
	@echo "     signatures -- functor arguments, all instantiated"
	@echo "     concretely.  See README-ARTIFACT-ROCQ.md, section 7.)"

check-qed: check-rocq
	@echo ""
	@echo "==> [2/3] Completed proof count"
	@n=`cat $(VFILES) | grep -c 'Qed\.'`; \
	 if [ "$$n" -ne "$(EXPECTED_QED)" ]; then \
	   echo "    FAIL: expected $(EXPECTED_QED) Qed, found $$n"; exit 1; fi; \
	 echo "    OK: $$n Qed across $(words $(VFILES)) files"

# Compiling Artifact_Check.v re-checks every proof term in the development and
# prints the axiom base of every headline result.  We then assert that each
# one is closed under the global context: no axiom of any kind.
$(CHECKLOG): $(CHECKV) $(VOFILES)
	@$(ROCQ) compile $(ROCQFLAGS) $(CHECKV) > $@ 2>&1 || \
	  { echo "    FAIL: $(CHECKV) did not compile:"; cat $@; rm -f $@; exit 1; }

check-assumptions: check-rocq $(CHECKLOG)
	@echo ""
	@echo "==> [3/3] Axiom base of the headline results"
	@want=`grep -c '^Print Assumptions' $(CHECKV)`; \
	 got=`grep -c '^Closed under the global context' $(CHECKLOG)`; \
	 if grep -q '^Axioms:' $(CHECKLOG) || [ "$$got" -ne "$$want" ]; then \
	   echo "    FAIL: some headline result depends on an axiom:"; \
	   sed 's/^/      /' $(CHECKLOG); exit 1; fi; \
	 echo "    OK: all $$want headline results are closed under the global context"
	@echo "    (No axiom of any kind -- not even the standard-library"
	@echo "     extensionality axioms -- is used.)"
	@echo ""
	@echo "    Full Check / Print Assumptions output: $(CHECKLOG)"

# --- Housekeeping -----------------------------------------------------------

clean:
	rm -f *.vo *.vok *.vos *.glob .*.aux .lia.cache .rocq-version $(CHECKLOG)

# Produce a source-only tarball of this directory, ready to hand to reviewers.
dist: clean
	@d=`basename \`pwd\``; cd .. && \
	 tar czf $$d.tgz \
	   $$d/README-ARTIFACT-ROCQ.md $$d/Makefile $$d/_CoqProject \
	   $$d/CASL_Model.v $$d/CASL_ProofRules.v \
	   $$d/CHERI_compartheap.v $$d/Artifact_Check.v && \
	 echo "wrote ../$$d.tgz"

help:
	@echo "make            build everything, then run the full audit (default)"
	@echo "make build      compile the three source files only"
	@echo "make check      run the audit (builds first if needed)"
	@echo "make clean      remove all build products"
	@echo "make dist       clean, then write a source-only ../proof_compartheap.tgz"
	@echo ""
	@echo "make ROCQ=/path/to/rocq ...   if rocq is not on PATH"

force:
