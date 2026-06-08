(** Auto-generated guard types from specs/core.shen.
    DO NOT EDIT - regenerate with shengen-ocaml. *)

(** kl-value *)
type kl_value
val make_kl_value : float -> (kl_value, string) result
val x_of_kl_value : kl_value -> float

(** interned-symbol *)
type interned_symbol
val make_interned_symbol : string -> float -> (interned_symbol, string) result
val name_of_interned_symbol : interned_symbol -> string
val id_of_interned_symbol : interned_symbol -> float

(** fn-binding *)
type fn_binding
val make_fn_binding : interned_symbol -> float -> (fn_binding, string) result
val name_of_fn_binding : fn_binding -> interned_symbol
val arity_of_fn_binding : fn_binding -> float

(** val-binding *)
type val_binding
val make_val_binding : interned_symbol -> (val_binding, string) result
val name_of_val_binding : val_binding -> interned_symbol

(** namespace-checked *)
type namespace_checked
val make_namespace_checked : fn_binding -> (namespace_checked, string) result
val b_of_namespace_checked : namespace_checked -> fn_binding

(** resolved-arity *)
type resolved_arity
val make_resolved_arity : fn_binding -> float -> (resolved_arity, string) result
val f_of_resolved_arity : resolved_arity -> fn_binding
val arity_of_resolved_arity : resolved_arity -> float

(** checked-application *)
type checked_application
val make_checked_application : resolved_arity -> float -> (checked_application, string) result
val f_of_checked_application : checked_application -> resolved_arity
val argcount_of_checked_application : checked_application -> float

(** valid-kl-ast *)
type valid_kl_ast
val make_valid_kl_ast : string -> (valid_kl_ast, string) result
val source_of_valid_kl_ast : valid_kl_ast -> string

(** tail-annotated *)
type tail_annotated
val make_tail_annotated : valid_kl_ast -> (tail_annotated, string) result
val ast_of_tail_annotated : tail_annotated -> valid_kl_ast

(** generated-module *)
type generated_module
val make_generated_module : tail_annotated -> string -> (generated_module, string) result
val ir_of_generated_module : generated_module -> tail_annotated
val modname_of_generated_module : generated_module -> string

(** registered-module *)
type registered_module
val make_registered_module : generated_module -> (registered_module, string) result
val mod__of_registered_module : registered_module -> generated_module

(** kernel-loaded *)
type kernel_loaded
val make_kernel_loaded : float -> (kernel_loaded, string) result
val count_of_kernel_loaded : kernel_loaded -> float

(** boot-complete *)
type boot_complete
val make_boot_complete : kernel_loaded -> (boot_complete, string) result
val k_of_boot_complete : boot_complete -> kernel_loaded

(** eval-kl-safe *)
type eval_kl_safe
val make_eval_kl_safe : valid_kl_ast -> (eval_kl_safe, string) result
val expr_of_eval_kl_safe : eval_kl_safe -> valid_kl_ast

