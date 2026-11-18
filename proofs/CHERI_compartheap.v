(* Copyright 2026 Bloomberg Finance L.P. *)
(* Distributed under the terms of the MIT license. *)

(** * CHERI_compartheap: Formal Model for Heap Compartmentalization

    Formalizes the CompartHeap CHERI logic from the paper:
    - Concrete PCM for CHERI compartment-tagged capabilities
      (with explicit proofs of PCM properties)
    - RGAtomsCHE atoms for compartment-aware heap operations
    - 20 proof rules from Appendix H (Figure 10) as an inductive type
      (sealing, unsealing, allocation, free, load, store, assignment,
      compartment entry, assertions, and the load/store error rules)
    - Module functor CHERILogic parameterized by function space,
      demonstrating that CASL can be instantiated for CHERI
    - Proof example: nginx-OpenSSL cross-compartment allocation
      scenario from Section 4 (Formal Model)

    Memory values are triples (AllocState, SealState, CompartID):
    - AllocState: Allocated or Freed
    - SealState: Sealed or Unsealed
    - CompartID: parent compartment identifier
*)

From Stdlib Require Import List.
From Stdlib Require Import Arith.
From Stdlib Require Import Bool.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import ListDec.
From Stdlib Require Import Lia.
From Stdlib Require Import Eqdep_dec.
From Stdlib Require Import Setoid Morphisms.
Import ListNotations.
From CASL Require Import CASL_Model.
From CASL Require Import CASL_ProofRules.

(* ================================================================== *)
(** ** Types                                                           *)
(* ================================================================== *)

(** Compartment identifier: a natural number naming a CHERI compartment. *)
Definition CompartID := nat.
(** Capability: a natural number naming a CHERI memory capability. *)
Definition Cap := nat.
(** Function identifier: a natural number naming a compartment-boundary function. *)
Definition FuncID := nat.

(** KNOWN DEFECT (deliberately not fixed here).  [CompartID], [Cap] and
    [FuncID] are all definitionally [nat], so the type checker cannot catch a
    compartment identifier being used where a function identifier is expected
    (or vice versa).  A previous version of [CHE_RetSeal] exploited this by
    accident, writing [F_all tau2 (caller_compart f)] with
    [caller_compart : FuncID -> CompartID], i.e. feeding a [CompartID] to a
    [FuncID] argument.  The *signature* defect is fixed below (the module type
    now declares [caller : FuncID -> FuncID], matching the paper's
    [caller(f) in F(tau)]), but making the three types genuinely distinct would
    cascade through the ~50 existing PCM proofs and is left as future work. *)

(** Decidable equality on compartment identifiers. *)
Definition CompartID_eq_dec : forall t1 t2 : CompartID, {t1 = t2} + {t1 <> t2}
  := Nat.eq_dec.

(** Allocation status of a capability: either live (Allocated) or reclaimed (Freed). *)
Inductive AllocState : Type :=
| Allocated : AllocState
| Freed : AllocState.

(** Seal status of a capability: sealed caps cross compartment boundaries; unsealed are local. *)
Inductive SealState : Type :=
| Sealed : SealState
| Unsealed : SealState.

(** The value carried by a capability entry: (alloc status, seal status, owner compartment). *)
Definition CapVal : Type := (AllocState * SealState * CompartID)%type.

(** Project the allocation status from a CapVal. *)
Definition cv_alloc (cv : CapVal) : AllocState := fst (fst cv).
(** Project the seal status from a CapVal. *)
Definition cv_seal  (cv : CapVal) : SealState  := snd (fst cv).
(** Project the compartment ID from a CapVal. *)
Definition cv_comp  (cv : CapVal) : CompartID  := snd cv.

(** Decidable equality for constituent types *)
(** Decidable equality for AllocState (two-constructor enum). *)
Definition AllocState_eq_dec : forall a b : AllocState, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(** Decidable equality for SealState (two-constructor enum). *)
Definition SealState_eq_dec : forall a b : SealState, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(** Decidable equality for CapVal triples. *)
Definition CapVal_eq_dec : forall v1 v2 : CapVal, {v1 = v2} + {v1 <> v2}.
Proof.
  intros [[a1 s1] c1] [[a2 s2] c2].
  destruct (AllocState_eq_dec a1 a2); [subst|right; congruence].
  destruct (SealState_eq_dec s1 s2); [subst|right; congruence].
  destruct (Nat.eq_dec c1 c2); [subst; left; reflexivity|right; congruence].
Defined.

(* ================================================================== *)
(** ** State Model (sorted finite map)                                 *)
(* ================================================================== *)

(** CapMap is a sorted association list (keys strictly ascending).
    Sorted order ensures structural equality for identical key-value
    sets, enabling decidable equality and provable commutativity. *)
Definition CapMap := list (Cap * CapVal).

(** Linear lookup in a CapMap by capability key. *)
Fixpoint cap_lookup (m : CapMap) (c : Cap) : option CapVal :=
  match m with
  | [] => None
  | (k, v) :: rest => if Nat.eqb c k then Some v else cap_lookup rest c
  end.

(** The empty capability map (no capabilities). *)
Definition cap_empty : CapMap := [].

