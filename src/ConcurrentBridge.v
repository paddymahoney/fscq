Require Import CoopConcur.
Require Import ConcurrentCache.
Require Import Specifications.
Require Import CoopConcurMonad.
Import HlistNotations.

Module MakeBridge (C:CacheSubProtocol).

  Module ConcurrentCache := MakeConcurrentCache C.
  (* App (and some useless aspects of the projection) *)
  Import C.
  (* cache variables (and uselessly the cache invariant/guar) *)
  Import CacheProtocol.
  (* cache operations (and a preponderance of useless automation) *)
  Import ConcurrentCache.

  (* Exc is a (somewhat obscure) synonym for option defined in Specif *)
  Fixpoint compile {T} (p: Prog.prog T) : prog App.Sigma (Exc T) :=
    match p with
    | Prog.Ret v => Ret (value v)
    | Prog.Read a => opt_v <- cache_read a;
                        match opt_v with
                        | Some v => Ret (value v)
                        (* in this branch T = valu so error_rx is safe;
                        might need to write this as a dependent match
                        to get it to typecheck *)
                        | None => Ret error
                        end
    | Prog.Write a v => _ <- cache_write a v;
                         Ret (value tt)
    | Prog.Sync => (* current concurrent disk model has no
                     asynchrony, but otherwise would need to issue
                     our own Sync here *)
      Ret (value tt)
    (* TODO: should really just remove Trim from Prog.prog *)
    | Prog.Trim a => Ret error
    (* TODO: should be a direct translation, but need hashing in
      concurrent execution semantics *)
    | Prog.Hash buf => Ret error
    | Prog.Bind p1 p2 => x <- compile p1;
                          match x with
                          | Some x => compile (p2 x)
                          | None => Ret error
                          end
    end.

  Record ConcurHoareSpec R :=
    ConcurSpec
      { concur_spec_pre: TID -> DISK ->
                         memory App.Sigma -> abstraction App.Sigma -> abstraction App.Sigma -> Prop;
        concur_spec_post: TID -> R ->
                          DISK -> memory App.Sigma -> abstraction App.Sigma -> abstraction App.Sigma ->
                          DISK -> memory App.Sigma -> abstraction App.Sigma -> abstraction App.Sigma -> Prop }.

  Definition concur_hoare_double R A (spec: A -> ConcurHoareSpec R)
             (p: prog App.Sigma R) :=
    forall T (rx: _ -> prog App.Sigma T) (tid:TID),
      valid App.delta tid
            (fun done d m s_i s =>
               exists a,
                 concur_spec_pre (spec a) tid d m s_i s /\
                 (forall ret_,
                     valid App.delta tid
                           (fun done_rx d' m' s_i' s' =>
                              concur_spec_post (spec a) tid ret_ d m s_i s d' m' s_i' s' /\
                              done_rx = done)
                           (rx ret_))
            ) (Bind p rx).

  (* [lift_disk] and [project_disk] convert between the view of the disk from
    sequential programs [Prog.prog] and concurrent programs [prog]: the
    differences are in the extra state (buffered writes vs race detecting
    readers) and the annoyance of having two different but provably equal valu
    definitions. *)

  Definition lift_disk (m: @mem addr _ prog_valuset) : DISK.
  Proof.
    intro a.
    destruct (m a); [ apply Some | apply None ].
    destruct p.
    exact (w, None).
  Defined.

  Definition project_disk (s: abstraction App.Sigma) : @mem addr _ prog_valuset.
  Proof.
    pose proof (get vdisk s) as vd.
    intro a.
    destruct (vd a); [ apply Some | apply None ].
    exact (w, nil).
  Defined.

  (* The idea of concurrent_spec is to compute a concurrent spec
     corresponding to sequential spec, capturing the same spec on top of
     the abstraction exported by the cache.

     TODO: need to also state only cache variables are modified, and thread
     through all lemmas.
   *)
  Definition concurrent_spec R (spec: SeqHoareSpec R) : ConcurHoareSpec (Exc R) :=
    let 'SeqSpec pre post _ := spec in
    ConcurSpec
      (fun tid d m s_i s =>
         invariant delta d m s /\
         pre (project_disk s) /\
         guar delta tid s_i s)
      (fun tid r d m s_i s d' m' s_i' s' =>
         invariant delta d' m' s' /\
         match r with
         | Some r => post r (project_disk s')
         | None => guar delta tid s s'
         end /\
         guar delta tid s_i' s').

  Ltac inv_exec' H :=
    inversion H; subst; repeat sigT_eq;
    try solve [ inv_step ].

  Ltac inv_exec :=
    match goal with
    | [ H: exec _ _ _ _ _ |- _ ] =>
      inv_exec' H
    end.

  Ltac inv_step :=
    match goal with
    | [ H: step _ _ _ _ _ |- _ ] =>
      inversion H; subst
    | [ H: fail_step _ _ _ _ |- _ ] =>
      inversion H; subst
    end.

  Ltac inv_outcome :=
    match goal with
    | [ H: @eq (outcome _) _ _ |- _ ] =>
      inversion H; subst
    end; unfold Exc in *; cleanup.

  Lemma exec_ret : forall Sigma (delta: Protocol Sigma)  tid T (v: T) st out,
      exec delta tid (Ret v) st out ->
      out = Finished st v.
  Proof.
    inversion 1; subst; repeat sigT_eq; auto.
    inversion H4.
    inversion H4.
  Qed.

  Ltac exec_ret :=
    match goal with
    | [ H: exec _ _ (Ret _) _ _ |- _ ] =>
      pose proof (exec_ret H); clear H; subst
    end; try inv_outcome.

  Hint Constructors Prog.exec.
  Hint Constructors Prog.step.

  Ltac _pattern_f x e :=
    match eval pattern x in e with
    | ?f _ => f
    end.

  Ltac _donecond :=
    match goal with
    | [ H: exec App.delta _ _ _ (Finished (?d', ?m', ?s_i', ?s') ?r) |- ?g ] =>
      let f := _pattern_f s' g in
      let f := _pattern_f s_i' f in
      let f := _pattern_f m' f in
      let f := _pattern_f d' f in
      let f := _pattern_f r f in
      f
    end.

  Theorem cache_read_hoare_triple : forall tid a
                                      d m s_i s
                                      d' m' s_i' s' v0 r,
      exec App.delta tid (cache_read a) (d, m, s_i, s)
           (Finished (d', m', s_i', s') r) ->
      cacheI d m s ->
      get vdisk s a = Some v0 ->
      modified [( vCache; vDisk0 )] s s' /\
      cacheI d' m' s' /\
      (forall v, r = Some v -> v = v0) /\
      s_i' = s_i /\
      guar delta tid s s'.
  Proof.
    intros.
    apply bind_right_id in H.
    let done := _donecond in
    apply (cache_read_ok (done:=done)) in H.
    repeat deex; inv_outcome; auto.

    exists v0; intuition.
    apply valid_unfold; intuition idtac.
    subst.
    exec_ret.
    repeat match goal with
           | |- exists _, _ => eexists
           end; intuition eauto.
  Qed.

  Theorem cache_read_no_failure : forall tid a
                                    d m s_i s
                                    v0,
      exec App.delta tid (cache_read a) (d, m, s_i, s)
           (Failed _) ->
      cacheI d m s ->
      get vdisk s a = Some v0 ->
      False.
  Proof.
    intros.
    apply bind_right_id in H.
    eapply cache_read_ok in H.
    2: instantiate (1 := fun _ _ _ _ _ => True).
    repeat deex; inv_outcome.
    exists v0; intuition.
    apply valid_unfold; intuition idtac.
    exec_ret.
    repeat match goal with
           | |- exists _, _ => eexists
           end; intuition eauto.
  Qed.

  Theorem cache_write_hoare_triple : forall tid a
                                      d m s_i s
                                      d' m' s_i' s' v0 v r,
      exec App.delta tid (cache_write a v) (d, m, s_i, s)
           (Finished (d', m', s_i', s') r) ->
      cacheI d m s ->
      get vdisk s a = Some v0 ->
      modified [( vCache; vDisk0; vWriteBuffer; vdisk )] s s' /\
      cacheI d' m' s' /\
      get vdisk s' = upd (get vdisk s) a v /\
      guar delta tid s s' /\
      s_i' = s_i /\
      r = tt.
  Proof.
    intros.
    destruct r.
    apply bind_right_id in H.
    let done := _donecond in
    apply (cache_write_ok (done:=done)) in H.
    repeat deex; inv_outcome; auto.

    exists v0; intuition.
    apply valid_unfold; intuition idtac.
    subst.
    exec_ret.
    repeat match goal with
           | |- exists _, _ => eexists
           end; intuition eauto.
  Qed.

  Lemma cache_addr_valid : forall d m s a v,
      cacheI d m s ->
      get vdisk s a = Some v ->
      exists v', d a = Some v'.
  Proof.
    unfold cacheI; intuition idtac.
    specialize (H2 a).
    specialize (H4 a).
    apply equal_f_dep with a in H3.
    destruct matches in *; intuition idtac;
      repeat deex; eauto.
    unfold DiskReaders.hide_readers in H3.
    simpl_match; congruence.
    unfold DiskReaders.hide_readers in H3.
    simpl_match; congruence.
  Qed.

  Lemma possible_sync_refl : forall A AEQ (m: @mem A AEQ valuset),
      PredCrash.possible_sync m m.
  Proof.
    unfold PredCrash.possible_sync; intros.
    destruct (m a).
    - right.
      destruct p.
      exists w, l, l; intuition auto.
    - left; auto.
  Qed.

  Lemma cache_read_success_in_domain : forall tid a
                                         d m s_i s v
                                         d' m' s_i' s',
      exec App.delta tid (cache_read a) (d, m, s_i, s)
           (Finished (d', m', s_i', s') (Some v)) ->
      cacheI d m s ->
      get vdisk s a = Some v.
  Proof.
    intros.
    inv_exec.

    inv_exec' H6.
    inv_step; repeat sigT_eq.

    unfold cacheI in H0; destruct_ands.
    rewrite H1 in *.
    destruct matches in *;
      repeat exec_ret.
    match goal with
    | [ H: WriteBuffer.wb_rep _ _ _ |- _ ] =>
      specialize (H a)
    end.
    simpl_match; destruct_ands; repeat deex.

    inv_exec' H8.
    inv_step; repeat sigT_eq.
    inv_exec' H15.
    inv_step; repeat sigT_eq.
    rewrite H0 in *.
    match goal with
    | [ H: MemCache.cache_rep _ _ _ |- _ ] =>
      specialize (H a)
    end.
    match goal with
    | [ H: WriteBuffer.wb_rep _ _ _ |- _ ] =>
      specialize (H a)
    end.
    destruct matches in *;
      repeat exec_ret;
      repeat simpl_match;
      destruct_ands; repeat deex.
    - apply equal_f_dep with a in H3.
      unfold DiskReaders.hide_readers in H3; simpl_match.
      congruence.
    - apply equal_f_dep with a in H3.
      unfold DiskReaders.hide_readers in H3; simpl_match.
      congruence.
    - apply equal_f_dep with a in H3.
      unfold DiskReaders.hide_readers in H3; simpl_match.
      (* need hoare spec for finish_fill *)
      admit.
    - inv_exec' H17.
      exec_ret.
  Admitted.

  Lemma project_disk_synced : forall s,
      sync_mem (project_disk s) = project_disk s.
  Proof.
    intros.
    extensionality a.
    unfold sync_mem, project_disk.
    destruct matches.
  Qed.

  Lemma project_disk_upd : forall (s s': abstraction App.Sigma) a v,
      get vdisk s' = upd (get vdisk s) a v ->
      project_disk s' = upd (project_disk s) a (v, nil).
  Proof.
    unfold project_disk, upd; intros.
    rewrite H.
    extensionality a'.
    destruct matches.
  Qed.

  Hint Extern 1 (guar _ _ ?a ?a) => apply guar_preorder.

  Theorem project_disk_vdisk_none : forall (s: abstraction App.Sigma) a,
      get vdisk s a = None ->
      project_disk s a = None.
  Proof.
    unfold project_disk; intros; rewrite H; auto.
  Qed.

  Hint Resolve project_disk_vdisk_none.

  Lemma value_is : forall T (v v':T),
      (forall t, Some v = Some t -> t = v') ->
      v = v'.
  Proof.
    eauto.
  Qed.

  Theorem cache_simulation_finish : forall T (p: Prog.prog T)
                                      (tid:TID) d m s_i s out hm,
      exec App.delta tid (compile p) (d, m, s_i, s) out ->
      cacheI d m s ->
      (forall d' m' s_i' s' (v:T),
          out = Finished (d', m', s_i', s') (value v) ->
          (Prog.exec (project_disk s) hm p (Prog.Finished (project_disk s') hm v) /\
           cacheI d' m' s' /\
           (* here we shouldn't guarantee the full guar App.delta, only the
           cache, since writes need not respect the global protocol *)
           guar delta tid s s' /\
           s_i' = s_i) \/
          (Prog.exec (project_disk s) hm p (Prog.Failed T))).
  Proof.
    induction p; simpl; intros; subst.
    - exec_ret.
      left.
      intuition eauto.
      apply cacheR_preorder.
    - inv_exec.
      destruct v0; exec_ret; eauto.

      case_eq (get vdisk s a); intros.
      {
        left.
        eapply cache_read_hoare_triple in H6; eauto.
        intuition auto; subst.
        apply value_is in H3; subst.

        eapply Prog.XStep; [ | apply possible_sync_refl ].
        assert (project_disk s = project_disk s') as Hproj.
        assert (get vdisk s = get vdisk s') by (apply H2; auto).
        unfold project_disk.
        replace (get vdisk s); auto.
        rewrite <- Hproj.
        eapply Prog.StepRead.
        unfold project_disk.
        simpl_match; auto.
      }
      {
        right.
        constructor.
        constructor.
        auto.
      }
    - inv_exec.
      destruct v0; exec_ret; eauto.

      case_eq (get vdisk s a); intros.
      {
        left.
        eapply cache_write_hoare_triple in H6; eauto.
        intuition auto; subst.

        eapply Prog.XStep with (upd (project_disk s) a (v, w::nil)).
        constructor.
        unfold project_disk; simpl_match; auto.
        assert (project_disk s' = upd (project_disk s) a (v, nil)) as Hproj.
        unfold project_disk.
        rewrite H3.
        extensionality a'.
        destruct (nat_dec a a'); subst; autorewrite with upd; auto.
        rewrite Hproj.
        eapply PredCrash.possible_sync_respects_upd; eauto.
        apply possible_sync_refl.
      }
      {
        right.
        constructor.
        constructor.
        auto.
      }
    - (* Sync *)
      (* probably don't need the writeback (just do nothing) *)
      exec_ret.
      left.
      intuition auto.
      eapply Prog.XStep; [ | apply possible_sync_refl ].
      rewrite <- project_disk_synced at 2.
      auto.
      apply cacheR_preorder.
    - (* Trim *)
      (* this is fine *)
      exec_ret.
    - (* Hash *)
      (* should add hashing to concurrent execution so it can be directly
      translated *)
      exec_ret.
    - (* Bind *)
      inv_exec' H0.
      destruct st' as (((d'',m''),s_i''),s'').
      destruct v0.

      * eapply IHp with (hm := hm) in H7; eauto.
        2: reflexivity.
        intuition auto.
        edestruct H; eauto.
        destruct_ands.
        subst.
        left.
        intuition auto.
        eapply Prog.XBindFinish; eauto.
        eapply cacheR_preorder; eauto.

      * left.
        split; intros; subst; exec_ret; inv_outcome.
  Qed.

  Theorem cache_simulation_failure : forall T (p: Prog.prog T)
                                       (tid:TID) d m s_i s hm,
      exec App.delta tid (compile p) (d, m, s_i, s) (Failed (Exc T)) ->
      cacheI d m s ->
      Prog.exec (project_disk s) hm p (Prog.Failed T).
  Proof.
  Admitted.

  Theorem prog_exec_ret : forall T m hm (r:T) out,
      Prog.exec m hm (Prog.Ret r) out ->
      out = (Prog.Finished m hm r).
  Proof.
    intros.
    inv_exec' H; auto.
    inversion H5.
    inversion H5.
    inversion H5.
  Qed.

  Hint Extern 1 (cacheR _ ?a ?a) => apply cacheR_preorder.

  Theorem cache_simulation_finish_error : forall T (p: Prog.prog T)
                                            (tid:TID) d m s_i s
                                            d' m' s_i' s',
      exec App.delta tid (compile p) (d, m, s_i, s) (Finished (d', m', s_i', s') error) ->
      cacheI d m s ->
      (cacheI d' m' s' /\
       guar delta tid s s' /\
       s_i' = s_i) \/
      (* TODO: all of these theorems should apply to any hashmap *)
      (Prog.exec (project_disk s) empty_hashmap p (Prog.Failed T)).
  Proof.
    induction p; simpl; intros.
    - exec_ret.
    - inv_exec.
      case_eq (get vdisk s a); intros.
      destruct v; exec_ret; try congruence.
      eapply cache_read_hoare_triple in H6; eauto.
      left.
      intuition eauto; subst.

      right.
      constructor.
      constructor.
      auto.
    - inv_exec.
      exec_ret.
    - exec_ret.
    - exec_ret.
      left.
      intuition auto.
    - exec_ret.
      left.
      intuition auto.
    - inv_exec.
      destruct v; try exec_ret.
      destruct st' as (((d'', m''), s_i''), s'').
      pose proof H7.
      eapply cache_simulation_finish with (hm:=empty_hashmap) in H7; eauto; try reflexivity.
      destruct H7; [ destruct_ands | right ]; subst.
      pose proof H9.
      eapply H in H9; eauto.
      destruct H9; [ destruct_ands | right ].
      subst.
      left.
      intuition eauto.
      eapply cacheR_preorder; eauto.
      eapply Prog.XBindFinish; eauto.
      eapply Prog.XBindFail; eauto.

      eapply IHp in H7; eauto.
      destruct H7; eauto.
  Qed.

  (* The master theorem: convert a sequential program into a concurrent
program via [compile], convert its spec to a concurrent spec via
[concurrent_spec], and prove the resulting concurrent Hoare double.
   *)
  Theorem compiler_correct : forall T (p: Prog.prog T) A (spec: A -> SeqHoareSpec T),
      seq_hoare_double spec p ->
      concur_hoare_double (fun a => concurrent_spec (spec a)) (compile p).
  Proof.
    unfold seq_hoare_double, concur_hoare_double, Hoare.corr2; intros.
    apply valid_unfold; intros.
    deex.
    case_eq (spec a); intros.
    rewrite H0 in *; simpl in *.
    destruct_ands.
    specialize (H T Prog.Ret).
    specialize (H (fun hm r d => seq_spec_post r d) (fun _ _ => True)).
    specialize (H (project_disk s) empty_hashmap).

    inv_exec' H1; try solve [ inv_fail_step ].
    destruct v as [r |].
    { (* executed succesfully to (Some r) *)
      destruct st' as (((d',m'),s_i'),s').
      match goal with
        | [ H: exec _ _ (compile p) _ _ |- _ ] =>
          eapply cache_simulation_finish with (hm:=empty_hashmap) in H;
            eauto; try reflexivity
      end.
      intuition.
      specialize (H (Prog.Finished (project_disk s') empty_hashmap r)).
      match type of H with
      | ?P -> ?Q -> _ =>
        assert Q
      end.
      apply ProgMonad.bind_right_id; auto.
      intuition.
      match type of H with
      | ?P -> ?Q -> ?R \/ ?R' =>
        assert (P -> R) as H'
      end.
      intros.
      intuition.
      repeat deex; congruence.
      match type of H' with
      | ?P -> _ => assert P
      end.
      {
        exists a; exists emp.
        repeat apply sep_star_lift_apply'; auto.
        apply pimpl_star_emp; auto.
        replace (spec a); simpl; auto.
        intros.
        destruct_lifts.
        replace (spec a) in *; simpl in *.

        match goal with
        | [ H: Prog.exec _ _ (Prog.Ret _) _ |- _ ] =>
          apply prog_exec_ret in H; subst
        end.
        left.
        do 3 eexists; eauto.
      }
      intuition; repeat deex; try congruence.
      repeat match goal with
               [ H: @eq (Prog.outcome _) _ _ |- _ ] =>
               inversion H; clear H
             end; subst.
      eapply H3 in H13; eauto.
      intuition auto.
      eapply cacheR_preorder; eauto.

      specialize (H (Prog.Failed T)).
      match type of H with
      | ?P -> ?Q -> _ =>
        assert Q
      end.
      apply ProgMonad.bind_right_id; auto.
      match type of H with
      | ?P -> ?Q -> ?R \/ ?R' =>
        assert (P -> R) as H'
      end.
      intros.
      intuition.
      repeat deex; congruence.
      match type of H' with
      | ?P -> _ => assert P
      end.
      {
        exists a; exists emp.
        repeat apply sep_star_lift_apply'; auto.
        apply pimpl_star_emp; auto.
        replace (spec a); simpl; auto.
        intros.
        destruct_lifts.
        replace (spec a) in *; simpl in *.

        match goal with
        | [ H: Prog.exec _ _ (Prog.Ret _) _ |- _ ] =>
          apply prog_exec_ret in H; subst
        end.
        left.
        do 3 eexists; eauto.
      }
      intuition; repeat deex; try congruence.
    }
    {
      (* execute to None case; need to apply cache_simulation_finish_error *)
      destruct st' as (((d', m'), s_i'), s').
      eapply cache_simulation_finish_error in H11; eauto.
      destruct H11.
      - destruct_ands.
        eapply H3 in H13; eauto.
        subst.
        intuition eauto.
        eapply cacheR_preorder; eauto.
      - (* failure if sequential isn't possible *)
        exfalso.
        specialize (H (Prog.Failed T)).
        match type of H with
        | ?P -> ?Q -> ?R \/ ?R' =>
          assert (P -> R) as H'
        end.
        apply ProgMonad.bind_right_id in H6; intuition auto.
        repeat deex; congruence.
        match type of H' with
        | ?P -> _ => assert P
        end.
        {
          exists a; exists emp.
          repeat apply sep_star_lift_apply'; auto.
          apply pimpl_star_emp; auto.
          replace (spec a); simpl; auto.
          intros.
          destruct_lifts.
          replace (spec a) in *; simpl in *.

          apply prog_exec_ret in H8; subst.
          left.
          do 3 eexists; eauto.
        }
        intuition; repeat deex; try congruence.
    }

    (* compiled code failed *)
    apply cache_simulation_failure with (hm:=empty_hashmap) in H11; auto.
    (* TODO: this snippet of proof is repetitive *)
    specialize (H (Prog.Failed T)).
    match type of H with
    | ?P -> ?Q -> ?R \/ ?R' =>
      assert (P -> R) as H'
    end.
    apply ProgMonad.bind_right_id in H11; intuition auto.
    repeat deex; congruence.
    match type of H' with
    | ?P -> _ => assert P
    end.
    {
      exists a; exists emp.
      repeat apply sep_star_lift_apply'; auto.
      apply pimpl_star_emp; auto.
      replace (spec a); simpl; auto.
      intros.
      destruct_lifts.
      replace (spec a) in *; simpl in *.

      apply prog_exec_ret in H7; subst.
      left.
      do 3 eexists; eauto.
    }
    intuition; repeat deex; try congruence.
  Qed.

End MakeBridge.

(* Local Variables: *)
(* company-coq-local-symbols: (("delta" . ?δ) ("Sigma" . ?Σ)) *)
(* End: *)