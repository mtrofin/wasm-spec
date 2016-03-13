(* Version *)

let version = 0x0b


(* Encoding stream *)

type stream =
{
   buf : Buffer.t;
   patches : (int * char) list ref
}

let stream () = {buf = Buffer.create 8192; patches = ref []}
let pos s = Buffer.length s.buf
let put s b = Buffer.add_char s.buf b
let put_string s bs = Buffer.add_string s.buf bs
let patch s pos b = s.patches := (pos, b) :: !(s.patches)

let to_string s =
  let bs = Buffer.to_bytes s.buf in
  List.iter (fun (pos, b) -> Bytes.set bs pos b) !(s.patches);
  Bytes.to_string bs


(* Generic types *)

let u8 s i = put s (Char.chr (i land 0xff))
let u16 s i = u8 s (i land 0xff); u8 s (i lsr 8)
let u32 s i =
  Int32.(u16 s (to_int (logand i 0xffffl)); u16 s (to_int (shift_right i 16)))

let rec vu64 s i =
  let b = Int64.(to_int (logand i 0x7fL)) in
  if i < 128L then
    u8 s b
  else
    (u8 s (b lor 0x80); vu64 s (Int64.shift_right i 7))

let rec vs64 s i =
  let b = Int64.(to_int (logand i 0x7fL)) in
  if -64L <= i && i < 64L then
    u8 s b
  else
    (u8 s (b lor 0x80); vs64 s (Int64.shift_right i 7))

let vu32 s i = vu64 s (Int64.of_int32 i)
let vs32 s i = vs64 s (Int64.of_int32 i)
let vu s i = vu64 s (Int64.of_int i)
let f32 s x = u32 s (F32.to_bits x)
let f64 s x = u64 s (F64.to_bits x)

let bool s b = u8 s (if b then 1 else 0)
let string s bs = vu s (String.length bs); put_string s bs
let list f s xs = List.iter (f s) xs
let opt f s xo = Lib.Option.app (f s) xo
let vec f s xs = vu s (List.length xs); list f s xs
let vec1 f s xo = bool s (xo <> None); opt f s xo

let gap s = let p = pos s in u32 s 0x80808000l; p
let patch_gap s p n =
  let s' = stream () in vu s' n;
  let off = to_string s' in
  let lead = 4 - String.length off in
  assert (lead >= 0); (* Strings cannot excess 2G anyway *)
  for i = 0 to String.length off - 1 do patch s (p + lead) off.[i] done


(* Types *)

open Types

let value_type s = function
  | Int32Type -> u8 s 0x01
  | Int64Type -> u8 s 0x02
  | Float32Type -> u8 s 0x03
  | Float64Type -> u8 s 0x04

let expr_type s t = vec1 value_type s t

let func_type s = function
  | {ins; out} -> u8 s 0x05; vec value_type s ins; expr_type s out


(* Expressions *)

open Source
open Kernel
open Ast

let op s n = u8 s n
let arity s xs = vu s (List.length xs)
let arity1 s xo = bool s (xo <> None)

let memop s off align =
  vu s align; vu64 s off

let var s x = vu s x.it
let var32 s x = vu32 s (Int32.of_int x.it)