(** Sorted insert — inserts (c, v) into a sorted map, maintaining sort order.
    If c is already present (shouldn't happen for disjoint maps), overwrites. *)
Fixpoint cap_sorted_insert (c : Cap) (v : CapVal) (m : CapMap) : CapMap :=
  match m with
  | [] => [(c, v)]
  | (k, v') :: rest =>
    if c <? k then (c, v) :: m
    else if c =? k then (c, v) :: rest
    else (k, v') :: cap_sorted_insert c v rest
  end.

(** Union: fold sorted insert of m1's elements into m2.
    For sorted disjoint maps, this produces the sorted merge,
    which is the same regardless of which argument is m1 or m2. *)
Definition cap_union (m1 m2 : CapMap) : CapMap :=
  fold_right (fun kv acc => cap_sorted_insert (fst kv) (snd kv) acc) m2 m1.

(** Sortedness predicate for CapMap: keys are strictly increasing. *)
Inductive CapMapSorted : CapMap -> Prop :=
| CMS_nil  : CapMapSorted []
| CMS_one  : forall k v, CapMapSorted [(k, v)]
| CMS_cons : forall k1 v1 k2 v2 rest,
    k1 < k2 -> CapMapSorted ((k2, v2) :: rest) ->
    CapMapSorted ((k1, v1) :: (k2, v2) :: rest).

(** The empty CapMap is sorted (vacuously). *)
Lemma cms_empty : CapMapSorted cap_empty.
Proof. constructor. Qed.

(** A singleton CapMap is always sorted. *)
Lemma cms_single : forall k v, CapMapSorted [(k, v)].
Proof. intros. constructor. Qed.

(** Looking up a key smaller than the head key in a sorted map returns None. *)
Lemma cap_lookup_lt_head : forall k m,
  CapMapSorted m ->
  match m with [] => True | (kh, _) :: _ => k < kh end ->
  cap_lookup m k = None.
Proof.
  intros k m Hm. induction Hm; simpl.
  - intros _. reflexivity.
  - intros Hlt.
    rewrite (proj2 (Nat.eqb_neq k k0) (Nat.lt_neq k k0 Hlt)). reflexivity.
  - intros Hlt.
    rewrite (proj2 (Nat.eqb_neq k k1) (Nat.lt_neq k k1 Hlt)).
    apply IHHm. lia.
Qed.

(** Two sorted maps are equal if they agree on all lookups (extensionality). *)
Lemma cap_lookup_ext : forall m1 m2,
  CapMapSorted m1 -> CapMapSorted m2 ->
  (forall c, cap_lookup m1 c = cap_lookup m2 c) ->
  m1 = m2.
Proof.
  intros m1. induction m1 as [|[k1 v1] rest1 IH]; intros m2 Hm1 Hm2 Hlu.
  - destruct m2 as [|[k2 v2] rest2]; [reflexivity|].
    specialize (Hlu k2). simpl in Hlu. rewrite Nat.eqb_refl in Hlu. discriminate.
  - destruct m2 as [|[k2 v2] rest2].
    + specialize (Hlu k1). simpl in Hlu. rewrite Nat.eqb_refl in Hlu. discriminate.
    + assert (k1 = k2).
      { destruct (Nat.eq_dec k1 k2) as [->|Hne]; [reflexivity|].
        exfalso.
        assert (k1 < k2 \/ k1 > k2) as [Hlt|Hgt] by lia.
        - assert (Hn2 : cap_lookup ((k2,v2)::rest2) k1 = None).
          { apply cap_lookup_lt_head; [exact Hm2 | exact Hlt]. }
          assert (Hn1 : cap_lookup ((k1,v1)::rest1) k1 = Some v1).
          { simpl. rewrite Nat.eqb_refl. reflexivity. }
          specialize (Hlu k1). rewrite Hn1 in Hlu. rewrite Hn2 in Hlu. discriminate.
        - assert (Hlt2 : k2 < k1) by lia.
          assert (Hn1 : cap_lookup ((k1,v1)::rest1) k2 = None).
          { apply cap_lookup_lt_head; [exact Hm1 | exact Hlt2]. }
          assert (Hn2 : cap_lookup ((k2,v2)::rest2) k2 = Some v2).
          { simpl. rewrite Nat.eqb_refl. reflexivity. }
          specialize (Hlu k2). rewrite Hn1 in Hlu. rewrite Hn2 in Hlu. discriminate.
      }
      subst k2.
      assert (v1 = v2).
      { specialize (Hlu k1). simpl in Hlu. rewrite Nat.eqb_refl in Hlu. congruence. }
      subst v2. f_equal.
      apply IH.
      { inversion Hm1; [constructor | assumption]. }
      { inversion Hm2; [constructor | assumption]. }
      { intros c. specialize (Hlu c). simpl in Hlu.
        destruct (Nat.eqb c k1) eqn:Ec.
        - apply Nat.eqb_eq in Ec. subst c.
          assert (H1 : cap_lookup rest1 k1 = None).
          { destruct rest1 as [|[kr vr] ?]; [reflexivity|].
            apply (cap_lookup_lt_head k1 ((kr,vr)::_)).
            + inversion Hm1; assumption.
            + inversion Hm1; assumption. }
          assert (H2 : cap_lookup rest2 k1 = None).
          { destruct rest2 as [|[kr vr] ?]; [reflexivity|].
            apply (cap_lookup_lt_head k1 ((kr,vr)::_)).
            + inversion Hm2; assumption.
            + inversion Hm2; assumption. }
          congruence.
        - exact Hlu. }
Qed.

(** Inserting a fresh key into a sorted map preserves sortedness. *)
Lemma cap_sorted_insert_sorted : forall k v m,
  CapMapSorted m ->
  cap_lookup m k = None ->
  CapMapSorted (cap_sorted_insert k v m).
Proof.
  intros k v m. revert k v.
  induction m as [|[k0 v0] rest IH]; intros k v Hm Hfresh.
  - constructor.
  - simpl in Hfresh.
    assert (Hrest : CapMapSorted rest).
    { inversion Hm; [constructor | assumption]. }
    simpl.
    destruct (k <? k0) eqn:Elt0.
    + apply Nat.ltb_lt in Elt0. constructor; [exact Elt0 | exact Hm].
    + destruct (k =? k0) eqn:Heq0; [discriminate | ].
      apply Nat.ltb_ge in Elt0. apply Nat.eqb_neq in Heq0.
      assert (Hlt0k : k0 < k) by lia.
      assert (IH_result : CapMapSorted (cap_sorted_insert k v rest)).
      { apply IH; [exact Hrest | exact Hfresh]. }
      destruct rest as [|[k2 v2] rest2].
      * simpl. constructor; [exact Hlt0k | constructor].
      * simpl in Hfresh.
        destruct (k <? k2) eqn:Elt2.
        -- assert (Hform : cap_sorted_insert k v ((k2, v2) :: rest2) =
                           (k, v) :: (k2, v2) :: rest2).
           { simpl. rewrite Elt2. reflexivity. }
           rewrite Hform in *.
           constructor; [lia | exact IH_result].
        -- destruct (k =? k2) eqn:Heq2; [discriminate | ].
           assert (Hform : cap_sorted_insert k v ((k2, v2) :: rest2) =
                           (k2, v2) :: cap_sorted_insert k v rest2).
           { simpl. rewrite Elt2. rewrite Heq2. reflexivity. }
           rewrite Hform in *.
           constructor; [|exact IH_result].
           inversion Hm; subst; assumption.
Qed.

(** Looking up the inserted key always returns the inserted value. *)
Lemma cap_sorted_insert_lookup_eq : forall k v m,
  cap_lookup (cap_sorted_insert k v m) k = Some v.
Proof.
  intros k v m. induction m as [|[k' v'] rest IH]; simpl.
  - rewrite Nat.eqb_refl. reflexivity.
  - destruct (k <? k') eqn:Elt.
    + simpl. rewrite Nat.eqb_refl. reflexivity.
    + destruct (k =? k') eqn:Heq.
      * simpl. rewrite Nat.eqb_refl. reflexivity.
      * simpl. rewrite Heq. exact IH.
Qed.

(** Looking up a key different from the inserted one is unchanged. *)
Lemma cap_sorted_insert_lookup_neq : forall k1 k2 v m,
  k1 <> k2 ->
  cap_lookup (cap_sorted_insert k1 v m) k2 = cap_lookup m k2.
Proof.
  intros k1 k2 v m Hne. induction m as [|[k' v'] rest IH]; simpl.
  - destruct (Nat.eqb k2 k1) eqn:H.
    + apply Nat.eqb_eq in H. congruence.
    + reflexivity.
  - destruct (k1 <? k') eqn:Elt.
    + simpl. destruct (Nat.eqb k2 k1) eqn:H.
      apply Nat.eqb_eq in H. congruence. reflexivity.
    + destruct (k1 =? k') eqn:Heq.
      * apply Nat.eqb_eq in Heq. subst.
        simpl. destruct (Nat.eqb k2 k') eqn:Hk2.
        { apply Nat.eqb_eq in Hk2. congruence. }
        reflexivity.
      * simpl. destruct (Nat.eqb k2 k') eqn:Hk2k'.
        -- reflexivity.
        -- exact IH.
Qed.

(** cap_sorted_insert preserves sortedness even when the key is already present. *)
Lemma cap_sorted_insert_sorted2 : forall k v m,
  CapMapSorted m ->
  CapMapSorted (cap_sorted_insert k v m).
Proof.
  intros k v m. revert k v.
  induction m as [|[k0 v0] rest IH]; intros k v Hm; simpl.
  - constructor.
  - destruct (k <? k0) eqn:Elt.
    + apply Nat.ltb_lt in Elt. constructor; [exact Elt | exact Hm].
    + destruct (k =? k0) eqn:Heq.
      * apply Nat.eqb_eq in Heq; subst.
        inversion Hm; subst.
        -- apply CMS_one.
        -- apply CMS_cons; assumption.
      * apply Nat.ltb_ge in Elt. apply Nat.eqb_neq in Heq.
        assert (Hlt : k0 < k) by lia.
        assert (Hrest : CapMapSorted rest). { inversion Hm; [constructor | assumption]. }
        pose (IH_result := IH k v Hrest).
        destruct rest as [|[k2 v2] rest2].
        -- simpl. constructor; [exact Hlt | constructor].
        -- destruct (k <? k2) eqn:Elt2.
           ++ assert (Hform : cap_sorted_insert k v ((k2, v2) :: rest2) = (k, v) :: (k2, v2) :: rest2).
              { simpl. rewrite Elt2. reflexivity. }
              rewrite Hform in *. constructor; [exact Hlt | exact IH_result].
           ++ destruct (k =? k2) eqn:Heq2.
              ** apply Nat.eqb_eq in Heq2; subst.
                 assert (Hform : cap_sorted_insert k2 v ((k2, v2) :: rest2) = (k2, v) :: rest2).
                 { simpl. rewrite Nat.ltb_irrefl. rewrite Nat.eqb_refl. reflexivity. }
                 rewrite Hform in *. inversion Hm; subst.
                 constructor; [assumption | inversion IH_result; subst; assumption].
              ** assert (Hform : cap_sorted_insert k v ((k2, v2) :: rest2) = (k2, v2) :: cap_sorted_insert k v rest2).
                 { simpl. rewrite Elt2. rewrite Heq2. reflexivity. }
                 rewrite Hform in *. constructor; [|exact IH_result].
                 inversion Hm; subst; assumption.
Qed.

(** Sorted insert is commutative for distinct keys: inserting in either order yields the same map. *)
Lemma cap_sorted_insert_comm : forall k1 v1 k2 v2 m,
  k1 <> k2 ->
  CapMapSorted m ->
  cap_sorted_insert k1 v1 (cap_sorted_insert k2 v2 m) =
  cap_sorted_insert k2 v2 (cap_sorted_insert k1 v1 m).
Proof.
  intros k1 v1 k2 v2 m Hne Hm.
  apply cap_lookup_ext.
  - apply cap_sorted_insert_sorted2. apply cap_sorted_insert_sorted2. exact Hm.
  - apply cap_sorted_insert_sorted2. apply cap_sorted_insert_sorted2. exact Hm.
  - intros c.
    destruct (Nat.eq_dec c k1) as [->|Hc1].
    + rewrite cap_sorted_insert_lookup_eq.
      rewrite cap_sorted_insert_lookup_neq; [|congruence].
      rewrite cap_sorted_insert_lookup_eq. reflexivity.
    + destruct (Nat.eq_dec c k2) as [->|Hc2].
      * rewrite cap_sorted_insert_lookup_neq; [|congruence].
        rewrite cap_sorted_insert_lookup_eq.
        rewrite cap_sorted_insert_lookup_eq. reflexivity.
      * rewrite cap_sorted_insert_lookup_neq; [|congruence].
        rewrite cap_sorted_insert_lookup_neq; [|congruence].
        rewrite cap_sorted_insert_lookup_neq; [|congruence].
        rewrite cap_sorted_insert_lookup_neq; [|congruence].
        reflexivity.
Qed.

(** The empty map is a left unit for cap_union. *)
Lemma cap_union_empty_l : forall m, cap_union cap_empty m = m.
Proof. intros m. unfold cap_union, cap_empty. reflexivity. Qed.

(** The empty map is a right unit for cap_union (requires sorted input). *)
Lemma cap_union_empty_r : forall m,
  CapMapSorted m -> cap_union m cap_empty = m.
Proof.
  intros m Hm. induction Hm.
  - reflexivity.
  - simpl. reflexivity.
  - unfold cap_union in *. simpl in *.
    rewrite IHHm.
    simpl. rewrite (proj2 (Nat.ltb_lt k1 k2) H). reflexivity.
Qed.

(** cap_union lookup: prefer m1's entry; fall back to m2 when m1 is undefined at c. *)
Lemma cap_union_lookup : forall m1 m2 c,
  cap_lookup (cap_union m1 m2) c =
  match cap_lookup m1 c with
  | Some v => Some v
  | None => cap_lookup m2 c
  end.
Proof.
  intros m1. induction m1 as [|[k v] rest IH]; intros m2 c; simpl.
  - reflexivity.
  - change (cap_lookup (cap_sorted_insert k v (cap_union rest m2)) c =
            match (if Nat.eqb c k then Some v else cap_lookup rest c)
            with Some v' => Some v' | None => cap_lookup m2 c end).
    destruct (Nat.eqb c k) eqn:Hck.
    + apply Nat.eqb_eq in Hck. subst.
      rewrite cap_sorted_insert_lookup_eq. reflexivity.
    + apply Nat.eqb_neq in Hck.
      rewrite (cap_sorted_insert_lookup_neq k c v (cap_union rest m2) (fun h => Hck (eq_sym h))).
      rewrite IH. reflexivity.
Qed.

(** cap_union of any m1 and a sorted m2 is sorted. *)
Lemma cap_union_sorted : forall m1 m2,
  CapMapSorted m2 ->
  CapMapSorted (cap_union m1 m2).
Proof.
  intros m1. induction m1 as [|[k v] rest IH]; intros m2 Hm2; simpl.
  - exact Hm2.
  - unfold cap_union. simpl. apply cap_sorted_insert_sorted2. apply IH. exact Hm2.
Qed.

(** Helper: disjoint_capmap properties *)
(** Two CapMaps are disjoint if no capability key appears in both. *)
Definition disjoint_capmap (m1 m2 : CapMap) : Prop :=
  forall c, cap_lookup m1 c = None \/ cap_lookup m2 c = None.

(** Disjointness of CapMaps is symmetric. *)
Lemma disjoint_capmap_comm : forall m1 m2,
  disjoint_capmap m1 m2 -> disjoint_capmap m2 m1.
Proof.
  unfold disjoint_capmap. intros m1 m2 H c.
  destruct (H c); auto.
Qed.

(** The empty map is disjoint from any map (left). *)
Lemma disjoint_capmap_empty_l : forall m,
  disjoint_capmap cap_empty m.
Proof.
  unfold disjoint_capmap, cap_empty. intros m c. left. reflexivity.
Qed.

(** The empty map is disjoint from any map (right). *)
Lemma disjoint_capmap_empty_r : forall m,
  disjoint_capmap m cap_empty.
Proof.
  unfold disjoint_capmap, cap_empty. intros m c. right. reflexivity.
Qed.

(** For sorted disjoint maps, cap_union is commutative: m1 ∪ m2 = m2 ∪ m1. *)
Lemma cap_union_comm : forall m1 m2,
  CapMapSorted m1 -> CapMapSorted m2 ->
  disjoint_capmap m1 m2 ->
  cap_union m1 m2 = cap_union m2 m1.
Proof.
  intros m1 m2 Hm1 Hm2 Hdisj.
  apply cap_lookup_ext.
  - apply cap_union_sorted. exact Hm2.
  - apply cap_union_sorted. exact Hm1.
  - intros c.
    rewrite !cap_union_lookup.
    destruct (Hdisj c) as [H1|H2].
    + rewrite H1. destruct (cap_lookup m2 c); reflexivity.
    + rewrite H2. destruct (cap_lookup m1 c); reflexivity.
Qed.

(** If m1 ∪ m2 is disjoint from m3, then m1 alone is disjoint from m3. *)
Lemma disjoint_union_l : forall m1 m2 m3,
  disjoint_capmap m1 m2 ->
  disjoint_capmap (cap_union m1 m2) m3 ->
  disjoint_capmap m1 m3.
Proof.
  intros m1 m2 m3 H12 H123 c.
  destruct (H123 c) as [Hu | H3].
  - rewrite cap_union_lookup in Hu.
    destruct (cap_lookup m1 c) eqn:E1.
    + discriminate.
    + left. reflexivity.
  - right. exact H3.
Qed.

(** If m1 ∪ m2 is disjoint from m3, then m2 alone is disjoint from m3. *)
Lemma disjoint_union_r : forall m1 m2 m3,
  disjoint_capmap m1 m2 ->
  disjoint_capmap (cap_union m1 m2) m3 ->
  disjoint_capmap m2 m3.
Proof.
  intros m1 m2 m3 H12 H123 c.
  destruct (H123 c) as [Hu | H3].
  - rewrite cap_union_lookup in Hu.
    destruct (cap_lookup m1 c) eqn:E1.
    + discriminate.
    + left. exact Hu.
  - right. exact H3.
Qed.

(** cap_union is associative at the lookup level (pointwise proof). *)
Lemma cap_union_assoc_lookup : forall m1 m2 m3 c,
  cap_lookup (cap_union (cap_union m1 m2) m3) c =
  cap_lookup (cap_union m1 (cap_union m2 m3)) c.
Proof.
  intros m1 m2 m3 c.
  rewrite !cap_union_lookup.
  destruct (cap_lookup m1 c); [reflexivity|].
  destruct (cap_lookup m2 c); reflexivity.
Qed.

(** cap_union is associative as maps (for sorted inputs), via lookup extensionality. *)
Lemma cap_union_assoc_eq : forall m1 m2 m3,
  CapMapSorted m1 -> CapMapSorted m2 -> CapMapSorted m3 ->
  cap_union (cap_union m1 m2) m3 = cap_union m1 (cap_union m2 m3).
Proof.
  intros m1 m2 m3 Hm1 Hm2 Hm3.
  apply cap_lookup_ext.
  - apply cap_union_sorted. exact Hm3.
  - apply cap_union_sorted. apply cap_union_sorted. exact Hm3.
  - intros c. apply cap_union_assoc_lookup.
Qed.

(** If m1 is disjoint from both m2 and m3 separately, it is disjoint from their union. *)
Lemma disjoint_cap_union_r : forall m1 m2 m3,
  disjoint_capmap m1 m2 ->
  disjoint_capmap m1 m3 ->
  disjoint_capmap m1 (cap_union m2 m3).
Proof.
  intros m1 m2 m3 H12 H13 c.
  destruct (H12 c) as [H1 | H2].
  - left. exact H1.
  - destruct (H13 c) as [H1 | H3].
    + left. exact H1.
    + right. rewrite cap_union_lookup. rewrite H2. exact H3.
Qed.

(** Helper: compart_merge *)
(** Merge two optional compartment IDs: None acts as "no compartment" (compatible with anything).
    The current compartment is exclusively owned: at most one of the two states may pin it,
    so two Some values never merge.  Exclusivity makes the state PCM cancellative. *)
Definition compart_merge (c1 c2 : option CompartID) : option (option CompartID) :=
  match c1, c2 with
  | None, None => Some None
  | None, Some t => Some (Some t)
  | Some t, None => Some (Some t)
  | Some _, Some _ => None
  end.

(** compart_merge is commutative. *)
Lemma compart_merge_comm : forall c1 c2,
  compart_merge c1 c2 = compart_merge c2 c1.
Proof. intros [t1|] [t2|]; reflexivity. Qed.

(** compart_merge is associative: (c1 ⊗ c2) ⊗ c3 = c1 ⊗ (c2 ⊗ c3) when defined. *)
Lemma compart_merge_assoc : forall c1 c2 c3 cm12 cm123,
  compart_merge c1 c2 = Some cm12 ->
  compart_merge cm12 c3 = Some cm123 ->
  exists cm23, compart_merge c2 c3 = Some cm23 /\
               compart_merge c1 cm23 = Some cm123.
Proof.
  intros c1 c2 c3 cm12 cm123 H12 H123.
  destruct c1 as [n1|], c2 as [n2|], c3 as [n3|]; simpl in H12;
    try discriminate; injection H12 as <-; simpl in H123;
    try discriminate; injection H123 as <-; eexists; split; reflexivity.
Qed.

(** compart_merge is cancellative. *)
Lemma compart_merge_cancel : forall c1 c2 c2' cm,
  compart_merge c1 c2 = Some cm -> compart_merge c1 c2' = Some cm -> c2 = c2'.
Proof.
  intros [t1|] [t2|] [t2'|] cm H H'; simpl in *; congruence.
Qed.

(* ================================================================== *)
(** ** CHEState as Record with sortedness invariant                    *)
(* ================================================================== *)

(** Boolean sortedness check, the computational counterpart of [CapMapSorted]. *)
Fixpoint cap_sortedb (m : CapMap) : bool :=
  match m with
  | [] => true
  | (k1, _) :: rest =>
      match rest with
      | [] => true
      | (k2, _) :: _ => Nat.ltb k1 k2 && cap_sortedb rest
      end
  end.

(** [cap_sortedb] reflects [CapMapSorted]: from the boolean to the predicate. *)
Lemma cms_of_b : forall m, cap_sortedb m = true -> CapMapSorted m.
Proof.
  induction m as [|[k1 v1] rest IH]; intros H; [constructor|].
  destruct rest as [|[k2 v2] rest']; [constructor|].
  simpl in H. apply andb_true_iff in H as [Hlt Hs].
  apply Nat.ltb_lt in Hlt. constructor; [exact Hlt | apply IH; exact Hs].
Qed.

(** [cap_sortedb] reflects [CapMapSorted]: from the predicate to the boolean. *)
Lemma cms_to_b : forall m, CapMapSorted m -> cap_sortedb m = true.
Proof.
  intros m H. induction H as [| k v | k1 v1 k2 v2 rest Hlt Hs IH]; [reflexivity | reflexivity |].
  change (Nat.ltb k1 k2 && cap_sortedb ((k2, v2) :: rest) = true).
  apply andb_true_iff. split; [apply Nat.ltb_lt; exact Hlt | exact IH].
Qed.

(** The CHERI heap state: a sorted capability map together with an optional compartment ID.
    The sortedness certificate is a boolean equation, so any two certificates
    are equal by [UIP_dec] on [bool]: no axiom is needed. *)
Record CHEState := mkCHEState {
  che_capmap  : CapMap;
  che_compart : option CompartID;
  che_sortedb : cap_sortedb che_capmap = true
}.

(** Every state's CapMap is sorted. *)
Definition che_sorted (s : CHEState) : CapMapSorted (che_capmap s) :=
  cms_of_b (che_capmap s) (che_sortedb s).

(** Build a state from a [CapMapSorted] certificate. *)
Definition mkCHEState' (m : CapMap) (c : option CompartID) (H : CapMapSorted m) : CHEState :=
  mkCHEState m c (cms_to_b m H).

(** Two CHEStates with equal fields are equal (sortedness certificates are unique). *)
Lemma chestate_eq : forall s1 s2,
  che_capmap s1 = che_capmap s2 ->
  che_compart s1 = che_compart s2 ->
  s1 = s2.
Proof.
  intros [m1 c1 p1] [m2 c2 p2] Hm Hc. simpl in *.
  subst m2. subst c2.
  f_equal. apply UIP_dec. exact Bool.bool_dec.
Qed.

(** Decidable equality for option types, parametric over the base type's decider. *)
Definition option_eq_dec' : forall A (dec : forall x y : A, {x=y}+{x<>y})
  (a b : option A), {a = b} + {a <> b}.
Proof.
  intros A dec [x|] [y|].
  - destruct (dec x y). subst. left; reflexivity. right; congruence.
  - right; discriminate.
  - right; discriminate.
  - left; reflexivity.
Defined.

(** Decidable equality for CapMap (association lists of (Cap * CapVal)). *)
Definition CapMap_eq_dec : forall m1 m2 : CapMap, {m1 = m2} + {m1 <> m2}.
Proof.
  apply list_eq_dec.
  intros [k1 v1] [k2 v2].
  destruct (Nat.eq_dec k1 k2) as [->|Hk].
  - destruct (CapVal_eq_dec v1 v2) as [->|Hv].
    + left. reflexivity.
    + right. congruence.
  - right. congruence.
Defined.

(** Decidable equality for CHEState: compare CapMap and compart fields, ignore proof. *)
Lemma CHEState_eq_dec : forall s1 s2 : CHEState, {s1 = s2} + {s1 <> s2}.
Proof.
  intros s1 s2.
  destruct (CapMap_eq_dec (che_capmap s1) (che_capmap s2)) as [Hm|Hm].
  - destruct (option_eq_dec' _ Nat.eq_dec (che_compart s1) (che_compart s2)) as [Hc|Hc].
    + left. apply chestate_eq; assumption.
    + right. intro H. apply Hc. exact (f_equal che_compart H).
  - right. intro H. apply Hm. exact (f_equal che_capmap H).
Defined.

(* ================================================================== *)
(** ** Disjoint decision procedure                                     *)
(* ================================================================== *)

(** Boolean disjointness check: true iff no key of m1 appears in m2. *)
Definition disjoint_bool (m1 m2 : CapMap) : bool :=
  forallb (fun kv => match cap_lookup m2 (fst kv) with
                     | Some _ => false
                     | None => true
                     end) m1.

(** If the boolean check returns true, the maps are propositionally disjoint. *)
Lemma disjoint_bool_sound : forall m1 m2,
  disjoint_bool m1 m2 = true -> disjoint_capmap m1 m2.
Proof.
  intros m1 m2 H c.
  unfold disjoint_bool in H.
  rewrite forallb_forall in H.
  destruct (cap_lookup m1 c) eqn:E1.
  - right.
    (* c is in m1 — we must show it's not in m2 *)
    (* Find (c, p) in m1 *)
    induction m1 as [|[k v] rest IH].
    + simpl in E1. discriminate.
    + simpl in E1. destruct (Nat.eqb c k) eqn:Eqck.
      * apply Nat.eqb_eq in Eqck. subst k.
        assert (Hin : In (c, v) ((c, v) :: rest)) by (left; reflexivity).
        specialize (H (c, v) Hin). simpl in H.
        destruct (cap_lookup m2 c); [discriminate | reflexivity].
      * apply IH.
        -- intros kv Hkv. apply H. right. exact Hkv.
        -- exact E1.
  - left. reflexivity.
Qed.

(** If (k, v) is in m as a list element, then cap_lookup m k is defined. *)
Lemma cap_lookup_in : forall (m : CapMap) (k : Cap) (v : CapVal),
  In (k, v) m -> exists v', cap_lookup m k = Some v'.
Proof.
  induction m as [|[k' v'] rest IH]; intros k v Hin.
  - simpl in Hin. contradiction.
  - simpl in Hin. destruct Hin as [Heq | Hin'].
    + inversion Heq. subst k'. subst v'. simpl. rewrite Nat.eqb_refl. eexists. reflexivity.
    + simpl. destruct (Nat.eqb k k') eqn:E.
      * eexists. reflexivity.
      * exact (IH k v Hin').
Qed.

(** The boolean check is complete: propositionally disjoint maps pass the check. *)
Lemma disjoint_bool_complete : forall m1 m2,
  disjoint_capmap m1 m2 -> disjoint_bool m1 m2 = true.
Proof.
  intros m1 m2 Hdisj.
  unfold disjoint_bool.
  rewrite forallb_forall.
  intros [k v] Hkv.
  destruct (cap_lookup_in m1 k v Hkv) as [v' Hlu].
  destruct (Hdisj k) as [H1 | H2].
  - rewrite Hlu in H1. discriminate.
  - simpl. rewrite H2. reflexivity.
Qed.

(** Decidable disjointness for CapMaps: decides disjoint_capmap via disjoint_bool. *)
Lemma disjoint_dec_maps : forall m1 m2 : CapMap,
  {disjoint_capmap m1 m2} + {~ disjoint_capmap m1 m2}.
Proof.
  intros m1 m2.
  destruct (disjoint_bool m1 m2) eqn:H.
  - left. apply disjoint_bool_sound. exact H.
  - right. intro Hdisj.
    assert (Htrue : disjoint_bool m1 m2 = true).
    { apply disjoint_bool_complete. exact Hdisj. }
    rewrite H in Htrue. discriminate.
Defined.

(** Decidable equality for optional compartment IDs. *)
Definition option_compart_eq_dec : forall c1 c2 : option CompartID,
  {c1 = c2} + {c1 <> c2} := option_eq_dec' _ Nat.eq_dec.

(** Decision procedure for full CHEState compatibility: CapMaps disjoint and compart_merge succeeds. *)
Definition disjoint_dec_full (s1 s2 : CHEState)
  : {disjoint_capmap (che_capmap s1) (che_capmap s2) /\
     compart_merge (che_compart s1) (che_compart s2) <> None} +
    {~ (disjoint_capmap (che_capmap s1) (che_capmap s2) /\
        compart_merge (che_compart s1) (che_compart s2) <> None)}.
Proof.
  destruct (disjoint_dec_maps (che_capmap s1) (che_capmap s2)) as [Hd | Hnd].
  - destruct (compart_merge (che_compart s1) (che_compart s2)) as [cm|] eqn:Ecm.
    + left. split.
      * exact Hd.
      * intro H. discriminate H.
    + right. intros [_ Hcm]. apply Hcm. reflexivity.
  - right. intros [Hd _]. apply Hnd. exact Hd.
Defined.

(* ================================================================== *)
(** ** PCM for CompartHeap State                                       *)
(* ================================================================== *)

(** PCM instance for the CHERI compartmentalized heap state.
    States compose by taking the disjoint union of CapMaps and merging compartment IDs. *)
Module CASLche_PCM <: PCM.

  (** The PCM carrier [State] is CHEState (sorted CapMap + optional compartment). *)
  Definition State := CHEState.

  (** The unit state: empty CapMap and no compartment constraint. *)
  Definition is_unit (s : State) : Prop :=
    che_capmap s = cap_empty /\
    che_compart s = None.

  (** compose: defined when CapMaps are disjoint and compart_merge succeeds.
      Returns a new CHEState with union CapMap and merged compart. *)
  Definition compose (s1 s2 : State) : option State :=
    match disjoint_dec_full s1 s2 with
    | left _ =>
        let um := cap_union (che_capmap s1) (che_capmap s2) in
        let Hsrt := cap_union_sorted (che_capmap s1) (che_capmap s2) (che_sorted s2) in
        match compart_merge (che_compart s1) (che_compart s2) with
        | Some cm => Some (mkCHEState' um cm Hsrt)
        | None => None
        end
    | right _ => None
    end.

  (** *** Helper: characterize compose success *)
  (** When compose s1 s2 = Some s, extract the disjointness and compart_merge witnesses. *)
  Lemma compose_success : forall s1 s2 s,
    compose s1 s2 = Some s ->
    disjoint_capmap (che_capmap s1) (che_capmap s2) /\
    exists cm, compart_merge (che_compart s1) (che_compart s2) = Some cm /\
    che_capmap s = cap_union (che_capmap s1) (che_capmap s2) /\
    che_compart s = cm.
  Proof.
    intros s1 s2 s H.
    unfold compose in H.
    destruct (disjoint_dec_full s1 s2) as [[Hdisj Hcm_nz] | Hn].
    - destruct (compart_merge (che_compart s1) (che_compart s2)) as [cm|] eqn:Ecm.
      + simpl in H. inversion H. subst. simpl.
        split. exact Hdisj. exists cm. repeat split; reflexivity.
      + exfalso. apply Hcm_nz. reflexivity.
    - discriminate.
  Qed.

  (** *** PCM Properties *)

  (** Composition is commutative when defined: cap_union and compart_merge are both symmetric. *)
  Lemma compose_comm_some : forall s1 s2 s,
    compose s1 s2 = Some s -> compose s2 s1 = Some s.
  Proof.
    intros s1 s2 s H.
    apply compose_success in H.
    destruct H as [Hdisj [cm [Hcm [Hmap Hcomp]]]].
    unfold compose.
    destruct (disjoint_dec_full s2 s1) as [_ | Hn].
    - rewrite compart_merge_comm. rewrite Hcm.
      simpl. f_equal.
      apply chestate_eq; simpl.
      + rewrite Hmap. symmetry. apply cap_union_comm.
        * exact (che_sorted s1).
        * exact (che_sorted s2).
        * exact Hdisj.
      + rewrite Hcomp. reflexivity.
    - exfalso. apply Hn. split.
      + apply disjoint_capmap_comm. exact Hdisj.
      + rewrite compart_merge_comm. rewrite Hcm. discriminate.
  Qed.

  (** Composition is associative: uses assoc of cap_union and compart_merge plus disjointness splitting. *)
  Lemma compose_assoc : forall s1 s2 s3 s12 s123,
    compose s1 s2 = Some s12 ->
    compose s12 s3 = Some s123 ->
    exists s23, compose s2 s3 = Some s23 /\
                compose s1 s23 = Some s123.
  Proof.
    intros s1 s2 s3 s12 s123 H12 H123.
    apply compose_success in H12 as [Hdisj12 [cm12 [Hcm12 [Hmap12 Hcomp12]]]].
    apply compose_success in H123 as [Hdisj123 [cm123 [Hcm123 [Hmap123 Hcomp123]]]].
    (* Hdisj123 : disjoint_capmap (che_capmap s12) (che_capmap s3) *)
    (* che_capmap s12 = cap_union (che_capmap s1) (che_capmap s2) *)
    rewrite Hmap12 in Hdisj123.
    assert (Hdisj13 : disjoint_capmap (che_capmap s1) (che_capmap s3)).
    { exact (disjoint_union_l _ _ _ Hdisj12 Hdisj123). }
    assert (Hdisj23 : disjoint_capmap (che_capmap s2) (che_capmap s3)).
    { exact (disjoint_union_r _ _ _ Hdisj12 Hdisj123). }
    assert (Hdisj1_23 : disjoint_capmap (che_capmap s1)
                          (cap_union (che_capmap s2) (che_capmap s3))).
    { exact (disjoint_cap_union_r _ _ _ Hdisj12 Hdisj13). }
    (* compart_merge chain: cm12 comes from merging s1,s2 comparts *)
    (* s12's compart = cm12 *)
    rewrite Hcomp12 in Hcm123.
    destruct (compart_merge_assoc _ _ _ _ _ Hcm12 Hcm123) as [cm23 [Hcm23 Hcm1_23]].
    (* Build s23 *)
    set (s23 := mkCHEState' (cap_union (che_capmap s2) (che_capmap s3)) cm23
                           (cap_union_sorted _ _ (che_sorted s3))).
    exists s23.
    split.
    - (* compose s2 s3 = Some s23 *)
      unfold compose.
      destruct (disjoint_dec_full s2 s3) as [_ | Hn].
      + rewrite Hcm23. reflexivity.
      + exfalso. apply Hn. split.
        * exact Hdisj23.
        * rewrite Hcm23. discriminate.
    - (* compose s1 s23 = Some s123 *)
      unfold compose.
      destruct (disjoint_dec_full s1 s23) as [_ | Hn].
      + simpl. rewrite Hcm1_23. f_equal.
        apply chestate_eq; simpl.
        * rewrite Hmap123. rewrite Hmap12. symmetry. apply cap_union_assoc_eq.
          exact (che_sorted s1). exact (che_sorted s2). exact (che_sorted s3).
        * symmetry. exact Hcomp123.
      + exfalso. apply Hn. split.
        * simpl. exact Hdisj1_23.
        * simpl. rewrite Hcm1_23. discriminate.
  Qed.

  (** Composition is commutative (as an equation on [option State]). *)
  Lemma compose_comm : forall a b, compose a b = compose b a.
  Proof.
    intros a b.
    destruct (compose a b) as [s|] eqn:Eab.
    - symmetry. apply compose_comm_some. exact Eab.
    - destruct (compose b a) as [s|] eqn:Eba; [|reflexivity].
      apply compose_comm_some in Eba. congruence.
  Qed.

  (** A unit exists: the empty state with no compartment. *)
  Lemma unit_exists : exists u, is_unit u.
  Proof. exists (mkCHEState' cap_empty None cms_empty). split; reflexivity. Qed.

  (** A unit composes on the left to give the identity: u ⊕ s = s when is_unit u. *)
  Lemma unit_compose : forall u s,
    is_unit u -> compose u s = Some s.
  Proof.
    intros u s [Hmap Hcomp].
    unfold compose.
    destruct (disjoint_dec_full u s) as [_ | Hn].
    - simpl. rewrite Hcomp. simpl.
      destruct (che_compart s) eqn:Ec; simpl.
      + f_equal. apply chestate_eq; simpl.
        * rewrite Hmap. apply cap_union_empty_l.
        * symmetry. exact Ec.
      + f_equal. apply chestate_eq; simpl.
        * rewrite Hmap. apply cap_union_empty_l.
        * symmetry. exact Ec.
    - exfalso. apply Hn. split.
      + rewrite Hmap. apply disjoint_capmap_empty_l.
      + rewrite Hcomp. simpl. destruct (che_compart s); simpl; discriminate.
  Qed.

  (** Composition is cancellative: disjoint union of CapMaps is cancellative,
      and so is the exclusive merge of the current compartment. *)
  Lemma compose_cancel : forall a b b' c,
    compose a b = Some c -> compose a b' = Some c -> b = b'.
  Proof.
    intros a b b' c H H'.
    apply compose_success in H as [Hd [cm [Hcm [Hmap Hcomp]]]].
    apply compose_success in H' as [Hd' [cm' [Hcm' [Hmap' Hcomp']]]].
    apply chestate_eq.
    - apply cap_lookup_ext; [exact (che_sorted b) | exact (che_sorted b') |].
      intros k.
      assert (Hk : cap_lookup (cap_union (che_capmap a) (che_capmap b)) k =
                   cap_lookup (cap_union (che_capmap a) (che_capmap b')) k)
        by (rewrite <- Hmap, <- Hmap'; reflexivity).
      rewrite !cap_union_lookup in Hk.
      destruct (cap_lookup (che_capmap a) k) eqn:Ea; [|exact Hk].
      destruct (Hd k) as [Ha | Hb]; [congruence|].
      destruct (Hd' k) as [Ha' | Hb']; [congruence|].
      congruence.
    - eapply compart_merge_cancel; [exact Hcm |].
      rewrite Hcm'. congruence.
  Qed.

End CASLche_PCM.

(* ================================================================== *)
(** ** Atoms: RGAtomsCHE                                               *)
(* ================================================================== *)

(** The ATOM module for CHERI: atomic operations on the compartmentalized heap. *)
Module CASLche_ATOM <: ATOM.

  (** The set of CHERI atomic commands: compartment entry, sealing/unsealing, heap alloc/free,
      memory load/store, assertions, and return operations. *)
  (** These constructors are in one-to-one correspondence with the grammar of
      [RGAtoms_che] in Fig. 7 of the paper:

<<
      atom ::= compartenter tau | f(x) | f(x,y) | ( *f )(x) | return_f(x)
             | return_f(x,y) | x := y | x = alloc(sz) | free(x)
             | y = *x | *x = y | assert P
>>
  *)
  Inductive CHEAtom : Type :=
  (** [compartenter tau] *)
  | CHECompartEnter : CompartID -> CHEAtom
  (** [f(x)] -- direct cross-compartment call with one capability argument *)
  | CHECall         : Cap -> CHEAtom
  (** [f(x,y)] -- direct cross-compartment call with two capability arguments *)
  | CHECallPair     : Cap -> Cap -> CHEAtom
  (** [( *f )(x)] -- indirect (function-pointer) call *)
  | CHEIndCall      : Cap -> CHEAtom
  (** [return_f(x)] *)
  | CHERet          : Cap -> CHEAtom
  (** [return_f(x,y)] *)
  | CHERetPair      : Cap -> Cap -> CHEAtom
  (** [x = alloc(sz)] *)
  | CHEAlloc        : Cap -> nat -> CHEAtom
  (** [free(x)] *)
  | CHEFree         : Cap -> CHEAtom
  (** [y = *x] -- load *)
  | CHELoad         : Cap -> Cap -> CHEAtom
  (** [*x = y] -- store *)
  | CHEStore        : Cap -> Cap -> CHEAtom
  (** [CHEAssign x y] is the pointer copy [x := y] of the paper's grammar.
      It is a *distinct* atom from [CHEStore] / [CHELoad]: assignment moves a
      capability between two storage slots and is the operation whose
      resealing behaviour is governed by [holder]. *)
  | CHEAssign       : Cap -> Cap -> CHEAtom
  (** [CHEAssert Q] asserts the state predicate [Q].  The argument is a
      predicate over states (not a bare [Prop]) so that the paper's
      side-conditions [P => Q] and [P => ~Q] are entailments between
      assertions, as in Fig. 7 / Fig. 10. *)
  | CHEAssert       : (CHEState -> Prop) -> CHEAtom.

  (** Atom is CHEAtom for the CASL instantiation. *)
  Definition Atom := CHEAtom.

End CASLche_ATOM.

(* ================================================================== *)
(** ** Instantiate the CASL Proof Rules                                *)
(* ================================================================== *)

(** Instantiate the full CASL proof rules with the CHERI PCM and atom type. *)
Module CASLche_Rules := CASLProofRules CASLche_PCM CASLche_ATOM.
Export CASLche_Rules.

(* ================================================================== *)
(** ** State Predicates                                                *)
(* ================================================================== *)

(** Singleton capability predicate: state contains exactly x with value (a, s, tau) and no other cap. *)
Definition cpt (x : Cap) (a : AllocState) (s : SealState) (tau : CompartID)
  : StateSet :=
  fun st =>
    cap_lookup (che_capmap st) x = Some (a, s, tau) /\
    (forall y, y <> x -> cap_lookup (che_capmap st) y = None) /\
    che_compart st = None.

(** State records the current active compartment tau and holds no capabilities. *)
Definition cur_compart (tau : CompartID) : StateSet :=
  fun st =>
    che_capmap st = cap_empty /\
    che_compart st = Some tau.

(** Capability x exists with some value (any alloc/seal/compart); state holds nothing else. *)
Definition cpt_any (x : Cap) : StateSet :=
  fun st =>
    (exists a s tau, cap_lookup (che_capmap st) x = Some (a, s, tau)) /\
    (forall y, y <> x -> cap_lookup (che_capmap st) y = None) /\
    che_compart st = None.

(** Capability x has known alloc status a and compartment tau but any seal state. *)
Definition cpt_alloc_any (x : Cap) (a : AllocState) (tau : CompartID)
  : StateSet :=
  fun st =>
    (exists s, cap_lookup (che_capmap st) x = Some (a, s, tau)) /\
    (forall y, y <> x -> cap_lookup (che_capmap st) y = None) /\
    che_compart st = None.

(** y is uninitialized: unmapped in the CapMap, state holds no other caps either. *)
Definition cap_uninit (y : Cap) : StateSet :=
  fun st =>
    cap_lookup (che_capmap st) y = None /\
    (forall x, x <> y -> cap_lookup (che_capmap st) x = None) /\
    che_compart st = None.

(** The empty CHERI state: empty CapMap and no compartment constraint. *)
Definition che_emp : StateSet :=
  fun st =>
    che_capmap st = cap_empty /\
    che_compart st = None.

(** Pure assertion with empty footprint: holds proposition P while state is empty. *)
Definition che_pure (P : Prop) : StateSet :=
  fun st => P /\ che_emp st.

(** x is present and sealed in the state (any alloc status and compartment). *)
Definition is_sealed (x : Cap) : CHEState -> Prop :=
  fun st => exists a tau, cap_lookup (che_capmap st) x = Some (a, Sealed, tau).

(** x is present and unsealed in the state (any alloc status and compartment). *)
Definition is_unsealed (x : Cap) : CHEState -> Prop :=
  fun st => exists a tau, cap_lookup (che_capmap st) x = Some (a, Unsealed, tau).

(* ================================================================== *)
(** ** Unit Lemmas                                                     *)
(* ================================================================== *)

(** Any state satisfying che_emp is a PCM unit. *)
Lemma che_emp_is_unit : forall s, che_emp s -> CASLche_PCM.is_unit s.
Proof. intros s [Hs Hc]. split; assumption. Qed.

(** There exists a concrete unit satisfying both che_emp and is_unit. *)
Lemma che_emp_unit_exists : exists u, che_emp u /\ CASLche_PCM.is_unit u.
Proof.
  exists (mkCHEState' cap_empty None cms_empty).
  split; (split; reflexivity).
Qed.

(** che_emp is a neutral element for state_sep: composing with emp on the left
    is the identity, pointwise. *)
Lemma state_sep_che_emp : forall p s, state_sep che_emp p s <-> p s.
Proof.
  intros p s. split.
  - apply state_sep_unit_l. exact che_emp_is_unit.
  - apply state_sep_unit_l_rev. exact che_emp_unit_exists.
Qed.

(* ================================================================== *)
(** ** Concrete states, inhabitants, and generic separation lemmas      *)
(*                                                                      *)
(*    Machinery used to reason about the CHERI invariant.  None of it    *)
(*    mentions [holder], so it lives outside the [CHERILogic] functor.   *)
(* ================================================================== *)

(** The empty CHERI state (empty CapMap, no compartment): the PCM unit. *)
Definition st_emp : CHEState := mkCHEState' cap_empty None cms_empty.

(** A state recording only the current compartment [tau] and holding no capabilities. *)
Definition st_cur (tau : CompartID) : CHEState := mkCHEState' cap_empty (Some tau) cms_empty.

(** A state holding exactly one capability cell [x |-> v], with compartment component [oc]. *)
Definition st_cell (x : Cap) (v : CapVal) (oc : option CompartID) : CHEState :=
  mkCHEState' [(x, v)] oc (cms_single x v).

(** Looking up the single cell of [st_cell] returns its value. *)
Lemma st_cell_lookup : forall x v oc,
  cap_lookup (che_capmap (st_cell x v oc)) x = Some v.
Proof. intros. simpl. rewrite Nat.eqb_refl. reflexivity. Qed.

(** [st_emp] is a PCM unit. *)
Lemma st_emp_is_unit : CASLche_PCM.is_unit st_emp.
Proof. split; reflexivity. Qed.

(** Composing on the left with [st_emp] is the identity. *)
Lemma compose_emp_l : forall s, compose st_emp s = Some s.
Proof. intros s. apply unit_compose. exact st_emp_is_unit. Qed.

(** Composing on the right with [st_emp] is the identity. *)
Lemma compose_emp_r : forall s, compose s st_emp = Some s.
Proof. intros s. rewrite compose_comm. apply compose_emp_l. Qed.

(** [st_cell] inhabits the singleton predicate [cpt]. *)
Lemma cpt_inhab : forall x a sl tau, cpt x a sl tau (st_cell x (a, sl, tau) None).
Proof.
  intros. unfold cpt. split; [apply st_cell_lookup | split; [| reflexivity]].
  intros y Hy. simpl. destruct (Nat.eqb y x) eqn:E.
  - apply Nat.eqb_eq in E. congruence.
  - reflexivity.
Qed.

(** [st_cur tau] inhabits [cur_compart tau]. *)
Lemma cur_compart_inhab : forall tau, cur_compart tau (st_cur tau).
Proof. intros. split; reflexivity. Qed.

(** [st_emp] inhabits [cap_uninit y] for every [y]. *)
Lemma cap_uninit_emp : forall y, cap_uninit y st_emp.
Proof. intros. split; [reflexivity | split; [intros; reflexivity | reflexivity]]. Qed.

(** A one-cell state composes with a pure compartment state. *)
Lemma compose_cell_cur : forall x v tau,
  compose (st_cell x v None) (st_cur tau) = Some (st_cell x v (Some tau)).
Proof.
  intros x v tau. unfold compose, CASLche_PCM.compose.
  destruct (disjoint_dec_full (st_cell x v None) (st_cur tau)) as [_|Hn].
  - simpl. f_equal. apply chestate_eq; reflexivity.
  - exfalso. apply Hn. split; simpl.
    + apply disjoint_capmap_empty_r.
    + discriminate.
Qed.

(** Any compartment-free state composes with a pure compartment state,
    leaving its CapMap unchanged. *)
Lemma compose_cur_r : forall st tau,
  che_compart st = None ->
  exists st', compose st (st_cur tau) = Some st' /\ che_capmap st' = che_capmap st.
Proof.
  intros st tau Hc. unfold compose, CASLche_PCM.compose.
  destruct (disjoint_dec_full st (st_cur tau)) as [_|Hn].
  - simpl. rewrite Hc. simpl. eexists. split; [reflexivity|].
    simpl. apply cap_union_empty_r. apply che_sorted.
  - exfalso. apply Hn. split; simpl.
    + apply disjoint_capmap_empty_r.
    + rewrite Hc. simpl. discriminate.
Qed.

(** Inhabitant of [cpt x ... * cur_compart tau2]. *)
Lemma sep_cell_cur_inhab : forall x a sl tau1 tau2,
  state_sep (cpt x a sl tau1) (cur_compart tau2) (st_cell x (a, sl, tau1) (Some tau2)).
Proof.
  intros. exists (st_cell x (a, sl, tau1) None), (st_cur tau2).
  split; [apply cpt_inhab | split; [apply cur_compart_inhab | apply compose_cell_cur]].
Qed.

(** Inhabitant of [cpt x ... * (y = -)]. *)
Lemma sep_cell_uninit_inhab : forall x a sl tau y,
  state_sep (cpt x a sl tau) (cap_uninit y) (st_cell x (a, sl, tau) None).
Proof.
  intros. exists (st_cell x (a, sl, tau) None), st_emp.
  split; [apply cpt_inhab | split; [apply cap_uninit_emp | apply compose_emp_r]].
Qed.

(** Inhabitant of [(x = -) * cpt y ...]. *)
Lemma sep_uninit_cell_inhab : forall x y a sl tau,
  state_sep (cap_uninit x) (cpt y a sl tau) (st_cell y (a, sl, tau) None).
Proof.
  intros. exists st_emp, (st_cell y (a, sl, tau) None).
  split; [apply cap_uninit_emp | split; [apply cpt_inhab | apply compose_emp_l]].
Qed.

(** A state set is compartment-free when none of its states constrains
    [tau_cur] (all the [cpt]-style spatial predicates are). *)
Definition compart_free (P : StateSet) : Prop :=
  forall s, P s -> che_compart s = None.

(** Singleton capability predicates are compartment-free. *)
Lemma compart_free_cpt : forall x a sl tau, compart_free (cpt x a sl tau).
Proof. intros x a sl tau s [_ [_ H]]. exact H. Qed.

(** [cpt_any] is compartment-free. *)
Lemma compart_free_cpt_any : forall x, compart_free (cpt_any x).
Proof. intros x s [_ [_ H]]. exact H. Qed.

(** [cap_uninit] is compartment-free. *)
Lemma compart_free_uninit : forall y, compart_free (cap_uninit y).
Proof. intros y s [_ [_ H]]. exact H. Qed.

(** Compartment-freedom is preserved by separating conjunction. *)
Lemma compart_free_sep : forall P Q,
  compart_free P -> compart_free Q -> compart_free (state_sep P Q).
Proof.
  intros P Q HP HQ s [s1 [s2 [H1 [H2 Hc]]]].
  apply CASLche_PCM.compose_success in Hc.
  destruct Hc as [_ [cm [Hcm [_ Hcp]]]].
  rewrite (HP s1 H1) in Hcm. rewrite (HQ s2 H2) in Hcm.
  simpl in Hcm. rewrite Hcp. congruence.
Qed.

(** Separating conjunction on state sets is associative, pointwise (a generic PCM fact). *)
Lemma state_sep_assoc : forall p q r s,
  state_sep p (state_sep q r) s <-> state_sep (state_sep p q) r s.
Proof.
  intros p q r s. split.
  - intros [s1 [s23 [Hp [[s2 [s3 [Hq [Hr H23]]]] H1_23]]]].
    destruct (compose_assoc_r _ _ _ _ _ H23 H1_23) as [s12 [H12 H12_3]].
    exists s12, s3. split; [exists s1, s2; auto | split; [exact Hr | exact H12_3]].
  - intros [s12 [s3 [[s1 [s2 [Hp [Hq H12]]]] [Hr H12_3]]]].
    destruct (compose_assoc _ _ _ _ _ H12 H12_3) as [s23 [H23 H1_23]].
    exists s1, s23. split; [exact Hp | split; [| exact H1_23]].
    exists s2, s3. split; [exact Hq | split; [exact Hr | exact H23]].
Qed.

(** Separating conjunction on state sets is commutative, pointwise. *)
Lemma state_sep_comm : forall p q s, state_sep p q s <-> state_sep q p s.
Proof.
  intros p q s. split; intros [s1 [s2 [H1 [H2 Hc]]]];
    exists s2, s1; (split; [exact H2 | split; [exact H1 | rewrite compose_comm; exact Hc]]).
Qed.

(** Pointwise equivalence of state sets.  The development reasons up to this
    equivalence instead of rewriting with equations between predicates, which
    would need functional and propositional extensionality. *)
Definition sset_equiv (p q : StateSet) : Prop := forall s, p s <-> q s.

(** [sset_equiv] is reflexive. *)
Lemma sset_equiv_refl : forall p, sset_equiv p p.
Proof. intros p s. reflexivity. Qed.

(** [sset_equiv] is symmetric. *)
Lemma sset_equiv_sym : forall p q, sset_equiv p q -> sset_equiv q p.
Proof. intros p q H s. symmetry. apply H. Qed.

(** [sset_equiv] is transitive. *)
Lemma sset_equiv_trans : forall p q r,
  sset_equiv p q -> sset_equiv q r -> sset_equiv p r.
Proof. intros p q r H1 H2 s. rewrite (H1 s). apply H2. Qed.

(** Separating conjunction respects [sset_equiv] in both arguments. *)
Lemma state_sep_equiv : forall p p' q q',
  sset_equiv p p' -> sset_equiv q q' -> sset_equiv (state_sep p q) (state_sep p' q').
Proof.
  intros p p' q q' Hp Hq s. split; intros [s1 [s2 [H1 [H2 Hc]]]]; exists s1, s2.
  - split; [apply Hp; exact H1 | split; [apply Hq; exact H2 | exact Hc]].
  - split; [apply Hp; exact H1 | split; [apply Hq; exact H2 | exact Hc]].
Qed.

(* ================================================================== *)
(** ** CHERI Function Space (Module Type)                               *)
(* ================================================================== *)

(** Module type for the CHERI function space: classifies cross- and intra-compartment calls,
    and fixes the [holder] metafunction of the paper's invariant. *)
Module Type CHERI_FUNC_SPACE.
  (** F_ext tau f: function f is an external (cross-compartment boundary) function of compartment tau. *)
  Parameter F_ext : CompartID -> FuncID -> Prop.
  (** F_int tau f: function f is an internal (intra-compartment) function of compartment tau. *)
  Parameter F_int : CompartID -> FuncID -> Prop.

  (** [caller f] is the *function* that called [f].  The paper's side condition
      is [caller(f) in F(tau)], i.e. a membership of a function in a
      compartment's function space — hence the result type is [FuncID], not
      [CompartID].  (The previous [caller_compart : FuncID -> CompartID] only
      type-checked against [F_all : CompartID -> FuncID -> Prop] because both
      identifier types are [nat]; see the KNOWN DEFECT note at the top.) *)
  Parameter caller : FuncID -> FuncID.

  (** [holder p] is the owner of the *storage that holds the capability [p]*.

      This is the paper's new metafunction and must not be confused with
      either of the other two compartment notions:
      - [tau_cur]  : the compartment currently executing (one per state,
                     modelled by [cur_compart], changed by [compartenter]);
      - [tau_p]    : the owner of the *object [p] points to* (the third
                     component of a [CapVal]);
      - [holder p] : the owner of the *slot in which the capability [p] lives*.
                     For a field [q.f] this is the owner of the enclosing
                     object [q].  It is static per capability. *)
  Parameter holder : Cap -> CompartID.
End CHERI_FUNC_SPACE.

(* ================================================================== *)
(** ** CHERILogic: Module Functor for CHERI Instantiation of CASL      *)
(*                                                                      *)
(*    The CHERI proof rules of the CompartHeap paper are defined as     *)
(*    inductive types, showing that CASL can be concretely instantiated  *)
(*    for CHERI heap compartmentalization.                               *)
(*                                                                       *)
(*    - [che_axioms]                : Fig. 10 (appendix), the extended   *)
(*                                    *safe* rule set.  Fig. 7 of the    *)
(*                                    body is the sub-set                *)
(*                                    {Alloc, Assert, Assign,            *)
(*                                     Compart-Enter, Call-Unseal,       *)
(*                                     Ret-Seal, Call-Mixed, Ret-Mixed}. *)
(*    - [che_unsafe_axioms]         : Fig. 11, the UNSAFE rule set,      *)
(*                                    kept in a SEPARATE inductive so it *)
(*                                    can never be confused with the     *)
(*                                    safe set.                          *)
(*    - [che_unsafe_assign_axioms]  : a PROPOSED ADDITION, not in the    *)
(*                                    paper -- see its comment.          *)
(* ================================================================== *)

Module CHERILogic (FS : CHERI_FUNC_SPACE).

  Import FS.
  Import CASLche_ATOM.

  (** [F_all tau f] is the paper's [F(tau) = F_int(tau) U F_ext(tau)].
      Defining it (rather than declaring it as a separate parameter) removes
      the possibility of the three function spaces being inconsistent. *)
  Definition F_all (tau : CompartID) (f : FuncID) : Prop :=
    F_int tau f \/ F_ext tau f.

  (** The sealing state produced by the assignment [x := y] when [y] points to
      an object owned by [tau]:
<<
        sigma' = U   if holder(x) = tau
        sigma' = S   otherwise
>>
      This is the side condition of CHERI-Assign.  Note that it is decided by
      [holder x] -- the owner of the slot *receiving* the capability -- and not
      by [tau_cur]. *)
  Definition assign_seal (x : Cap) (tau : CompartID) : SealState :=
    if CompartID_eq_dec (holder x) tau then Unsealed else Sealed.

  (** If the receiving slot belongs to the object's owner, the copy stays unsealed. *)
  Lemma assign_seal_holder : forall x tau,
    holder x = tau -> assign_seal x tau = Unsealed.
  Proof.
    intros x tau H. unfold assign_seal.
    destruct (CompartID_eq_dec (holder x) tau); congruence.
  Qed.

  (** If the receiving slot belongs to a different compartment, the copy is sealed. *)
  Lemma assign_seal_not_holder : forall x tau,
    holder x <> tau -> assign_seal x tau = Sealed.
  Proof.
    intros x tau H. unfold assign_seal.
    destruct (CompartID_eq_dec (holder x) tau); congruence.
  Qed.

  (* ---------------------------------------------------------------- *)
  (** *** The safe rule set (Fig. 10 of the appendix)                   *)
  (* ---------------------------------------------------------------- *)

  (** The CHERI safe axioms.  Every constructor is a verbatim transcription of
      a rule of Fig. 10; the correspondence is noted rule by rule.  CASL-Frame
      is *not* here: it is inherited from CASL ([RFrame] in CASL_ProofRules.v). *)
  Inductive che_axioms : StateSet -> Atom -> Tag -> StateSet -> Prop :=

  (** CHERI-Alloc:
<<
      [x |-> (F,U,tau) /\ tau_cur = tau] x = alloc(sz) [ok: x |-> (A,U,tau) /\ tau_cur = tau]
>> *)
  | CHE_Alloc : forall (x : Cap) (sz : nat) (tau : CompartID),
      che_axioms
        (state_sep (cpt x Freed Unsealed tau) (cur_compart tau))
        (CHEAlloc x sz) Ok
        (state_sep (cpt x Allocated Unsealed tau) (cur_compart tau))

  (** CHERI-Free:
<<
      [x |-> (A,U,tau)] free(x) [ok: x |-> (F,U,tau)]
>>
      The paper no longer requires [tau_cur = tau] here (an earlier version
      did), so the [cur_compart] conjunct is gone. *)
  | CHE_Free : forall (x : Cap) (tau : CompartID),
      che_axioms
        (cpt x Allocated Unsealed tau)
        (CHEFree x) Ok
        (cpt x Freed Unsealed tau)

  (** CHERI-Load:
<<
      holder(y) = tau
      -------------------------------------------------------------------
      [x |-> (A,U,tau) * y = -] y = *x [ok: x |-> (A,U,tau) * y |-> (A,U,tau)]
>> *)
  | CHE_Load : forall (x y : Cap) (tau : CompartID),
      holder y = tau ->
      che_axioms
        (state_sep (cpt x Allocated Unsealed tau) (cap_uninit y))
        (CHELoad y x) Ok
        (state_sep (cpt x Allocated Unsealed tau) (cpt y Allocated Unsealed tau))

  (** CHERI-Store:
<<
      [x |-> (A,U,tau1) * y |-> (A,-,tau2)] *x = y [ok: x |-> (A,U,tau1) * y |-> (A,-,tau2)]
>>
      The paper made this an identity: the store does not rewrite [x]'s owner
      (an earlier version overwrote it with [tau2]). *)
  | CHE_Store : forall (x y : Cap) (tau1 tau2 : CompartID),
      che_axioms
        (state_sep (cpt x Allocated Unsealed tau1) (cpt_alloc_any y Allocated tau2))
        (CHEStore x y) Ok
        (state_sep (cpt x Allocated Unsealed tau1) (cpt_alloc_any y Allocated tau2))

  (** CHERI-Assign (new; the workhorse rule):
<<
      sigma' = U if holder(x) = tau else S
      ---------------------------------------------------------------------------
      [x = - * y |-> (A,sigma,tau)] x := y [ok: x |-> (A,sigma',tau) * y |-> (A,sigma,tau)]
>> *)
  | CHE_Assign : forall (x y : Cap) (sigma : SealState) (tau : CompartID),
      che_axioms
        (state_sep (cap_uninit x) (cpt y Allocated sigma tau))
        (CHEAssign x y) Ok
        (state_sep (cpt x Allocated (assign_seal x tau) tau)
                   (cpt y Allocated sigma tau))

  (** CHERI-Assert:
<<
      P => Q
      -----------------------
      [P] assert Q [ok: P]
>> *)
  | CHE_Assert : forall (P Q : StateSet),
      sset_subset P Q ->
      che_axioms P (CHEAssert Q) Ok P

  (** CHERI-Assert-Fail:
<<
      P => ~Q
      -----------------------
      [P] assert Q [er: P]
>> *)
  | CHE_AssertFailed : forall (P Q : StateSet),
      sset_subset P (fun s => ~ Q s) ->
      che_axioms P (CHEAssert Q) (Err 1) P

  (** CHERI-Load-Fail: dereferencing a sealed capability from a compartment
      that does not own it.
<<
      [x |-> (A,S,tau1) * y = - /\ tau_cur = tau2] y = *x
        [er: x |-> (A,S,tau1) * y = - /\ tau_cur = tau2]
>> *)
  | CHE_LoadFail : forall (x y : Cap) (tau1 tau2 : CompartID),
      che_axioms
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cap_uninit y) (cur_compart tau2)))
        (CHELoad y x) (Err 2)
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cap_uninit y) (cur_compart tau2)))

  (** CHERI-Store-Fail: storing through a sealed capability from a compartment
      that does not own it.
<<
      [x |-> (A,S,tau1) * y = - /\ tau_cur = tau2] *x = y
        [er: x |-> (A,S,tau1) * y = - /\ tau_cur = tau2]
>> *)
  | CHE_StoreFail : forall (x y : Cap) (tau1 tau2 : CompartID),
      che_axioms
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cap_uninit y) (cur_compart tau2)))
        (CHEStore x y) (Err 3)
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cap_uninit y) (cur_compart tau2)))

  (** CHERI-Compart-Enter:
<<
      [tau_cur = tau1] compartenter tau2 [ok: tau_cur = tau2]
>> *)
  | CHE_CompartEnter : forall (tau1 tau2 : CompartID),
      che_axioms (cur_compart tau1) (CHECompartEnter tau2) Ok (cur_compart tau2)

  (** CHERI-Call-Seal:
<<
      f in F_ext(tau2)
      ----------------------------------------------------------------
      [x |-> (A,U,tau1) /\ tau_cur = tau1] f(x) [ok: x |-> (A,S,tau1) /\ tau_cur = tau2]
>>
      No [holder] premise is needed: the postcondition's cell is Sealed. *)
  | CHE_CallSeal : forall (f : FuncID) (x : Cap) (tau1 tau2 : CompartID),
      F_ext tau2 f ->
      che_axioms
        (state_sep (cpt x Allocated Unsealed tau1) (cur_compart tau1))
        (CHECall x) Ok
        (state_sep (cpt x Allocated Sealed tau1) (cur_compart tau2))

  (** CHERI-Call-Unseal:
<<
      f in F_ext(tau2)    holder(x) = tau2
      ----------------------------------------------------------------
      [x |-> (A,S,tau2) /\ tau_cur = tau1] f(x) [ok: x |-> (A,U,tau2) /\ tau_cur = tau2]
>> *)
  | CHE_CallUnseal : forall (f : FuncID) (x : Cap) (tau1 tau2 : CompartID),
      F_ext tau2 f ->
      holder x = tau2 ->
      che_axioms
        (state_sep (cpt x Allocated Sealed tau2) (cur_compart tau1))
        (CHECall x) Ok
        (state_sep (cpt x Allocated Unsealed tau2) (cur_compart tau2))

  (** CHERI-IndCall-Seal:
<<
      f in F_ext(tau2)
      -----------------------------------------------------------------------
      [fc |-> (A,S,tau2) * x |-> (A,U,tau1) /\ tau_cur = tau1] ( *f )(x)
        [ok: fc |-> (A,S,tau2) * x |-> (A,S,tau1) /\ tau_cur = tau2]
>> *)
  | CHE_IndCallSeal :
      forall (fc x : Cap) (tau1 tau2 : CompartID) (f : FuncID),
      F_ext tau2 f ->
      che_axioms
        (state_sep (cpt fc Allocated Sealed tau2)
          (state_sep (cpt x Allocated Unsealed tau1) (cur_compart tau1)))
        (CHEIndCall x) Ok
        (state_sep (cpt fc Allocated Sealed tau2)
          (state_sep (cpt x Allocated Sealed tau1) (cur_compart tau2)))

  (** CHERI-IndCall-Unseal:
<<
      f in F_ext(tau2)    holder(x) = tau2
      -------------------------------------------------------------------
      [x |-> (A,S,tau2) /\ tau_cur = tau1] ( *f )(x) [ok: x |-> (A,U,tau2) /\ tau_cur = tau2]
>> *)
  | CHE_IndCallUnseal :
      forall (x : Cap) (tau1 tau2 : CompartID) (f : FuncID),
      F_ext tau2 f ->
      holder x = tau2 ->
      che_axioms
        (state_sep (cpt x Allocated Sealed tau2) (cur_compart tau1))
        (CHEIndCall x) Ok
        (state_sep (cpt x Allocated Unsealed tau2) (cur_compart tau2))

  (** CHERI-Call-Mixed:
<<
      f in F_ext(tau2)    holder(y) = tau2
      -------------------------------------------------------------------------
      [x |-> (A,U,tau1) * y |-> (A,S,tau2) /\ tau_cur = tau1] f(x,y)
        [ok: x |-> (A,S,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau2]
>> *)
  | CHE_CallMixed :
      forall (f : FuncID) (x y : Cap) (tau1 tau2 : CompartID),
      F_ext tau2 f ->
      holder y = tau2 ->
      che_axioms
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Sealed tau2) (cur_compart tau1)))
        (CHECallPair x y) Ok
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau2)))

  (** CHERI-Ret-Mixed:
<<
      f in F_ext(tau2)    caller(f) in F(tau1)    holder(x) = tau1
      -------------------------------------------------------------------------
      [x |-> (A,S,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau2] return_f(x,y)
        [ok: x |-> (A,U,tau1) * y |-> (A,S,tau2) /\ tau_cur = tau1]
>>
      Both the [caller(f) in F(tau1)] premise and the [holder(x) = tau1]
      premise were missing from the previous mechanization. *)
  | CHE_RetMixed :
      forall (f : FuncID) (x y : Cap) (tau1 tau2 : CompartID),
      F_ext tau2 f ->
      F_all tau1 (caller f) ->
      holder x = tau1 ->
      che_axioms
        (state_sep (cpt x Allocated Sealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau2)))
        (CHERetPair x y) Ok
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Sealed tau2) (cur_compart tau1)))

  (** CHERI-Call-NoSeal (intra-compartment call: nothing is (un)sealed):
<<
      f in F_int(tau)
      ---------------------------------------------------------
      [x |-> - /\ tau_cur = tau] f(x) [ok: x |-> - /\ tau_cur = tau]
>> *)
  | CHE_CallNoSeal :
      forall (f : FuncID) (x : Cap) (tau : CompartID),
      F_int tau f ->
      che_axioms
        (state_sep (cpt_any x) (cur_compart tau))
        (CHECall x) Ok
        (state_sep (cpt_any x) (cur_compart tau))

  (** CHERI-Ret-NoSeal:
<<
      f in F_int(tau)
      -------------------------------------------------
      [x |-> (A,-,tau)] return_f(x) [ok: x |-> (A,-,tau)]
>> *)
  | CHE_RetNoSeal :
      forall (f : FuncID) (x : Cap) (tau : CompartID),
      F_int tau f ->
      che_axioms
        (cpt_alloc_any x Allocated tau)
        (CHERet x) Ok
        (cpt_alloc_any x Allocated tau)

  (** CHERI-Ret-Seal:
<<
      f in F_ext(tau1)    caller(f) in F(tau2)
      -----------------------------------------------------------------------
      [x |-> (A,U,tau1) /\ tau_cur = tau1] return_f(x)
        [ok: x |-> (A,S,tau1) /\ tau_cur = tau2]
>> *)
  | CHE_RetSeal :
      forall (f : FuncID) (x : Cap) (tau1 tau2 : CompartID),
      F_ext tau1 f ->
      F_all tau2 (caller f) ->
      che_axioms
        (state_sep (cpt x Allocated Unsealed tau1) (cur_compart tau1))
        (CHERet x) Ok
        (state_sep (cpt x Allocated Sealed tau1) (cur_compart tau2))

  (** CHERI-Ret-Unseal:
<<
      f in F_ext(tau1)    caller(f) in F(tau2)    holder(x) = tau2
      -----------------------------------------------------------------------
      [x |-> (A,S,tau2) /\ tau_cur = tau1] return_f(x)
        [ok: x |-> (A,U,tau2) /\ tau_cur = tau2]
>>
      HISTORY.  An earlier revision of Fig. 10 omitted the [holder(x) = tau2]
      premise that this rule's siblings CHERI-Call-Unseal and
      CHERI-IndCall-Unseal both carry.  Without it this was the one safe rule
      that did *not* preserve INV -- it produced an unsealed cell with nothing
      pinning its holder to its owner.  The premise is now present in the
      paper, and with it all twenty rules of Fig. 10 preserve INV
      unconditionally; see [che_axioms_preserve_INV]. *)
  | CHE_RetUnseal :
      forall (f : FuncID) (x : Cap) (tau1 tau2 : CompartID),
      F_ext tau1 f ->
      F_all tau2 (caller f) ->
      holder x = tau2 ->
      che_axioms
        (state_sep (cpt x Allocated Sealed tau2) (cur_compart tau1))
        (CHERet x) Ok
        (state_sep (cpt x Allocated Unsealed tau2) (cur_compart tau2)).

  (* ---------------------------------------------------------------- *)
  (** *** The UNSAFE rule set (Fig. 11 of the appendix)                 *)
  (* ---------------------------------------------------------------- *)

  (** The four UNSAFE rules of Fig. 11.  They are kept in a separate inductive
      from [che_axioms] so that a derivation cannot silently mix them with the
      safe rules.  These rules model call/return boundaries that fail to seal
      or unseal the capabilities they pass. *)
  Inductive che_unsafe_axioms : StateSet -> Atom -> Tag -> StateSet -> Prop :=

  (** UNSAFE-Call-NoSeal:
<<
      f in F(tau2)
      ---------------------------------------------------------------
      [x |-> (A,U,-) /\ tau_cur = tau1] f(x) [ok: x |-> (A,U,-) /\ tau_cur = tau2]
>>
      The [-] in the owner position is a wildcard, hence the extra [tau]. *)
  | UNSAFE_CallNoSeal :
      forall (f : FuncID) (x : Cap) (tau tau1 tau2 : CompartID),
      F_all tau2 f ->
      che_unsafe_axioms
        (state_sep (cpt x Allocated Unsealed tau) (cur_compart tau1))
        (CHECall x) Ok
        (state_sep (cpt x Allocated Unsealed tau) (cur_compart tau2))

  (** UNSAFE-Ret-NoSeal:
<<
      f in F(tau1)
      -------------------------------------------------------------------------
      [x |-> (A,U,tau2) /\ tau_cur = tau2] return_f(x)
        [ok: x |-> (A,U,tau2) /\ tau_cur = tau1]
>> *)
  | UNSAFE_RetNoSeal :
      forall (f : FuncID) (x : Cap) (tau1 tau2 : CompartID),
      F_all tau1 f ->
      che_unsafe_axioms
        (state_sep (cpt x Allocated Unsealed tau2) (cur_compart tau2))
        (CHERet x) Ok
        (state_sep (cpt x Allocated Unsealed tau2) (cur_compart tau1))

  (** UNSAFE-Call-Two-NoSeal:
<<
      f in F(tau2)
      -------------------------------------------------------------------------
      [x |-> (A,U,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau1] f(x,y)
        [ok: x |-> (A,U,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau2]
>> *)
  | UNSAFE_CallTwoNoSeal :
      forall (f : FuncID) (x y : Cap) (tau1 tau2 : CompartID),
      F_all tau2 f ->
      che_unsafe_axioms
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau1)))
        (CHECallPair x y) Ok
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau2)))

  (** UNSAFE-Ret-Two-NoSeal:
<<
      f in F(tau1)
      -------------------------------------------------------------------------
      [x |-> (A,U,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau2] return_f(x,y)
        [ok: x |-> (A,U,tau1) * y |-> (A,U,tau2) /\ tau_cur = tau1]
>> *)
  | UNSAFE_RetTwoNoSeal :
      forall (f : FuncID) (x y : Cap) (tau1 tau2 : CompartID),
      F_all tau1 f ->
      che_unsafe_axioms
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau2)))
        (CHERetPair x y) Ok
        (state_sep (cpt x Allocated Unsealed tau1)
          (state_sep (cpt y Allocated Unsealed tau2) (cur_compart tau1))).

  (** *** UNSAFE-Assign (Fig. 11).

      Why this rule has to exist.  The four Call/Return rules above never
      change any cell's (seal state, owner) pair -- they only move [tau_cur] --
      and INV does not mention [tau_cur], so all four trivially preserve INV
      (see [che_unsafe_axioms_preserve_INV]).  On their own they therefore
      cannot drive an INV-satisfying state to an INV-violating one, and the
      error derivation of Fig. 12 does not go through: its [Assign] steps,
      annotated with the safe CHERI-Assign, would have their [holder] side
      condition seal exactly the cells Fig. 12 needs unsealed.

      This rule supplies the missing ingredient: a plain capability copy that
      propagates [sigma] verbatim instead of re-deriving it from [holder(x)].
      It is a faithful model of the implementation bug -- failing to seal at a
      compartment boundary -- and it is what makes Fig. 12 a genuine witness.

      PROVENANCE.  This constructor was originally added here as a proposed
      addition, flagged as absent from the paper.  The paper has since adopted
      it: UNSAFE-Assign now appears in Fig. 11, and Fig. 12's three assignment
      steps are annotated [UnsafeAssign] rather than [Assign].  It is part of
      the paper and the flag has been removed accordingly. *)
  Inductive che_unsafe_assign_axioms : StateSet -> Atom -> Tag -> StateSet -> Prop :=
  | UNSAFE_Assign : forall (x y : Cap) (sigma : SealState) (tau : CompartID),
      che_unsafe_assign_axioms
        (state_sep (cap_uninit x) (cpt y Allocated sigma tau))
        (CHEAssign x y) Ok
        (state_sep (cpt x Allocated sigma tau) (cpt y Allocated sigma tau)).

  (** The axiom set used for the error derivation of Fig. 12: the safe rules
      (for [alloc] and [assert]) together with the UNSAFE rules and the
      proposed UNSAFE-Assign. *)
  Definition che_error_axioms : StateSet -> Atom -> Tag -> StateSet -> Prop :=
    fun p a tg q =>
      che_axioms p a tg q \/
      che_unsafe_axioms p a tg q \/
      che_unsafe_assign_axioms p a tg q.

  (* ---------------------------------------------------------------- *)
  (** *** The pointer invariant INV                                     *)
  (* ---------------------------------------------------------------- *)

  (** The invariant of Fig. 7 / Fig. 10:
<<
        INV  ==  forall p x tau_p. p |-> (-, x, tau_p) /\ holder(p) <> tau_p => x = S
>>
      "Any pointer shared out of its originating compartment to a holder
      compartment must be sealed."

      Note the wildcard in the first (allocation-state) component: INV
      constrains Freed cells exactly as it constrains Allocated ones.  This is
      what makes CHERI-Alloc INV-preserving, since the freed cell in its
      precondition already pins down [holder x]. *)
  Definition INV_state (st : CHEState) : Prop :=
    forall (p : Cap) (al : AllocState) (sl : SealState) (tau_p : CompartID),
      cap_lookup (che_capmap st) p = Some (al, sl, tau_p) ->
      holder p <> tau_p ->
      sl = Sealed.

  (** INV viewed as a state set, so it can be the argument of [CHEAssert]. *)
  Definition INV_set : StateSet := INV_state.

  (** A state set satisfies INV when all of its states do. *)
  Definition INV_holds (P : StateSet) : Prop := forall st, P st -> INV_state st.

  (** The empty state holds no cells, so INV is vacuous. *)
  Lemma INV_che_emp : INV_holds che_emp.
  Proof.
    intros st [Hm _] p al sl t Hlu _.
    rewrite Hm in Hlu. simpl in Hlu. discriminate.
  Qed.

  (** INV is a pointwise condition on cells, hence it distributes over [*]. *)
  Lemma INV_sep : forall P Q,
    INV_holds P -> INV_holds Q -> INV_holds (state_sep P Q).
  Proof.
    intros P Q HP HQ st [s1 [s2 [H1 [H2 Hc]]]].
    apply CASLche_PCM.compose_success in Hc.
    destruct Hc as [_ [cm [_ [Hmap _]]]].
    intros p al sl tau Hlu Hne.
    rewrite Hmap in Hlu. rewrite cap_union_lookup in Hlu.
    destruct (cap_lookup (che_capmap s1) p) eqn:E1.
    - injection Hlu as Hlu. subst c.
      exact (HP s1 H1 p al sl tau E1 Hne).
    - exact (HQ s2 H2 p al sl tau Hlu Hne).
  Qed.

  (** A pure compartment assertion holds no cells, so INV is vacuous. *)
  Lemma INV_cur_compart : forall tau, INV_holds (cur_compart tau).
  Proof.
    intros tau st [Hm _] p al sl t Hlu _.
    rewrite Hm in Hlu. simpl in Hlu. discriminate.
  Qed.

  (** An uninitialised slot holds no cells, so INV is vacuous. *)
  Lemma INV_cap_uninit : forall y, INV_holds (cap_uninit y).
  Proof.
    intros y st [Hy [Hother _]] p al sl t Hlu _.
    destruct (Nat.eq_dec p y) as [->|Hpy].
    - rewrite Hy in Hlu. discriminate.
    - rewrite (Hother p Hpy) in Hlu. discriminate.
  Qed.

  (** A sealed cell satisfies INV whatever its holder. *)
  Lemma INV_cpt_sealed : forall x a tau, INV_holds (cpt x a Sealed tau).
  Proof.
    intros x a tau st [Hx [Hother _]] p al sl t Hlu _.
    destruct (Nat.eq_dec p x) as [->|Hpx].
    - rewrite Hx in Hlu. injection Hlu as _ Hs _. congruence.
    - rewrite (Hother p Hpx) in Hlu. discriminate.
  Qed.

  (** A cell held by its own owner satisfies INV whatever its seal state. *)
  Lemma INV_cpt_holder : forall x a sl tau,
    holder x = tau -> INV_holds (cpt x a sl tau).
  Proof.
    intros x a sl tau Hh st [Hx [Hother _]] p al sl' t Hlu Hne.
    destruct (Nat.eq_dec p x) as [->|Hpx].
    - rewrite Hx in Hlu. injection Hlu as _ _ Ht. exfalso. congruence.
    - rewrite (Hother p Hpx) in Hlu. discriminate.
  Qed.

  (** INV never mentions [tau_cur], so for a compartment-free [P] the truth of
      INV for [P * (tau_cur = t)] does not depend on [t]. *)
  Lemma INV_cur_irrelevant : forall (P : StateSet) t1 t2,
    compart_free P ->
    INV_holds (state_sep P (cur_compart t1)) ->
    INV_holds (state_sep P (cur_compart t2)).
  Proof.
    intros P t1 t2 Hcf H st [s1 [s2 [H1 [H2 Hc]]]].
    apply CASLche_PCM.compose_success in Hc.
    destruct Hc as [_ [cm [_ [Hmap _]]]].
    destruct H2 as [Hm2 _].
    destruct (compose_cur_r s1 t1 (Hcf s1 H1)) as [st' [Hc' Hmap']].
    assert (Hst' : state_sep P (cur_compart t1) st').
    { exists s1, (st_cur t1).
      split; [exact H1 | split; [apply cur_compart_inhab | exact Hc']]. }
    specialize (H st' Hst').
    intros p al sl tau Hlu Hne.
    rewrite Hmap in Hlu. rewrite cap_union_lookup in Hlu. rewrite Hm2 in Hlu.
    destruct (cap_lookup (che_capmap s1) p) eqn:E1.
    - injection Hlu as Hlu. subst c.
      apply (H p al sl tau); [rewrite Hmap'; exact E1 | exact Hne].
    - simpl in Hlu. discriminate.
  Qed.

  (** *** Extracting [holder] facts from an INV precondition.

      Each of these says: if a precondition asserts an *unsealed* cell
      [x |-> (a,U,tau)] and that precondition satisfies INV, then [holder x]
      must be [tau] -- otherwise INV would force the cell to be sealed.  These
      are exactly the arguments that make CHERI-Alloc, CHERI-Free, CHERI-Load
      and CHERI-Assign INV-preserving without extra premises. *)

  (** From [x |-> (a,U,tau1) /\ tau_cur = tau2]. *)
  Lemma INV_forces_holder_cur : forall x al tau1 tau2,
    INV_holds (state_sep (cpt x al Unsealed tau1) (cur_compart tau2)) ->
    holder x = tau1.
  Proof.
    intros x al tau1 tau2 H.
    destruct (CompartID_eq_dec (holder x) tau1) as [He|Hne]; [exact He|].
    exfalso.
    specialize (H _ (sep_cell_cur_inhab x al Unsealed tau1 tau2)).
    specialize (H x al Unsealed tau1 (st_cell_lookup _ _ _) Hne). discriminate.
  Qed.

  (** From a bare [x |-> (a,U,tau)]. *)
  Lemma INV_forces_holder_plain : forall x al tau,
    INV_holds (cpt x al Unsealed tau) -> holder x = tau.
  Proof.
    intros x al tau H.
    destruct (CompartID_eq_dec (holder x) tau) as [He|Hne]; [exact He|].
    exfalso.
    specialize (H _ (cpt_inhab x al Unsealed tau)).
    specialize (H x al Unsealed tau (st_cell_lookup _ _ _) Hne). discriminate.
  Qed.

  (** From [x |-> (a,U,tau) * y = -]. *)
  Lemma INV_forces_holder_uninit_r : forall x al tau y,
    INV_holds (state_sep (cpt x al Unsealed tau) (cap_uninit y)) ->
    holder x = tau.
  Proof.
    intros x al tau y H.
    destruct (CompartID_eq_dec (holder x) tau) as [He|Hne]; [exact He|].
    exfalso.
    specialize (H _ (sep_cell_uninit_inhab x al Unsealed tau y)).
    specialize (H x al Unsealed tau (st_cell_lookup _ _ _) Hne). discriminate.
  Qed.

  (** From [x = - * y |-> (a,U,tau)]. *)
  Lemma INV_forces_holder_uninit_l : forall x y al tau,
    INV_holds (state_sep (cap_uninit x) (cpt y al Unsealed tau)) ->
    holder y = tau.
  Proof.
    intros x y al tau H.
    destruct (CompartID_eq_dec (holder y) tau) as [He|Hne]; [exact He|].
    exfalso.
    specialize (H _ (sep_uninit_cell_inhab x y al Unsealed tau)).
    specialize (H y al Unsealed tau (st_cell_lookup _ _ _) Hne). discriminate.
  Qed.

  (* ---------------------------------------------------------------- *)
  (** *** INV preservation                                              *)
  (* ---------------------------------------------------------------- *)

  (** MAIN RESULT.  Every rule of Fig. 10 takes INV-satisfying preconditions to
      INV-satisfying postconditions.  Unconditionally: there is no excluded
      rule and no side hypothesis.

      The proof is one case per rule.  In each case either
      (i)  the postcondition is syntactically the precondition (Store, Assert,
           Assert-Fail, Load-Fail, Store-Fail, Call-NoSeal, Ret-NoSeal); or
      (ii) every cell it produces is Sealed (Call-Seal, IndCall-Seal, Ret-Seal,
           and the sealed halves of Call-Mixed / Ret-Mixed); or
      (iii) the unsealed cell it produces is justified by an explicit [holder]
           premise (Load, Call-Unseal, IndCall-Unseal, Call-Mixed, Ret-Mixed,
           Ret-Unseal); or
      (iv) the unsealed cell it produces already appears, unsealed and with the
           same owner, in the precondition, so INV on the precondition pins
           down its holder (Alloc, Free, Load's [x], Assign's [y]); or
      (v)  the seal state is computed from [holder] by [assign_seal] (Assign's
           [x]).

      Case (iii) is the whole content of the theorem: each [holder] premise is
      exactly the preservation argument for that rule's unsealed output cell.
      An earlier revision of the paper omitted the premise on Ret-Unseal, and
      this theorem then held only with that rule excluded by hypothesis -- the
      omission was found by attempting this induction and watching the case
      fail, not by reading the figure. *)
  Theorem che_axioms_preserve_INV :
    forall p a tg q,
      che_axioms p a tg q ->
      INV_holds p -> INV_holds q.
  Proof.
    intros p a tg q H HP.
    destruct H as
      [ x sz tau                          (* Alloc *)
      | x tau                             (* Free *)
      | x y tau Hhy                       (* Load *)
      | x y tau1 tau2                     (* Store *)
      | x y sigma tau                     (* Assign *)
      | P Q Hpq                           (* Assert *)
      | P Q Hpq                           (* AssertFailed *)
      | x y tau1 tau2                     (* LoadFail *)
      | x y tau1 tau2                     (* StoreFail *)
      | tau1 tau2                         (* CompartEnter *)
      | f x tau1 tau2 Hf                  (* CallSeal *)
      | f x tau1 tau2 Hf Hh               (* CallUnseal *)
      | fc x tau1 tau2 f Hf               (* IndCallSeal *)
      | x tau1 tau2 f Hf Hh               (* IndCallUnseal *)
      | f x y tau1 tau2 Hf Hh             (* CallMixed *)
      | f x y tau1 tau2 Hf Hc Hh          (* RetMixed *)
      | f x tau Hf                        (* CallNoSeal *)
      | f x tau Hf                        (* RetNoSeal *)
      | f x tau1 tau2 Hf Hc               (* RetSeal *)
      | f x tau1 tau2 Hf Hc Hh            (* RetUnseal *) ].

    - (* CHERI-Alloc: the freed cell in the precondition pins down holder x. *)
      assert (Hh : holder x = tau) by exact (INV_forces_holder_cur x Freed tau tau HP).
      apply INV_sep; [apply INV_cpt_holder; exact Hh | apply INV_cur_compart].

    - (* CHERI-Free *)
      assert (Hh : holder x = tau) by exact (INV_forces_holder_plain x Allocated tau HP).
      apply INV_cpt_holder; exact Hh.

    - (* CHERI-Load: holder x from the precondition, holder y from the premise. *)
      assert (Hh : holder x = tau) by exact (INV_forces_holder_uninit_r x Allocated tau y HP).
      apply INV_sep; apply INV_cpt_holder; assumption.

    - (* CHERI-Store: identity *)
      exact HP.

    - (* CHERI-Assign *)
      apply INV_sep.
      + destruct (CompartID_eq_dec (holder x) tau) as [He|Hne].
        * rewrite (assign_seal_holder x tau He). apply INV_cpt_holder; exact He.
        * rewrite (assign_seal_not_holder x tau Hne). apply INV_cpt_sealed.
      + destruct sigma.
        * apply INV_cpt_sealed.
        * apply INV_cpt_holder.
          exact (INV_forces_holder_uninit_l x y Allocated tau HP).

    - (* CHERI-Assert: identity *)      exact HP.
    - (* CHERI-Assert-Fail: identity *) exact HP.
    - (* CHERI-Load-Fail: identity *)   exact HP.
    - (* CHERI-Store-Fail: identity *)  exact HP.

    - (* CHERI-Compart-Enter *)
      apply INV_cur_compart.

    - (* CHERI-Call-Seal: output cell is Sealed *)
      apply INV_sep; [apply INV_cpt_sealed | apply INV_cur_compart].

    - (* CHERI-Call-Unseal: holder premise *)
      apply INV_sep; [apply INV_cpt_holder; exact Hh | apply INV_cur_compart].

    - (* CHERI-IndCall-Seal: both output cells Sealed *)
      apply INV_sep; [apply INV_cpt_sealed |].
      apply INV_sep; [apply INV_cpt_sealed | apply INV_cur_compart].

    - (* CHERI-IndCall-Unseal: holder premise *)
      apply INV_sep; [apply INV_cpt_holder; exact Hh | apply INV_cur_compart].

    - (* CHERI-Call-Mixed: x becomes Sealed, y is justified by holder(y) = tau2 *)
      apply INV_sep; [apply INV_cpt_sealed |].
      apply INV_sep; [apply INV_cpt_holder; exact Hh | apply INV_cur_compart].

    - (* CHERI-Ret-Mixed: x is justified by holder(x) = tau1, y becomes Sealed *)
      apply INV_sep; [apply INV_cpt_holder; exact Hh |].
      apply INV_sep; [apply INV_cpt_sealed | apply INV_cur_compart].

    - (* CHERI-Call-NoSeal: identity *) exact HP.
    - (* CHERI-Ret-NoSeal: identity *)  exact HP.

    - (* CHERI-Ret-Seal: output cell is Sealed *)
      apply INV_sep; [apply INV_cpt_sealed | apply INV_cur_compart].

    - (* CHERI-Ret-Unseal: holder premise -- the case that used to fail *)
      apply INV_sep; [apply INV_cpt_holder; exact Hh | apply INV_cur_compart].
  Qed.

  (** All four UNSAFE rules of Fig. 11 leave every capability cell untouched:
      they change only [tau_cur].  Since INV does not mention [tau_cur], they
      all preserve INV.  This is a NEGATIVE result about the paper's error
      example: the printed Fig. 11 rule set cannot, on its own, drive an
      INV-satisfying state to an INV-violating one. *)
  Theorem che_unsafe_axioms_preserve_INV :
    forall p a tg q, che_unsafe_axioms p a tg q -> INV_holds p -> INV_holds q.
  Proof.
    intros p a tg q H HP.
    destruct H as
      [ f x tau tau1 tau2 Hf
      | f x tau1 tau2 Hf
      | f x y tau1 tau2 Hf
      | f x y tau1 tau2 Hf ].
    - apply (INV_cur_irrelevant _ tau1 tau2); [apply compart_free_cpt | exact HP].
    - apply (INV_cur_irrelevant _ tau2 tau1); [apply compart_free_cpt | exact HP].
    - intros st Hst. apply (proj1 (state_sep_assoc _ _ _ st)) in Hst. revert st Hst.
      apply (INV_cur_irrelevant _ tau1 tau2).
      + apply compart_free_sep; apply compart_free_cpt.
      + intros st Hst. apply HP. apply (proj2 (state_sep_assoc _ _ _ st)). exact Hst.
    - intros st Hst. apply (proj1 (state_sep_assoc _ _ _ st)) in Hst. revert st Hst.
      apply (INV_cur_irrelevant _ tau2 tau1).
      + apply compart_free_sep; apply compart_free_cpt.
      + intros st Hst. apply HP. apply (proj2 (state_sep_assoc _ _ _ st)). exact Hst.
  Qed.

End CHERILogic.

(* ================================================================== *)
(** ** Proof Example: nginx-OpenSSL Cross-Compartment Allocation        *)
(* ================================================================== *)

(** *** Compartments *)

(** Compartment ID for the nginx compartment. *)
Definition tau_ngx : CompartID := 0.
(** Compartment ID for the OpenSSL compartment. *)
Definition tau_ssl : CompartID := 1.

(** nginx and OpenSSL are different compartments. *)
Lemma tau_ngx_neq_ssl : tau_ngx <> tau_ssl.
Proof. unfold tau_ngx, tau_ssl. discriminate. Qed.

(** *** Capabilities

    The paper distinguishes the caller's and the callee's capability to the
    *same* object by name: nginx's [conn] vs OpenSSL's [s], and nginx's [c] vs
    OpenSSL's [data].  They are modelled as distinct [Cap] values that share an
    owner but differ in [holder].  Likewise the argument [ctx] of [SSL_new] and
    the callee's parameter [ct] are distinct capabilities: [ct] is bound to
    [ctx] by an assignment when [SSL_new] is entered. *)

(** nginx's connection object [ngx_connection_t *c]; nginx-held, nginx-owned. *)
Definition cap_c       : Cap := 0.
(** The SSL context argument slot; OpenSSL-held, OpenSSL-owned. *)
Definition cap_ctx     : Cap := 1.
(** nginx's handle on the SSL object ([conn]); nginx-held, OpenSSL-owned. *)
Definition cap_conn    : Cap := 2.
(** OpenSSL's own pointer to the SSL object ([s]); OpenSSL-held, OpenSSL-owned. *)
Definition cap_s       : Cap := 3.
(** The field [s.ex_data]; held by the OpenSSL-owned object [s]. *)
Definition cap_sexdata : Cap := 4.
(** OpenSSL's handle on nginx's connection ([data]); OpenSSL-held, nginx-owned. *)
Definition cap_data    : Cap := 5.
(** [SSL_new]'s parameter [ct], bound to the argument [ctx] on entry;
    OpenSSL-held, OpenSSL-owned. *)
Definition cap_ct      : Cap := 6.

(** *** Functions *)

(** Function ID for SSL_new (OpenSSL compartment boundary). *)
Definition f_ssl_new         : FuncID := 0.
(** Function ID for SSL_set_ex_data (OpenSSL compartment boundary). *)
Definition f_ssl_set_ex_data : FuncID := 1.
(** The nginx-internal function that calls into OpenSSL. *)
Definition f_ngx_create_conn : FuncID := 2.

(** Concrete function space and [holder] assignment for the nginx-OpenSSL
    example.  [SSL_new] and [SSL_set_ex_data] are external functions of
    [tau_ssl]; [ngx_ssl_create_conn] is an internal function of [tau_ngx] and
    is the caller of both. *)
Module NginxFS <: CHERI_FUNC_SPACE.

  Inductive F_ext_ind : CompartID -> FuncID -> Prop :=
  | F_ext_ssl_new         : F_ext_ind tau_ssl f_ssl_new
  | F_ext_ssl_set_ex_data : F_ext_ind tau_ssl f_ssl_set_ex_data.
  Definition F_ext := F_ext_ind.

  Inductive F_int_ind : CompartID -> FuncID -> Prop :=
  | F_int_ngx_create_conn : F_int_ind tau_ngx f_ngx_create_conn.
  Definition F_int := F_int_ind.

  (** Every OpenSSL entry point in this example is called from nginx's
      [ngx_ssl_create_conn]. *)
  Definition caller (_ : FuncID) : FuncID := f_ngx_create_conn.

  (** Which compartment owns the *storage* of each capability:
      - [cap_c] (0) and [cap_conn] (2) live in nginx's connection structure;
      - everything else ([cap_ctx], [cap_s], [cap_sexdata], [cap_data],
        [cap_ct]) lives in OpenSSL storage -- the argument and parameter slots
        of the OpenSSL entry points and the fields of the OpenSSL [SSL]
        object. *)
  Definition holder (p : Cap) : CompartID :=
    match p with
    | 0 => tau_ngx
    | 2 => tau_ngx
    | _ => tau_ssl
    end.

End NginxFS.

Module NginxCHERI := CHERILogic NginxFS.
Import NginxCHERI.

(** *** Function space lemmas *)

(** SSL_new is an external function of the OpenSSL compartment. *)
Lemma f_ssl_new_ext : NginxFS.F_ext tau_ssl f_ssl_new.
Proof. apply NginxFS.F_ext_ssl_new. Qed.

(** SSL_set_ex_data is an external function of the OpenSSL compartment. *)
Lemma f_ssl_set_ex_data_ext : NginxFS.F_ext tau_ssl f_ssl_set_ex_data.
Proof. apply NginxFS.F_ext_ssl_set_ex_data. Qed.

(** The caller of any OpenSSL entry point here is in nginx's function space. *)
Lemma caller_in_ngx : forall f, F_all tau_ngx (NginxFS.caller f).
Proof. intros f. left. apply NginxFS.F_int_ngx_create_conn. Qed.

(** [holder] values, spelled out for the derivations. *)
Lemma holder_c       : NginxFS.holder cap_c       = tau_ngx. Proof. reflexivity. Qed.
Lemma holder_ctx     : NginxFS.holder cap_ctx     = tau_ssl. Proof. reflexivity. Qed.
Lemma holder_conn    : NginxFS.holder cap_conn    = tau_ngx. Proof. reflexivity. Qed.
Lemma holder_s       : NginxFS.holder cap_s       = tau_ssl. Proof. reflexivity. Qed.
Lemma holder_sexdata : NginxFS.holder cap_sexdata = tau_ssl. Proof. reflexivity. Qed.
Lemma holder_data    : NginxFS.holder cap_data    = tau_ssl. Proof. reflexivity. Qed.
Lemma holder_ct      : NginxFS.holder cap_ct      = tau_ssl. Proof. reflexivity. Qed.

(** *** Rely/guarantee setting for the sequential example *)

(** Empty rely map for the sequential single-thread proof example. *)
Definition example_R : UMap := empty_umap.
(** Empty guarantee map for the sequential single-thread proof example. *)
Definition example_G : UMap := empty_umap.

(** The empty rely and guarantee maps are trivially well-formed. *)
Lemma wf_example : well_formed example_R example_G.
Proof.
  split.
  - unfold umap_disjoint. intros u [HR _]. unfold in_dom in HR.
    destruct HR as [act Hact]. unfold example_R, empty_umap in Hact.
    discriminate.
  - intros u p tg q HRu. unfold example_R, empty_umap in HRu.
    discriminate.
Qed.

(* ================================================================== *)
(** ** Machine-checked counterexamples                                  *)
(* ================================================================== *)

(** nginx and OpenSSL are different compartments (other direction). *)
Lemma tau_ssl_neq_ngx : tau_ssl <> tau_ngx.
Proof. unfold tau_ngx, tau_ssl. discriminate. Qed.

(** Two distinct one-cell states compose. *)
Lemma disjoint_two_cells : forall x vx y vy, x <> y -> disjoint_capmap [(x,vx)] [(y,vy)].
Proof.
  intros x vx y vy Hne c. simpl.
  destruct (Nat.eqb c x) eqn:Ex.
  - apply Nat.eqb_eq in Ex. subst c. right.
    destruct (Nat.eqb x y) eqn:Ey.
    + apply Nat.eqb_eq in Ey. congruence.
    + reflexivity.
  - left. reflexivity.
Qed.

(** A two-cell separating conjunction of distinct capabilities is inhabited,
    and the first capability is looked up in the composite state. *)
Lemma sep_two_cpt_inhab : forall x ax sx tx y ay sy ty,
  x <> y ->
  exists st, state_sep (cpt x ax sx tx) (cpt y ay sy ty) st /\
             cap_lookup (che_capmap st) x = Some (ax, sx, tx).
Proof.
  intros x ax sx tx y ay sy ty Hne.
  assert (Hc : exists st,
            compose (st_cell x (ax,sx,tx) None) (st_cell y (ay,sy,ty) None) = Some st /\
            che_capmap st = cap_union [(x,(ax,sx,tx))] [(y,(ay,sy,ty))]).
  { unfold compose, CASLche_PCM.compose.
    destruct (disjoint_dec_full (st_cell x (ax,sx,tx) None)
                                (st_cell y (ay,sy,ty) None)) as [_|Hn].
    - simpl. eexists. split; reflexivity.
    - exfalso. apply Hn. split; simpl.
      + apply disjoint_two_cells. exact Hne.
      + discriminate. }
  destruct Hc as [st [Hcomp Hmap]].
  exists st. split.
  - exists (st_cell x (ax,sx,tx) None), (st_cell y (ay,sy,ty) None).
    split; [apply cpt_inhab | split; [apply cpt_inhab | exact Hcomp]].
  - rewrite Hmap. rewrite cap_union_lookup. simpl.
    rewrite Nat.eqb_refl. reflexivity.
Qed.

(** RESOLVED FINDING (kept as a record, no longer instantiable).

    An earlier revision of Fig. 10 gave CHERI-Ret-Unseal without the premise
    [holder(x) = tau2] that its siblings CHERI-Call-Unseal and
    CHERI-IndCall-Unseal both carry, and that rule then broke INV.  The
    counterexample was: [f = SSL_new], [tau1 = tau_ssl], [tau2 = tau_ngx],
    [x = s] -- whose *storage* belongs to OpenSSL, [holder s = tau_ssl].  The
    precondition [s |-> (A,S,tau_ngx) /\ tau_cur = tau_ssl] satisfied INV (the
    cell is sealed); the postcondition [s |-> (A,U,tau_ngx) /\ tau_cur =
    tau_ngx] did not, since [holder s = tau_ssl <> tau_ngx] and the cell is
    unsealed.

    The premise is now present in the paper, so the counterexample no longer
    type-checks and the theorem that exhibited it has been removed rather than
    left to rot.  [che_axioms_preserve_INV] is correspondingly unconditional.
    Recorded here because it is the motivating example for why the induction
    is worth doing: nothing about the omission was visible from reading the
    figure. *)

(** FINDING.  The proposed UNSAFE-Assign does violate INV -- unlike the four
    printed Fig. 11 rules, which all preserve it
    (see [che_unsafe_axioms_preserve_INV]).

    Copying the OpenSSL-owned, unsealed capability [s] into nginx's slot
    [conn] without resealing yields [conn |-> (A,U,tau_ssl)] while
    [holder conn = tau_ngx]. *)
Theorem unsafe_assign_violates_INV :
  exists p a tg q, che_unsafe_assign_axioms p a tg q /\ INV_holds p /\ ~ INV_holds q.
Proof.
  exists (state_sep (cap_uninit cap_conn) (cpt cap_s Allocated Unsealed tau_ssl)).
  exists (CASLche_ATOM.CHEAssign cap_conn cap_s).
  exists Ok.
  exists (state_sep (cpt cap_conn Allocated Unsealed tau_ssl)
                    (cpt cap_s Allocated Unsealed tau_ssl)).
  split; [apply UNSAFE_Assign | split].
  - apply INV_sep; [apply INV_cap_uninit | apply INV_cpt_holder; exact holder_s].
  - intros HINV.
    destruct (sep_two_cpt_inhab cap_conn Allocated Unsealed tau_ssl
                                cap_s Allocated Unsealed tau_ssl)
      as [st [Hst Hlu]].
    { unfold cap_conn, cap_s. discriminate. }
    assert (Hne : NginxFS.holder cap_conn <> tau_ssl).
    { rewrite holder_conn. exact tau_ngx_neq_ssl. }
    specialize (HINV st Hst cap_conn Allocated Unsealed tau_ssl Hlu Hne).
    discriminate.
Qed.

(* ================================================================== *)
(** ** Right-nested separating conjunction over a list of state sets    *)
(*                                                                      *)
(*    Bookkeeping for the worked derivations: a whole program state is   *)
(*    a list of cell assertions, and the frame rule is applied by moving *)
(*    the cells a rule touches to the front of the list.                 *)
(* ================================================================== *)

(** [sep_list [p1; ...; pn]] is [p1 * (p2 * (... * (pn * emp)))]. *)
Fixpoint sep_list (l : list StateSet) : StateSet :=
  match l with
  | [] => che_emp
  | p :: rest => state_sep p (sep_list rest)
  end.

(** Adjacent transposition in a right-nested separating conjunction. *)
Lemma sep_swap12 : forall a b r,
  sset_equiv (state_sep a (state_sep b r)) (state_sep b (state_sep a r)).
Proof.
  intros a b r.
  apply sset_equiv_trans with (q := state_sep (state_sep a b) r);
    [intros s; apply state_sep_assoc |].
  apply sset_equiv_trans with (q := state_sep (state_sep b a) r).
  - apply state_sep_equiv; [intros s; apply state_sep_comm | apply sset_equiv_refl].
  - intros s. symmetry. apply state_sep_assoc.
Qed.

(** Moving one element of the list to the front leaves the assertion unchanged. *)
Lemma sep_list_move : forall (pre suf : list StateSet) (a : StateSet),
  sset_equiv (sep_list (pre ++ a :: suf)) (sep_list (a :: pre ++ suf)).
Proof.
  intros pre. induction pre as [|h t IH]; intros suf a; simpl.
  - apply sset_equiv_refl.
  - apply sset_equiv_trans with (q := state_sep h (state_sep a (sep_list (t ++ suf)))).
    + apply state_sep_equiv; [apply sset_equiv_refl | apply (IH suf a)].
    + apply sep_swap12.
Qed.

(** Move the element at index 1 to the front. *)
Lemma sep_move1 : forall a b l, sset_equiv (sep_list (a::b::l)) (sep_list (b::a::l)).
Proof. intros. exact (sep_list_move [a] l b). Qed.
(** Move the element at index 2 to the front. *)
Lemma sep_move2 : forall a b c l,
  sset_equiv (sep_list (a::b::c::l)) (sep_list (c::a::b::l)).
Proof. intros. exact (sep_list_move [a;b] l c). Qed.
(** Move the element at index 3 to the front. *)
Lemma sep_move3 : forall a b c d l,
  sset_equiv (sep_list (a::b::c::d::l)) (sep_list (d::a::b::c::l)).
Proof. intros. exact (sep_list_move [a;b;c] l d). Qed.
(** Move the element at index 4 to the front. *)
Lemma sep_move4 : forall a b c d e l,
  sset_equiv (sep_list (a::b::c::d::e::l)) (sep_list (e::a::b::c::d::l)).
Proof. intros. exact (sep_list_move [a;b;c;d] l e). Qed.
(** Move the element at index 5 to the front. *)
Lemma sep_move5 : forall a b c d e f l,
  sset_equiv (sep_list (a::b::c::d::e::f::l)) (sep_list (f::a::b::c::d::e::l)).
Proof. intros. exact (sep_list_move [a;b;c;d;e] l f). Qed.
(** Move the element at index 6 to the front. *)
Lemma sep_move6 : forall a b c d e f g l,
  sset_equiv (sep_list (a::b::c::d::e::f::g::l)) (sep_list (g::a::b::c::d::e::f::l)).
Proof. intros. exact (sep_list_move [a;b;c;d;e;f] l g). Qed.
(** Move the element at index 7 to the front. *)
Lemma sep_move7 : forall a b c d e f g h l,
  sset_equiv (sep_list (a::b::c::d::e::f::g::h::l))
             (sep_list (h::a::b::c::d::e::f::g::l)).
Proof. intros. exact (sep_list_move [a;b;c;d;e;f;g] l h). Qed.

(** If a [cpt] assertion occurs anywhere in the list, its cell is present in
    every state of the whole assertion. *)
Lemma sep_list_cpt_lookup : forall l1 x a sl tau l2 st,
  sep_list (l1 ++ cpt x a sl tau :: l2) st ->
  cap_lookup (che_capmap st) x = Some (a, sl, tau).
Proof.
  induction l1 as [|h t IH]; intros x a sl tau l2 st Hst; simpl in Hst.
  - destruct Hst as [s1 [s2 [H1 [_ Hc]]]].
    apply CASLche_PCM.compose_success in Hc.
    destruct Hc as [_ [cm [_ [Hmap _]]]].
    destruct H1 as [Hx _].
    rewrite Hmap. rewrite cap_union_lookup. rewrite Hx. reflexivity.
  - destruct Hst as [s1 [s2 [_ [H2 Hc]]]].
    apply CASLche_PCM.compose_success in Hc.
    destruct Hc as [Hdisj [cm [_ [Hmap _]]]].
    specialize (IH x a sl tau l2 s2 H2).
    rewrite Hmap. rewrite cap_union_lookup.
    destruct (Hdisj x) as [H1n | H2n].
    + rewrite H1n. exact IH.
    + rewrite H2n in IH. discriminate.
Qed.

(* ================================================================== *)
(** ** Generic CASL plumbing for the worked derivations                 *)
(*                                                                      *)
(*    The derivations use the CASL proof rules of CASL_ProofRules.v.    *)
(*    All resources live in the thread-local component of a world: a     *)
(*    state assertion [p] is used as the world assertion [lift_state p]   *)
(*    (local state in [p], shared state arbitrary).                       *)
(* ================================================================== *)

(** Every CASL derivation has a well-formed context: each rule requires it
    of its conclusion. *)
Lemma derives_wf : forall (A : Axioms) R G T tg P C Q,
  derives A R G T tg P C Q -> well_formed R G.
Proof. intros A R G T tg P C Q H. destruct H; assumption. Qed.

(** Pointwise equivalence of world sets. *)
Definition wset_equiv (P Q : WorldSet) : Prop := forall w, P w <-> Q w.

(** [sset_equiv] is an equivalence relation (enables setoid rewriting). *)
#[export] Instance sset_equiv_Equivalence : Equivalence sset_equiv.
Proof.
  split; [exact sset_equiv_refl | exact sset_equiv_sym | exact sset_equiv_trans].
Qed.

(** [wset_equiv] is an equivalence relation. *)
#[export] Instance wset_equiv_Equivalence : Equivalence wset_equiv.
Proof.
  split.
  - intros P w. reflexivity.
  - intros P Q H w. symmetry. apply H.
  - intros P Q S H1 H2 w. rewrite (H1 w). apply H2.
Qed.

(** [lift_state] maps equivalent state sets to equivalent world sets. *)
#[export] Instance lift_state_Proper : Proper (sset_equiv ==> wset_equiv) lift_state.
Proof. intros p q H w. apply H. Qed.

(** CASL triples are invariant under pointwise equivalence of their pre- and
    postconditions (by the rule of consequence, RCons). *)
#[export] Instance derives_Proper (A : Axioms) R G T tg :
  Proper (wset_equiv ==> eq ==> wset_equiv ==> iff) (derives A R G T tg).
Proof.
  assert (Hcons : forall P P' C Q Q', wset_equiv P P' -> wset_equiv Q Q' ->
            derives A R G T tg P C Q -> derives A R G T tg P' C Q').
  { intros P P' C Q Q' HP HQ H.
    apply RCons with (R' := R) (G' := G) (T' := T) (P' := P) (Q' := Q).
    - eapply derives_wf. exact H.
    - intros w Hw. apply HP. exact Hw.
    - exact H.
    - intros w Hw. apply HQ. exact Hw.
    - apply rely_consistent_refl.
    - apply rely_consistent_refl.
    - apply traceset_subset_refl. }
  intros P P' HP C C' <- Q Q' HQ. split; apply Hcons; try assumption; symmetry; assumption.
Qed.

(** A purely local assertion is stable under every action map: actions only
    change the shared component of a world. *)
Lemma stable_lift_state : forall (F : StateSet) (M : UMap), stable (lift_state F) M.
Proof. intros F M l g u p tg q gq g' gp gn HF _ _ _ _ _ _. exact HF. Qed.

(** World separation of two local assertions is contained in the local
    assertion of their separating conjunction. *)
Lemma lift_state_sep_l : forall p q,
  wset_subset (world_sep (lift_state p) (lift_state q)) (lift_state (state_sep p q)).
Proof.
  intros p q [l g] [[l1 g1] [[l2 g2] [Hp [Hq [_ [_ Hc]]]]]].
  exists l1, l2. split; [exact Hp | split; [exact Hq | exact Hc]].
Qed.

(** Conversely, a separating conjunction of local states splits into world
    separation (both parts see the same shared state). *)
Lemma lift_state_sep_r : forall p q,
  wset_subset (lift_state (state_sep p q)) (world_sep (lift_state p) (lift_state q)).
Proof.
  intros p q [l g] [l1 [l2 [Hp [Hq Hc]]]].
  exists (l1, g), (l2, g). split; [exact Hp | split; [exact Hq |]].
  split; [reflexivity | split; [reflexivity | exact Hc]].
Qed.

(** Sequencing a local [ok] step (empty trace set) in front of a derivation
    keeps the derivation's trace set. *)
Lemma casl_seq_left_ok :
  forall (A : Axioms) (R G : UMap) T tg (P M Q : WorldSet) C1 C2,
  well_formed R G ->
  derives A R G empty_traces Ok P C1 M ->
  derives A R G T tg M C2 Q ->
  derives A R G T tg P (CSeq C1 C2) Q.
Proof.
  intros A R G T tg P M Q C1 C2 Hwf H1 H2.
  apply RCons with (R' := R) (G' := G) (T' := traces_concat empty_traces T)
                   (P' := P) (Q' := Q).
  - exact Hwf.
  - intros w Hw; exact Hw.
  - eapply RSeq; [exact Hwf | exact H1 | exact H2].
  - intros w Hw; exact Hw.
  - apply rely_consistent_refl.
  - apply rely_consistent_refl.
  - intros tr Htr. exists [], tr.
    split; [reflexivity | split; [exact Htr | reflexivity]].
Qed.

(** A local axiom applied to part of the local state, framing off the rest:
    AtomLocal, then Frame (a local frame is always stable), then Cons. *)
Lemma casl_atom_frame :
  forall (A : Axioms) (R G : UMap) (p q f : StateSet) (at_ : Atom),
  well_formed R G ->
  A p at_ Ok q ->
  derives A R G empty_traces Ok
    (lift_state (state_sep p f)) (CAtom at_) (lift_state (state_sep q f)).
Proof.
  intros A R G p q f at_ Hwf Hax.
  apply RCons with (R' := R) (G' := G) (T' := empty_traces)
                   (P' := world_sep (lift_state p) (lift_state f))
                   (Q' := world_sep (lift_state q) (lift_state f)).
  - exact Hwf.
  - apply lift_state_sep_l.
  - apply RFrame; [exact Hwf | | apply stable_lift_state].
    apply RAtomLocal; [exact Hwf | exact Hax].
  - apply lift_state_sep_r.
  - apply rely_consistent_refl.
  - apply rely_consistent_refl.
  - apply traceset_subset_refl.
Qed.

(** Regrouping the first three elements of a right-nested conjunction. *)
Lemma sep_assoc3 : forall a1 a2 a3 r,
  sset_equiv (state_sep a1 (state_sep a2 (state_sep a3 r)))
             (state_sep (state_sep a1 (state_sep a2 a3)) r).
Proof.
  intros a1 a2 a3 r.
  apply sset_equiv_trans with (q := state_sep a1 (state_sep (state_sep a2 a3) r)).
  - apply state_sep_equiv; [apply sset_equiv_refl | intros s; apply state_sep_assoc].
  - intros s; apply state_sep_assoc.
Qed.

(** Apply an axiom whose footprint is the first TWO elements of the list,
    framing off the rest. *)
Lemma casl_frame_sep2 :
  forall (A : Axioms) (R G : UMap) (a1 a2 b1 b2 : StateSet)
         (l : list StateSet) (at_ : Atom),
  well_formed R G ->
  A (state_sep a1 a2) at_ Ok (state_sep b1 b2) ->
  derives A R G empty_traces Ok
    (lift_state (sep_list (a1 :: a2 :: l))) (CAtom at_)
    (lift_state (sep_list (b1 :: b2 :: l))).
Proof.
  intros A R G a1 a2 b1 b2 l at_ Hwf Hax.
  assert (Hp : sset_equiv (sep_list (a1 :: a2 :: l))
                          (state_sep (state_sep a1 a2) (sep_list l)))
    by (intros s; exact (state_sep_assoc a1 a2 (sep_list l) s)).
  assert (Hq : sset_equiv (sep_list (b1 :: b2 :: l))
                          (state_sep (state_sep b1 b2) (sep_list l)))
    by (intros s; exact (state_sep_assoc b1 b2 (sep_list l) s)).
  rewrite Hp, Hq.
  apply casl_atom_frame; [exact Hwf | exact Hax].
Qed.

(** Apply an axiom whose footprint is the first THREE elements of the list. *)
Lemma casl_frame_sep3 :
  forall (A : Axioms) (R G : UMap) (a1 a2 a3 b1 b2 b3 : StateSet)
         (l : list StateSet) (at_ : Atom),
  well_formed R G ->
  A (state_sep a1 (state_sep a2 a3)) at_ Ok (state_sep b1 (state_sep b2 b3)) ->
  derives A R G empty_traces Ok
    (lift_state (sep_list (a1 :: a2 :: a3 :: l))) (CAtom at_)
    (lift_state (sep_list (b1 :: b2 :: b3 :: l))).
Proof.
  intros A R G a1 a2 a3 b1 b2 b3 l at_ Hwf Hax.
  rewrite (sep_assoc3 a1 a2 a3 (sep_list l) : sset_equiv (sep_list (a1 :: a2 :: a3 :: l)) _).
  rewrite (sep_assoc3 b1 b2 b3 (sep_list l) : sset_equiv (sep_list (b1 :: b2 :: b3 :: l)) _).
  apply casl_atom_frame; [exact Hwf | exact Hax].
Qed.

(** Apply an error axiom to the whole local state.  The step is recorded by a
    guarantee action on the empty shared resource, as RAtom requires. *)
Lemma casl_atom_err_whole :
  forall (A : Axioms) (R G : UMap) (uid : UID) (p q : StateSet)
         (at_ : Atom) (tg : Tag),
  well_formed R G ->
  G uid = Some (che_emp, tg, che_emp) ->
  A (state_sep p che_emp) at_ tg (state_sep q che_emp) ->
  derives A R G (singleton_trace uid) tg (lift_state p) (CAtom at_) (lift_state q).
Proof.
  intros A R G uid p q at_ tg Hwf HG Hax.
  apply RCons with (R' := R) (G' := G) (T' := singleton_trace uid)
                   (P' := wset_inter (lift_state p) (local_shared che_emp sset_full))
                   (Q' := wset_inter (lift_state q) (local_shared che_emp sset_full)).
  - exact Hwf.
  - intros w [Hw _]. exact Hw.
  - eapply RAtom; [exact Hwf | exact HG | exact Hax].
  - intros w Hw. split; [exact Hw |].
    unfold local_shared. apply state_sep_unit_l_rev; [exact che_emp_unit_exists | exact I].
  - apply rely_consistent_refl.
  - apply rely_consistent_refl.
  - apply traceset_subset_refl.
Qed.

(* ================================================================== *)
(** ** Cell assertion abbreviations for the nginx-OpenSSL example       *)
(* ================================================================== *)

(** nginx's connection object, unsealed, nginx-owned. *)
Abbreviation Kc_AU    := (cpt cap_c Allocated Unsealed tau_ngx).
(** nginx's connection object, sealed. *)
Abbreviation Kc_AS    := (cpt cap_c Allocated Sealed   tau_ngx).
(** The SSL context argument slot, sealed. *)
Abbreviation Kctx_AS  := (cpt cap_ctx Allocated Sealed   tau_ssl).
(** The SSL context argument slot, unsealed. *)
Abbreviation Kctx_AU  := (cpt cap_ctx Allocated Unsealed tau_ssl).
(** nginx's [conn] slot, uninitialised. *)
Abbreviation Kconn_un := (cap_uninit cap_conn).
(** nginx's [conn] slot, holding a sealed OpenSSL-owned capability. *)
Abbreviation Kconn_AS := (cpt cap_conn Allocated Sealed   tau_ssl).
(** nginx's [conn] slot, holding an UNSEALED OpenSSL-owned capability
    (an INV violation; only reachable with the unsafe rules). *)
Abbreviation Kconn_AU := (cpt cap_conn Allocated Unsealed tau_ssl).
(** The OpenSSL [SSL] object, freed. *)
Abbreviation Ks_FU    := (cpt cap_s Freed     Unsealed tau_ssl).
(** The OpenSSL [SSL] object, allocated and unsealed. *)
Abbreviation Ks_AU    := (cpt cap_s Allocated Unsealed tau_ssl).
(** The OpenSSL [SSL] object, allocated and sealed. *)
Abbreviation Ks_AS    := (cpt cap_s Allocated Sealed   tau_ssl).
(** The field [s.ex_data], uninitialised. *)
Abbreviation Ksx_un   := (cap_uninit cap_sexdata).
(** The field [s.ex_data], holding a sealed nginx-owned capability. *)
Abbreviation Ksx_AS   := (cpt cap_sexdata Allocated Sealed   tau_ngx).
(** The field [s.ex_data], holding an UNSEALED nginx-owned capability. *)
Abbreviation Ksx_AU   := (cpt cap_sexdata Allocated Unsealed tau_ngx).
(** OpenSSL's [data] slot, uninitialised. *)
Abbreviation Kdata_un := (cap_uninit cap_data).
(** OpenSSL's [data] slot, holding a sealed nginx-owned capability. *)
Abbreviation Kdata_AS := (cpt cap_data Allocated Sealed   tau_ngx).
(** OpenSSL's [data] slot, holding an UNSEALED nginx-owned capability. *)
Abbreviation Kdata_AU := (cpt cap_data Allocated Unsealed tau_ngx).
(** [SSL_new]'s parameter [ct], not yet bound. *)
Abbreviation Kct_un   := (cap_uninit cap_ct).
(** [SSL_new]'s parameter [ct], bound to the unsealed SSL context. *)
Abbreviation Kct_AU   := (cpt cap_ct Allocated Unsealed tau_ssl).

(** The four [assign_seal] side conditions used by the safe derivation.
    Binding [SSL_new]'s parameter [ct] copies an OpenSSL-owned capability into
    OpenSSL storage, so CHERI-Assign leaves the copy unsealed. *)
Lemma assign_ct_from_ctx : assign_seal cap_ct tau_ssl = Unsealed.
Proof. apply assign_seal_holder. exact holder_ct. Qed.

(** In the other three cases the receiving slot belongs to a different
    compartment from the object being copied, so CHERI-Assign seals the copy. *)
Lemma assign_conn_from_s : assign_seal cap_conn tau_ssl = Sealed.
Proof. apply assign_seal_not_holder. rewrite holder_conn. exact tau_ngx_neq_ssl. Qed.

Lemma assign_data_from_c : assign_seal cap_data tau_ngx = Sealed.
Proof. apply assign_seal_not_holder. rewrite holder_data. exact tau_ssl_neq_ngx. Qed.

Lemma assign_sexdata_from_data : assign_seal cap_sexdata tau_ngx = Sealed.
Proof. apply assign_seal_not_holder. rewrite holder_sexdata. exact tau_ssl_neq_ngx. Qed.

(* ================================================================== *)
(** ** The SAFE derivation (Fig. 7, bottom of the paper)                *)
(*                                                                      *)
(*    ngx_ssl_create_conn(ngx_conn_t *c, ... *ctx) {                     *)
(*      conn = SSL_new(ctx);                                             *)
(*      // inside OpenSSL:  ct = ctx; s = OSSL_malloc(); return s;       *)
(*      SSL_set_ex_data(conn, c);                                        *)
(*      // inside OpenSSL:  data = c; s->ex_data = data; return (...);   *)
(*      assert INV;                                                      *)
(*    }                                                                  *)
(*                                                                      *)
(*    Unlike the previous mechanization, the states below genuinely       *)
(*    chain: the postcondition of step N *is* the precondition of step    *)
(*    N+1, so P1 really does lead to P9.                                  *)
(* ================================================================== *)

(** P1: nginx holds [c] (unsealed, nginx-owned) and the sealed SSL context;
    the OpenSSL object [s] is not yet allocated and the slots [conn],
    [s.ex_data], [data] and [SSL_new]'s parameter [ct] are empty.  Current
    compartment: nginx. *)
Definition P1 : StateSet :=
  sep_list [Kctx_AS; cur_compart tau_ngx; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_un].

(** P1a: [conn = SSL_new(ctx)] has crossed into OpenSSL: the context argument
    is unsealed and [tau_cur = tau_ssl]; the parameter [ct] is not yet bound. *)
Definition P1a : StateSet :=
  sep_list [Kctx_AU; cur_compart tau_ssl; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_un].

(** P2 (paper's P2): [SSL_new] has bound its parameter, [ct |-> (A,U,tau_ssl)]. *)
Definition P2 : StateSet :=
  sep_list [Kctx_AU; cur_compart tau_ssl; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_AU].

(** P3 (paper's P3): OSSL_malloc has allocated [s]. *)
Definition P3 : StateSet :=
  sep_list [Ks_AU; cur_compart tau_ssl; Kctx_AU; Kc_AU; Kconn_un; Ksx_un; Kdata_un;
            Kct_AU].

(** P4: [return s] seals [s] and returns control to nginx. *)
Definition P4 : StateSet :=
  sep_list [Ks_AS; cur_compart tau_ngx; Kctx_AU; Kc_AU; Kconn_un; Ksx_un; Kdata_un;
            Kct_AU].

(** P5 (paper's P4): nginx's [conn] slot now holds the sealed handle. *)
Definition P5 : StateSet :=
  sep_list [Kconn_AS; Ks_AS; cur_compart tau_ngx; Kctx_AU; Kc_AU; Ksx_un; Kdata_un;
            Kct_AU].

(** P6: [SSL_set_ex_data(conn, c)] seals nginx's [c] and unseals OpenSSL's
    view [s] of the object, switching to the OpenSSL compartment. *)
Definition P6 : StateSet :=
  sep_list [Kc_AS; Ks_AU; cur_compart tau_ssl; Kconn_AS; Kctx_AU; Ksx_un; Kdata_un;
            Kct_AU].

(** P7 (paper's P5): OpenSSL's parameter slot [data] now holds the sealed
    nginx capability. *)
Definition P7 : StateSet :=
  sep_list [Kdata_AS; Kc_AS; Ks_AU; cur_compart tau_ssl; Kconn_AS; Kctx_AU; Ksx_un;
            Kct_AU].

(** P8 (paper's P6): [s->ex_data := data] stores the sealed capability into
    the OpenSSL-owned object. *)
Definition P8 : StateSet :=
  sep_list [Ksx_AS; Kdata_AS; Kc_AS; Ks_AU; cur_compart tau_ssl; Kconn_AS; Kctx_AU;
            Kct_AU].

(** P9 (paper's P7): the return reseals [s] and unseals nginx's [c].  Every
    cell is either sealed or held by its own owner, so INV holds. *)
Definition P9 : StateSet :=
  sep_list [Kc_AU; Ks_AS; cur_compart tau_ngx; Ksx_AS; Kdata_AS; Kconn_AS; Kctx_AU;
            Kct_AU].

(** Step 1 (CallUnseal + Frame): [conn = SSL_new(ctx)] enters OpenSSL.
    The premise [holder(ctx) = tau_ssl] holds because the argument slot is
    OpenSSL storage. *)
Theorem step1_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P1) (CAtom (CASLche_ATOM.CHECall cap_ctx)) (lift_state P1a).
Proof.
  unfold P1, P1a.
  apply casl_frame_sep2; [exact wf_example|].
  eapply CHE_CallUnseal; [exact f_ssl_new_ext | exact holder_ctx].
Qed.

(** Step 1a (Assign + Frame): on entry, [SSL_new] binds its parameter,
    [ct := ctx].  [holder(ct) = tau_ssl] and the context is OpenSSL-owned, so
    CHERI-Assign leaves the copy unsealed.  Steps 1 and 1a together are the
    paper's "CallUnseal + Frame + Assign" for [conn = SSL_new(ctx)]. *)
Theorem step1a_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P1a) (CAtom (CASLche_ATOM.CHEAssign cap_ct cap_ctx)) (lift_state P2).
Proof.
  unfold P1a, P2.
  rewrite (sep_move7 Kctx_AU (cur_compart tau_ssl) Kc_AU Kconn_un Ks_FU Ksx_un Kdata_un
                     Kct_un).
  rewrite (sep_move7 Kctx_AU (cur_compart tau_ssl) Kc_AU Kconn_un Ks_FU Ksx_un Kdata_un
                     Kct_AU).
  apply casl_frame_sep2; [exact wf_example|].
  rewrite <- assign_ct_from_ctx.
  apply CHE_Assign.
Qed.

(** Step 2 (Alloc + Frame): [s = OSSL_malloc()] inside OpenSSL. *)
Theorem step2_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P2) (CAtom (CASLche_ATOM.CHEAlloc cap_s 1)) (lift_state P3).
Proof.
  unfold P2, P3.
  rewrite (sep_move1 Kctx_AU (cur_compart tau_ssl)).
  rewrite (sep_move4 (cur_compart tau_ssl) Kctx_AU Kc_AU Kconn_un Ks_FU).
  apply casl_frame_sep2; [exact wf_example|].
  apply CHE_Alloc.
Qed.

(** Step 3 (RetSeal + Frame): [return s] from SSL_new seals the object and
    hands control back to nginx. *)
Theorem step3_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P3) (CAtom (CASLche_ATOM.CHERet cap_s)) (lift_state P4).
Proof.
  unfold P3, P4.
  apply casl_frame_sep2; [exact wf_example|].
  eapply CHE_RetSeal; [exact f_ssl_new_ext | apply caller_in_ngx].
Qed.

(** Step 4 (Assign + Frame): nginx stores the returned handle, [conn := s].
    [holder(conn) = tau_ngx <> tau_ssl], so CHERI-Assign seals the copy --
    this is precisely the paper's "RetSeal + Assign" annotation, and it is
    what distinguishes nginx's name [conn] from OpenSSL's name [s]. *)
Theorem step4_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P4) (CAtom (CASLche_ATOM.CHEAssign cap_conn cap_s)) (lift_state P5).
Proof.
  unfold P4, P5.
  rewrite (sep_move4 Ks_AS (cur_compart tau_ngx) Kctx_AU Kc_AU Kconn_un).
  apply casl_frame_sep2; [exact wf_example|].
  rewrite <- assign_conn_from_s.
  apply CHE_Assign.
Qed.

(** Step 5 (CallMixed + Frame): [SSL_set_ex_data(conn, c)].
    The caller-owned argument [c] is sealed on the way in; the callee-owned
    object [s] is unsealed, justified by [holder(s) = tau_ssl]. *)
Theorem step5_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P5) (CAtom (CASLche_ATOM.CHECallPair cap_c cap_s)) (lift_state P6).
Proof.
  unfold P5, P6.
  rewrite (sep_move2 Kconn_AS Ks_AS (cur_compart tau_ngx)).
  rewrite (sep_move2 (cur_compart tau_ngx) Kconn_AS Ks_AS).
  rewrite (sep_move4 Ks_AS (cur_compart tau_ngx) Kconn_AS Kctx_AU Kc_AU).
  apply casl_frame_sep3; [exact wf_example|].
  eapply CHE_CallMixed; [exact f_ssl_set_ex_data_ext | exact holder_s].
Qed.

(** Step 6 (Assign + Frame): inside OpenSSL, [data := c].
    [holder(data) = tau_ssl <> tau_ngx], so the copy stays sealed: this is the
    paper's P5, in which [data |-> (A,S,tau_ngx)]. *)
Theorem step6_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P6) (CAtom (CASLche_ATOM.CHEAssign cap_data cap_c)) (lift_state P7).
Proof.
  unfold P6, P7.
  rewrite (sep_move6 Kc_AS Ks_AU (cur_compart tau_ssl) Kconn_AS Kctx_AU Ksx_un Kdata_un).
  apply casl_frame_sep2; [exact wf_example|].
  rewrite <- assign_data_from_c.
  apply CHE_Assign.
Qed.

(** Step 7 (Assign + Frame): [s->ex_data := data].
    [holder(s.ex_data) = tau_ssl] (the field lives inside the OpenSSL-owned
    object [s]) while the capability points at an nginx-owned object, so the
    copy is sealed. *)
Theorem step7_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P7) (CAtom (CASLche_ATOM.CHEAssign cap_sexdata cap_data)) (lift_state P8).
Proof.
  unfold P7, P8.
  rewrite (sep_move6 Kdata_AS Kc_AS Ks_AU (cur_compart tau_ssl) Kconn_AS Kctx_AU Ksx_un).
  apply casl_frame_sep2; [exact wf_example|].
  rewrite <- assign_sexdata_from_data.
  apply CHE_Assign.
Qed.

(** Step 8 (RetMixed + Frame): return from SSL_set_ex_data.
    Premises: [SSL_set_ex_data in F_ext(tau_ssl)], [caller(f) in F(tau_ngx)]
    and [holder(c) = tau_ngx]. *)
Theorem step8_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P8) (CAtom (CASLche_ATOM.CHERetPair cap_c cap_s)) (lift_state P9).
Proof.
  unfold P8, P9.
  rewrite (sep_move4 Ksx_AS Kdata_AS Kc_AS Ks_AU (cur_compart tau_ssl)).
  rewrite (sep_move4 (cur_compart tau_ssl) Ksx_AS Kdata_AS Kc_AS Ks_AU).
  rewrite (sep_move4 Ks_AU (cur_compart tau_ssl) Ksx_AS Kdata_AS Kc_AS).
  apply casl_frame_sep3; [exact wf_example|].
  eapply CHE_RetMixed;
    [exact f_ssl_set_ex_data_ext | apply caller_in_ngx | exact holder_c].
Qed.

(** The final state satisfies the invariant: every cell is either sealed, or
    unsealed and held by its own owner. *)
Theorem P9_satisfies_INV : INV_holds P9.
Proof.
  unfold P9. simpl.
  apply INV_sep; [apply INV_cpt_holder; exact holder_c |].
  apply INV_sep; [apply INV_cpt_sealed |].
  apply INV_sep; [apply INV_cur_compart |].
  apply INV_sep; [apply INV_cpt_sealed |].
  apply INV_sep; [apply INV_cpt_sealed |].
  apply INV_sep; [apply INV_cpt_sealed |].
  apply INV_sep; [apply INV_cpt_holder; exact holder_ctx |].
  apply INV_sep; [apply INV_cpt_holder; exact holder_ct |].
  apply INV_che_emp.
Qed.

(** Step 9 (Assert): [assert INV] succeeds. *)
Theorem step9_derives :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P9) (CAtom (CASLche_ATOM.CHEAssert INV_set)) (lift_state P9).
Proof.
  apply RAtomLocal; [exact wf_example|].
  apply CHE_Assert. exact P9_satisfies_INV.
Qed.

(** The whole program of Fig. 7. *)
Definition prog_safe : Comm :=
  CSeq (CAtom (CASLche_ATOM.CHECall cap_ctx))
  (CSeq (CAtom (CASLche_ATOM.CHEAssign cap_ct cap_ctx))
  (CSeq (CAtom (CASLche_ATOM.CHEAlloc cap_s 1))
  (CSeq (CAtom (CASLche_ATOM.CHERet cap_s))
  (CSeq (CAtom (CASLche_ATOM.CHEAssign cap_conn cap_s))
  (CSeq (CAtom (CASLche_ATOM.CHECallPair cap_c cap_s))
  (CSeq (CAtom (CASLche_ATOM.CHEAssign cap_data cap_c))
  (CSeq (CAtom (CASLche_ATOM.CHEAssign cap_sexdata cap_data))
  (CSeq (CAtom (CASLche_ATOM.CHERetPair cap_c cap_s))
        (CAtom (CASLche_ATOM.CHEAssert INV_set)))))))))).

(** THE SAFE DERIVATION: [P1] leads to [P9] and the final assertion of INV
    succeeds. *)
Theorem nginx_openssl_safe_derivation :
  derives che_axioms example_R example_G empty_traces Ok
    (lift_state P1) prog_safe (lift_state P9).
Proof.
  unfold prog_safe.
  eapply casl_seq_left_ok; [exact wf_example | exact step1_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step1a_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step2_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step3_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step4_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step5_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step6_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step7_derives |].
  eapply casl_seq_left_ok; [exact wf_example | exact step8_derives |].
  exact step9_derives.
Qed.

(* ================================================================== *)
(** ** The ERROR derivation (Fig. 12 of the appendix)                   *)
(*                                                                      *)
(*    The same program, but with the UNSAFE call/return rules of         *)
(*    Fig. 11 in place of the sealing ones -- and with the proposed      *)
(*    UNSAFE-Assign in place of CHERI-Assign, WITHOUT WHICH FIG. 12      *)
(*    DOES NOT GO THROUGH (see the comment on                            *)
(*    [che_unsafe_assign_axioms]).                                       *)
(* ================================================================== *)

(** E1: as P1, except that the SSL context is not sealed to begin with
    (this is what the paper's error example shows). *)
Definition E1 : StateSet :=
  sep_list [Kctx_AU; cur_compart tau_ngx; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_un].

(** E1a: the unsafe call has entered OpenSSL; [ct] is not yet bound. *)
Definition E1a : StateSet :=
  sep_list [Kctx_AU; cur_compart tau_ssl; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_un].

(** E2 (paper's error P2): [SSL_new]'s parameter [ct] is bound. *)
Definition E2 : StateSet :=
  sep_list [Kctx_AU; cur_compart tau_ssl; Kc_AU; Kconn_un; Ks_FU; Ksx_un; Kdata_un;
            Kct_AU].

(** E3 (paper's error P3). *)
Definition E3 : StateSet :=
  sep_list [Ks_AU; cur_compart tau_ssl; Kctx_AU; Kc_AU; Kconn_un; Ksx_un; Kdata_un;
            Kct_AU].

(** E4: the unsafe return does not seal [s]. *)
Definition E4 : StateSet :=
  sep_list [Ks_AU; cur_compart tau_ngx; Kctx_AU; Kc_AU; Kconn_un; Ksx_un; Kdata_un;
            Kct_AU].

(** E5 (paper's error P4): nginx's [conn] slot now holds an UNSEALED
    OpenSSL-owned capability.  INV is already violated here. *)
Definition E5 : StateSet :=
  sep_list [Kconn_AU; Ks_AU; cur_compart tau_ngx; Kctx_AU; Kc_AU; Ksx_un; Kdata_un;
            Kct_AU].

(** E6: the unsafe two-argument call seals nothing. *)
Definition E6 : StateSet :=
  sep_list [Kc_AU; Ks_AU; cur_compart tau_ssl; Kconn_AU; Kctx_AU; Ksx_un; Kdata_un;
            Kct_AU].

(** E7 (paper's error P5): OpenSSL's [data] slot holds an unsealed
    nginx-owned capability. *)
Definition E7 : StateSet :=
  sep_list [Kdata_AU; Kc_AU; Ks_AU; cur_compart tau_ssl; Kconn_AU; Kctx_AU; Ksx_un;
            Kct_AU].

(** E8 (paper's error P6): the leak is now stored in the OpenSSL object. *)
Definition E8 : StateSet :=
  sep_list [Ksx_AU; Kdata_AU; Kc_AU; Ks_AU; cur_compart tau_ssl; Kconn_AU; Kctx_AU;
            Kct_AU].

(** E9 (paper's error P7): control is back in nginx and three cells
    ([conn], [data], [s.ex_data]) are unsealed capabilities to objects owned
    by another compartment. *)
Definition E9 : StateSet :=
  sep_list [Kc_AU; Ks_AU; cur_compart tau_ngx; Ksx_AU; Kdata_AU; Kconn_AU; Kctx_AU;
            Kct_AU].

(** Guarantee map carrying the single error action of the derivation. *)
Definition err_uid : UID := 0.

(** The guarantee used by the error derivation: one entry, for the failing
    assertion. *)
Definition error_G : UMap :=
  fun u => if Nat.eqb u err_uid then Some (che_emp, Err 1, che_emp) else None.

(** The empty rely together with [error_G] is well formed. *)
Lemma wf_error : well_formed example_R error_G.
Proof.
  split.
  - intros u [HR _]. destruct HR as [act Hact].
    unfold example_R, empty_umap in Hact. discriminate.
  - intros u p tg q HRu. unfold example_R, empty_umap in HRu. discriminate.
Qed.

(** [SSL_new] is in [F(tau_ssl)]. *)
Lemma f_ssl_new_all : F_all tau_ssl f_ssl_new.
Proof. right. exact f_ssl_new_ext. Qed.

(** [SSL_set_ex_data] is in [F(tau_ssl)]. *)
Lemma f_ssl_set_ex_data_all : F_all tau_ssl f_ssl_set_ex_data.
Proof. right. exact f_ssl_set_ex_data_ext. Qed.

(** nginx's own entry point is in [F(tau_ngx)]. *)
Lemma f_ngx_all : F_all tau_ngx f_ngx_create_conn.
Proof. left. apply NginxFS.F_int_ngx_create_conn. Qed.

(** Error step 1 (UNSAFE-Call-NoSeal + Frame). *)
Theorem estep1_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E1) (CAtom (CASLche_ATOM.CHECall cap_ctx)) (lift_state E1a).
Proof.
  unfold E1, E1a.
  apply casl_frame_sep2; [exact wf_error|].
  right; left. eapply UNSAFE_CallNoSeal. exact f_ssl_new_all.
Qed.

(** Error step 1a (UNSAFE-Assign + Frame): [SSL_new] binds its parameter,
    [ct := ctx].  The same program as the safe derivation, so the parameter
    binding is present here too; as for the other assignments of this
    derivation, the unsafe rule is used (here it gives the same cell as
    CHERI-Assign, since [holder(ct) = tau_ssl]). *)
Theorem estep1a_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E1a) (CAtom (CASLche_ATOM.CHEAssign cap_ct cap_ctx)) (lift_state E2).
Proof.
  unfold E1a, E2.
  rewrite (sep_move7 Kctx_AU (cur_compart tau_ssl) Kc_AU Kconn_un Ks_FU Ksx_un Kdata_un
                     Kct_un).
  rewrite (sep_move7 Kctx_AU (cur_compart tau_ssl) Kc_AU Kconn_un Ks_FU Ksx_un Kdata_un
                     Kct_AU).
  apply casl_frame_sep2; [exact wf_error|].
  right; right. apply UNSAFE_Assign.
Qed.

(** Error step 2 (Alloc + Frame): the safe allocation rule is still used. *)
Theorem estep2_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E2) (CAtom (CASLche_ATOM.CHEAlloc cap_s 1)) (lift_state E3).
Proof.
  unfold E2, E3.
  rewrite (sep_move1 Kctx_AU (cur_compart tau_ssl)).
  rewrite (sep_move4 (cur_compart tau_ssl) Kctx_AU Kc_AU Kconn_un Ks_FU).
  apply casl_frame_sep2; [exact wf_error|].
  left. apply CHE_Alloc.
Qed.

(** Error step 3 (UNSAFE-Ret-NoSeal + Frame): the return does not seal [s]. *)
Theorem estep3_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E3) (CAtom (CASLche_ATOM.CHERet cap_s)) (lift_state E4).
Proof.
  unfold E3, E4.
  apply casl_frame_sep2; [exact wf_error|].
  right; left. eapply UNSAFE_RetNoSeal. exact f_ngx_all.
Qed.

(** Error step 4 (UNSAFE-Assign + Frame): [conn := s] with no resealing. *)
Theorem estep4_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E4) (CAtom (CASLche_ATOM.CHEAssign cap_conn cap_s)) (lift_state E5).
Proof.
  unfold E4, E5.
  rewrite (sep_move4 Ks_AU (cur_compart tau_ngx) Kctx_AU Kc_AU Kconn_un).
  apply casl_frame_sep2; [exact wf_error|].
  right; right. apply UNSAFE_Assign.
Qed.

(** Error step 5 (UNSAFE-Call-Two-NoSeal + Frame). *)
Theorem estep5_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E5) (CAtom (CASLche_ATOM.CHECallPair cap_c cap_s)) (lift_state E6).
Proof.
  unfold E5, E6.
  rewrite (sep_move2 Kconn_AU Ks_AU (cur_compart tau_ngx)).
  rewrite (sep_move2 (cur_compart tau_ngx) Kconn_AU Ks_AU).
  rewrite (sep_move4 Ks_AU (cur_compart tau_ngx) Kconn_AU Kctx_AU Kc_AU).
  apply casl_frame_sep3; [exact wf_error|].
  right; left. eapply UNSAFE_CallTwoNoSeal. exact f_ssl_set_ex_data_all.
Qed.

(** Error step 6 (UNSAFE-Assign + Frame): [data := c] with no resealing. *)
Theorem estep6_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E6) (CAtom (CASLche_ATOM.CHEAssign cap_data cap_c)) (lift_state E7).
Proof.
  unfold E6, E7.
  rewrite (sep_move6 Kc_AU Ks_AU (cur_compart tau_ssl) Kconn_AU Kctx_AU Ksx_un Kdata_un).
  apply casl_frame_sep2; [exact wf_error|].
  right; right. apply UNSAFE_Assign.
Qed.

(** Error step 7 (UNSAFE-Assign + Frame): [s->ex_data := data]. *)
Theorem estep7_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E7) (CAtom (CASLche_ATOM.CHEAssign cap_sexdata cap_data)) (lift_state E8).
Proof.
  unfold E7, E8.
  rewrite (sep_move6 Kdata_AU Kc_AU Ks_AU (cur_compart tau_ssl) Kconn_AU Kctx_AU Ksx_un).
  apply casl_frame_sep2; [exact wf_error|].
  right; right. apply UNSAFE_Assign.
Qed.

(** Error step 8 (UNSAFE-Ret-Two-NoSeal + Frame). *)
Theorem estep8_derives :
  derives che_error_axioms example_R error_G empty_traces Ok
    (lift_state E8) (CAtom (CASLche_ATOM.CHERetPair cap_c cap_s)) (lift_state E9).
Proof.
  unfold E8, E9.
  rewrite (sep_move4 Ksx_AU Kdata_AU Kc_AU Ks_AU (cur_compart tau_ssl)).
  rewrite (sep_move4 (cur_compart tau_ssl) Ksx_AU Kdata_AU Kc_AU Ks_AU).
  rewrite (sep_move4 Ks_AU (cur_compart tau_ssl) Ksx_AU Kdata_AU Kc_AU).
  apply casl_frame_sep3; [exact wf_error|].
  right; left. eapply UNSAFE_RetTwoNoSeal. exact f_ngx_all.
Qed.

(** The final state of the error derivation violates INV: nginx's [conn] slot
    holds an unsealed capability to an OpenSSL-owned object. *)
Theorem E9_violates_INV : sset_subset E9 (fun s => ~ INV_set s).
Proof.
  intros st Hst HINV.
  assert (Hlu : cap_lookup (che_capmap st) cap_conn
                = Some (Allocated, Unsealed, tau_ssl)).
  { apply (sep_list_cpt_lookup
             [Kc_AU; Ks_AU; cur_compart tau_ngx; Ksx_AU; Kdata_AU]
             cap_conn Allocated Unsealed tau_ssl [Kctx_AU; Kct_AU] st Hst). }
  assert (Hne : NginxFS.holder cap_conn <> tau_ssl).
  { rewrite holder_conn. exact tau_ngx_neq_ssl. }
  specialize (HINV cap_conn Allocated Unsealed tau_ssl Hlu Hne).
  discriminate.
Qed.

(** Error step 9 (Assert-Fail): the assertion of INV fails. *)
Theorem estep9_derives :
  derives che_error_axioms example_R error_G (singleton_trace err_uid) (Err 1)
    (lift_state E9) (CAtom (CASLche_ATOM.CHEAssert INV_set)) (lift_state E9).
Proof.
  apply casl_atom_err_whole with (uid := err_uid).
  - exact wf_error.
  - unfold error_G. rewrite Nat.eqb_refl. reflexivity.
  - left. apply CHE_AssertFailed. intros s Hs.
    apply E9_violates_INV.
    exact (proj1 (state_sep_che_emp E9 s) (proj1 (state_sep_comm E9 che_emp s) Hs)).
Qed.

(** THE ERROR DERIVATION: the same program, under the UNSAFE rules, ends in an
    [er] triple whose final state violates INV. *)
Theorem nginx_openssl_error_derivation :
  derives che_error_axioms example_R error_G (singleton_trace err_uid) (Err 1)
    (lift_state E1) prog_safe (lift_state E9).
Proof.
  unfold prog_safe.
  eapply casl_seq_left_ok; [exact wf_error | exact estep1_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep1a_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep2_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep3_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep4_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep5_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep6_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep7_derives |].
  eapply casl_seq_left_ok; [exact wf_error | exact estep8_derives |].
  exact estep9_derives.
Qed.
