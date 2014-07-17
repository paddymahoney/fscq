Require Import List.
Require Import Arith.
Import ListNotations.
Require Import CpdtTactics.
Require Import FsTactics.
Require Import Storage.
Require Import Disk.
Require Import Util.
Require Import Trans2.
Require Import Inode.

Set Implicit Arguments.

Section Block.

(* block allocation *)

Inductive bproc :=
  | BHalt
  | BIRead (inum:inodenum) (rx: inode -> bproc)
  | BIWrite (inum: inodenum) (i:inode) (rx: bproc)
  | BAllocate (rx: option blocknum -> bproc)
  | BFree (bn:blocknum) (rx: bproc)
  | BRead (bn:blocknum) (rx:block -> bproc)
  | BWrite (bn:blocknum) (b: block) (rx: bproc).

Bind Scope iprog_scope with bproc.

Notation "ra <- a ; b" := (a (fun ra => b))
  (right associativity, at level 60) : iprog_scope.

Notation "a ;; b" := (a (b))
  (right associativity, at level 60) : iprog_scope.

Open Scope iprog_scope.

Program Fixpoint find_block bm bn off (OFFOK: off <= SizeBlock) rx :=
  match off with
  | O => rx None
  | S off' =>
    let isfree := (FreeList bm off') in
    if isfree then rx (Some (SizeBlock * bn + off'))
    else @find_block bm bn off' _ rx
  end.

Definition do_ballocate rx :=
  bm <- IReadBlockMap 0;
  find_block bm 0 SizeBlock rx.

Definition do_free bn rx :=
  rx.

Program Fixpoint compile_bi (p:bproc) : iproc :=
  match p with
  | BHalt => IHalt
  | BIWrite inum i rx => IWrite inum i (compile_bi rx)
  | BIRead inum rx => IRead inum (fun v => compile_bi (rx v))
  | BRead bn rx => IReadBlock bn (fun v => compile_bi (rx v))
  | BWrite bn b rx => IWriteBlock bn b (compile_bi rx)
  | BAllocate rx => do_ballocate (fun v => compile_bi (rx v))
  | BFree bn rx => do_bfree bn (compile_bi rx)
  end.

Close Scope iprog_scope.

(* For small-step simulation and proof *)

Record bstate := BSt {
  BSProg: bproc;
  BSInodes: istorage;
  BSBlockMap: bmstorage;
  BSBlocks: bstorage
}.


Inductive bstep : bstate -> bstate -> Prop :=
  | BsmHalt: forall i m b,
    istep (BSt BHalt i m b) (BSt IHalt i m b)
  | BsmIwrite: forall is inum i m b rx,
    istep (ISt (IWrite inum i rx) is m b) (ISt rx (iwrite is inum i) m b)
  | BsmIread: forall is inum b m rx,
    istep (ISt (IRead inum rx) is m b) (ISt (rx (iread is inum)) is m b)
  | BsmIwriteBlockMap: forall is bn bm map b rx,
    istep (ISt (IWriteBlockMap bn bm rx) is map b) (ISt rx is (blockmap_write map bn bm) b)
  | BsmIreadBlockMap: forall is bn map b rx,
    istep (ISt (IReadBlockMap bn rx) is map b) (ISt (rx (blockmap_read map bn)) is map b)
  | BsmIreadBlock: forall is bn b m rx,
    istep (ISt (IReadBlock bn rx) is m b) (ISt (rx (bread b bn)) is m b)
  | BsmIwriteBlock: forall is bn b bs m rx,
    istep (ISt (IWriteBlock bn b rx) is m bs) (ISt rx is m (bwrite bs bn b)).

(* XXX perhaps for showing small-step simulation does something sensible? *)
Fixpoint iexec (p:iproc) (s:istate) : istate :=
  match p with
  | IHalt => s
  | IWrite inum i rx  =>
    iexec rx (ISt p (iwrite (ISInodes s) inum i) (ISBlockMap s) (ISBlocks s))
  | IRead inum rx =>
    iexec (rx (iread (ISInodes s) inum)) s                            
  | IReadBlockMap bn rx =>
    iexec (rx (blockmap_read (ISBlockMap s) bn)) s
  | IWriteBlockMap bn bm rx =>
    iexec rx (ISt p (ISInodes s) (blockmap_write (ISBlockMap s) bn bm) (ISBlocks s))
  | IReadBlock o rx =>
    iexec (rx (bread (ISBlocks s) o)) s
  | IWriteBlock o b rx =>
    iexec rx (ISt p (ISInodes s) (ISBlockMap s) (bwrite (ISBlocks s) o b))
  end.

End Inode.