let rec expr s e =
  match e.it with
  | Nop -> op s 0x00
  | Block es -> op s 0x01; list expr s es; op s 0x17
  | Loop es -> op s 0x02; list expr s es; op s 0x17
  | If (e, es1, es2) ->
    op s 0x03; list expr s es1;
    if es2 <> [] then op s 0x04; list expr s es2; op s 0x17
  | Select (e1, e2, e3) -> expr s e1; expr s e2; expr s e3; op s 0x05
  | Br (x, eo) -> vec1 expr s eo; op s 0x06; arity1 s eo; var s x
  | Br_if (x, eo, e) ->
    vec1 expr s eo; expr s e; op s 0x07; arity1 s eo; var s x
  | Br_table (xs, x, eo, e) ->
    vec1 expr s eo; expr s e; op s 0x08; arity1 s eo; list var32 s xs; var32 s x

  | Ast.I32_const c -> op s 0x0a; vs32 s c.it
  | Ast.I64_const c -> op s 0x0b; vs64 s c.it
  | Ast.F32_const c -> op s 0x0c; f32 s c.it
  | Ast.F64_const c -> op s 0x0d; f64 s c.it

  | Ast.Get_local x -> op s 0x0e; var s x
  | Ast.Set_local (x, e) -> expr s e; op s 0x0f; var s x

  | Ast.Call (x, es) -> list expr s es; op s 0x12; arity s es; var s x
  | Ast.Call_import (x, es) -> list expr s es; op s 0x1f; arity s es; var s x
  | Ast.Call_indirect (x, e, es) ->
    expr s e; list expr s es; op s 0x13; arity s es; var s x
  | Ast.Return eo -> vec1 expr s eo; op s 0x14; arity1 s eo
  | Ast.Unreachable -> op s 0x15

  | I32_load8_s (o, a, e) -> expr s e; op s 0x20; memop s o a
  | I32_load8_u (o, a, e) -> expr s e; op s 0x21; memop s o a
  | I32_load16_s (o, a, e) -> expr s e; op s 0x22; memop s o a
  | I32_load16_u (o, a, e) -> expr s e; op s 0x23; memop s o a
  | I64_load8_s (o, a, e) -> expr s e; op s 0x24; memop s o a
  | I64_load8_u (o, a, e) -> expr s e; op s 0x25; memop s o a
  | I64_load16_s (o, a, e) -> expr s e; op s 0x26; memop s o a
  | I64_load16_u (o, a, e) -> expr s e; op s 0x27; memop s o a
  | I64_load32_s (o, a, e) -> expr s e; op s 0x28; memop s o a
  | I64_load32_u (o, a, e) -> expr s e; op s 0x29; memop s o a
  | I32_load (o, a, e) -> expr s e; op s 0x2a; memop s o a
  | I64_load (o, a, e) -> expr s e; op s 0x2b; memop s o a
  | F32_load (o, a, e) -> expr s e; op s 0x2c; memop s o a
  | F64_load (o, a, e) -> expr s e; op s 0x2d; memop s o a

  | I32_store8 (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x2e; memop s o a
  | I32_store16 (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x2f; memop s o a
  | I64_store8 (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x30; memop s o a
  | I64_store16 (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x31; memop s o a
  | I64_store32 (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x32; memop s o a
  | I32_store (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x33; memop s o a
  | I64_store (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x34; memop s o a
  | F32_store (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x35; memop s o a
  | F64_store (o, a, e1, e2) -> expr s e1; expr s e2; op s 0x36; memop s o a

  | Grow_memory e -> expr s e; op s 0x39
  | Memory_size -> op s 0x3b

  | I32_add (e1, e2) -> expr s e1; expr s e2; op s 0x40
  | I32_sub (e1, e2) -> expr s e1; expr s e2; op s 0x41
  | I32_mul (e1, e2) -> expr s e1; expr s e2; op s 0x42
  | I32_div_s (e1, e2) -> expr s e1; expr s e2; op s 0x43
  | I32_div_u (e1, e2) -> expr s e1; expr s e2; op s 0x44
  | I32_rem_s (e1, e2) -> expr s e1; expr s e2; op s 0x45
  | I32_rem_u (e1, e2) -> expr s e1; expr s e2; op s 0x46
  | I32_and (e1, e2) -> expr s e1; expr s e2; op s 0x47
  | I32_or (e1, e2) -> expr s e1; expr s e2; op s 0x48
  | I32_xor (e1, e2) -> expr s e1; expr s e2; op s 0x49
  | I32_shl (e1, e2) -> expr s e1; expr s e2; op s 0x4a
  | I32_shr_u (e1, e2) -> expr s e1; expr s e2; op s 0x4b
  | I32_shr_s (e1, e2) -> expr s e1; expr s e2; op s 0x4c
  | I32_rotl (e1, e2) -> expr s e1; expr s e2; op s 0xb6
  | I32_rotr (e1, e2) -> expr s e1; expr s e2; op s 0xb7
  | I32_eq (e1, e2) -> expr s e1; expr s e2; op s 0x4d
  | I32_ne (e1, e2) -> expr s e1; expr s e2; op s 0x4e
  | I32_lt_s (e1, e2) -> expr s e1; expr s e2; op s 0x4f
  | I32_le_s (e1, e2) -> expr s e1; expr s e2; op s 0x50
  | I32_lt_u (e1, e2) -> expr s e1; expr s e2; op s 0x51
  | I32_le_u (e1, e2) -> expr s e1; expr s e2; op s 0x52
  | I32_gt_s (e1, e2) -> expr s e1; expr s e2; op s 0x53
  | I32_ge_s (e1, e2) -> expr s e1; expr s e2; op s 0x54
  | I32_gt_u (e1, e2) -> expr s e1; expr s e2; op s 0x55
  | I32_ge_u (e1, e2) -> expr s e1; expr s e2; op s 0x56
  | I32_clz e -> expr s e; op s 0x57
  | I32_ctz e -> expr s e; op s 0x58
  | I32_popcnt e -> expr s e; op s 0x59
  | I32_eqz e -> expr s e; op s 0x5a

  | I64_add (e1, e2) -> expr s e1; expr s e2; op s 0x5b
  | I64_sub (e1, e2) -> expr s e1; expr s e2; op s 0x5c
  | I64_mul (e1, e2) -> expr s e1; expr s e2; op s 0x5d
  | I64_div_s (e1, e2) -> expr s e1; expr s e2; op s 0x5e
  | I64_div_u (e1, e2) -> expr s e1; expr s e2; op s 0x5f
  | I64_rem_s (e1, e2) -> expr s e1; expr s e2; op s 0x60
  | I64_rem_u (e1, e2) -> expr s e1; expr s e2; op s 0x61
  | I64_and (e1, e2) -> expr s e1; expr s e2; op s 0x62
  | I64_or (e1, e2) -> expr s e1; expr s e2; op s 0x63
  | I64_xor (e1, e2) -> expr s e1; expr s e2; op s 0x64
  | I64_shl (e1, e2) -> expr s e1; expr s e2; op s 0x65
  | I64_shr_u (e1, e2) -> expr s e1; expr s e2; op s 0x66
  | I64_shr_s (e1, e2) -> expr s e1; expr s e2; op s 0x67
  | I64_rotl (e1, e2) -> expr s e1; expr s e2; op s 0xb8
  | I64_rotr (e1, e2) -> expr s e1; expr s e2; op s 0xb9
  | I64_eq (e1, e2) -> expr s e1; expr s e2; op s 0x68
  | I64_ne (e1, e2) -> expr s e1; expr s e2; op s 0x69
  | I64_lt_s (e1, e2) -> expr s e1; expr s e2; op s 0x6a
  | I64_le_s (e1, e2) -> expr s e1; expr s e2; op s 0x6b
  | I64_lt_u (e1, e2) -> expr s e1; expr s e2; op s 0x6c
  | I64_le_u (e1, e2) -> expr s e1; expr s e2; op s 0x6d
  | I64_gt_s (e1, e2) -> expr s e1; expr s e2; op s 0x6e
  | I64_ge_s (e1, e2) -> expr s e1; expr s e2; op s 0x6f
  | I64_gt_u (e1, e2) -> expr s e1; expr s e2; op s 0x70
  | I64_ge_u (e1, e2) -> expr s e1; expr s e2; op s 0x71
  | I64_clz e -> expr s e; op s 0x72
  | I64_ctz e -> expr s e; op s 0x73
  | I64_popcnt e -> expr s e; op s 0x74
  | I64_eqz e -> expr s e; op s 0xba

  | F32_add (e1, e2) -> expr s e1; expr s e2; op s 0x75
  | F32_sub (e1, e2) -> expr s e1; expr s e2; op s 0x76
  | F32_mul (e1, e2) -> expr s e1; expr s e2; op s 0x77
  | F32_div (e1, e2) -> expr s e1; expr s e2; op s 0x78
  | F32_min (e1, e2) -> expr s e1; expr s e2; op s 0x79
  | F32_max (e1, e2) -> expr s e1; expr s e2; op s 0x7a
  | F32_abs e -> expr s e; op s 0x7b
  | F32_neg e -> expr s e; op s 0x7c
  | F32_copysign (e1, e2) -> expr s e1; expr s e2; op s 0x7d
  | F32_ceil e -> expr s e; op s 0x7e
  | F32_floor e -> expr s e; op s 0x7f
  | F32_trunc e -> expr s e; op s 0x80
  | F32_nearest e -> expr s e; op s 0x81
  | F32_sqrt e -> expr s e; op s 0x82
  | F32_eq (e1, e2) -> expr s e1; expr s e2; op s 0x83
  | F32_ne (e1, e2) -> expr s e1; expr s e2; op s 0x84
  | F32_lt (e1, e2) -> expr s e1; expr s e2; op s 0x85
  | F32_le (e1, e2) -> expr s e1; expr s e2; op s 0x86
  | F32_gt (e1, e2) -> expr s e1; expr s e2; op s 0x87
  | F32_ge (e1, e2) -> expr s e1; expr s e2; op s 0x88

  | F64_add (e1, e2) -> expr s e1; expr s e2; op s 0x89
  | F64_sub (e1, e2) -> expr s e1; expr s e2; op s 0x8a
  | F64_mul (e1, e2) -> expr s e1; expr s e2; op s 0x8b
  | F64_div (e1, e2) -> expr s e1; expr s e2; op s 0x8c
  | F64_min (e1, e2) -> expr s e1; expr s e2; op s 0x8d
  | F64_max (e1, e2) -> expr s e1; expr s e2; op s 0x8e
  | F64_abs e -> expr s e; op s 0x8f
  | F64_neg e -> expr s e; op s 0x90
  | F64_copysign (e1, e2) -> expr s e1; expr s e2; op s 0x91
  | F64_ceil e -> expr s e; op s 0x92
  | F64_floor e -> expr s e; op s 0x93
  | F64_trunc e -> expr s e; op s 0x94
  | F64_nearest e -> expr s e; op s 0x95
  | F64_sqrt e -> expr s e; op s 0x96
  | F64_eq (e1, e2) -> expr s e1; expr s e2; op s 0x97
  | F64_ne (e1, e2) -> expr s e1; expr s e2; op s 0x98
  | F64_lt (e1, e2) -> expr s e1; expr s e2; op s 0x99
  | F64_le (e1, e2) -> expr s e1; expr s e2; op s 0x9a
  | F64_gt (e1, e2) -> expr s e1; expr s e2; op s 0x9b
  | F64_ge (e1, e2) -> expr s e1; expr s e2; op s 0x9c

  | I32_trunc_s_f32 e -> expr s e; op s 0x9d
  | I32_trunc_s_f64 e -> expr s e; op s 0x9e
  | I32_trunc_u_f32 e -> expr s e; op s 0x9f
  | I32_trunc_u_f64 e -> expr s e; op s 0xa0
  | I32_wrap_i64 e -> expr s e; op s 0xa1
  | I64_trunc_s_f32 e -> expr s e; op s 0xa2
  | I64_trunc_s_f64 e -> expr s e; op s 0xa3
  | I64_trunc_u_f32 e -> expr s e; op s 0xa4
  | I64_trunc_u_f64 e -> expr s e; op s 0xa5
  | I64_extend_s_i32 e -> expr s e; op s 0xa6
  | I64_extend_u_i32 e -> expr s e; op s 0xa7
  | F32_convert_s_i32 e -> expr s e; op s 0xa8
  | F32_convert_u_i32 e -> expr s e; op s 0xa9
  | F32_convert_s_i64 e -> expr s e; op s 0xaa
  | F32_convert_u_i64 e -> expr s e; op s 0xab
  | F32_demote_f64 e -> expr s e; op s 0xac
  | F32_reinterpret_i32 e -> expr s e; op s 0xad
  | F64_convert_s_i32 e -> expr s e; op s 0xae
  | F64_convert_u_i32 e -> expr s e; op s 0xaf
  | F64_convert_s_i64 e -> expr s e; op s 0xb0
  | F64_convert_u_i64 e -> expr s e; op s 0xb1
  | F64_promote_f32 e -> expr s e; op s 0xb2
  | F64_reinterpret_i64 e -> expr s e; op s 0xb3
  | I32_reinterpret_f32 e -> expr s e; op s 0xb4
  | I64_reinterpret_f64 e -> expr s e; op s 0xb5


(* Sections *)

let section id f s x needed =
  if needed then begin
    let p = gap s in
    string s id;
    f s x;
    patch_gap s p (pos s - p)
  end


(* Type section *)

let type_section s ts =
  section "signatures" (vec func_type) s ts (ts <> [])


(* Import section *)

let import s imp =
  let {itype; module_name; func_name} = imp.it in
  var s itype; string s module_name; string s func_name

let import_section s imps =
  section "import_table" (vec import) s imps (imps <> [])


(* Function section *)

let func s f =
  let {ftype; _} = f.it in
  var s ftype

let func_section s fs =
  section "function_signatures" (vec func) s fs (fs <> [])


(* Table section *)

let table_section s tab =
  section "function_table" (vec var) s tab (tab <> [])


(* Memory section *)

let memory s mem =
  let {min; max; _} = mem.it in
  vu64 s min; vu64 s max; bool s true (*TODO: pending change*)

let memory_section s memo =
  section "memory" (opt memory) s memo (memo <> None)


(* Export section *)

let export s exp =
  let {Kernel.name; kind} = exp.it in
  (match kind with
  | `Func x -> var s x
  | `Memory -> () (*TODO: pending resolution*)
  ); string s name

let export_section s exps =
  section "export_table" (vec export) s exps (exps <> [])


(* Start section *)

let start_section s xo =
  section "start_function" (opt var) s xo (xo <> None)


(* Code section *)

let compress locals =
  let combine t = function
    | (t', n) :: ts when t = t' -> (t, n + 1) :: ts
    | ts -> (t, 1) :: ts
  in List.fold_right combine locals []

let local s (t, n) =
  vu s n; value_type s t

let code s f =
  let {locals; body; _} = f.it in
  list local s (compress locals);
  let p = gap s in
  list expr s body;
  patch_gap s p (pos s - p)

let code_section s fs =
  section "function_bodies" (vec code) s fs (fs <> [])


(* Data section *)

let segment s seg =
  let {Memory.addr; data} = seg.it in
  vu64 s addr; string s data

let data_section s segs =
  section "data_segments" (opt (list segment)) s
    segs (segs <> None && segs <> Some [])


(* End section *)

let end_section s =
  section "end" (fun s -> ignore) s () true


(* Module *)

let module_ s m =
  u32 s 0x6d736100l; u32 s (Int32.of_int version);
  type_section s m.it.types;
  import_section s m.it.imports;
  func_section s m.it.funcs;
  table_section s m.it.table;
  memory_section s m.it.memory;
  export_section s m.it.exports;
  start_section s m.it.start;
  code_section s m.it.funcs;
  data_section s (Lib.Option.map (fun mem -> mem.it.segments) m.it.memory);
  end_section s

let encode m =
  let s = stream () in
  module_ s m;
  to_string s
