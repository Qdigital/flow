(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast

module LocMap = Utils_js.LocMap

module Kind = Signature_builder_kind
module Entry = Signature_builder_entry

module Deps = Signature_builder_deps
module Error = Deps.Error
module Dep = Deps.Dep

let loc_TODO = Loc.none
let loc_WILDCARD = Loc.none

module T = struct
  type type_ = (Loc.t, Loc.t) Ast.Type.t

  and decl =
    (* type definitions *)
    | Type of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        right: type_;
      }
    | OpaqueType of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        impltype: type_ option;
        supertype: type_ option;
      }
    | Interface of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic list;
        body: Loc.t * object_type;
      }
    (* declarations and outlined expressions *)
    | ClassDecl of class_t
    | LocalDecl of Loc.t * little_annotation
    (* remote *)
    | ImportNamed of {
        kind: Ast.Statement.ImportDeclaration.importKind;
        source: Ast_utils.source;
        name: Ast_utils.ident;
      }
    | ImportStar of {
        kind: Ast.Statement.ImportDeclaration.importKind;
        source: Ast_utils.source;
      }
    | Require of {
        source: Ast_utils.source;
      }

  and generic = Loc.t * (Loc.t, Loc.t) Ast.Type.Generic.t

  and class_implement = (Loc.t, Loc.t) Ast.Class.Implements.t

  and little_annotation =
    | TYPE of type_
    | EXPR of expr_type

  and expr_type =
    (* types and expressions *)
    | Function of (Loc.t * function_t)
    | ObjectLiteral of (Loc.t * object_property_t) list
    | ArrayLiteral of array_element_t Nel.t
    | ValueRef of Loc.t * reference (* typeof `x` *)

    | NumberLiteral of Ast.NumberLiteral.t
    | StringLiteral of Ast.StringLiteral.t
    | BooleanLiteral of bool
    | Number
    | String
    | Boolean
    | Void
    | Null

    | TypeCast of type_

    | Outline of Loc.t * outlinable_t

  and object_type = (Loc.t, Loc.t) Ast.Type.Object.t

  and object_key = (Loc.t, Loc.t) Ast.Expression.Object.Property.key

  and outlinable_t =
    | Class of class_t
    | DynamicImport of Loc.t * Ast.StringLiteral.t
    | DynamicRequire of (Loc.t, Loc.t) Ast.Expression.t

  and function_t =
    | FUNCTION of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        params: function_params;
        return: little_annotation;
      }

  and function_params =
    Loc.t * (Loc.t * type_) list * (Loc.t * (Loc.t * type_)) option

  and class_t =
    | CLASS of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic option;
        implements: class_implement list;
        body: Loc.t * (Loc.t * class_element_t) list;
      }
    | DECLARE_CLASS of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic option;
        mixins: generic list;
        implements: class_implement list;
        body: Loc.t * object_type;
      }

  and class_element_t =
    | CMethod of object_key * (Loc.t * function_t)
    | CProperty of object_key * type_
    | CPrivateField of string * type_

  and object_property_t =
    | OInit of object_key * expr_type
    | OMethod of object_key * (Loc.t * function_t)
    | OGet of object_key * (Loc.t * function_t)
    | OSet of object_key * (Loc.t * function_t)

  and array_element_t =
    | AInit of expr_type

  and reference =
    | RLexical of Loc.t * string
    | RPath of Loc.t * reference * (Loc.t * string)

  module Outlined: sig
    type 'a t
    val create: unit -> 'a t
    val next: 'a t -> Loc.t -> (Loc.t Ast.Identifier.t -> 'a) -> Loc.t Ast.Identifier.t
    val get: 'a t -> 'a list
  end = struct
    type 'a t = (int * 'a list) ref
    let create () = ref (0, [])
    let next outlined outlined_loc f =
      let n, l = !outlined in
      let n = n + 1 in
      let id = outlined_loc, Printf.sprintf "$%d" n in
      let l = (f id) :: l in
      outlined := (n, l);
      id
    let get outlined =
      let _, l = !outlined in
      l
  end

  let param_of_type (loc, t) =
    loc, {
      Ast.Type.Function.Param.name = None;
      annot = t;
      optional = false;
    }

  let type_of_generic (loc, gt) =
    loc, Ast.Type.Generic gt

  let source_of_source (loc, x) =
    loc, { Ast.StringLiteral.value = x; raw = x; }

  let rec type_of_expr_type outlined loc = function
    | Function function_t -> type_of_function outlined function_t
    | ObjectLiteral pts ->
      loc, Ast.Type.Object {
        Ast.Type.Object.exact = true;
        properties = List.map (type_of_object_property outlined) pts
      }
    | ArrayLiteral ets ->
      loc, Ast.Type.Array (match ets with
        | et, [] -> type_of_array_element outlined et
        | et1, et2::ets ->
          loc, Ast.Type.Union (
            type_of_array_element outlined et1,
            type_of_array_element outlined et2,
            List.map (type_of_array_element outlined) ets
          )
      )
    | ValueRef (ref_loc, reference) ->
      loc, Ast.Type.Typeof (type_of_generic (ref_loc, {
        Ast.Type.Generic.id = generic_id_of_reference reference;
        targs = None;
      }))
    | NumberLiteral nt -> loc, Ast.Type.NumberLiteral nt
    | StringLiteral st -> loc, Ast.Type.StringLiteral st
    | BooleanLiteral b -> loc, Ast.Type.BooleanLiteral b
    | Number -> loc, Ast.Type.Number
    | String -> loc, Ast.Type.String
    | Boolean -> loc, Ast.Type.Boolean
    | Void -> loc, Ast.Type.Void
    | Null -> loc, Ast.Type.Null

    | TypeCast t -> t

    | Outline (outlined_loc, ht) ->
      let f = outlining_fun outlined outlined_loc ht in
      let id = Outlined.next outlined outlined_loc f in
      loc, Ast.Type.Typeof (type_of_generic (outlined_loc, {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified id;
        targs = None;
      }))

  and generic_id_of_reference = function
    | RLexical (loc, x) -> Ast.Type.Generic.Identifier.Unqualified (loc, x)
    | RPath (path_loc, reference, (loc, x)) -> Ast.Type.Generic.Identifier.Qualified (path_loc, {
        Ast.Type.Generic.Identifier.qualification = generic_id_of_reference reference;
        id = loc, x
      })

  and outlining_fun outlined decl_loc ht id = match ht with
    | Class class_t ->
      stmt_of_decl outlined decl_loc id (ClassDecl class_t)
    | DynamicImport (source_loc, source_lit) ->
      let importKind = Ast.Statement.ImportDeclaration.ImportValue in
      let source = source_loc, source_lit in
      let default = None in
      let specifiers =
        Some (Ast.Statement.ImportDeclaration.ImportNamespaceSpecifier (decl_loc, id)) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
        specifiers;
      }
    | DynamicRequire require ->
      let kind = Ast.Statement.VariableDeclaration.Const in
      let pattern = decl_loc, Ast.Pattern.Identifier {
        Ast.Pattern.Identifier.name = id;
        annot = Ast.Type.Missing (fst id);
        optional = false;
      } in
      let declaration = {
        Ast.Statement.VariableDeclaration.Declarator.id = pattern;
        init = Some require;
      } in
      decl_loc, Ast.Statement.VariableDeclaration {
        Ast.Statement.VariableDeclaration.kind;
        declarations = [decl_loc, declaration];
      }


  and type_of_array_element outlined = function
    | AInit expr_type -> type_of_expr_type outlined loc_TODO expr_type

  and type_of_object_property outlined = function
    | loc, OInit (key, expr_type) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Init (type_of_expr_type outlined loc_TODO expr_type);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })
    | loc, OMethod (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Init (type_of_function outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = true;
        variance = None;
      })
    | loc, OGet (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Get (type_of_function_t outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })
    | loc, OSet (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Set (type_of_function_t outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })

  and type_of_function_t outlined = function
    | loc, FUNCTION {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        params: function_params;
        return: little_annotation;
      } ->
      let params_loc, params, rest = params in
      loc, {
        Ast.Type.Function.tparams;
        params = params_loc, {
          Ast.Type.Function.Params.params = List.map param_of_type params;
          rest = match rest with
            | None -> None
            | Some (loc, rest) -> Some (loc, {
                Ast.Type.Function.RestParam.argument = param_of_type rest
              })
        };
        return = type_of_little_annotation outlined return;
      }

  and type_of_function outlined function_t =
    let loc, function_t = type_of_function_t outlined function_t in
    loc, Ast.Type.Function function_t

  and type_of_little_annotation outlined = function
    | TYPE t -> t
    | EXPR expr_type -> type_of_expr_type outlined loc_TODO expr_type

  and stmt_of_decl outlined decl_loc id = function
    | Type { tparams; right; } ->
      decl_loc, Ast.Statement.TypeAlias { Ast.Statement.TypeAlias.id; tparams; right }
    | OpaqueType { tparams; impltype; supertype; } ->
      decl_loc, Ast.Statement.OpaqueType { Ast.Statement.OpaqueType.id; tparams; impltype; supertype }
    | Interface { tparams; extends; body; } ->
      decl_loc, Ast.Statement.InterfaceDeclaration { Ast.Statement.Interface.id; tparams; extends; body }
    | ClassDecl (CLASS { tparams; extends; implements; body = (body_loc, body) }) ->
      let body = body_loc, {
        Ast.Type.Object.exact = false;
        properties = List.map (object_type_property_of_class_element outlined) body;
      } in
      let mixins = [] in
      decl_loc, Ast.Statement.DeclareClass {
        Ast.Statement.DeclareClass.id; tparams; extends; implements; mixins; body;
      }
    | ClassDecl (DECLARE_CLASS { tparams; extends; mixins; implements; body }) ->
      decl_loc, Ast.Statement.DeclareClass {
        Ast.Statement.DeclareClass.id; tparams; extends; implements; mixins; body;
      }
    | LocalDecl (loc, little_annotation) ->
      decl_loc, Ast.Statement.DeclareVariable {
        Ast.Statement.DeclareVariable.id;
        annot = Ast.Type.Available (loc, type_of_little_annotation outlined little_annotation)
      }
    | ImportNamed { kind; source; name; } ->
      let importKind = kind in
      let source = source_of_source source in
      let default = if snd name = "default" then Some id else None in
      let specifiers =
        if snd name = "default" then None else
          Some (Ast.Statement.ImportDeclaration.ImportNamedSpecifiers [{
            Ast.Statement.ImportDeclaration.kind = None;
            local = if snd id = snd name then None else Some id;
            remote = name;
          }]) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
          specifiers;
      }
    | ImportStar { kind; source; } ->
      let importKind = kind in
      let source = source_of_source source in
      let default = None in
      let specifiers =
        Some (Ast.Statement.ImportDeclaration.ImportNamespaceSpecifier (fst id, id)) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
        specifiers;
      }
    | Require { source; } ->
      let kind = Ast.Statement.VariableDeclaration.Const in
      let pattern = fst id, Ast.Pattern.Identifier {
        Ast.Pattern.Identifier.name = id;
        annot = Ast.Type.Missing (fst id);
        optional = false;
      } in
      let loc, x = source in
      let require = decl_loc, Ast.Expression.Call {
        Ast.Expression.Call.callee =
          loc_WILDCARD, Ast.Expression.Identifier (loc_WILDCARD, "require");
        targs = None;
        arguments = [Ast.Expression.Expression (loc, Ast.Expression.Literal {
          Ast.Literal.value = Ast.Literal.String x;
          raw = x;
        })];
      } in
      let declaration = {
        Ast.Statement.VariableDeclaration.Declarator.id = pattern;
        init = Some require;
      } in
      decl_loc, Ast.Statement.VariableDeclaration {
        Ast.Statement.VariableDeclaration.kind;
        declarations = [decl_loc, declaration];
      }

  and object_type_property_of_class_element outlined = function
    | loc, CMethod (object_key, f) ->
      let open Ast.Type.Object in
      Property (loc, {
        Property.key = object_key;
        value = Property.Init (type_of_function outlined f);
        optional = false;
        static = false;
        proto = false;
        _method = true;
        variance = None;
      })
    | loc, CProperty (object_key, t) ->
      let open Ast.Type.Object in
      Property (loc, {
        Property.key = object_key;
        value = Property.Init t;
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })
    | _loc, CPrivateField (_x, _t) -> assert false

