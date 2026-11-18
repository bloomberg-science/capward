(* Copyright 2026 Bloomberg Finance L.P. *)
(* Distributed under the terms of the MIT license. *)

(** * Artifact_Check: machine-checked audit of the artifact's headline claims

    This file is not part of the development.  It is compiled by [make check]
    and does two things:

    - [Check] each headline result, so its exact statement is printed and can
      be compared against the claims table of README-ARTIFACT-ROCQ.md;
    - [Print Assumptions] on each, so the complete axiom base of the artifact
      is visible.  [make check] parses this output and fails unless every
      headline result is closed under the global context, i.e. depends on
      no axiom at all.

    Compiling this file at all already proves the development is consistent
    enough to be loaded: [Require Import CHERI_compartheap] type-checks every
    definition and every proof term in the three source files.
*)

From CASL Require Import CHERI_compartheap.

(* ================================================================== *)
(** ** C1 -- the CompartHeap state model is a genuine PCM              *)
(* ================================================================== *)

(** Composition is commutative, associative, unital and cancellative, and -- crucially --
    decidable: [disjoint_dec_full] is a decision procedure, not an axiom. *)
Check CASLche_PCM.compose_comm.
Check CASLche_PCM.compose_assoc.
Check CASLche_PCM.unit_exists.
Check CASLche_PCM.compose_cancel.
Check CASLche_PCM.unit_compose.
Check disjoint_dec_full.
Check CHEState_eq_dec.

(* ================================================================== *)
(** ** C2 -- every safe rule preserves INV, unconditionally            *)
(* ================================================================== *)

Check NginxCHERI.che_axioms_preserve_INV.
Print Assumptions NginxCHERI.che_axioms_preserve_INV.

(* ================================================================== *)
(** ** C3 -- the unsafe call/return rules cannot break INV,            *)
(**          but UNSAFE-Assign can                                     *)
(* ================================================================== *)

Check NginxCHERI.che_unsafe_axioms_preserve_INV.
Print Assumptions NginxCHERI.che_unsafe_axioms_preserve_INV.

Check unsafe_assign_violates_INV.
Print Assumptions unsafe_assign_violates_INV.

(* ================================================================== *)
(** ** C4 -- the safe nginx/OpenSSL derivation, ending in INV          *)
(* ================================================================== *)

Check nginx_openssl_safe_derivation.
Print Assumptions nginx_openssl_safe_derivation.

Check P9_satisfies_INV.
Print Assumptions P9_satisfies_INV.

(* ================================================================== *)
(** ** C5 -- the error derivation, ending in an [er] triple that       *)
(**          violates INV                                              *)
(* ================================================================== *)

Check nginx_openssl_error_derivation.
Print Assumptions nginx_openssl_error_derivation.

Check E9_violates_INV.
Print Assumptions E9_violates_INV.
