(* Copyright 2026 Bloomberg Finance L.P. *)
(* Distributed under the terms of the MIT license. *)

(** * CASL_Model: the CASL model

    The model of CASL, the concurrent adversarial separation logic on which
    the paper's formal model of heap compartmentalization is built (§ Formal
    Heap Compartmentalization Model, which cites it as [CASL]):
    - the state PCM (a CASL parameter, instantiated by [CASLche_PCM]),
    - worlds = pairs (local, shared) of compatible states,
    - action identifiers, action maps (rely/guarantee) and traces,
    - well-formedness of rely/guarantee pairs, and stability, the side
      condition of the CASL-Frame rule.

    Two requirements, both needed by CASL's soundness proof:
    - The PCM must be cancellative (true for disjoint-union heaps), and
      rely post-conditions must be precise.  Precision is used by
      EnvL/EnvR/EnvEr to recover the frame of a rely action.
    - Worlds are plain pairs; well-formedness (compatibility of the
      local and shared states) is a separate predicate [wf_world], so
      world sets are ordinary predicates and no proof irrelevance is
      needed.

    This file is the artifact's own copy of the CASL model: its code is
    that of the CASL model in the CASL development, with only comments and
    module names changed.  Nothing outside this directory is needed. *)

From Stdlib Require Import List.
Import ListNotations.

(** ** Exit conditions, action identifiers, traces

    These do not depend on the PCM and are shared by all instances. *)

Inductive Tag : Type :=
| Ok : Tag
| Err : nat -> Tag.

Definition is_error (t : Tag) : bool :=
  match t with Ok => false | Err _ => true end.

Definition UID := nat.

Definition STrace := list UID.
Definition STraceSet := STrace -> Prop.

(** Θ0 = {[]} *)
Definition empty_traces : STraceSet := fun tr => tr = [].

(** Θ1 ++ Θ2 *)
Definition traces_concat (T1 T2 : STraceSet) : STraceSet :=
  fun tr => exists tr1 tr2, T1 tr1 /\ T2 tr2 /\ tr = tr1 ++ tr2.

(** α :: Θ *)
Definition uid_prepend (u : UID) (T : STraceSet) : STraceSet :=
  fun tr => exists tr', T tr' /\ tr = u :: tr'.

Definition singleton_trace (u : UID) : STraceSet := fun tr => tr = [u].

Definition traceset_union (T1 T2 : STraceSet) : STraceSet :=
  fun tr => T1 tr \/ T2 tr.

Definition traceset_inter (T1 T2 : STraceSet) : STraceSet :=
  fun tr => T1 tr /\ T2 tr.

Definition traceset_subset (T1 T2 : STraceSet) : Prop :=
  forall tr, T1 tr -> T2 tr.

Definition traceset_nonempty (T : STraceSet) : Prop := exists tr, T tr.

(** Θ^n = Θ ++ ... ++ Θ (n times); Θ^0 = Θ0. *)
Fixpoint traces_pow (T : STraceSet) (n : nat) : STraceSet :=
  match n with
  | 0 => empty_traces
  | S m => traces_concat (traces_pow T m) T
  end.

(** ** PCM module type

    A partial commutative monoid (State, ∘, State0).  Every law below is
    satisfied by disjoint union of finite partial maps, so instances
    prove them; nothing here is assumed globally. *)

Module Type PCM.
  Parameter State : Type.
  Parameter compose : State -> State -> option State.
  Parameter is_unit : State -> Prop.

  Parameter compose_comm : forall a b, compose a b = compose b a.

  Parameter compose_assoc : forall a b c ab abc,
    compose a b = Some ab ->
    compose ab c = Some abc ->
    exists bc, compose b c = Some bc /\ compose a bc = Some abc.

  Parameter unit_exists : exists u, is_unit u.

  Parameter unit_compose : forall u s, is_unit u -> compose u s = Some s.

  (** Cancellativity: holds for disjoint union. *)
  Parameter compose_cancel : forall a b b' c,
    compose a b = Some c -> compose a b' = Some c -> b = b'.
End PCM.

(** ** CASL model functor *)

