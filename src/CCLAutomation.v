Require Import CCLProg CCLMonadLaws CCLHoareTriples CCLPrimitives.
Require Export Automation.

Ltac simplify :=
  repeat match goal with
         | [ H: _ /\ _ |- _ ] => destruct H
         | [ |- exists (_:unit), _ ] => exists tt
         | [ |- True /\ _ ] => split; [ exact I | ]
         | [ a:unit |- _ ] => clear a
         | _ => progress deex
         | _ => progress subst
         | _ => break_tuple
         | _ => progress safe_intuition
         | _ => progress intros
         end.

Ltac spec_monad_simpl :=
  let rewrite_equiv H := eapply spec_respects_exec_equiv;
                         [ solve [ apply H ] | ] in
  repeat match goal with
         | [ |- cprog_spec _ _ _ (Bind _ (Ret _)) ] =>
           rewrite_equiv monad_right_id
         | [ |- cprog_spec _ _ _ (Bind (Ret _) _) ] =>
           rewrite_equiv monad_left_id
         | [ |- cprog_spec _ _ _ (Bind (Bind _ _) _) ] =>
           rewrite_equiv monad_assoc
         end.

Ltac monad_simpl :=
  let rewrite_equiv H := eapply cprog_ok_respects_exec_equiv;
                         [ solve [ apply H ] | ] in
  repeat match goal with
         | [ |- cprog_ok _ _ _ (Bind _ (Ret _)) ] =>
           rewrite_equiv monad_right_id
         | [ |- cprog_ok _ _ _ (Bind (Ret _) _) ] =>
           rewrite_equiv monad_left_id
         | [ |- cprog_ok _ _ _ (Bind (Bind _ _) _) ] =>
           rewrite_equiv monad_assoc
         end.

Ltac step :=
  intros;
  match goal with
  | [ |- cprog_spec _ _ _ _ ] =>
    spec_monad_simpl;
    first [ apply Ret_general_ok; simplify
          | unfold cprog_spec; step]
  | [ |- cprog_ok _ _ _ _ ] =>
    eapply cprog_ok_weaken; [
      match goal with
      | _ => monad_simpl; solve [ auto with prog ]
      | _ => apply Ret_ok
      | _ => monad_simpl;
            lazymatch goal with
            | [ |- cprog_ok _ _ _ (Bind ?p _) ] =>
              fail "no spec for" p
            | [ |- cprog_ok _ _ _ ?p ] =>
              fail "no spec for" p
            end
      end | ];
    simplify
  end.

Ltac hoare finisher :=
  let check :=
      try lazymatch goal with
          | [ |- cprog_ok _ _ _ _ ] => idtac
          | _ => fail 1
          end in
  let cleanup :=
      try ((intuition auto); let n := numgoals in guard n <= 1) in
  repeat (step; try (finisher; check); cleanup).