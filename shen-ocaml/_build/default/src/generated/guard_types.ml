(* Auto-generated guard types from specs/core.shen.
   DO NOT EDIT - regenerate with shengen-ocaml. *)

type kl_value = { kl_value_v : float }

let make_kl_value x =
  Ok { kl_value_v = x }

let x_of_kl_value t = t.kl_value_v

type interned_symbol = {
  interned_symbol_name : string;
  interned_symbol_id : float;
}

let make_interned_symbol name id =
  if not (id >= 0.) then
    Error "interned_symbol: validation failed: id >= 0"
  else
  Ok {
    interned_symbol_name = name;
    interned_symbol_id = id;
  }

let name_of_interned_symbol t = t.interned_symbol_name
let id_of_interned_symbol t = t.interned_symbol_id

type fn_binding = {
  fn_binding_name : interned_symbol;
  fn_binding_arity : float;
}

let make_fn_binding name arity =
  if not (arity >= 0.) then
    Error "fn_binding: validation failed: arity >= 0"
  else
  Ok {
    fn_binding_name = name;
    fn_binding_arity = arity;
  }

let name_of_fn_binding t = t.fn_binding_name
let arity_of_fn_binding t = t.fn_binding_arity

type val_binding = { val_binding_v : interned_symbol }

let make_val_binding name =
  Ok { val_binding_v = name }

let name_of_val_binding t = t.val_binding_v

type namespace_checked = { namespace_checked_v : fn_binding }

let make_namespace_checked b =
  Ok { namespace_checked_v = b }

let b_of_namespace_checked t = t.namespace_checked_v

type resolved_arity = {
  resolved_arity_f : fn_binding;
  resolved_arity_arity : float;
}

let make_resolved_arity f arity =
  if not (arity > 0.) then
    Error "resolved_arity: validation failed: arity > 0"
  else
  Ok {
    resolved_arity_f = f;
    resolved_arity_arity = arity;
  }

let f_of_resolved_arity t = t.resolved_arity_f
let arity_of_resolved_arity t = t.resolved_arity_arity

type checked_application = {
  checked_application_f : resolved_arity;
  checked_application_argcount : float;
}

let make_checked_application f argcount =
  if not (argcount >= 0.) then
    Error "checked_application: validation failed: argcount >= 0"
  else
  Ok {
    checked_application_f = f;
    checked_application_argcount = argcount;
  }

let f_of_checked_application t = t.checked_application_f
let argcount_of_checked_application t = t.checked_application_argcount

type valid_kl_ast = { valid_kl_ast_v : string }

let make_valid_kl_ast source =
  Ok { valid_kl_ast_v = source }

let source_of_valid_kl_ast t = t.valid_kl_ast_v

type tail_annotated = { tail_annotated_v : valid_kl_ast }

let make_tail_annotated ast =
  Ok { tail_annotated_v = ast }

let ast_of_tail_annotated t = t.tail_annotated_v

type generated_module = {
  generated_module_ir : tail_annotated;
  generated_module_modname : string;
}

let make_generated_module ir modname =
  Ok {
    generated_module_ir = ir;
    generated_module_modname = modname;
  }

let ir_of_generated_module t = t.generated_module_ir
let modname_of_generated_module t = t.generated_module_modname

type registered_module = { registered_module_v : generated_module }

let make_registered_module mod_ =
  Ok { registered_module_v = mod_ }

let mod__of_registered_module t = t.registered_module_v

type kernel_loaded = { kernel_loaded_v : float }

let make_kernel_loaded count =
  if not (count >= 20.) then
    Error "kernel_loaded: validation failed: count >= 20"
  else
  Ok { kernel_loaded_v = count }

let count_of_kernel_loaded t = t.kernel_loaded_v

type boot_complete = { boot_complete_v : kernel_loaded }

let make_boot_complete k =
  Ok { boot_complete_v = k }

let k_of_boot_complete t = t.boot_complete_v

type eval_kl_safe = { eval_kl_safe_v : valid_kl_ast }

let make_eval_kl_safe expr =
  Ok { eval_kl_safe_v = expr }

let expr_of_eval_kl_safe t = t.eval_kl_safe_v