Module CASLModel (P : PCM).

  Export P.

  (** *** Derived PCM facts *)

  Definition compatible (s1 s2 : State) : Prop :=
    exists s, compose s1 s2 = Some s.

  Lemma compose_assoc_r : forall a b c bc abc,
    compose b c = Some bc ->
    compose a bc = Some abc ->
    exists ab, compose a b = Some ab /\ compose ab c = Some abc.
  Proof.
    intros a b c bc abc Hbc Habc.
    rewrite compose_comm in Hbc, Habc.
    destruct (compose_assoc c b a bc abc Hbc Habc) as [ba [Hba Hcba]].
    exists ba. rewrite compose_comm. split; [exact Hba |].
    rewrite compose_comm. exact Hcba.
  Qed.

  Lemma compose_unit_r : forall u s, is_unit u -> compose s u = Some s.
  Proof. intros u s Hu. rewrite compose_comm. apply unit_compose. exact Hu. Qed.

  Lemma unit_identity : forall u s s', is_unit u -> compose s u = Some s' -> s = s'.
  Proof.
    intros u s s' Hu H. rewrite (compose_unit_r u s Hu) in H.
    injection H. auto.
  Qed.

  Lemma compose_cancel_r : forall a a' b c,
    compose a b = Some c -> compose a' b = Some c -> a = a'.
  Proof.
    intros a a' b c H1 H2. rewrite compose_comm in H1, H2.
    eapply compose_cancel; eassumption.
  Qed.

  Lemma compatible_comm : forall a b, compatible a b -> compatible b a.
  Proof. intros a b [s H]. exists s. rewrite compose_comm. exact H. Qed.

  (** If a ∘ b is compatible with c, then a is compatible with c. *)
  Lemma compatible_sub : forall a b ab c,
    compose a b = Some ab -> compatible ab c -> compatible a c.
  Proof.
    intros a b ab c Hab [abc Habc].
    destruct (compose_assoc a b c ab abc Hab Habc) as [bc [_ Habc']].
    rewrite compose_comm in Hab.
    destruct (compose_assoc b a c ab abc Hab Habc) as [ac [Hac _]].
    exists ac. exact Hac.
  Qed.

  (** *** Worlds

      A world is a pair (l, g) of a local and a shared state; it is
      well-formed when l # g. *)

  Definition World : Type := (State * State)%type.
  Definition wlocal (w : World) : State := fst w.
  Definition wshared (w : World) : State := snd w.

  Definition wf_world (w : World) : Prop := compatible (fst w) (snd w).

  (** ⌈(l, g)⌉ = l ∘ g *)
  Definition flat (w : World) (s : State) : Prop := compose (fst w) (snd w) = Some s.

  Definition WorldSet := World -> Prop.
  Definition StateSet := State -> Prop.

  (** World composition • : locals compose, shared states agree. *)
  Definition wcomp (w1 w2 w : World) : Prop :=
    snd w1 = snd w /\ snd w2 = snd w /\ compose (fst w1) (fst w2) = Some (fst w).

  (** *** Assertions *)

  (** p ∗ q on state sets *)
  Definition state_sep (p q : StateSet) : StateSet :=
    fun s => exists s1 s2, p s1 /\ q s2 /\ compose s1 s2 = Some s.

  (** P ∗ Q on world sets *)
  Definition world_sep (P Q : WorldSet) : WorldSet :=
    fun w => exists w1 w2, P w1 /\ Q w2 /\ wcomp w1 w2 w.

  (** [p ∗ f]: the shared state decomposes as p-piece ∘ f-piece. *)
  Definition local_shared (p f : StateSet) : WorldSet :=
    fun w => state_sep p f (snd w).

  (** p lifted to worlds: the local state is in p, the shared state is arbitrary. *)
  Definition lift_state (p : StateSet) : WorldSet := fun w => p (fst w).

  Definition wset_inter (P Q : WorldSet) : WorldSet := fun w => P w /\ Q w.
  Definition wset_union (P Q : WorldSet) : WorldSet := fun w => P w \/ Q w.
  Definition wset_subset (P Q : WorldSet) : Prop := forall w, P w -> Q w.
  Definition wset_empty : WorldSet := fun _ => False.

  Definition sset_full : StateSet := fun _ => True.
  Definition sset_subset (p q : StateSet) : Prop := forall s, p s -> q s.

  Lemma wf_world_comp_l : forall w1 w2 w,
    wcomp w1 w2 w -> wf_world w -> wf_world w1.
  Proof.
    intros [l1 g1] [l2 g2] [l g] [H1 [H2 H3]] Hwf. simpl in *. subst.
    unfold wf_world. simpl. eapply compatible_sub; eassumption.
  Qed.

  Lemma wf_world_comp_r : forall w1 w2 w,
    wcomp w1 w2 w -> wf_world w -> wf_world w2.
  Proof.
    intros [l1 g1] [l2 g2] [l g] [H1 [H2 H3]] Hwf. simpl in *. subst.
    unfold wf_world. simpl. rewrite compose_comm in H3.
    eapply compatible_sub; eassumption.
  Qed.

  (** *** Action maps (rely and guarantee) *)

  Definition ActionTriple := (StateSet * Tag * StateSet)%type.
  Definition UMap := UID -> option ActionTriple.

  Definition empty_umap : UMap := fun _ => None.

  Definition in_dom (m : UMap) (u : UID) : Prop := exists act, m u = Some act.

  (** dsj(R, G) *)
  Definition umap_disjoint (R G : UMap) : Prop :=
    forall u, ~ (in_dom R u /\ in_dom G u).

  (** R1 ⊆ R2 *)
  Definition umap_leq (R1 R2 : UMap) : Prop :=
    forall u act, R1 u = Some act -> R2 u = Some act.

  (** Left-biased union; used as G1 ⊎ G2 (disjoint) and R ∪ G. *)
  Definition umap_union (M1 M2 : UMap) : UMap :=
    fun u => match M1 u with Some act => Some act | None => M2 u end.

  Definition umap_inter (M1 M2 : UMap) : UMap :=
    fun u => match M1 u, M2 u with
             | Some act1, Some _ => Some act1
             | _, _ => None
             end.

  (** R' ≼θ R: R' and R agree on the actions of θ that R' defines. *)
  Definition rely_consistent_trace (tr : STrace) (R' R : UMap) : Prop :=
    forall u act, In u tr -> R' u = Some act -> R u = Some act.

  (** R' ≼Θ R *)
  Definition rely_consistent (T : STraceSet) (R' R : UMap) : Prop :=
    forall tr, T tr -> rely_consistent_trace tr R' R.

  (** Θ ⊑ G *)
  Definition traces_in_guar (T : STraceSet) (G : UMap) : Prop :=
    forall tr, T tr -> forall u, In u tr -> in_dom G u.

  (** *** Well-formedness *)

  (** q ∗ {l} ≠ ∅  ⇒  p ∗ {l} ≠ ∅ *)
  Definition frame_preserving (p q : StateSet) : Prop :=
    forall l, (exists gq s, q gq /\ compose gq l = Some s) ->
              (exists gp s, p gp /\ compose gp l = Some s).

  (** A state set is precise when it picks out at most one sub-state of
      any state. *)
  Definition precise (q : StateSet) : Prop :=
    forall s1 s2 f1 f2 s,
      q s1 -> q s2 -> compose s1 f1 = Some s -> compose s2 f2 = Some s -> s1 = s2.

  (** wf(R, G), strengthened with precision of rely post-conditions. *)
  Definition well_formed (R G : UMap) : Prop :=
    umap_disjoint R G /\
    forall u p tg q, R u = Some (p, tg, q) -> frame_preserving p q /\ precise q.

  (** *** Stability (the side condition of CASL-Frame)

      stable(Rf, M): replacing an M-action post-state sub-part of the
      shared state by any pre-state keeps (well-formed) worlds in Rf. *)
  Definition stable (Rf : WorldSet) (M : UMap) : Prop :=
    forall l g u p tg q gq g' gp gn,
      Rf (l, g) ->
      M u = Some (p, tg, q) ->
      q gq -> compose gq g' = Some g ->
      p gp -> compose gp g' = Some gn ->
      compatible l gn ->
      Rf (l, gn).

  (** *** Basic lemmas *)

  Lemma rely_consistent_refl : forall T M, rely_consistent T M M.
  Proof. intros T M tr _ u act _ H. exact H. Qed.

  Lemma traceset_subset_refl : forall T, traceset_subset T T.
  Proof. intros T tr H. exact H. Qed.

  Lemma traces_concat_empty_r : forall T tr,
    traces_concat T empty_traces tr <-> T tr.
  Proof.
    intros T tr. unfold traces_concat, empty_traces. split.
    - intros [tr1 [tr2 [HT [-> ->]]]]. rewrite app_nil_r. exact HT.
    - intros HT. exists tr, []. rewrite app_nil_r. auto.
  Qed.

  Lemma traces_concat_empty_l : forall T tr,
    traces_concat empty_traces T tr <-> T tr.
  Proof.
    intros T tr. unfold traces_concat, empty_traces. split.
    - intros [tr1 [tr2 [-> [HT ->]]]]. exact HT.
    - intros HT. exists [], tr. auto.
  Qed.

  Lemma umap_disjoint_none_r : forall R G,
    (forall u, R u <> None -> G u = None) -> umap_disjoint R G.
  Proof.
    intros R G Hdom u [[a Ha] [b Hb]].
    assert (G u = None) as HG by (apply Hdom; congruence).
    congruence.
  Qed.

  (** Units are precise singletons' frames: a unit-only set adds nothing. *)
  Lemma state_sep_unit_l : forall (q p : StateSet) s,
    (forall s, q s -> is_unit s) -> state_sep q p s -> p s.
  Proof.
    intros q p s Hu [s1 [s2 [Hq [Hp Hc]]]].
    rewrite compose_comm in Hc.
    rewrite (unit_identity s1 s2 s (Hu _ Hq) Hc) in Hp. exact Hp.
  Qed.

  Lemma state_sep_unit_l_rev : forall (q p : StateSet) s,
    (exists u, q u /\ is_unit u) -> p s -> state_sep q p s.
  Proof.
    intros q p s [u [Hq Hu]] Hp. exists u, s. repeat split; auto.
    apply unit_compose. exact Hu.
  Qed.

End CASLModel.
