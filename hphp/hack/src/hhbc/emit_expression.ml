(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

open Core
open Hhbc_ast
open Instruction_sequence

module A = Ast
module H = Hhbc_ast
module TC = Hhas_type_constraint
module SN = Naming_special_names
module CBR = Continue_break_rewriter

(* When using the PassX instructions we need to emit the right kind *)
module PassByRefKind = struct
  type t = AllowCell | WarnOnCell | ErrorOnCell
end

(* Locals, array elements, and properties all support the same range of l-value
 * operations. *)
module LValOp = struct
  type t =
  | Set
  | SetOp of eq_op
  | IncDec of incdec_op
end

let self_name = ref (None : string option)
let set_self n = self_name := n

let compiler_options = ref Hhbc_options.default
let set_compiler_options o = compiler_options := o

(* Emit a comment in lieu of instructions for not-yet-implemented features *)
let emit_nyi description =
  instr (IComment ("NYI: " ^ description))

let strip_dollar id =
  String.sub id 1 (String.length id - 1)

let make_varray p es = p, A.Array (List.map es ~f:(fun e -> A.AFvalue e))
let make_kvarray p kvs =
  p, A.Array (List.map kvs ~f:(fun (k, v) -> A.AFkvalue (k, v)))

(* Strict binary operations; assumes that operands are already on stack *)
let from_binop op =
  let ints_overflow_to_ints =
    Hhbc_options.ints_overflow_to_ints !compiler_options in
  match op with
  | A.Plus -> instr (IOp (if ints_overflow_to_ints then Add else AddO))
  | A.Minus -> instr (IOp (if ints_overflow_to_ints then Sub else  SubO))
  | A.Star -> instr (IOp (if ints_overflow_to_ints then Mul else MulO))
  | A.Slash -> instr (IOp Div)
  | A.Eqeq -> instr (IOp Eq)
  | A.EQeqeq -> instr (IOp Same)
  | A.Starstar -> instr (IOp Pow)
  | A.Diff -> instr (IOp Neq)
  | A.Diff2 -> instr (IOp NSame)
  | A.Lt -> instr (IOp Lt)
  | A.Lte -> instr (IOp Lte)
  | A.Gt -> instr (IOp Gt)
  | A.Gte -> instr (IOp Gte)
  | A.Dot -> instr (IOp Concat)
  | A.Amp -> instr (IOp BitAnd)
  | A.Bar -> instr (IOp BitOr)
  | A.Ltlt -> instr (IOp Shl)
  | A.Gtgt -> instr (IOp Shr)
  | A.Percent -> instr (IOp Mod)
  | A.Xor -> instr (IOp BitXor)
  | A.Eq _ -> emit_nyi "Eq"
  | A.AMpamp
  | A.BArbar ->
    failwith "short-circuiting operator cannot be generated as a simple binop"

let binop_to_eqop op =
  let ints_overflow_to_ints =
    Hhbc_options.ints_overflow_to_ints !compiler_options in
  match op with
  | A.Plus -> Some (if ints_overflow_to_ints then PlusEqual else PlusEqualO)
  | A.Minus -> Some (if ints_overflow_to_ints then MinusEqual else MinusEqualO)
  | A.Star -> Some (if ints_overflow_to_ints then MulEqual else MulEqualO)
  | A.Slash -> Some DivEqual
  | A.Starstar -> Some PowEqual
  | A.Amp -> Some AndEqual
  | A.Bar -> Some OrEqual
  | A.Xor -> Some XorEqual
  | A.Ltlt -> Some SlEqual
  | A.Gtgt -> Some SrEqual
  | A.Percent -> Some ModEqual
  | A.Dot -> Some ConcatEqual
  | _ -> None

let unop_to_incdec_op op =
  let ints_overflow_to_ints =
    Hhbc_options.ints_overflow_to_ints !compiler_options in
  match op with
  | A.Uincr -> Some (if ints_overflow_to_ints then PreInc else PreIncO)
  | A.Udecr -> Some (if ints_overflow_to_ints then PreDec else PreDecO)
  | A.Upincr -> Some (if ints_overflow_to_ints then PostInc else PostIncO)
  | A.Updecr -> Some (if ints_overflow_to_ints then PostDec else PostDecO)
  | _ -> None

let collection_type = function
  | "Vector"    -> 17
  | "Map"       -> 18
  | "Set"       -> 19
  | "Pair"      -> 20
  | "ImmVector" -> 21
  | "ImmMap"    -> 22
  | "ImmSet"    -> 23
  | x -> failwith ("unknown collection type '" ^ x ^ "'")

let istype_op id =
  match id with
  | "is_int" | "is_integer" -> Some OpInt
  | "is_bool" -> Some OpBool
  | "is_float" | "is_real" | "is_double" -> Some OpDbl
  | "is_string" -> Some OpStr
  | "is_array" -> Some OpArr
  | "is_object" -> Some OpObj
  | "is_null" -> Some OpNull
  | "is_scalar" -> Some OpScalar
  | _ -> None

(* See EmitterVisitor::getPassByRefKind in emitter.cpp *)
let get_passByRefKind expr =
  let open PassByRefKind in
  let rec from_non_list_assignment permissive_kind expr =
    match snd expr with
    | A.New _ | A.Lvar _ | A.Clone _ -> AllowCell
    | A.Binop(A.Eq None, (_, A.List _), e) ->
      from_non_list_assignment WarnOnCell e
    | A.Array_get(_, Some _) -> permissive_kind
    | A.Binop(A.Eq _, _, _) -> WarnOnCell
    | A.Unop((A.Uincr | A.Udecr), _) -> WarnOnCell
    | _ -> ErrorOnCell in
  from_non_list_assignment AllowCell expr

let extract_shape_field_name_pstring = function
  | A.SFlit p
  | A.SFclass_const (_, p) ->  p

let extract_shape_field_name = function
  | A.SFlit (_, s)
  | A.SFclass_const (_, (_, s)) -> s

let rec expr_and_newc instr_to_add_new instr_to_add = function
  | A.AFvalue e ->
    gather [from_expr e; instr_to_add_new]
  | A.AFkvalue (k, v) ->
    gather [
      emit_two_exprs k v;
      instr_to_add
    ]

and from_local x =
  if x = SN.SpecialIdents.this then instr_this
  else instr_cgetl (Local.Named x)

and emit_two_exprs e1 e2 =
  (* Special case to make use of CGetL2 *)
  match e1 with
  | (_, A.Lvar (_, local)) ->
    gather [
      from_expr e2;
      instr_cgetl2 (Local.Named local);
    ]
  | _ ->
    gather [
      from_expr e1;
      from_expr e2;
    ]

and emit_is_null e =
  match e with
  | (_, A.Lvar (_, id)) ->
    instr_istypel (Local.Named id) OpNull
  | _ ->
    gather [
      from_expr e;
      instr_istypec OpNull
    ]

and emit_binop op e1 e2 =
  match op with
  | A.AMpamp -> emit_logical_and e1 e2
  | A.BArbar -> emit_logical_or e1 e2
  | A.Eq None -> emit_lval_op LValOp.Set e1 (Some e2)
  | A.Eq (Some obop) ->
    begin match binop_to_eqop obop with
    | None -> emit_nyi "illegal eq op"
    | Some op -> emit_lval_op (LValOp.SetOp op) e1 (Some e2)
    end
  | A.EQeqeq when snd e2 = A.Null ->
    emit_is_null e1
  | A.EQeqeq when snd e1 = A.Null ->
    emit_is_null e2
  | A.Diff2 when snd e2 = A.Null ->
    gather [
      emit_is_null e1;
      instr_not
    ]
  | A.Diff2 when snd e1 = A.Null ->
    gather [
      emit_is_null e2;
      instr_not
    ]
  | _ ->
    gather [
      emit_two_exprs e1 e2;
      from_binop op
    ]

and emit_instanceof e1 e2 =
  match (e1, e2) with
  | (_, (_, A.Id (_, id))) ->
    gather [
      from_expr e1;
      instr_instanceofd id ]
  | _ ->
    gather [
      from_expr e1;
      from_expr e2;
      instr_instanceof ]

and emit_null_coalesce e1 e2 =
  let end_label = Label.next_regular () in
  gather [
    emit_quiet_expr e1;
    instr_dup;
    instr_istypec OpNull;
    instr_not;
    instr_jmpnz end_label;
    instr_popc;
    from_expr e2;
    instr_label end_label;
  ]

and emit_cast hint expr =
  let op =
    begin match hint with
    | A.Happly((_, id), [])
      when id = SN.Typehints.int
        || id = SN.Typehints.integer ->
      instr (IOp CastInt)
    | A.Happly((_, id), [])
      when id = SN.Typehints.bool
        || id = SN.Typehints.boolean ->
      instr (IOp CastBool)
    | A.Happly((_, id), [])
      when id = SN.Typehints.string ->
      instr (IOp CastString)
    | A.Happly((_, id), [])
      when id = SN.Typehints.object_cast ->
      instr (IOp CastObject)
    | A.Happly((_, id), [])
      when id = SN.Typehints.array ->
      instr (IOp CastArray)
    | A.Happly((_, id), [])
      when id = SN.Typehints.real
        || id = SN.Typehints.double
        || id = SN.Typehints.float ->
      instr (IOp CastDouble)
      (* TODO: unset *)
    | _ ->
      emit_nyi "cast type"
    end in
  gather [
    from_expr expr;
    op;
  ]

and emit_conditional_expression etest etrue efalse =
  match etrue with
  | Some etrue ->
    let false_label = Label.next_regular () in
    let end_label = Label.next_regular () in
    gather [
      from_expr etest;
      instr_jmpz false_label;
      from_expr etrue;
      instr_jmp end_label;
      instr_label false_label;
      from_expr efalse;
      instr_label end_label;
    ]
  | None ->
    let end_label = Label.next_regular () in
    gather [
      from_expr etest;
      instr_dup;
      instr_jmpnz end_label;
      instr_popc;
      from_expr efalse;
      instr_label end_label;
    ]

and emit_aget class_expr =
  match class_expr with
  | _, A.Lvar (_, id) ->
    instr (IGet (ClsRefGetL (Local.Named id, 0)))

  | _ ->
    gather [
      from_expr class_expr;
      instr (IGet (ClsRefGetC 0))
    ]

and emit_new class_expr args uargs =
  let nargs = List.length args + List.length uargs in
  match class_expr with
  | _, A.Id (_, id) ->
    gather [
      instr_fpushctord nargs id;
      emit_args_and_call args uargs;
      instr_popr
    ]
  | _ ->
    gather [
      emit_aget class_expr;
      instr_fpushctor nargs 0;
      emit_args_and_call args uargs;
      instr_popr
    ]

and emit_clone expr =
  gather [
    from_expr expr;
    instr_clone;
  ]

and emit_shape expr fl =
  let are_values_all_literals =
    List.for_all fl ~f:(fun (_, e) -> is_literal e)
  in
  let p = fst expr in
  if are_values_all_literals then
    let fl =
      List.map fl
        ~f:(fun (fn, e) ->
              A.AFkvalue ((p,
                A.String (extract_shape_field_name_pstring fn)), e))
    in
    from_expr (fst expr, A.Array fl)
  else
    let es = List.map fl ~f:(fun (_, e) -> from_expr e) in
    let keys = List.map fl ~f:(fun (fn, _) -> extract_shape_field_name fn) in
    gather [
      gather es;
      instr_newstructarray keys;
    ]

and emit_tuple p es =
  (* Did you know that tuples are functions? *)
  let af_list = List.map es ~f:(fun e -> A.AFvalue e) in
  from_expr (p, A.Array af_list)

and emit_call_expr expr =
  let instrs, flavor = emit_flavored_expr expr in
  gather [
    instrs;
    (* If the instruction has produced a ref then unbox it *)
    if flavor = Flavor.Ref then instr_unboxr else empty
  ]

and emit_known_class_id cid =
  gather [
    instr_string (Utils.strip_ns cid);
    instr (IGet (ClsRefGetC 0))
  ]

and emit_class_id cid =
  if cid = SN.Classes.cStatic
  then instr (IMisc (LateBoundCls 0))
  else
  if cid = SN.Classes.cSelf
  then match !self_name with
  | None -> instr (IMisc Self)
  | Some cid -> emit_known_class_id cid
  else emit_known_class_id cid

and emit_class_get param_num_opt cid id =
    gather [
      (* We need to strip off the initial dollar *)
      instr_string (strip_dollar id);
      emit_class_id cid;
      match param_num_opt with
      | None -> instr (IGet (CGetS 0))
      | Some i -> instr (ICall (FPassS (i, 0)))
    ]

and emit_class_const cid id =
  if id = SN.Members.mClass then instr_string cid
  else if cid = SN.Classes.cStatic
  then
    instrs [
      IMisc (LateBoundCls 0);
      ILitConst (ClsCns (id, 0));
    ]
  else if cid = SN.Classes.cSelf
  then
    match !self_name with
    | None ->
      instrs [
        IMisc Self;
        ILitConst (ClsCns (id, 0));
      ]
    | Some cid -> instr (ILitConst (ClsCnsD (id, cid)))
  else
    instr (ILitConst (ClsCnsD (id, cid)))

and emit_await e =
  let after_await = Label.next_regular () in
  gather [
    from_expr e;
    instr_dup;
    instr_istypec OpNull;
    instr_jmpnz after_await;
    instr_await;
    instr_label after_await;
  ]

and emit_yield = function
  | A.AFvalue e ->
    gather [
      from_expr e;
      instr_yield;
    ]
  | A.AFkvalue (e1, e2) ->
    gather [
      from_expr e1;
      from_expr e2;
      instr_yieldk;
    ]

and emit_yield_break () =
  gather [
    instr_null;
    instr_retc;
  ]

and emit_string2 exprs =
  match exprs with
  | [e] ->
    gather [
      from_expr e;
      instr (IOp CastString)
    ]
  | e1::e2::es ->
    gather @@ [
      emit_two_exprs e1 e2;
      instr (IOp Concat);
      gather (List.map es (fun e -> gather [from_expr e; instr (IOp Concat)]))
    ]

  | [] -> failwith "String2 with zero arguments is impossible"

and emit_lambda fundef ids =
  (* Closure conversion puts the class number used for CreateCl in the "name"
   * of the function definition *)
  let class_num = int_of_string (snd fundef.A.f_name) in
  gather [
    (* TODO: deal with explicit use (...) capture variables *)
    gather @@ List.map ids
      (fun (x, _isref) -> instr (IGet (CUGetL (Local.Named (snd x)))));
    instr (IMisc (CreateCl (List.length ids, class_num)))
  ]

and emit_id (p, s) =
  match s with
  | "__FILE__" -> instr (ILitConst File)
  | "__DIR__" -> instr (ILitConst Dir)
  | "__LINE__" ->
    (* If the expression goes on multi lines, we return the last line *)
    let _, line, _, _ = Pos.info_pos_extended p in
    instr_int line
  | _ -> instr (ILitConst (Cns s))

and rename_xhp (p, s) =
  (* Translates given :name to xhp_name *)
  if String_utils.string_starts_with s ":"
  then (p, "xhp_" ^ (String_utils.lstrip s ":"))
  else failwith "Incorrectly named xhp element"

and emit_xhp p id attributes children =
  (* Translate into a constructor call. The arguments are:
   *  1) shape-like array of attributes
   *  2) vec-like array of children
   *  3) filename, for debugging
   *  4) line number, for debugging
   *)
  let convert_xml_attr (name, v) = (A.SFlit name, v) in
  let attributes = List.map ~f:convert_xml_attr attributes in
  let attribute_map = p, A.Shape attributes in
  let children_vec = make_varray p children in
  let filename = p, A.Id (p, "__FILE__") in
  let line = p, A.Id (p, "__LINE__") in
  from_expr @@
    (p, A.New (
      (p, A.Id (rename_xhp id)),
      [attribute_map ; children_vec ; filename ; line],
      []))

