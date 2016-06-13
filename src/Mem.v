Require Import FunctionalExtensionality.

Set Implicit Arguments.

Definition EqDec (T : Type) := forall (a b : T), {a = b} + {a <> b}.

(* generalized memory of any address / value type *)

Definition mem {A : Type} {AEQ : EqDec A} {V : Type} := A -> option V.
Definition empty_mem {A : Type} {AEQ : EqDec A} {V : Type} : @mem A AEQ V := fun a => None.

Section GenMem.
  Variable A : Type.
  Variable V : Type.
  Variable AEQ : EqDec A.

  Definition upd (m : @mem A AEQ V) (a : A) (v : V) : @mem A AEQ V :=
    fun a' => if AEQ a' a then
      match m a with
      | None => None
      | Some _ => Some v
      end else m a'.

  Definition delete (m : @mem A AEQ V) (a : A) : @mem A AEQ V :=
    fun a' => if AEQ a' a then None else m a'.

  Definition insert (m : @mem A AEQ V) (a : A) (v : V) : @mem A AEQ V :=
    fun a' => if AEQ a' a then
      match m a with
      | None => Some v
      | Some _ => m a'
      end else m a'.

  Theorem upd_eq : forall m (a : A) (v v' : V) a',
    m a = Some v' -> a' = a -> upd m a v a' = Some v.
  Proof.
    intros; subst; unfold upd.
    rewrite H.
    destruct (AEQ a a); tauto.
  Qed.

  Theorem upd_ne : forall m (a : A) (v : V) a',
    a' <> a -> upd m a v a' = m a'.
  Proof.
    intros; subst; unfold upd.
    destruct (AEQ a' a); tauto.
  Qed.

  Theorem upd_repeat: forall m (a : A) (v v':V),
    upd (upd m a v') a v = upd m a v.
  Proof.
    intros; apply functional_extensionality; unfold upd; intros.
    destruct (AEQ a a); try congruence.
    destruct (AEQ x a); auto.
    destruct (m a); auto.
  Qed.

  Theorem upd_nop: forall m (a : A) (v : V),
    m a = Some v ->
    upd m a v = m.
  Proof.
    intros; apply functional_extensionality; intros.
    case_eq (AEQ a x); intros; subst.
    repeat erewrite upd_eq; eauto.
    repeat rewrite upd_ne; auto.
  Qed.

  Theorem upd_comm: forall m (a0 : A) (v0 : V) a1 v1, a0 <> a1
    -> upd (upd m a0 v0) a1 v1 = upd (upd m a1 v1) a0 v0.
  Proof.
    intros; apply functional_extensionality; unfold upd; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

  Theorem upd_insert_comm: forall m (a0 : A) (v0 : V) a1 v1, a0 <> a1
    -> upd (insert m a0 v0) a1 v1 = insert (upd m a1 v1) a0 v0.
  Proof.
    intros; apply functional_extensionality; unfold upd, insert; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

  Theorem upd_delete_comm: forall m (a0 : A) a1 (v1 : V), a0 <> a1
    -> upd (delete m a0) a1 v1 = delete (upd m a1 v1) a0.
  Proof.
    intros; apply functional_extensionality; unfold upd, delete; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

  Theorem insert_comm: forall m (a0 : A) (v0 : V) a1 v1, a0 <> a1
    -> insert (insert m a0 v0) a1 v1 = insert (insert m a1 v1) a0 v0.
  Proof.
    intros; apply functional_extensionality; unfold insert; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

  Theorem insert_delete_comm: forall m (a0 : A) a1 (v1 : V), a0 <> a1
    -> insert (delete m a0) a1 v1 = delete (insert m a1 v1) a0.
  Proof.
    intros; apply functional_extensionality; unfold insert, delete; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

  Theorem delete_comm: forall m (a0 : A) a1, a0 <> a1
    -> delete (delete m a0) a1 = delete (delete m a1) a0.
  Proof.
    intros; apply functional_extensionality; unfold delete; intros.
    destruct (AEQ a1 a0); destruct (AEQ a0 a1); try congruence.
    case_eq (AEQ x a1); case_eq (AEQ x a0); intros; subst; try congruence.
  Qed.

End GenMem.
