(**********************************************************************
 *                                                                    *
 *                            OCamlFormat                             *
 *                                                                    *
 *  Copyright (c) 2017-present, Facebook, Inc.  All rights reserved.  *
 *                                                                    *
 *  This source code is licensed under the MIT license found in the   *
 *  LICENSE file in the root directory of this source tree.           *
 *                                                                    *
 **********************************************************************)

(** Support for reading Reason code *)

(** Type of Reason binary serialized data, which must agree with the type
    used by the implementation of `refmt`. *)
type 'a reason_data =
  string * string * 'a * (string * int * Location.t) list * bool * bool

(** [input magic_number input_channel] reads a serialized ast from
    [input_channel]. It is expected to have the given [magic_number] and is
    assumed to be the output of `refmt --print=binary_reason` where `refmt`
    has been compiled with the same version of `ocaml` as `ocamlformat`. *)
let input ast_magic _conf ic =
  let (magic, _, (ast : 'a), comments, _, _) : 'a reason_data =
    Caml.Marshal.from_channel ic
  in
  if String.equal magic ast_magic then
    let comments = List.map comments ~f:(fun (txt, _, loc) -> (txt, loc)) in
    {Translation_unit.ast; comments}
  else user_error "input not a serialized translation unit" []

let input_impl = input Config.ast_impl_magic_number

let input_intf = input Config.ast_intf_magic_number

open Migrate_ast
open Asttypes
open Parsetree
open Ast_helper

(* extend Normalize.mapper with additional transformations for Reason code *)

let mapper c cmts ~ignore_doc_comments =
  (* holds if an attribute is a docstring that also appears as a comment *)
  let atr_is_dup =
    let cmts = Set.of_list (module String) (List.map cmts ~f:fst) in
    function
    | ( {txt= "ocaml.doc" | "ocaml.text"}
      , PStr
          [ { pstr_desc=
                Pstr_eval
                  ( {pexp_desc= Pexp_constant (Pconst_string (txt, None))}
                  , [] ) } ] ) ->
        Set.mem cmts ("*" ^ txt)
    | _ -> false
  in
  let attributes (m : Ast_mapper.mapper) atrs =
    let atrs =
      if ignore_doc_comments then
        List.filter atrs ~f:(function
          | {txt= "ocaml.doc" | "ocaml.text"}, _ -> false
          | _ -> true )
      else atrs
    in
    (* remove docstrings that duplicate comments *)
    let atrs = List.filter atrs ~f:(Fn.non atr_is_dup) in
    Normalize.(mapper c).attributes m atrs
  in
  let pat (m : Ast_mapper.mapper) pat =
    let {ppat_desc; ppat_loc; ppat_attributes} = pat in
    (* remove explicit_arity attributes *)
    let explicit_arity, attrs =
      List.partition_tf ppat_attributes ~f:(function
        | {txt= "explicit_arity"}, _ -> true
        | _ -> false )
    in
    match ppat_desc with
    | Ppat_construct (id, Some {ppat_desc= Ppat_tuple [p0]})
      when not (List.is_empty explicit_arity) ->
        m.pat m (Pat.construct ~loc:ppat_loc ~attrs id (Some p0))
    | _ ->
        let pat =
          if List.is_empty explicit_arity then pat
          else Pat.mk ~loc:ppat_loc ~attrs ppat_desc
        in
        Normalize.(mapper c).pat m pat
  in
  let expr (m : Ast_mapper.mapper) exp =
    let {pexp_desc; pexp_loc; pexp_attributes} = exp in
    (* remove explicit_arity attributes *)
    let explicit_arity, attrs =
      List.partition_tf pexp_attributes ~f:(function
        | {txt= "explicit_arity"}, _ -> true
        | _ -> false )
    in
    match pexp_desc with
    | Pexp_construct (id, Some {pexp_desc= Pexp_tuple [e0]})
      when not (List.is_empty explicit_arity) ->
        m.expr m (Exp.construct ~loc:pexp_loc ~attrs id (Some e0))
    | _ ->
        let exp =
          if List.is_empty explicit_arity then exp
          else Exp.mk ~loc:pexp_loc ~attrs pexp_desc
        in
        Normalize.(mapper c).expr m exp
  in
  let structure (m : Ast_mapper.mapper) pstr =
    (* remove structure items that are attributes that duplicate comments,
       when converting Reason *)
    Normalize.(mapper c).structure m
      (List.filter pstr ~f:(function
        | {pstr_desc= Pstr_attribute atr} -> not (atr_is_dup atr)
        | _ -> true ))
  in
  let signature (m : Ast_mapper.mapper) psig =
    (* remove signature items that are attributes that duplicate comments,
       when converting Reason *)
    Normalize.(mapper c).signature m
      (List.filter psig ~f:(function
        | {psig_desc= Psig_attribute atr} -> not (atr_is_dup atr)
        | _ -> true ))
  in
  {(Normalize.mapper c) with attributes; pat; expr; structure; signature}

let norm_impl c {Translation_unit.ast; comments} =
  map_structure (mapper ~ignore_doc_comments:false c comments) ast

let norm_intf c {Translation_unit.ast; comments} =
  map_signature (mapper ~ignore_doc_comments:false c comments) ast

let equal_impl ~ignore_doc_comments c x y =
  Normalize.equal_impl ~ignore_doc_comments c (norm_impl c x)
    (norm_impl c y)

let equal_intf ~ignore_doc_comments c x y =
  Normalize.equal_intf ~ignore_doc_comments c (norm_intf c x)
    (norm_intf c y)

let moved_docstrings_impl c {Translation_unit.ast= x}
    {Translation_unit.ast= y} =
  Normalize.moved_docstrings_impl c x y

let moved_docstrings_intf c {Translation_unit.ast= x}
    {Translation_unit.ast= y} =
  Normalize.moved_docstrings_intf c x y