and emit_import flavor e =
  let import_instr = match flavor with
    | A.Include -> instr @@ IIncludeEvalDefine Incl
    | A.Require -> instr @@ IIncludeEvalDefine Req
    | A.IncludeOnce -> instr @@ IIncludeEvalDefine InclOnce
    | A.RequireOnce -> instr @@ IIncludeEvalDefine ReqOnce
  in
  gather [
    from_expr e;
    import_instr;
  ]

and emit_lvarvar n (_, id) =
  gather [
    instr_cgetl (Local.Named id);
    gather @@ List.replicate ~num:n instr_cgetn;
  ]

and from_expr expr =
  (* Note that this takes an Ast.expr, not a Nast.expr. *)
  match snd expr with
  | A.Float (_, litstr) -> instr_double litstr
  | A.String (_, litstr) -> instr_string litstr
  (* TODO deal with integer out of range *)
  | A.Int (_, litstr) -> instr_int_of_string litstr
  | A.Null -> instr_null
  | A.False -> instr_false
  | A.True -> instr_true
  | A.Lvar (_, x) -> from_local x
  | A.Class_const ((_, cid), (_, id)) -> emit_class_const cid id
  | A.Unop (op, e) -> emit_unop op e
  | A.Binop (op, e1, e2) -> emit_binop op e1 e2
  | A.Pipe (e1, e2) -> emit_pipe e1 e2
  | A.Dollardollar -> instr_cgetl2 Local.Pipe
  | A.InstanceOf (e1, e2) -> emit_instanceof e1 e2
  | A.NullCoalesce (e1, e2) -> emit_null_coalesce e1 e2
  | A.Cast((_, hint), e) -> emit_cast hint e
  | A.Eif (etest, etrue, efalse) ->
    emit_conditional_expression etest etrue efalse
  | A.Expr_list es -> gather @@ List.map es ~f:from_expr
  | A.Call ((p, A.Id (_, "tuple")), es, _) -> emit_tuple p es
  | A.Call _ -> emit_call_expr expr
  | A.New (typeexpr, args, uargs) -> emit_new typeexpr args uargs
  | A.Array es -> emit_collection expr es
  | A.Darray es ->
    es
      |> List.map ~f:(fun (e1, e2) -> A.AFkvalue (e1, e2))
      |> emit_collection expr
  | A.Varray es ->
    es
      |> List.map ~f:(fun e -> A.AFvalue e)
      |> emit_collection expr
  | A.Collection ((pos, name), fields) ->
    emit_named_collection expr pos name fields
  | A.Array_get(base_expr, opt_elem_expr) ->
    emit_array_get None base_expr opt_elem_expr
  | A.Clone e -> emit_clone e
  | A.Shape fl -> emit_shape expr fl
  | A.Obj_get (expr, prop, nullflavor) -> emit_obj_get None expr prop nullflavor
  | A.Await e -> emit_await e
  | A.Yield e -> emit_yield e
  | A.Yield_break -> emit_yield_break ()
  | A.Lfun _ ->
    failwith "expected Lfun to be converted to Efun during closure conversion"
  | A.Efun (fundef, ids) -> emit_lambda fundef ids
  | A.Class_get ((_, cid), (_, id))  -> emit_class_get None cid id
  | A.String2 es -> emit_string2 es
  | A.Unsafeexpr e -> from_expr e
  | A.Id id -> emit_id id
  | A.Xml (id, attributes, children) ->
    emit_xhp (fst expr) id attributes children
  | A.Import (flavor, e) -> emit_import flavor e
  | A.Lvarvar (n, id) -> emit_lvarvar n id
  (* TODO *)
  | A.Id_type_arguments (_, _)  -> emit_nyi "id_type_arguments"
  | A.List _                    -> emit_nyi "list"

