(* Copyright 2026 Bloomberg Finance L.P. *)
(* Distributed under the terms of the MIT license. *)

(** * CASL_ProofRules: the CASL proof rules

    The proof rules of CASL, the logic on which the paper's formal model is
    built: Skip, Seq, SeqEr, Atom, AtomLocal, Loop1, Loop2,
    BackwardsVariant, Choice, Comb, EnvL, EnvR, EnvEr, Frame, Par, ParEr
    and Cons.  The paper restates only Frame, as CASL-Frame; the worked
    derivations of [CHERI_compartheap.v] use Atom, AtomLocal, Seq, Frame
    and Cons.  Choice and ParEr are split into left/right constructors.
    Every rule requires its conclusion context (R, G) to be well-formed.

    This file is the artifact's own copy of the CASL proof rules: its code
    is that of the CASL proof rules in the CASL development, with only
    comments and module names changed.  Nothing else is needed.
*)

From Stdlib Require Import List.
Import ListNotations.
From CASL Require Import CASL_Model.

(** ** Atoms (a CASL parameter) *)

Module Type ATOM.
  Parameter Atom : Type.
End ATOM.

Module CASLProofRules (P : PCM) (A : ATOM).

  Module M := CASLModel P.
  Export M.
  Export A.

  (** *** Commands *)
  Inductive Comm : Type :=
  | CAtom   : Atom -> Comm
  | CSkip   : Comm
  | CSeq    : Comm -> Comm -> Comm
  | CChoice : Comm -> Comm -> Comm
  | CRep    : Comm -> Comm
  | CPar    : Comm -> Comm -> Comm.

  (** *** Atomic axioms (a CASL parameter): tuples (p, a, ε, q). *)
  Definition Axioms := StateSet -> Atom -> Tag -> StateSet -> Prop.

  Section Derivation.

  Variable axioms : Axioms.

  (** derives R G Θ ε P C Q  ==  R, G, Θ ⊢ [P] C [ε : Q] *)
  Inductive derives : UMap -> UMap -> STraceSet -> Tag -> WorldSet -> Comm -> WorldSet -> Prop :=

  (** Skip:  R, G, Θ0 ⊢ [P] skip [ok : P] *)
  | RSkip : forall R G P,
      well_formed R G ->
      derives R G empty_traces Ok P CSkip P

  (** Seq *)
  | RSeq : forall R G T1 T2 P Mid Q C1 C2 tg,
      well_formed R G ->
      derives R G T1 Ok P C1 Mid ->
      derives R G T2 tg Mid C2 Q ->
      derives R G (traces_concat T1 T2) tg P (CSeq C1 C2) Q

  (** SeqEr *)
  | RSeqEr : forall R G T P Q C1 C2 er,
      well_formed R G ->
      is_error er = true ->
      derives R G T er P C1 Q ->
      derives R G T er P (CSeq C1 C2) Q

  (** Atom:
        G(α) = (p, ε, q)    (p' ∗ p, a, ε, q' ∗ q) ∈ Axiom
        ---------------------------------------------------
        R, G, {[α]} ⊢ [p' ∗ [p ∗ f]] a [ε : q' ∗ [q ∗ f]] *)
  | RAtom : forall R G uid p tg q p' q' f (a : Atom),
      well_formed R G ->
      G uid = Some (p, tg, q) ->
      axioms (state_sep p' p) a tg (state_sep q' q) ->
      derives R G (singleton_trace uid) tg
              (wset_inter (lift_state p') (local_shared p f))
              (CAtom a)
              (wset_inter (lift_state q') (local_shared q f))

  (** AtomLocal:  (p, a, ok, q) ∈ Axiom  ⟹  R, G, Θ0 ⊢ [p] a [ok : q] *)
  | RAtomLocal : forall R G p q (a : Atom),
      well_formed R G ->
      axioms p a Ok q ->
      derives R G empty_traces Ok (lift_state p) (CAtom a) (lift_state q)

  (** Loop1 *)
  | RLoop1 : forall R G P C,
      well_formed R G ->
      derives R G empty_traces Ok P (CRep C) P

  (** Loop2 *)
  | RLoop2 : forall R G T P Q C tg,
      well_formed R G ->
      derives R G T tg P (CSeq (CRep C) C) Q ->
      derives R G T tg P (CRep C) Q

  (** BackwardsVariant:
        ∀k. R, G, Θ ⊢ [S(k)] C [ok : S(k+1)]
        -----------------------------------------
        R, G, Θ^n ⊢ [S(0)] C⋆ [ok : S(n)] *)
  | RBackwardsVariant : forall R G T (S : nat -> WorldSet) C n,
      well_formed R G ->
      (forall k, derives R G T Ok (S k) C (S (Datatypes.S k))) ->
      derives R G (traces_pow T n) Ok (S 0) (CRep C) (S n)

  (** Choice *)
  | RChoiceL : forall R G T P Q C1 C2 tg,
      well_formed R G ->
      derives R G T tg P C1 Q ->
      derives R G T tg P (CChoice C1 C2) Q

  | RChoiceR : forall R G T P Q C1 C2 tg,
      well_formed R G ->
      derives R G T tg P C2 Q ->
      derives R G T tg P (CChoice C1 C2) Q

  (** Comb *)
  | RComb : forall R G T1 T2 P Q C tg,
      well_formed R G ->
      derives R G T1 tg P C Q ->
      derives R G T2 tg P C Q ->
      derives R G (traceset_union T1 T2) tg P C Q

  (** EnvL:
        R(α) = (p, ok, r)    R, G, Θ ⊢ [p' ∗ [r ∗ f]] C [ε : Q]
        --------------------------------------------------------
        R, G, α :: Θ ⊢ [p' ∗ [p ∗ f]] C [ε : Q] *)
  | REnvL : forall R G T Q C uid p r f p' tg,
      well_formed R G ->
      R uid = Some (p, Ok, r) ->
      derives R G T tg (wset_inter (lift_state p') (local_shared r f)) C Q ->
      derives R G (uid_prepend uid T) tg
              (wset_inter (lift_state p') (local_shared p f)) C Q

  (** EnvR:
        R, G, Θ ⊢ [P] C [ok : r' ∗ [r ∗ f]]    R(α) = (r, ε, q)
        --------------------------------------------------------
        R, G, Θ ++ {[α]} ⊢ [P] C [ε : r' ∗ [q ∗ f]] *)
  | REnvR : forall R G T P C uid r tg q f r',
      well_formed R G ->
      derives R G T Ok P C (wset_inter (lift_state r') (local_shared r f)) ->
      R uid = Some (r, tg, q) ->
      derives R G (traces_concat T (singleton_trace uid)) tg
              P C (wset_inter (lift_state r') (local_shared q f))

  (** EnvEr:
        R(α) = (p, er, q)    er ∈ ErExit
        -----------------------------------------
        R, G, {[α]} ⊢ [[p ∗ f]] C [er : [q ∗ f]] *)
  | REnvEr : forall R G uid p er q f C,
      well_formed R G ->
      R uid = Some (p, er, q) ->
      is_error er = true ->
      derives R G (singleton_trace uid) er
              (local_shared p f) C (local_shared q f)

  (** Frame *)
  | RFrame : forall R G T P Q C Rf tg,
      well_formed R G ->
      derives R G T tg P C Q ->
      stable Rf (umap_union R G) ->
      derives R G T tg (world_sep P Rf) C (world_sep Q Rf)

  (** Par *)
  | RPar : forall R1 R2 G1 G2 T1 T2 P1 P2 Q1 Q2 C1 C2 tg,
      well_formed (umap_inter R1 R2) (umap_union G1 G2) ->
      derives R1 G1 T1 tg P1 C1 Q1 ->
      derives R2 G2 T2 tg P2 C2 Q2 ->
      umap_leq R1 (umap_union G2 R2) ->
      umap_leq R2 (umap_union G1 R1) ->
      umap_disjoint G1 G2 ->
      traceset_nonempty (traceset_inter T1 T2) ->
      derives (umap_inter R1 R2) (umap_union G1 G2)
              (traceset_inter T1 T2) tg
              (world_sep P1 P2) (CPar C1 C2) (world_sep Q1 Q2)

  (** ParEr *)
  | RParErL : forall R G T P Q C1 C2 er,
      well_formed R G ->
      is_error er = true ->
      derives R G T er P C1 Q ->
      traces_in_guar T G ->
      derives R G T er P (CPar C1 C2) Q

  | RParErR : forall R G T P Q C1 C2 er,
      well_formed R G ->
      is_error er = true ->
      derives R G T er P C2 Q ->
      traces_in_guar T G ->
      derives R G T er P (CPar C1 C2) Q

  (** Cons *)
  | RCons : forall R G T R' G' T' P P' Q Q' C tg,
      well_formed R G ->
      wset_subset P' P ->
      derives R' G' T' tg P' C Q' ->
      wset_subset Q Q' ->
      rely_consistent T R' R ->
      rely_consistent T G' G ->
      traceset_subset T T' ->
      derives R G T tg P C Q.

  End Derivation.

End CASLProofRules.