end

(* A signature of a module is described by exported expressions / definitions, but what we're really
   interested in is their types. In particular, we are interested in computing these types early, so
   that we can check the code inside a module against the signature in a separate pass. So the
   question is: what information is necessary to compute these types?

   Assuming we know how to map various kinds of type constructors (and destructors) to their
   meanings, all that remains to verify is that the types are well-formed: any identifiers appearing
   inside them should be defined in the top-level local scope, or imported, or global; and their
   "sort" of use (as a type or as a value) must match up with their definition.

   We break up the verification of well-formedness by computing a set of "dependencies" found by
   walking the structure of types, definitions, and expressions. The dependencies are simply the
   identifiers that are reached in this walk, coupled with their sort of use. Elsewhere, we
   recursively expand these dependencies by looking up the definitions of such identifiers, possibly
   uncovering further dependencies, and so on.

   A couple of important things to note at this point.

   1. The verification of well-formedness (and computation of types) is complete only up to the
   top-level local scope: any identifiers that are imported or global need to be resolved in a
   separate phase that builds things up in module-dependency order. To reflect this arrangement,
   verification returns not only a set of immediate errors but a set of conditions on imported and
   global identifiers that must be enforced by that separate phase.

   2. There is a fine line between errors found during verification and errors found during the
   computation of types (since both kinds of errors are static errors). Still, one might argue that
   the verification step should ensure that the computation step never fails. In that regard, the
   checks we have so far are not enough. In particular:

   (a) While classes are intended to be the only values that can be used as types, we also allow
   variables to be used as types, to account for the fact that a variable could be bound to a
   top-level local, imported, or global class. Ideally we would verify that these expectation is
   met, but we don't yet.

   (b) While destructuring only makes sense on types of the corresponding kinds (e.g., object
   destructuring would only work on object types), currently we allow destructuring on all
   types. Again, ideally we would discharge verification conditions for these and ensure that they
   are satisfied.

   (c) Parts of the module system are still under design. For example, can types be defined locally
   in anything other than the top-level scope? Do (or under what circumstances do) `require` and
   `import *` bring exported types in scope? These considerations will affect the computation step
   and ideally would be verified as well, but we're punting on them right now.
*)
module Eval(Env: Signature_builder_verify.EvalEnv) = struct
  exception Error of string
  exception Unreachable

  let rec type_ t = t

  and type_params tparams = tparams

  and object_key key = key

  and object_type ot = ot

  and generic tr = tr

  and type_args = function
    | None -> None
    | Some (loc, ts) -> Some (loc, List.map (type_) ts)

  let rec annot_path = function
    | Kind.Annot_path.Annot (_, t) -> type_ t
    | Kind.Annot_path.Object (path, _) -> annot_path path
    | Kind.Annot_path.Array (path, _) -> annot_path path

  let rec annotated_type annot =
    match annot with
      | Some path -> annot_path path
      | None -> raise (Error "annotated_type")

  and annotation ?init annot =
    match annot with
      | Some path -> T.TYPE (annot_path path)
      | None ->
        begin match init with
          | Some expr -> T.EXPR (literal_expr expr)
          | None -> raise (Error "annotation")
        end

  and pattern patt =
    let open Ast.Pattern in
    match patt with
      | loc, Identifier { Identifier.annot; _ } ->
        loc, annotated_type (Kind.Annot_path.mk_annot annot)
      | loc, Object { Object.annot; _ } -> loc, annotated_type (Kind.Annot_path.mk_annot annot)
      | loc, Array { Array.annot; _ } -> loc, annotated_type (Kind.Annot_path.mk_annot annot)
      | _, Assignment { Assignment.left; _ } -> pattern left
      | _loc (* TODO *), Expression _ -> raise (Error "pattern")

  and literal_expr =
    let open Ast.Expression in
    function
      | _, Literal { Ast.Literal.value; raw } ->
        begin match value with
          | Ast.Literal.String value -> T.StringLiteral { Ast.StringLiteral.value; raw }
          | Ast.Literal.Number value -> T.NumberLiteral { Ast.NumberLiteral.value; raw }
          | Ast.Literal.Boolean b -> T.BooleanLiteral b
          | Ast.Literal.Null -> T.Null
          | _ -> raise (Error "literal_expr")
        end
      | _, TemplateLiteral _ -> T.String
      | loc, Identifier stuff -> T.ValueRef (loc, identifier stuff)
      | loc, Class stuff ->
        let open Ast.Class in
        let { id = _; tparams; body; extends; implements; _ } = stuff in
        let super, super_targs = match extends with
          | None -> None, None
          | Some (_, { Extends.expr; targs; }) -> Some expr, targs in
        T.Outline (loc, T.Class (class_ tparams body super super_targs implements))
      | loc, Function stuff
      | loc, ArrowFunction stuff
        ->
        let open Ast.Function in
        let { id = _; generator; tparams; params; return; body; _ } = stuff in
        T.Function (loc, function_ generator tparams params return body)
      | _, Object stuff ->
        let open Ast.Expression.Object in
        let { properties } = stuff in
        T.ObjectLiteral (object_ properties)
      | _, Array stuff ->
        let open Ast.Expression.Array in
        let { elements } = stuff in
        T.ArrayLiteral (array_ elements)
      | _, TypeCast stuff ->
        let open Ast.Expression.TypeCast in
        let { annot; _ } = stuff in
        let _, t = annot in
        T.TypeCast (type_ t)
      | loc, Member stuff -> T.ValueRef (loc, member stuff)
      | loc, Import (source_loc,
         (Literal { Ast.Literal.value = Ast.Literal.String value; raw } |
          TemplateLiteral {
            TemplateLiteral.quasis = [_, {
              TemplateLiteral.Element.value = { TemplateLiteral.Element.cooked = value; raw }; _
            }]; _
          })) ->
        T.Outline (loc, T.DynamicImport (source_loc, { Ast.StringLiteral.value; raw }))
      | (_, Call { Ast.Expression.Call.callee = (_, Identifier (_, "require")); _ }) as expr ->
        T.Outline (fst expr, T.DynamicRequire expr)
      | loc, Unary stuff ->
        let open Ast.Expression.Unary in
        let { operator; argument; _ } = stuff in
        arith_unary operator loc argument
      | loc, Binary stuff ->
        let open Ast.Expression.Binary in
        let { operator; left; right } = stuff in
        arith_binary operator loc left right
      | _, Sequence stuff ->
        let open Ast.Expression.Sequence in
        let { expressions } = stuff in
        begin match List.rev expressions with
          | expr::_ -> literal_expr expr
          | [] -> raise (Error "sequence")
        end
      | _, Assignment stuff ->
        let open Ast.Expression.Assignment in
        let { operator; left = _; right } = stuff in
        begin match operator with
          | Assign -> literal_expr right
          | _ -> raise (Error "assignment")
        end
      | _, Update stuff ->
        let open Ast.Expression.Update in
        (* This operation has a simple result type. *)
        let { argument = _; _ } = stuff in
        T.Number

      | _loc, Call _
      | _loc, Comprehension _
      | _loc, Conditional _
      | _loc, Generator _
      | _loc, Import _
      | _loc, JSXElement _
      | _loc, JSXFragment _
      | _loc, Logical _
      | _loc, MetaProperty _
      | _loc, New _
      | _loc, OptionalCall _
      | _loc, OptionalMember _
      | _loc, Super
      | _loc, TaggedTemplate _
      | _loc, This
      | _loc, Yield _
        -> raise (Error "other expression")

  and identifier stuff =
    let loc, name = stuff in
    T.RLexical (loc, name)

  and member stuff =
    let open Ast.Expression.Member in
    let { _object; property; _ } = stuff in
    let path_loc, t = ref_expr _object in
    let name = match property with
      | PropertyIdentifier (loc, x) -> loc, x
      | PropertyPrivateName (_, (loc, x)) -> loc, x
      | PropertyExpression _ -> raise (Error "member")
    in
    T.RPath (path_loc, t, name)

  and ref_expr expr =
    let open Ast.Expression in
    match expr with
      | loc, Identifier stuff -> loc, identifier stuff
      | loc, Member stuff -> loc, member stuff
      | _ -> raise (Error "ref_expr") (* TODO: verification error *)

  and arith_unary operator _loc (* TODO *) _argument =
    let open Ast.Expression.Unary in
    match operator with
      (* These operations have simple result types. *)
      | Minus -> T.Number
      | Plus -> T.Number
      | Not -> T.Boolean
      | BitNot -> T.Number
      | Typeof -> T.String
      | Void -> T.Void
      | Delete -> T.Boolean

      | Await ->
        (* The result type of this operation depends in a complicated way on the argument type. *)
        raise (Error "await")

  and arith_binary operator _loc (* TODO *) _left _right =
    let open Ast.Expression.Binary in
    match operator with
      | Plus -> raise (Error "plus") (* TODO: verification error *)
      (* These operations have simple result types. *)
      | Equal -> T.Boolean
      | NotEqual -> T.Boolean
      | StrictEqual -> T.Boolean
      | StrictNotEqual -> T.Boolean
      | LessThan -> T.Boolean
      | LessThanEqual -> T.Boolean
      | GreaterThan -> T.Boolean
      | GreaterThanEqual -> T.Boolean
      | LShift -> T.Number
      | RShift -> T.Number
      | RShift3 -> T.Number
      | Minus -> T.Number
      | Mult -> T.Number
      | Exp -> T.Number
      | Div -> T.Number
      | Mod -> T.Number
      | BitOr -> T.Number
      | Xor -> T.Number
      | BitAnd -> T.Number
      | In -> T.Boolean
      | Instanceof -> T.Boolean

  and function_ =
    let function_params params =
      let open Ast.Function in
      let params_loc, { Params.params; rest; } = params in
      let params = List.map pattern params in
      let rest = match rest with
        | None -> None
        | Some (loc, { RestElement.argument }) -> Some (loc, pattern argument) in
      params_loc, params, rest

    in fun generator tparams params return body ->
      let tparams = type_params tparams in
      let params = function_params params in
      let return = match return with
        | Ast.Type.Missing loc ->
          if not generator && Signature_utils.Procedure_decider.is body then T.EXPR (T.Void)
          else raise (Error (Printf.sprintf "%s (%s)" "not void" (Loc.to_string loc)))
        | Ast.Type.Available (_, t) -> T.TYPE (type_ t) in
      T.FUNCTION {
        tparams;
        params;
        return
      }

  and class_ =
    let class_element acc element =
      let open Ast.Class in
      match element with
        | Body.Method (_, { Method.key = (Ast.Expression.Object.Property.Identifier (_, name)); _ })
        | Body.Property (_, { Property.key = (Ast.Expression.Object.Property.Identifier (_, name)); _ })
            when not Env.prevent_munge && Signature_utils.is_munged_property_name name ->
          acc
        | Body.Property (_, {
            Property.key = (Ast.Expression.Object.Property.Identifier (_, "propTypes"));
            static = true; _
          }) when Env.ignore_static_propTypes ->
          acc

        | Body.Method (elem_loc, { Method.key; value; _ }) ->
          let x = object_key key in
          let loc, { Ast.Function.generator; tparams; params; return; body; _ } = value in
          (elem_loc, T.CMethod (x, (loc, function_ generator tparams params return body))) :: acc
        | Body.Property (elem_loc, { Property.key; annot; _ }) ->
          let x = object_key key in
          (elem_loc, T.CProperty (x, annotated_type (Kind.Annot_path.mk_annot annot))) :: acc
        | Body.PrivateField (elem_loc, { PrivateField.key = (_, (_, x)); annot; _ }) ->
          (elem_loc, T.CPrivateField (x, annotated_type (Kind.Annot_path.mk_annot annot))) :: acc

    in fun tparams body super super_targs implements ->
      let open Ast.Class in
      let body_loc, { Body.body } = body in
      let tparams = type_params tparams in
      let body = List.rev @@ List.fold_left class_element [] body in
      let extends = match super with
        | None -> None
        | Some expr ->
          let loc, reference = ref_expr expr in
          Some (loc, {
            Ast.Type.Generic.id = T.generic_id_of_reference reference;
            targs = type_args super_targs;
          })
      in
      let implements = List.map class_implement implements in
      T.CLASS {
        tparams;
        extends;
        implements;
        body = body_loc, body;
      }

  and array_ =
    let array_element expr_or_spread_opt =
      let open Ast.Expression in
      match expr_or_spread_opt with
        | None -> T.AInit (T.Void)
        | Some (Expression expr) -> T.AInit (literal_expr expr)
        | Some (Spread _spread) -> raise (Error "spread element") (* TODO: verification error *)
    in
    function
      | [] -> raise (Error "empty array") (* TODO: verification error *)
      | t::ts -> Nel.map array_element (t, ts)

  and class_implement implement = implement

  and object_ =
    let object_property =
      let open Ast.Expression.Object.Property in
      function
        | loc, Init { key; value; _ } ->
          let x = object_key key in
          loc, T.OInit (x, literal_expr value)
        | loc, Method { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let { generator; tparams; params; return; body; _ } = fn in
          loc, T.OMethod (x, (fn_loc, function_ generator tparams params return body))
        | loc, Get { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let { generator; tparams; params; return; body; _ } = fn in
          loc, T.OGet (x, (fn_loc, function_ generator tparams params return body))
        | loc, Set { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let { generator; tparams; params; return; body; _ } = fn in
          loc, T.OSet (x, (fn_loc, function_ generator tparams params return body))
    in
    fun properties ->
      let open Ast.Expression.Object in
      List.map (function
        | Property p -> object_property p
        | SpreadProperty _p -> raise (Error "spread property") (* TODO: verification error *)
      ) properties

end

module Generator(Env: Signature_builder_verify.EvalEnv) = struct

  module Eval = Eval(Env)

  let eval (loc, kind) =
    match kind with
      | Kind.VariableDef { annot; init } ->
        T.LocalDecl (loc_TODO, Eval.annotation ?init annot)
      | Kind.FunctionDef { generator; tparams; params; return; body; } ->
        T.LocalDecl (loc_TODO, T.EXPR
          (T.Function (loc, Eval.function_ generator tparams params return body)))
      | Kind.DeclareFunctionDef { annot = (_, t) } ->
        T.LocalDecl (loc_TODO, T.TYPE (Eval.type_ t))
      | Kind.ClassDef { tparams; body; super; super_targs; implements } ->
        T.ClassDecl (Eval.class_ tparams body super super_targs implements)
      | Kind.DeclareClassDef { tparams; body = (body_loc, body); extends; mixins; implements } ->
        let tparams = Eval.type_params tparams in
        let body = Eval.object_type body in
        let extends = match extends with
          | None -> None
          | Some r -> Some (Eval.generic r) in
        let mixins = List.map (Eval.generic) mixins in
        let implements = List.map Eval.class_implement implements in
        T.ClassDecl (T.DECLARE_CLASS {
          tparams;
          extends;
          mixins;
          implements;
          body = body_loc, body;
        })
      | Kind.TypeDef { tparams; right } ->
        let tparams = Eval.type_params tparams in
        let right = Eval.type_ right in
        T.Type {
          tparams;
          right;
        }
      | Kind.OpaqueTypeDef { tparams; impltype; supertype } ->
        let tparams = Eval.type_params tparams in
        let impltype = match impltype with
          | None -> None
          | Some t -> Some (Eval.type_ t)
        in
        let supertype = match supertype with
          | None -> None
          | Some t -> Some (Eval.type_ t)
        in
        T.OpaqueType {
          tparams;
          impltype;
          supertype;
        }
      | Kind.InterfaceDef { tparams; extends; body = (body_loc, body) } ->
        let tparams = Eval.type_params tparams in
        let extends = List.map (Eval.generic) extends in
        let body = Eval.object_type body in
        T.Interface {
          tparams;
          extends;
          body = body_loc, body;
        }
      | Kind.ImportNamedDef { kind; source; name } ->
        T.ImportNamed { kind; source; name }
      | Kind.ImportStarDef { kind; source } ->
        T.ImportStar { kind; source }
      | Kind.RequireDef { source } ->
        T.Require { source }
      | Kind.SketchyToplevelDef ->
        raise (Eval.Error "sketchy toplevel def")

  let make_env outlined env =
    SMap.fold (fun n entries acc ->
      Utils_js.LocMap.fold (fun loc kind acc ->
        let id = loc, n in
        let dt = eval kind in
        let decl_loc = fst kind in
        (T.stmt_of_decl outlined decl_loc id dt) :: acc
      ) entries acc
    ) env []

  let cjs_exports outlined =
    function
      | None, [] -> []
      | Some mod_exp_loc, [File_sig.DeclareModuleExportsDef (loc, t)] ->
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (loc, t)]
      | Some mod_exp_loc, [File_sig.SetModuleExportsDef expr] ->
        let annot = T.type_of_expr_type outlined loc_TODO (Eval.literal_expr expr) in
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (loc_TODO, annot)]
      | Some mod_exp_loc, list ->
        let properties = List.map (function
          | File_sig.AddModuleExportsDef (id, expr) ->
            let annot = T.type_of_expr_type outlined loc_TODO (Eval.literal_expr expr) in
            let open Ast.Type.Object in
            Property (fst id, {
              Property.key = Ast.Expression.Object.Property.Identifier id;
              value = Property.Init annot;
              optional = false;
              static = false;
              proto = false;
              _method = true;
              variance = None;
            })
          | _ -> raise (Eval.Error "weird cjs exports")
        ) list in
        let ot = {
          Ast.Type.Object.exact = true;
          properties;
        } in
        let t = mod_exp_loc, Ast.Type.Object ot in
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (mod_exp_loc, t)]
      | _ -> raise (Eval.Error "weird cjs exports")

  let eval_entry (id, kind) =
    id, eval kind

  let eval_declare_variable loc declare_variable =
    eval_entry (Entry.declare_variable loc declare_variable)

  let eval_declare_function loc declare_function =
    eval_entry (Entry.declare_function loc declare_function)

  let eval_declare_class loc declare_class =
    eval_entry (Entry.declare_class loc declare_class)

  let eval_type_alias loc type_alias =
    eval_entry (Entry.type_alias loc type_alias)

  let eval_opaque_type loc opaque_type =
    eval_entry (Entry.opaque_type loc opaque_type)

  let eval_interface loc interface =
    eval_entry (Entry.interface loc interface)

  let eval_function_declaration loc function_declaration =
    eval_entry (Entry.function_declaration loc function_declaration)

  let eval_class loc class_ =
    eval_entry (Entry.class_ loc class_)

  let eval_variable_declaration loc variable_declaration =
    List.map eval_entry @@
      Entry.variable_declaration loc variable_declaration

  let eval_export_default_declaration = Ast.Statement.ExportDefaultDeclaration.(function
    | Declaration (loc, Ast.Statement.FunctionDeclaration
        ({ Ast.Function.id = Some _; _ } as function_declaration)
      ) ->
      `Decl (eval_function_declaration loc function_declaration)
    | Declaration (loc, Ast.Statement.FunctionDeclaration
        ({ Ast.Function.id = None; generator; tparams; params; return; body; _ })
      ) ->
      `Expr (T.Function (loc, Eval.function_ generator tparams params return body))
    | Declaration (loc, Ast.Statement.ClassDeclaration ({ Ast.Class.id = Some _; _ } as class_)) ->
      `Decl (eval_class loc class_)
    | Declaration (loc, Ast.Statement.ClassDeclaration
        ({ Ast.Class.id = None; tparams; body; extends; implements; _ })
      ) ->
      let super, super_targs = match extends with
        | None -> None, None
        | Some (_, { Ast.Class.Extends.expr; targs; }) -> Some expr, targs in
      `Expr (T.Outline (loc, T.Class (Eval.class_ tparams body super super_targs implements)))
    | Declaration _stmt -> raise Eval.Unreachable (* TODO: update signature verifier *)
    | Expression (loc, Ast.Expression.Function ({ Ast.Function.id = Some _; _ } as function_)) ->
      `Decl (eval_function_declaration loc function_)
    | Expression expr -> `Expr (Eval.literal_expr expr)
  )

  let eval_export_value_bindings outlined named named_infos star =
    let open File_sig in
    let stmts = List.fold_left (fun acc -> function
      | export_loc, ExportStar { star_loc; source; } ->
        (export_loc, Ast.Statement.ExportNamedDeclaration {
          Ast.Statement.ExportNamedDeclaration.declaration = None;
          specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportBatchSpecifier (
            star_loc, None
          ));
          source = Some (T.source_of_source source);
          exportKind = Ast.Statement.ExportValue;
        }) :: acc
    ) [] star in
    SMap.fold (fun n (export_loc, export) acc ->
      let export_def = SMap.get n named_infos in
      match export, export_def with
        | ExportDefault { default_loc; local }, Some (DeclareExportDef decl) ->
          begin match local with
            | Some id ->
              (export_loc, Ast.Statement.ExportNamedDeclaration {
                Ast.Statement.ExportNamedDeclaration.declaration = None;
                specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
                  loc_WILDCARD, {
                    Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = id;
                    exported = Some (default_loc, n);
                  }
                ]);
                source = None;
                exportKind = Ast.Statement.ExportValue;
              }) :: acc
            | None ->
              (export_loc, Ast.Statement.DeclareExportDeclaration {
                default = Some default_loc;
                Ast.Statement.DeclareExportDeclaration.declaration = Some decl;
                specifiers = None;
                source = None;
              }) :: acc
          end
        | ExportNamed { loc; kind = NamedDeclaration }, Some (DeclareExportDef _decl) ->
          (export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
              loc_WILDCARD, {
                Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = (loc, n);
                exported = None;
              }
            ]);
            source = None;
            exportKind = Ast.Statement.ExportValue;
          }) :: acc
        | ExportDefault { default_loc; _ }, Some (ExportDefaultDef decl) ->
          begin match eval_export_default_declaration decl with
            | `Decl (id, _dt) ->
              (export_loc, Ast.Statement.ExportNamedDeclaration {
                Ast.Statement.ExportNamedDeclaration.declaration = None;
                specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
                  loc_WILDCARD, {
                    Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = id;
                    exported = Some (default_loc, n);
                  }
                ]);
                source = None;
                exportKind = Ast.Statement.ExportValue;
              }) :: acc
            | `Expr expr_type ->
              let declaration = Ast.Statement.DeclareExportDeclaration.DefaultType
                (T.type_of_expr_type outlined loc_TODO expr_type) in
              (export_loc, Ast.Statement.DeclareExportDeclaration {
                Ast.Statement.DeclareExportDeclaration.default = Some default_loc;
                declaration = Some declaration;
                specifiers = None;
                source = None;
              }) :: acc
          end
        | ExportNamed { loc; kind = NamedDeclaration }, Some (ExportNamedDef _stmt) ->
          (export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
              loc_WILDCARD, {
                Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = (loc, n);
                exported = None;
              }
            ]);
            source = None;
            exportKind = Ast.Statement.ExportValue;
          }) :: acc
        | ExportNamed { loc; kind = NamedSpecifier { local = name; source } }, None ->
          (export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
              loc_WILDCARD, {
                Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = name;
                exported = if (snd name) = n then None else Some (loc, n);
              }
            ]);
            source = (match source with
              | None -> None
              | Some source -> Some (T.source_of_source source)
            );
            exportKind = Ast.Statement.ExportValue;
          }) :: acc
        | ExportNs { loc; star_loc; source; }, None ->
          (export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportBatchSpecifier (
              star_loc, Some (loc, n)
            ));
            source = Some (T.source_of_source source);
            exportKind = Ast.Statement.ExportValue;
          }) :: acc
        | _ -> assert false
    ) named stmts

  let eval_export_type_bindings type_named type_named_infos type_star =
    let open File_sig in
    let stmts = List.fold_left (fun acc -> function
      | export_loc, ExportStar { star_loc; source } ->
        (export_loc, Ast.Statement.ExportNamedDeclaration {
          Ast.Statement.ExportNamedDeclaration.declaration = None;
          specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportBatchSpecifier (
            star_loc, None
          ));
          source = Some (T.source_of_source source);
          exportKind = Ast.Statement.ExportType;
        }) :: acc
    ) [] type_star in
    SMap.fold (fun n (export_loc, export) acc ->
      let export_def = SMap.get n type_named_infos in
      (match export, export_def with
        | TypeExportNamed { kind = NamedDeclaration; _ }, Some (DeclareExportDef _decl) ->
          raise Eval.Unreachable (* TODO: update signature verifier *)
        | TypeExportNamed { loc; kind = NamedDeclaration }, Some (ExportNamedDef _stmt) ->
          export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
              loc_WILDCARD, {
                Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = (loc, n);
                exported = None;
              }
            ]);
            source = None;
            exportKind = Ast.Statement.ExportType;
          }
        | TypeExportNamed { loc; kind = NamedSpecifier { local = name; source } }, None ->
          export_loc, Ast.Statement.ExportNamedDeclaration {
            Ast.Statement.ExportNamedDeclaration.declaration = None;
            specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
              loc_WILDCARD, {
                Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local = name;
                exported = if (snd name) = n then None else Some (loc, n);
              }
            ]);
            source = (match source with
              | None -> None
              | Some source -> Some (T.source_of_source source)
            );
            exportKind = Ast.Statement.ExportType;
          }
        | _ -> assert false
      ) :: acc
    ) type_named stmts

  let exports outlined file_sig =
    let open File_sig in
    let module_sig = file_sig.module_sig in
    let {
      info = exports_info;
      module_kind;
      type_exports_named;
      type_exports_star;
      requires = _;
    } = module_sig in
    let { module_kind_info; type_exports_named_info } = exports_info in
    let values = match module_kind, module_kind_info with
      | CommonJS { mod_exp_loc }, CommonJSInfo cjs_exports_defs ->
        cjs_exports outlined (mod_exp_loc, cjs_exports_defs)
      | ES { named; star }, ESInfo named_infos ->
        eval_export_value_bindings outlined named named_infos star
      | _ -> assert false
    in
    let types = eval_export_type_bindings type_exports_named type_exports_named_info type_exports_star in
    values, types

  let relativize loc program_loc =
    Loc.{ program_loc with
      start = {
        line = program_loc._end.line + loc.start.line;
        column = loc.start.column;
        offset = 0;
      };
      _end = {
        line = program_loc._end.line + loc._end.line;
        column = loc._end.column;
        offset = 0;
      };
    }

  let make env file_sig program =
    let program_loc, _, comments = program in
    let outlined = T.Outlined.create () in
    let env = make_env outlined env in
    let values, types = exports outlined file_sig in
    let outlined_stmts = T.Outlined.get outlined in
    program_loc,
    List.sort Pervasives.compare (
      List.rev_append env @@
      List.rev_append values @@
      List.rev_append types @@
      List.rev outlined_stmts
    ),
    comments

end