and emit_static_collection ~transform_to_collection expr es =
  let a_label = Label.get_next_data_label () in
  (* Arrays can either contains values or key/value pairs *)
  let need_index = match snd expr with
    | A.Collection ((_, "vec"), _)
    | A.Collection ((_, "keyset"), _) -> false
    | _ -> true
  in
  let _, es =
    List.fold_left
      es
      ~init:(0, [])
      ~f:(fun (index, l) x ->
            let open Constant_folder in
            (index + 1, match x with
            | A.AFvalue e when need_index ->
              literal_from_expr e :: Int (Int64.of_int index) :: l
            | A.AFvalue e ->
              literal_from_expr e :: l
            | A.AFkvalue (k,v) ->
              literal_from_expr v :: literal_from_expr k :: l)
          )
  in
  let es = List.rev es in
  let lit_constructor = match snd expr with
    | A.Array _ -> Array (a_label, es)
    | A.Collection ((_, "dict"), _) -> Dict (a_label, es)
    | A.Collection ((_, "vec"), _) -> Vec (a_label, es)
    | A.Collection ((_, "keyset"), _) -> Keyset (a_label, es)
    | _ -> failwith "impossible"
  in
  let transform_instr =
    match transform_to_collection with
    | Some n -> instr_colfromarray n
    | None -> empty
  in
  gather [
    instr (ILitConst lit_constructor);
    transform_instr;
  ]

