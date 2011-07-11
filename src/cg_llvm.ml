open Ir
open Llvm

let dbgprint = true

let entrypoint_name = "_im_main"
let caml_entrypoint_name = entrypoint_name ^ "_caml_runner"

exception UnsupportedType of val_type
exception MissingEntrypoint
exception UnimplementedInstruction

(* An exception for debugging *)
exception WTF

let buffer_t c = pointer_type (i8_type c)

(* Algebraic type wrapper for LLVM comparison ops *)
type cmp =
  | CmpInt of Icmp.t
  | CmpFloat of Fcmp.t

(* Function to encapsulate shared state for primary codegen *)
let codegen_root (c:llcontext) (m:llmodule) (b:llbuilder) (s:stmt) =

  let int_imm_t = i32_type c in
  let float_imm_t = float_type c in

  let rec type_of_val_type t = match t with
    | UInt(1) | Int(1) -> i1_type c
    | UInt(8) | Int(8) -> i8_type c
    | UInt(16) | Int(16) -> i16_type c
    | UInt(32) | Int(32) -> i32_type c
    | UInt(64) | Int(64) -> i64_type c
    | Float(32) -> float_type c
    | Float(64) -> double_type c
    | Vector(t, n) -> vector_type (type_of_val_type t) n
    | _ -> raise (UnsupportedType(t))
  in

  let ptr_to_buffer buf =
    (* TODO: put buffers in their own LLVM memory spaces *)
    match lookup_function entrypoint_name m with
      | Some(f) -> param f (buf-1)
      | None -> raise (MissingEntrypoint)
  in

  (* The symbol table for loop variables *)
  let sym_table =
    Hashtbl.create 10 
  in

  let sym_add name llv =
    Hashtbl.add sym_table name llv
  and sym_remove name =
    Hashtbl.remove sym_table name
  and sym_get name =
    Hashtbl.find sym_table name
  in

  let rec cg_expr = function
    (* constants *)
    | IntImm(i) | UIntImm(i) -> const_int   (int_imm_t)   i
    | FloatImm(f)            -> const_float (float_imm_t) f

    (* cast *)
    | Cast(t,e) -> cg_cast t e

    (* TODO: coding style: use more whitespace, fewer parens in matches? *)

    (* Binary operators are generated from builders for int, uint, float types *)
    (* Arithmetic and comparison on vector types use the same build calls as 
     * the scalar versions *)

    (* arithmetic *)
    | Add(l, r) -> cg_binop build_add  build_add  build_fadd l r
    | Sub(l, r) -> cg_binop build_sub  build_sub  build_fsub l r
    | Mul(l, r) -> cg_binop build_mul  build_mul  build_fmul l r
    | Div(l, r) -> cg_binop build_sdiv build_udiv build_fdiv l r

    (* comparison *)
    | EQ(l, r) -> cg_cmp Icmp.Eq  Icmp.Eq  Fcmp.Oeq l r
    | NE(l, r) -> cg_cmp Icmp.Ne  Icmp.Ne  Fcmp.One l r
    | LT(l, r) -> cg_cmp Icmp.Slt Icmp.Ult Fcmp.Olt l r
    | LE(l, r) -> cg_cmp Icmp.Sle Icmp.Ule Fcmp.Ole l r
    | GT(l, r) -> cg_cmp Icmp.Sgt Icmp.Ugt Fcmp.Ogt l r
    | GE(l, r) -> cg_cmp Icmp.Sge Icmp.Uge Fcmp.Oge l r

    (* Select *)
    | Select(c, t, f) -> build_select (cg_expr c) (cg_expr t) (cg_expr f) "" b

    (* memory *)
    | Load(t, mr) -> build_load (cg_memref mr t) "" b

    (* Loop variables *)
    | Var(name) -> sym_get name

    (* TODO: fill out other ops *)
    | _ -> raise UnimplementedInstruction

  and cg_binop iop uop fop l r =
    let build = match val_type_of_expr l with
      | Int _   | Vector(Int(_),_)   -> iop
      | UInt _  | Vector(UInt(_),_)  -> uop
      | Float _ | Vector(Float(_),_) -> fop
      | t -> raise (UnsupportedType(t))
    in
      build (cg_expr l) (cg_expr r) "" b

  and cg_cmp iop uop fop l r =
    cg_binop (build_icmp iop) (build_icmp uop) (build_fcmp fop) l r

  and cg_cast t e =
    (* shorthand for the common case *)
    let simple_cast build e t = build (cg_expr e) (type_of_val_type t) "" b in

    match (val_type_of_expr e, t) with

      (* TODO: cast vector types *)

      | UInt(fb), Int(tb) when fb > tb ->
          (* TODO: factor this truncate-then-zext pattern into a helper? *)
          (* truncate to t-1 bits, then zero-extend to t bits to avoid sign bit *)
          build_zext
            (build_trunc (cg_expr e) (integer_type c (tb-1)) "" b)
            (integer_type c tb) "" b

      | UInt(fb), Int(tb)
      | UInt(fb), UInt(tb) when fb < tb ->
          simple_cast build_zext e t

      (* TODO: what to do for negative sign in Int -> UInt? *)
      | Int(fb), UInt(tb) when fb > tb ->
          simple_cast build_trunc e t
      | Int(fb), UInt(tb) when fb < tb ->
          (* truncate to f-1 bits, then zero-extend to t bits to avoid sign bit *)
          build_zext
            (build_trunc (cg_expr e) (integer_type c (fb-1)) "" b)
            (integer_type c tb) "" b

      | UInt(fb), Int(tb)
      | Int(fb),  UInt(tb)
      | UInt(fb), UInt(tb)
      | Int(fb),  Int(tb) when fb = tb ->
          (* do nothing *)
          cg_expr e

      | UInt(fb), UInt(tb) when fb > tb -> simple_cast build_trunc e t

      (* int <--> float *)
      | Int(_),   Float(_) -> simple_cast build_sitofp e t
      | UInt(_),  Float(_) -> simple_cast build_uitofp e t
      | Float(_), Int(_)   -> simple_cast build_fptosi e t
      | Float(_), UInt(_)  -> simple_cast build_fptoui e t

      (* build_intcast in the C/OCaml interface assumes signed, so only
       * works for Int *)
      | Int(_), Int(_)       -> simple_cast build_intcast e t
      | Float(fb), Float(tb) -> simple_cast build_fpcast  e t

      (* TODO: remaining casts *)
      | _ -> raise UnimplementedInstruction

  and cg_for var_name min max body = 
      (* Emit the start code first, without 'variable' in scope. *)
      let start_val = const_int int_imm_t min in

      (* Make the new basic block for the loop header, inserting after current
       * block. *)
      let preheader_bb = insertion_block b in
      let the_function = block_parent preheader_bb in
      let loop_bb = append_block c (var_name ^ "_loop") the_function in

      (* Insert an explicit fall through from the current block to the
       * loop_bb. *)
      ignore (build_br loop_bb b);

      (* Start insertion in loop_bb. *)
      position_at_end loop_bb b;

      (* Start the PHI node with an entry for start. *)
      let variable = build_phi [(start_val, preheader_bb)] var_name b in

      (* Within the loop, the variable is defined equal to the PHI node. *)
      sym_add var_name variable;

      (* Emit the body of the loop.  This, like any other expr, can change the
       * current BB.  Note that we ignore the value computed by the body, but
       * don't allow an error *)
      ignore (cg_stmt body);

      (* Emit the updated counter value. *)
      let next_var = build_add variable (const_int int_imm_t 1) (var_name ^ "_nextvar") b in

      (* Compute the end condition. *)
      let end_cond = build_icmp Icmp.Slt next_var (const_int int_imm_t max) "" b in

      (* Create the "after loop" block and insert it. *)
      let loop_end_bb = insertion_block b in
      let after_bb = append_block c (var_name ^ "_afterloop") the_function in

      (* Insert the conditional branch into the end of loop_end_bb. *)
      ignore (build_cond_br end_cond loop_bb after_bb b);

      (* Any new code will be inserted in after_bb. *)
      position_at_end after_bb b;

      (* Add a new entry to the PHI node for the backedge. *)
      add_incoming (next_var, loop_end_bb) variable;

      (* Remove the variable binding *)
      sym_remove var_name;      

      (* Return an ignorable llvalue *)
      const_int int_imm_t 0

  and cg_stmt = function
    | Store(e, mr) ->
        let ptr = cg_memref mr (val_type_of_expr e) in
          build_store (cg_expr e) ptr b
    | Map( { name=n; range=(min, max) }, stmt) ->
        cg_for n min max stmt
    | For( { name=n; range=(min, max) }, stmt) ->
        cg_for n min max stmt
    | Block (first::second::rest) ->
        ignore(cg_stmt first);
        cg_stmt (Block (second::rest))
    | Block(first::[]) ->
        cg_stmt first
    | Block _ -> raise WTF
    | _ -> raise UnimplementedInstruction

  and cg_memref mr vt =
    (* load the global buffer** *)
    let base = ptr_to_buffer mr.buf in
    (* cast pointer to pointer-to-target-type *)
    let ptr = build_pointercast base (pointer_type (type_of_val_type vt)) "" b in
    (* build getelementpointer into buffer *)
    build_gep ptr [| cg_expr mr.idx |] "" b


  in

    (* actually generate from the root statement, returning the result *)
    cg_stmt s


module BufferSet = Set.Make (
struct
  type t = int
  let compare = Pervasives.compare
end)
(*module BufferMap = Map.Make( BufferOrder )*)

let rec buffers_in_stmt = function
  | If(e, s) -> BufferSet.union (buffers_in_expr e) (buffers_in_stmt s)
  | IfElse(e, st, sf) ->
      BufferSet.union (buffers_in_expr e) (
        BufferSet.union (buffers_in_stmt st) (buffers_in_stmt sf))
  | Map(_, s) -> buffers_in_stmt s
  | For(_, s) -> buffers_in_stmt s
  | Block stmts ->
      List.fold_left BufferSet.union BufferSet.empty (List.map buffers_in_stmt stmts)
  | Reduce (_, e, mr) | Store (e, mr) -> BufferSet.add mr.buf (buffers_in_expr e)

and buffers_in_expr = function
  (* immediates, vars *)
  | IntImm _ | UIntImm _ | FloatImm _ | Var _ -> BufferSet.empty

  (* binary ops *)
  | Add(l, r) | Sub(l, r) | Mul(l, r) | Div(l, r) | EQ(l, r)
  | NE(l, r) | LT(l, r) | LE(l, r) | GT(l, r) | GE(l, r) | And(l, r) | Or(l, r) ->
      BufferSet.union (buffers_in_expr l) (buffers_in_expr r)

  (* unary ops *)
  | Not e | Cast (_,e) -> buffers_in_expr e

  (* ternary ops *)
  | Select (c, t, f) -> BufferSet.union (buffers_in_expr c)
                          (BufferSet.union (buffers_in_expr t) (buffers_in_expr f))

  (* memory ops *)
  | Load (_, mr) -> BufferSet.singleton mr.buf

exception CGFailed of string
let verify_cg m =
    (* verify the generated module *)
    match Llvm_analysis.verify_module m with
      | Some reason -> raise(CGFailed(reason))
      | None -> ()

let codegen c s =
  (* create a new module for this cg result *)
  let m = create_module c "<fimage>" in

  (* enumerate all referenced buffers *)
  let buffers = buffers_in_stmt s in

    (* TODO: assert that all buffer IDs are represented in ordinal positions in list? *)
    (* TODO: build and carry buffer ID -> param Llvm.value map *)
    (* TODO: set readonly attributes on buffer args which aren't written *)

  (* define `void main(buf1, buf2, ...)` entrypoint*)
  let buf_args =
    Array.map (fun b -> buffer_t c) (Array.of_list (BufferSet.elements buffers)) in
  let main = define_function entrypoint_name (function_type (void_type c) buf_args) m in

    (* iterate over args and assign name "bufXXX" with `set_value_name s v` *)
    Array.iteri (fun i v -> set_value_name ("buf" ^ string_of_int (i+1)) v) (params main);

  (* start codegen at entry block of main *)
  let b = builder_at_end c (entry_block main) in

    (* codegen body *)
    ignore (codegen_root c m b s);

    (* return void from main *)
    ignore (build_ret_void b);

    if dbgprint then dump_module m;

    ignore (verify_cg m);

    (* return generated module and function *)
    (m,main)

exception BCWriteFailed of string

let codegen_to_file filename s =
  (* construct basic LLVM state *)
  let c = create_context () in

  (* codegen *)
  let (m,_) = codegen c s in

    (* write to bitcode file *)
    match Llvm_bitwriter.write_bitcode_file m filename with
      | false -> raise(BCWriteFailed(filename))
      | true -> ();

    (* free memory *)
    dispose_module m

(*
 * Wrappers
 *)
let codegen_caml_wrapper c m f =

  let is_buffer p = type_of p = buffer_t c in

  let wrapper_args = Array.map
                       (fun p ->
                          if is_buffer p then pointer_type (buffer_t c)
                          else type_of p)
                       (params f) in

  let wrapper = define_function
                  (caml_entrypoint_name)
                  (function_type (void_type c) wrapper_args)
                  m in

  let b = builder_at_end c (entry_block wrapper) in

  (* ba is an llvalue of the pointer generated by:
   *   GenericValue.of_pointer some_bigarray_object *)
  let codegen_bigarray_to_buffer (ba:llvalue) =
    (* fetch object pointer = ((void* )val)+1 *)
    let field_ptr = build_gep ba [| const_int (i32_type c) 1 |] "" b in
    (* deref object pointer *)
    let ptr = build_load field_ptr "" b in
      (* cast to buffer_t for passing into im function *)
      build_pointercast ptr (buffer_t c) "" b
  in

  let args = Array.mapi 
               (fun i p ->
                  if is_buffer p then
                    codegen_bigarray_to_buffer (param wrapper i)
                  else
                    param wrapper i)
               (params f) in

    (* codegen the call *)
    ignore (build_call f args "" b);

    (* return *)
    ignore (build_ret_void b);

    if dbgprint then dump_module m;

    ignore (verify_cg m);

    (* return the wrapper function *)
    wrapper

let codegen_to_ocaml_callable s =
  (* construct basic LLVM state *)
  let c = create_context () in

  (* codegen *)
  let (m,f) = codegen c s in

  (* codegen the wrapper *)
  let w = codegen_caml_wrapper c m f in

    (m,w)