(* transform_to_collection argument keeps track of
 * what collection to transform to *)
and emit_dynamic_collection ~transform_to_collection expr es =
  let is_only_values =
    List.for_all es ~f:(function A.AFkvalue _ -> false | _ -> true)
  in
  let count = List.length es in
  if is_only_values && transform_to_collection = None then begin
    let lit_constructor = match snd expr with
      | A.Array _ -> NewPackedArray count
      | A.Collection ((_, "vec"), _) -> NewVecArray count
      | A.Collection ((_, "keyset"), _) -> NewKeysetArray count
      | _ -> failwith "impossible"
    in
    gather [
      gather @@
      List.map es
        ~f:(function A.AFvalue e -> from_expr e | _ -> failwith "impossible");
      instr @@ ILitConst lit_constructor;
    ]
  end else begin
    let lit_constructor = match snd expr with
      | A.Array _ -> NewMixedArray count
      | A.Collection ((_, "dict"), _) -> NewDictArray count
      | _ -> failwith "impossible"
    in
    let transform_instr =
      match transform_to_collection with
      | Some n -> instr_colfromarray n
      | None -> empty
    in
    let add_elem_instr =
      if transform_to_collection = None
      then instr_add_new_elemc
      else instr_col_add_new_elemc
    in
    gather @@
      (instr @@ ILitConst lit_constructor) :: transform_instr ::
      (List.map es ~f:(expr_and_newc add_elem_instr instr_add_elemc))
  end

and emit_named_collection expr pos name fields =
  match name with
  | "dict" | "vec" | "keyset" -> emit_collection expr fields
  | "Vector" | "ImmVector" ->
    let collection_type = collection_type name in
    gather [
      emit_collection (pos, A.Collection ((pos, "vec"), fields)) fields;
      instr_colfromarray collection_type;
    ]
  | "Set" | "ImmSet" | "Map" | "ImmMap" ->
    let collection_type = collection_type name in
    if fields = []
    then instr_newcol collection_type
    else
      emit_collection
        ~transform_to_collection:collection_type
        (pos, A.Array fields)
        fields
  | "Pair" ->
    let collection_type = collection_type name in
    let values = gather @@ List.map
      fields
      ~f:(fun x ->
        expr_and_newc instr_col_add_new_elemc instr_col_add_new_elemc x)
    in
    gather [
      instr_newcol collection_type;
      values;
    ]
  | _ -> failwith @@ "collection: " ^ name ^ " does not exist"

and emit_collection ?(transform_to_collection) expr es =
  if is_literal_afield_list es then
    emit_static_collection ~transform_to_collection expr es
  else
    emit_dynamic_collection ~transform_to_collection expr es

and emit_pipe e1 e2 =
  stash_in_local e1
  begin fun temp _break_label ->
  let rewrite_dollardollar e =
    let rewriter i =
      match i with
      | IGet (CGetL2 Local.Pipe) ->
        IGet (CGetL2 temp)
      | _ -> i in
    InstrSeq.map e ~f:rewriter in
  rewrite_dollardollar (from_expr e2)
  end

and emit_logical_and e1 e2 =
  let left_is_false = Label.next_regular () in
  let right_is_true = Label.next_regular () in
  let its_done = Label.next_regular () in
  gather [
    from_expr e1;
    instr_jmpz left_is_false;
    from_expr e2;
    instr_jmpnz right_is_true;
    instr_label left_is_false;
    instr_false;
    instr_jmp its_done;
    instr_label right_is_true;
    instr_true;
    instr_label its_done ]

and emit_logical_or e1 e2 =
  let its_true = Label.next_regular () in
  let its_done = Label.next_regular () in
  gather [
    from_expr e1;
    instr_jmpnz its_true;
    from_expr e2;
    instr_jmpnz its_true;
    instr_false;
    instr_jmp its_done;
    instr_label its_true;
    instr_true;
    instr_label its_done ]

and emit_quiet_expr (_, expr_ as expr) =
  match expr_ with
  | A.Lvar (_, x) ->
    instr_cgetquietl (Local.Named x)
  | _ ->
    from_expr expr

(* Emit code for e1[e2].
 * If param_num_opt = Some i
 * then this is the i'th parameter to a function
 *)
and emit_array_get param_num_opt base_expr opt_elem_expr =
  let elem_expr_instrs, elem_stack_size = emit_elem_instrs opt_elem_expr in
  let base_expr_instrs, base_setup_instrs, base_stack_size =
    emit_base MemberOpMode.Warn elem_stack_size param_num_opt base_expr in
  let mk = get_elem_member_key 0 opt_elem_expr in
  let total_stack_size = elem_stack_size + base_stack_size in
  let final_instr =
    instr (IFinal (
      match param_num_opt with
      | None -> QueryM (total_stack_size, QueryOp.CGet, mk)
      | Some i -> FPassM (i, total_stack_size, mk)
    )) in
  gather [
    base_expr_instrs;
    elem_expr_instrs;
    base_setup_instrs;
    final_instr
  ]

(* Emit code for e1->e2 or e1?->e2.
 * If param_num_opt = Some i
 * then this is the i'th parameter to a function
 *)
and emit_obj_get param_num_opt expr prop null_flavor =
  let prop_expr_instrs, prop_stack_size = emit_prop_instrs prop in
  let base_expr_instrs, base_setup_instrs, base_stack_size =
    emit_base MemberOpMode.Warn prop_stack_size param_num_opt expr in
  let mk = get_prop_member_key null_flavor 0 prop in
  let total_stack_size = prop_stack_size + base_stack_size in
  let final_instr =
    instr (IFinal (
      match param_num_opt with
      | None -> QueryM (total_stack_size, QueryOp.CGet, mk)
      | Some i -> FPassM (i, total_stack_size, mk)
    )) in
  gather [
    base_expr_instrs;
    prop_expr_instrs;
    base_setup_instrs;
    final_instr
  ]

and emit_elem_instrs opt_elem_expr =
  match opt_elem_expr with
  (* These all have special inline versions of member keys *)
  | Some (_, (A.Lvar _ | A.Int _ | A.String _)) -> empty, 0
  | Some expr -> from_expr expr, 1
  | None -> empty, 0

and emit_prop_instrs (_, expr_ as expr) =
  match expr_ with
  (* These all have special inline versions of member keys *)
  | A.Lvar _ | A.Id _ -> empty, 0
  | _ -> from_expr expr, 1

(* Get the member key for an array element expression: the `elem` in
 * expressions of the form `base[elem]`.
 * If the array element is missing, use the special key `W`.
 *)
and get_elem_member_key stack_index opt_expr =
  match opt_expr with
  (* Special case for local *)
  | Some (_, A.Lvar (_, x)) -> MemberKey.EL (Local.Named x)
  (* Special case for literal integer *)
  | Some (_, A.Int (_, str)) -> MemberKey.EI (Int64.of_string str)
  (* Special case for literal string *)
  | Some (_, A.String (_, str)) -> MemberKey.ET str
  (* General case *)
  | Some _ -> MemberKey.EC stack_index
  (* ELement missing (so it's array append) *)
  | None -> MemberKey.W

(* Get the member key for a property *)
and get_prop_member_key null_flavor stack_index prop_expr =
  match prop_expr with
  (* Special case for known property name *)
  | (_, A.Id (_, str)) ->
    begin match null_flavor with
    | Ast.OG_nullthrows -> MemberKey.PT str
    | Ast.OG_nullsafe -> MemberKey.QT str
    end
  (* Special case for local *)
  | (_, A.Lvar (_, x)) -> MemberKey.PL (Local.Named x)
  (* General case *)
  | _ -> MemberKey.PC stack_index

(* Emit code for a base expression `expr` that forms part of
 * an element access `expr[elem]` or field access `expr->fld`.
 * The instructions are divided into three sections:
 *   1. base and element/property expression instructions:
 *      push non-trivial base and key values on the stack
 *   2. base selector instructions: a sequence of Base/Dim instructions that
 *      actually constructs the base address from "member keys" that are inlined
 *      in the instructions, or pulled from the key values that
 *      were pushed on the stack in section 1.
 *   3. (constructed by the caller) a final accessor e.g. QueryM or setter
 *      e.g. SetOpM instruction that has the final key inlined in the
 *      instruction, or pulled from the key values that were pushed on the
 *      stack in section 1.
 * The function returns a triple (base_instrs, base_setup_instrs, stack_size)
 * where base_instrs is section 1 above, base_setup_instrs is section 2, and
 * stack_size is the number of values pushed onto the stack by section 1.
 *
 * For example, the r-value expression $arr[3][$ix+2]
 * will compile to
 *   # Section 1, pushing the value of $ix+2 on the stack
 *   Int 2
 *   CGetL2 $ix
 *   AddO
 *   # Section 2, constructing the base address of $arr[3]
 *   BaseL $arr Warn
 *   Dim Warn EI:3
 *   # Section 3, indexing the array using the value at stack position 0 (EC:0)
 *   QueryM 1 CGet EC:0
 *)
and emit_base mode base_offset param_num_opt (_, expr_ as expr) =
   match expr_ with
   | A.Lvar (_, x) when x = SN.SpecialIdents.this ->
     instr (IMisc CheckThis),
     instr (IBase BaseH),
     0

   | A.Lvar (_, x) ->
     empty,
     instr (IBase (
       match param_num_opt with
       | None -> BaseL (Local.Named x, mode)
       | Some i -> FPassBaseL (i, Local.Named x)
       )),
     0

   | A.Array_get(base_expr, opt_elem_expr) ->
     let elem_expr_instrs, elem_stack_size = emit_elem_instrs opt_elem_expr in
     let base_expr_instrs, base_setup_instrs, base_stack_size =
       emit_base mode (base_offset + elem_stack_size) param_num_opt base_expr in
     let mk = get_elem_member_key base_offset opt_elem_expr in
     let total_stack_size = base_stack_size + elem_stack_size in
     gather [
       base_expr_instrs;
       elem_expr_instrs;
     ],
     gather [
       base_setup_instrs;
       instr (IBase (
         match param_num_opt with
         | None -> Dim (mode, mk)
         | Some i -> FPassDim (i, mk)
       ))
     ],
     total_stack_size

   | A.Obj_get(base_expr, prop_expr, null_flavor) ->
     let prop_expr_instrs, prop_stack_size = emit_prop_instrs prop_expr in
     let base_expr_instrs, base_setup_instrs, base_stack_size =
       emit_base mode (base_offset + prop_stack_size) param_num_opt base_expr in
     let mk = get_prop_member_key null_flavor base_offset prop_expr in
     let total_stack_size = prop_stack_size + base_stack_size in
     let final_instr =
       instr (IBase (
         match param_num_opt with
         | None -> Dim (mode, mk)
         | Some i -> FPassDim (i, mk)
       )) in
     gather [
       base_expr_instrs;
       prop_expr_instrs;
     ],
     gather [
       base_setup_instrs;
       final_instr
     ],
     total_stack_size

   | A.Class_get((_, cid), (_, id)) ->
     let prop_expr_instrs = instr_string (strip_dollar id) in
     gather [
       prop_expr_instrs;
       emit_class_id cid
     ],
     gather [
       instr (IBase (BaseSC (base_offset, 0)))
     ],
     1

    | _ ->
     let base_expr_instrs, flavor = emit_flavored_expr expr in
     base_expr_instrs,
     instr (IBase (if flavor = Flavor.Ref
                   then BaseR base_offset else BaseC base_offset)),
     1

and instr_fpass kind i =
  match kind with
  | PassByRefKind.AllowCell -> instr (ICall (FPassC i))
  | PassByRefKind.WarnOnCell -> instr (ICall (FPassCW i))
  | PassByRefKind.ErrorOnCell -> instr (ICall (FPassCE i))

and instr_fpassr i = instr (ICall (FPassR i))

and emit_arg i ((_, expr_) as e) =
  match expr_ with
  | A.Lvar (_, x) -> instr_fpassl i (Local.Named x)

  | A.Array_get(base_expr, opt_elem_expr) ->
    emit_array_get (Some i) base_expr opt_elem_expr

  | A.Obj_get(e1, e2, nullflavor) ->
    emit_obj_get (Some i) e1 e2 nullflavor

  | A.Class_get((_, cid), (_, id)) ->
    emit_class_get (Some i) cid id

  | _ ->
    let instrs, flavor = emit_flavored_expr e in
    gather [
      instrs;
      if flavor = Flavor.Ref
      then instr_fpassr i
      else instr_fpass (get_passByRefKind e) i
    ]

and emit_ignored_expr e =
  let instrs, flavor = emit_flavored_expr e in
  gather [
    instrs;
    instr_pop flavor;
  ]

(* Emit code to construct the argument frame and then make the call *)
and emit_args_and_call args uargs =
  let all_args = args @ uargs in
  let nargs = List.length all_args in
  gather [
    gather (List.mapi all_args emit_arg);
    if uargs = []
    then instr (ICall (FCall nargs))
    else instr (ICall (FCallUnpack nargs))
  ]

and emit_call_lhs (_, expr_ as expr) nargs =
  match expr_ with
  | A.Obj_get (obj, (_, A.Id (_, id)), null_flavor) ->
    gather [
      from_expr obj;
      instr (ICall (FPushObjMethodD (nargs, id, null_flavor)));
    ]

  | A.Class_const ((_, cid), (_, id)) when cid = SN.Classes.cSelf ->
    gather [
      instr_string id;
      emit_class_id cid;
      instr (ICall (FPushClsMethodF (nargs, 0)));
    ]

  | A.Class_const ((_, cid), (_, id)) when cid = SN.Classes.cStatic ->
    gather [
      instr_string id;
      instr (IMisc (LateBoundCls 0));
      instr (ICall (FPushClsMethod (nargs, 0)));
      ]

  | A.Class_const ((_, cid), (_, id)) when cid = SN.Classes.cParent ->
    gather [
      instr_string id;
      instr (IMisc (Parent 0));
      instr (ICall (FPushClsMethodF (nargs, 0)));
      ]

  | A.Class_const ((_, cid), (_, id)) when cid.[0] = '$' ->
    gather [
      instr_string id;
      instr (IGet (ClsRefGetL (Local.Named cid, 0)));
      instr (ICall (FPushClsMethod (nargs, 0)))
    ]

  | A.Class_const ((_, cid),  (_, id)) ->
    instr (ICall (FPushClsMethodD (nargs, id, cid)))

  | A.Id (_, id) ->
    instr (ICall (FPushFuncD (nargs, id)))

  | _ ->
    gather [
      from_expr expr;
      instr (ICall (FPushFunc nargs))
    ]

and emit_call (_, expr_ as expr) args uargs =
  let nargs = List.length args + List.length uargs in
  let default () =
    gather [
      emit_call_lhs expr nargs;
      emit_args_and_call args uargs;
    ], Flavor.Ref in
  match expr_ with
  | A.Id (_, id) when id = SN.SpecialFunctions.echo ->
    let instrs = gather @@ List.mapi args begin fun i arg ->
         gather [
           from_expr arg;
           instr (IOp Print);
           if i = nargs-1 then empty else instr_popc
         ] end in
    instrs, Flavor.Cell

  | A.Id (_, id) ->
    begin match args, istype_op id with
    | [(_, A.Lvar (_, arg_id))], Some i ->
      instr (IIsset (IsTypeL (Local.Named arg_id, i))),
      Flavor.Cell
    | [arg_expr], Some i ->
      gather [
        from_expr arg_expr;
        instr (IIsset (IsTypeC i))
      ], Flavor.Cell
    | _ -> default ()
    end
  | _ -> default ()


(* Emit code for an expression that might leave a cell or reference on the
 * stack. Return which flavor it left.
 *)
and emit_flavored_expr (_, expr_ as expr) =
  match expr_ with
  | A.Call (e, args, uargs) ->
    emit_call e args uargs
  | _ ->
    from_expr expr, Flavor.Cell

and is_literal expr =
  match snd expr with
  | A.Array afl
  | A.Collection ((_, "vec"), afl)
  | A.Collection ((_, "keyset"), afl)
  | A.Collection ((_, "dict"), afl) -> is_literal_afield_list afl
  | A.Float _
  | A.String _
  | A.Int _
  | A.Null
  | A.False
  | A.True -> true
  | _ -> false

and is_literal_afield_list afl =
  List.for_all afl
    ~f:(function A.AFvalue e -> is_literal e
               | A.AFkvalue (k,v) -> is_literal k && is_literal v)

and emit_final_member_op stack_index op mk =
  match op with
  | LValOp.Set -> instr (IFinal (SetM (stack_index, mk)))
  | LValOp.SetOp op -> instr (IFinal (SetOpM (stack_index, op, mk)))
  | LValOp.IncDec op -> instr (IFinal (IncDecM (stack_index, op, mk)))

and emit_final_local_op op lid =
  match op with
  | LValOp.Set -> instr (IMutator (SetL lid))
  | LValOp.SetOp op -> instr (IMutator (SetOpL (lid, op)))
  | LValOp.IncDec op -> instr (IMutator (IncDecL (lid, op)))

and emit_final_static_op op =
  match op with
  | LValOp.Set -> instr (IMutator (SetS 0))
  | LValOp.SetOp op -> instr (IMutator (SetOpS (op, 0)))
  | LValOp.IncDec op -> instr (IMutator (IncDecS (op, 0)))

(* Given a local $local and a list of integer array indices i_1, ..., i_n,
 * generate code to extract the value of $local[i_n]...[i_1]:
 *   BaseL $local Warn
 *   Dim Warn EI:i_n ...
 *   Dim Warn EI:i_2
 *   QueryM 0 CGet EI:i_1
 *)
and emit_array_get_fixed local indices =
  gather (
    instr (IBase (BaseL (local, MemberOpMode.Warn))) ::
    List.rev_mapi indices (fun i ix ->
      let mk = MemberKey.EI (Int64.of_int ix) in
      if i = 0
      then instr (IFinal (QueryM (0, QueryOp.CGet, mk)))
      else instr (IBase (Dim (MemberOpMode.Warn, mk))))
      )

(* Generate code for each lvalue assignment in a list destructuring expression.
 * Lvalues are assigned right-to-left, regardless of the nesting structure. So
 *     list($a, list($b, $c)) = $d
 * and list(list($a, $b), $c) = $d
 * will both assign to $c, $b and $a in that order.
 *)
 and emit_lval_op_list local indices expr =
  match expr with
  | (_, A.List exprs) ->
    gather @@
    List.rev @@
    List.mapi exprs (fun i expr -> emit_lval_op_list local (i::indices) expr)
  | _ ->
    (* Generate code to access the element from the array *)
    let access_instrs = emit_array_get_fixed local indices in
    (* Generate code to assign to the lvalue *)
    let assign_instrs = emit_lval_op_nonlist LValOp.Set expr access_instrs 1 in
    gather [
      assign_instrs;
      instr_popc
    ]

(* Emit code for an l-value operation *)
and emit_lval_op op expr1 opt_expr2 =
  match op, expr1, opt_expr2 with
    (* Special case for list destructuring, only on assignment *)
    | LValOp.Set, (_, A.List _), Some expr2 ->
      stash_in_local ~leave_on_stack:true expr2
      begin fun local _break_label ->
        emit_lval_op_list local [] expr1
      end
    | _ ->
      let rhs_instrs, rhs_stack_size =
        match opt_expr2 with
        | None -> empty, 0
      | Some e -> from_expr e, 1 in
      emit_lval_op_nonlist op expr1 rhs_instrs rhs_stack_size

and emit_lval_op_nonlist op expr1 rhs_instrs rhs_stack_size =
  match expr1 with
  | (_, A.Lvar (_, id)) ->
    gather [
      rhs_instrs;
      emit_final_local_op op (Local.Named id)
    ]

  | (_, A.Array_get(base_expr, opt_elem_expr)) ->
    let elem_expr_instrs, elem_stack_size = emit_elem_instrs opt_elem_expr in
    let base_offset = elem_stack_size + rhs_stack_size in
    let base_expr_instrs, base_setup_instrs, base_stack_size =
      emit_base MemberOpMode.Define base_offset None base_expr in
    let mk = get_elem_member_key rhs_stack_size opt_elem_expr in
    let total_stack_size = elem_stack_size + base_stack_size in
    let final_instr = emit_final_member_op total_stack_size op mk in
    gather [
      base_expr_instrs;
      elem_expr_instrs;
      rhs_instrs;
      base_setup_instrs;
      final_instr
    ]

  | (_, A.Obj_get(e1, e2, null_flavor)) ->
    let prop_expr_instrs, prop_stack_size = emit_prop_instrs e2 in
    let base_offset = prop_stack_size + rhs_stack_size in
    let base_expr_instrs, base_setup_instrs, base_stack_size =
      emit_base MemberOpMode.Define base_offset None e1 in
    let mk = get_prop_member_key null_flavor rhs_stack_size e2 in
    let total_stack_size = prop_stack_size + base_stack_size in
    let final_instr = emit_final_member_op total_stack_size op mk in
    gather [
      base_expr_instrs;
      prop_expr_instrs;
      rhs_instrs;
      base_setup_instrs;
      final_instr
    ]

  | (_, A.Class_get((_, cid), (_, id))) ->
    let prop_expr_instrs = instr_string (strip_dollar id) in
    let final_instr = emit_final_static_op op in
    gather [
      prop_expr_instrs;
      emit_class_id cid;
      rhs_instrs;
      final_instr
    ]

  | _ ->
    gather [
      emit_nyi "lval expression";
      rhs_instrs;
    ]

and emit_unop op e =
  let ints_overflow_to_ints =
    Hhbc_options.ints_overflow_to_ints !compiler_options in
  match op with
  | A.Utild -> gather [from_expr e; instr (IOp BitNot)]
  | A.Unot -> gather [from_expr e; instr (IOp Not)]
  | A.Uplus -> gather
    [instr (ILitConst (Int (Int64.zero)));
    from_expr e;
    instr (IOp (if ints_overflow_to_ints then Add else AddO))]
  | A.Uminus -> gather
    [instr (ILitConst (Int (Int64.zero)));
    from_expr e;
    instr (IOp (if ints_overflow_to_ints then Sub else SubO))]
  | A.Uincr | A.Udecr | A.Upincr | A.Updecr ->
    begin match unop_to_incdec_op op with
    | None -> emit_nyi "incdec"
    | Some incdec_op ->
      emit_lval_op (LValOp.IncDec incdec_op) e None
    end
  | A.Uref ->
    emit_nyi "references"

and from_exprs exprs =
  gather (List.map exprs from_expr)

and stash_in_local ?(leave_on_stack=false) e f =
  let break_label = Label.next_regular () in
  match e with
  | (_, A.Lvar (_, id)) ->
    gather [
      f (Local.Named id) break_label;
      instr_label break_label;
    ]
  | _ ->
    let temp = Local.get_unnamed_local () in
    let fault_label = Label.next_fault () in
    gather [
      from_expr e;
      instr_setl temp;
      instr_popc;
      instr_try_fault
        fault_label
        (* try block *)
        (f temp break_label)
        (* fault block *)
        (gather [
          instr_unsetl temp;
          instr_unwind ]);
      instr_label break_label;
      if leave_on_stack then instr_pushl temp else instr_unsetl temp
    ]
