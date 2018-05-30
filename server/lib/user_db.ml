open Core

open Types
open Types.RuntimeT
open Types.RuntimeT.DbT

module RT = Runtime

open Db

let find_db tables table_name : db =
  match List.find ~f:(fun (d : db) -> d.display_name = String.capitalize table_name) tables with
   | Some d -> d
   | None -> failwith ("table not found: " ^ table_name)

(* ------------------------- *)
(* SQL Type Conversions; here placed to avoid OCaml circular dep issues *)
(* ------------------------- *)

let rec cast_expression_for (dv : dval) : string option =
  match dv with
  | DID _ -> Some "uuid"
  | DList l ->
    l
    |> List.filter_map ~f:cast_expression_for
    |> List.hd
    |> Option.map ~f:(fun cast -> cast ^ "[]")
  | _ -> None

let rec dval_to_sql ?quote:(quote="'") ?cast:(cast=true) (dv: dval) : string =
  let literal =
    match dv with
    | DInt i -> string_of_int i
    | DID i ->
      quote ^ Uuid.to_string i ^ quote
    | DBool b -> if b then "TRUE" else "FALSE"
    | DChar c -> Char.to_string c
    | DStr s -> quote ^ (escape s) ^ quote
    | DFloat f -> string_of_float f
    | DNull -> "NULL"
    | DDate d ->
      "TIMESTAMP WITH TIME ZONE "
      ^ quote
      ^ Dval.sqlstring_of_date d
      ^ quote
    | DList l ->
      quote
      ^ "{ "
      ^ (String.concat ~sep:", " (List.map ~f:(dval_to_sql ~quote:"\"" ~cast:false) l))
      ^ " }"
      ^ quote
    | _ -> Exception.client ("We don't know how to convert a " ^ Dval.tipename dv ^ " into the DB format")
  in
  match cast_expression_for dv with
  | Some e when cast = true -> literal ^ "::" ^ e
  | _ ->  literal

let escape_col (keyname: string) : string =
  keyname
  |> escape
  |> fun name -> "\"" ^ name ^ "\""

let col_names names : string =
  names
  |> List.map ~f:escape_col
  |> String.concat ~sep:", "

let key_names (vals: dval_map) : string =
  vals
  |> DvalMap.keys
  |> col_names

let val_names (vals: dval_map) : string =
  vals
  |> DvalMap.data
  |> List.map ~f:dval_to_sql
  |> String.concat ~sep:", "

(* Turn db rows into list of string/type pairs - removes elements with
 * holes, as they won't have been put in the DB yet *)
let cols_for (db: db) : (string * tipe) list =
  db.cols
  |> List.filter_map ~f:(fun c ->
    match c with
    | Filled (_, name), Filled (_, tipe) ->
      Some (name, tipe)
    | _ ->
      None)
  |> fun l -> ("id", TID) :: l

(*
 * Dear god, OCaml this is the worst
 * *)
let rec sql_to_dval tables (tipe: tipe) (sql: string) : dval =
  match tipe with
  | TID -> sql |> Uuid.of_string |> DID
  | TInt -> sql |> int_of_string |> DInt
  | TFloat -> sql |> float_of_string |> DFloat
  | TTitle -> sql |> DTitle
  | TUrl -> sql |> DUrl
  | TStr -> sql |> DStr
  | TBool ->
    (match sql with
    | "f" -> DBool false
    | "t" -> DBool true
    | b -> failwith ("bool should be true or false: " ^ b))
  | TDate ->
    DDate (if sql = ""
           then Time.epoch
           else Dval.date_of_sqlstring sql)
  | TBelongsTo table ->
    (* fetch here for now *)
    let id = sql |> Uuid.of_string |> DID in
    let db = find_db tables table in
    (match (fetch_by ~tables db "id" id) with
     | DList (a :: _) -> a
     | DList _ -> DNull
     | _ -> failwith "should never happen, fetch_by returns a DList")
  | THasMany table ->
    (* we get the string "{ foo, bar, baz }" back *)
    let split =
      sql
      |> fun s -> String.drop_prefix s 1
      |> fun s -> String.drop_suffix s 1
      |> fun s -> String.split s ~on:','
    in
    let ids =
      if split = [""]
      then []
      else
        split
        |> List.map ~f:(fun s -> s |> String.strip |> Uuid.of_string |> DID)
    in
    let db = find_db tables table in
    (* TODO(ian): fix the N+1 here *)
    List.map
      ~f:(fun i ->
          (match (fetch_by ~tables db "id" i) with
           | DList l -> List.hd_exn l
           | _ -> failwith "should never happen, fetch_by returns a DList")
        ) ids
    |> DList
  | TDbList tipe ->
    sql
    |> fun s -> String.drop_prefix s 1
    |> fun s -> String.drop_suffix s 1
    |> fun s -> String.split s ~on:','
    |> List.filter ~f:(fun s -> not (String.is_empty s))
    |> List.map ~f:(fun v -> sql_to_dval tables tipe v)
    |> DList
  | _ -> failwith ("type not yet converted from SQL: " ^ sql ^
                   (Dval.tipe_to_string tipe))
and
fetch_by ~tables db (col: string) (dv: dval) : dval =
  let (names, types) = cols_for db |> List.unzip in
  let colnames = col_names names in
  Printf.sprintf
    "SELECT %s FROM \"%s\" WHERE %s = %s"
    colnames (escape db.actual_name) (escape_col col) (dval_to_sql dv)
  |> fetch_via_sql_in_ns ~host:db.host
  |> List.map ~f:(to_obj tables names types)
  |> DList
and
(* PG returns lists of strings. This converts them to types using the
 * row info provided *)
to_obj tables (names : string list) (types: tipe list) (db_strings : string list)
  : dval =
  db_strings
  |> List.map2_exn ~f:(sql_to_dval tables) types
  |> List.zip_exn names
  |> Dval.to_dobj


let rec sql_tipe_for (tipe: tipe) : string =
  match tipe with
  | TAny -> failwith "todo sql type"
  | TInt -> "INT"
  | TFloat -> "REAL"
  | TBool -> "BOOLEAN"
  | TNull -> failwith "todo sql type"
  | TChar -> failwith "todo sql type"
  | TStr -> "TEXT"
  | TList -> failwith "todo sql type"
  | TObj -> failwith "todo sql type"
  | TIncomplete -> failwith "todo sql type"
  | TError -> failwith "todo sql type"
  | TBlock -> failwith "todo sql type"
  | TResp -> failwith "todo sql type"
  | TDB -> failwith "todo sql type"
  | TID | TBelongsTo _ -> "UUID"
  | THasMany _ -> "uuid ARRAY"
  | TDate -> "TIMESTAMP WITH TIME ZONE"
  | TTitle -> "TEXT"
  | TUrl -> "TEXT"
  | TDbList t -> (sql_tipe_for t) ^ " ARRAY"

let default_for (tipe: tipe) : string =
  match tipe with
  | TAny -> failwith "todo sql type"
  | TInt -> "0"
  | TFloat -> "0.0"
  | TBool -> "FALSE"
  | TNull -> failwith "todo sql type"
  | TChar -> failwith "todo sql type"
  | TStr -> "''"
  | TList -> failwith "todo sql type"
  | TObj -> failwith "todo sql type"
  | TIncomplete -> failwith "todo sql type"
  | TError -> failwith "todo sql type"
  | TBlock -> failwith "todo sql type"
  | TResp -> failwith "todo sql type"
  | TDB -> failwith "todo sql type"
  | TID | TBelongsTo _ -> "'00000000-0000-0000-0000-000000000000'::uuid"
  | THasMany _ -> "'{}'"
  | TDate -> "CURRENT_TIMESTAMP"
  | TTitle -> "''"
  | TUrl -> "''"
  | TDbList _ -> "'{}'"

(* ------------------------- *)
(* frontend stuff *)
(* ------------------------- *)
let dbs_as_env (dbs: db list) : dval_map =
  dbs
  |> List.map ~f:(fun (db: db) -> (db.display_name, DDB db))
  |> DvalMap.of_alist_exn

let dbs_as_exe_env (dbs: db list) : dval_map =
  dbs_as_env dbs

(* ------------------------- *)
(* actual DB stuff *)
(* ------------------------- *)
let is_relation (valu: dval) : bool =
  match valu with
  | DObj _ -> true
  | DList l ->
    List.for_all ~f:Dval.is_obj l
  | _ -> false

let rec insert ~tables (db: db) (vals: dval_map) : Uuid.t =
  let id = Uuid.create () in
  let vals = DvalMap.set ~key:"id" ~data:(DID id) vals in
  (* split out complex objects *)
  let objs, normal =
    Map.partition_map
      ~f:(fun v -> if is_relation v then `Fst v else `Snd v) vals
  in
  let cols = cols_for db in
  (* insert complex objects into their own table, return the inserted ids *)
  let obj_id_map = Map.mapi ~f:(upsert_dependent_object tables cols) objs in
  (* merge the maps *)
  let merged = Util.merge_left normal obj_id_map in
  let _ = Printf.sprintf "INSERT into \"%s\" (%s) VALUES (%s)"
      (escape db.actual_name) (key_names merged) (val_names merged)
          |> run_sql_in_ns ~host:db.host
  in
    id
and update ~tables db (vals: dval_map) =
  let id = DvalMap.find_exn vals "id" in
  (* split out complex objects *)
  let objs, normal =
    Map.partition_map
      ~f:(fun v -> if is_relation v then `Fst v else `Snd v) vals
  in
  let cols = cols_for db in
  (* update complex objects *)
  let obj_id_map = Map.mapi ~f:(upsert_dependent_object tables cols) objs in
  let merged = Util.merge_left normal obj_id_map in
  let sets = merged
           |> DvalMap.to_alist
           |> List.map ~f:(fun (k,v) ->
               (escape_col k) ^ " = " ^ dval_to_sql v)
           |> String.concat ~sep:", " in
  Printf.sprintf "UPDATE \"%s\" SET %s WHERE id = %s"
    (escape db.actual_name) sets (dval_to_sql id)
  |> run_sql_in_ns ~host:db.host
and upsert_dependent_object tables cols ~key:relation ~data:obj : dval =
  (* find table via coltype *)
  let table_name =
    let (cname, ctype) =
      try
        List.find_exn cols ~f:(fun (n, t) -> n = relation)
      with e -> RT.error "Trying to create a relation that doesn't exist"
                  ~actual:(DStr relation)
                  ~expected:("one of" ^ Batteries.dump cols)
    in
    match ctype with
    | TBelongsTo t | THasMany t -> t
    | _ -> failwith ("Expected TBelongsTo/THasMany, got: " ^ (show_tipe_ ctype))
  in
  let db_obj = find_db tables table_name in
  match obj with
  | DObj m ->
    (match DvalMap.find m "id" with
     | Some existing -> update ~tables db_obj m; existing
     | None -> insert ~tables db_obj m |> DID)
  | DList l ->
    List.map ~f:(fun x -> upsert_dependent_object tables cols ~key:relation ~data:x) l |> DList
  | _ -> failwith ("Expected complex object (DObj), got: " ^ (Dval.to_repr obj))

let fetch_all ~tables (db: db) : dval =
  let (names, types) = cols_for db |> List.unzip in
  let colnames = col_names names in
  Printf.sprintf
    "SELECT %s FROM \"%s\""
    colnames (escape db.actual_name)
  |> fetch_via_sql_in_ns ~host:db.host
  |> List.map ~f:(to_obj tables names types)
  |> DList

let delete ~tables (db: db) (vals: dval_map) =
  let id = DvalMap.find_exn vals "id" in
  Printf.sprintf "DELETE FROM \"%s\" WHERE id = %s"
    (escape db.actual_name) (dval_to_sql id)
  |> run_sql_in_ns ~host:db.host

let delete_all ~tables (db: db) =
  Printf.sprintf "DELETE FROM \"%s\""
    (escape db.actual_name)
  |> run_sql_in_ns ~host:db.host



let count (db: db) =
  Printf.sprintf "SELECT COUNT(*) AS c FROM \"%s\""
    (escape db.actual_name)
  |> fetch_via_sql_in_ns ~host:db.host
  |> List.hd_exn
  |> List.hd_exn
  |> int_of_string

(* ------------------------- *)
(* run all db and schema changes as migrations *)
(* ------------------------- *)

let initialize_migrations host : unit =
  "CREATE TABLE IF NOT EXISTS
     migrations
     ( id BIGINT
     , sql TEXT
     , PRIMARY KEY (id))"
  |> run_sql_in_ns ~host


let run_migration (host: string) (id: id) (sql:string) : unit =
  Log.infO "migration" sql;
  Printf.sprintf
    "DO
       $do$
         BEGIN
           IF ((SELECT COUNT(*) FROM migrations WHERE id = %d) = 0)
           THEN
             %s;
             INSERT INTO migrations (id, sql)
               VALUES (%d, (quote_literal('%s')));
           END IF;
         END
       $do$"
    id sql id (escape sql)
  |> run_sql_in_ns ~host

(* -------------------------
(* SQL for DB *)
 * TODO: all of the SQL here is very very easily SQL injectable.
 * This MUST be fixed before we go to production
 * ------------------------- *)

let create_table_sql (table_name: string) =
  Printf.sprintf
    "CREATE TABLE IF NOT EXISTS \"%s\" (id UUID PRIMARY KEY)"
    (escape table_name)

let add_col_sql (table_name: string) (name: string) (tipe: tipe) : string =
  Printf.sprintf
    "ALTER TABLE \"%s\" ADD COLUMN \"%s\" %s NOT NULL DEFAULT %s"
    (escape table_name) (escape name) (sql_tipe_for tipe) (default_for tipe)

let rename_col_sql (table_name: string) (oldname: string) (newname: string) : string =
  Printf.sprintf
    "ALTER TABLE \"%s\" RENAME \"%s\" TO \"%s\""
    (escape table_name) (escape oldname) (escape newname)

let retype_col_sql (table_name: string) (name: string) (tipe: tipe) : string =
  Printf.sprintf
    "ALTER TABLE \"%s\" ALTER COLUMN \"%s\" TYPE %s"
    (escape table_name) (escape name) (sql_tipe_for tipe)



(* ------------------------- *)
(* locked/unlocked (not _locking_) *)
(* ------------------------- *)

let schema_qualified (db: db) =
  ns_name (db.host) ^ "." ^ db.actual_name

let db_locked (db: db) : bool =
  Printf.sprintf
    "SELECT n_live_tup
    FROM pg_catalog.pg_stat_all_tables
    WHERE relname = '%s'
      AND schemaname = '%s';
    "
    (escape db.actual_name)
    (escape (ns_name db.host))
  |> fetch_via_sql
  |> (<>) [["0"]]


let unlocked (dbs: db list) : db list =
  match dbs with
  | [] -> []
  | db :: _ ->
    let host = db.host in
    let empties =
      (Printf.sprintf
        "SELECT relname, n_live_tup
        FROM pg_catalog.pg_stat_all_tables
        WHERE relname LIKE 'user_%%'
          AND schemaname = '%s';
        "
        (escape (ns_name host))
      )
      |> fetch_via_sql
    in
    dbs
    |> List.filter
      ~f:(fun db ->
          List.mem ~equal:(=) empties [db.actual_name; "0"])

(* TODO(ian): make single query *)
let drop (db: db) =
  if db_locked db
   && not (String.is_substring ~substring:"conduit" db.host)
   && not (String.is_substring ~substring:"onecalendar" db.host)
  then
    Printf.sprintf
      "Attempted to drop table %s, but it has data"
      db.actual_name
    |> Exception.internal
  else
    Printf.sprintf "DROP TABLE IF EXISTS \"%s\""
      (escape db.actual_name)
    |> run_sql_in_ns ~host:db.host

(* ------------------------- *)
(* DB schema *)
(* ------------------------- *)

let create (host:host) (name:string) (id: tlid) : db =
  { tlid = id
  ; host = host
  ; display_name = name
  ; actual_name = "user_" ^ name (* there's a schema too *)
  ; cols = []
  ; version = 0
  ; old_migrations = []
  ; active_migration = None
  }

let init_storage (db: db) =
  run_migration db.host db.tlid (create_table_sql db.actual_name)

(* we only add this when it is complete, and we use the ID to mark the
   migration table to know whether it's been done before. *)
let maybe_add_to_actual_db (db: db) (id: id) (col: col) (do_db_ops: bool) : col =
  if do_db_ops
  then
    (match col with
    | Filled (_, name), Filled (_, tipe) ->
      run_migration db.host id (add_col_sql db.actual_name name tipe)
    | _ ->
      ())
  else ();
  col


let add_col colid typeid (db: db) =
  { db with cols = db.cols @ [(Blank colid, Blank typeid)]}

let set_col_name id name (do_db_ops: bool) db =
  let set col =
    match col with
    | (Blank hid, tipe) when hid = id ->
        maybe_add_to_actual_db db id (Filled (hid, name), tipe) do_db_ops
    | _ -> col in
  let newcols = List.map ~f:set db.cols in
  if db.cols = newcols && do_db_ops
  then Exception.client "No change made to col type"
  else { db with cols = newcols }

let change_col_name id name (do_db_ops: bool) db =
  let change col =
    match col with
    | (Filled (hid, oldname), Filled (tipeid, tipename))
      when hid = id ->
      if do_db_ops
      then
        if db_locked db
        then
          (* change_col_name is called every time we build the canvas
           * (eg every API call).  However, db_locked is an transitory
           * state - so only fail if we're really trying to execute the
           * change, rather than just building the canvas. *)
          Exception.client ("Can't edit a locked DB: " ^ db.display_name)
        else
          run_migration db.host id
            (rename_col_sql db.actual_name oldname name)
      else ();
      (Filled (hid, name), Filled (tipeid, tipename))

    | _ -> col in
  { db with cols = List.map ~f:change db.cols }


let set_col_type id tipe (do_db_ops: bool) db =
  let set col =
    match col with
    | (name, Blank hid) when hid = id ->
        maybe_add_to_actual_db db id (name, Filled (hid, tipe)) do_db_ops
    | _ -> col in
  let newcols = List.map ~f:set db.cols in
  if db.cols = newcols && do_db_ops
  then Exception.client "No change made to col type"
  else { db with cols = newcols }

let change_col_type id newtipe (do_db_ops: bool) db =
  let change col =
    match col with
    | (Filled (nameid, name), Filled (tipeid, oldtipe))
      when tipeid = id ->
      if do_db_ops
      then
        if db_locked db
        then
          (* change_col_name is called every time we build the canvas
           * (eg every API call).  However, db_locked is an transitory
           * state - so only fail if we're really trying to execute the
           * change, rather than just building the canvas. *)
          Exception.client ("Can't edit a locked DB: " ^ db.display_name)
        else
          run_migration db.host id
            (retype_col_sql db.actual_name name newtipe)
      else ();
      (Filled (nameid, name), Filled (tipeid, newtipe))

    | _ -> col in
  { db with cols = List.map ~f:change db.cols }

let initialize_migration id rbid rfid kind (db : db) =
  if Option.is_some db.active_migration
  then
    Exception.internal
      ("Attempted to init a migration for a table with an active one: " ^ db.display_name);
  match kind with
  | ChangeColType ->
    let new_migration =
      { starting_version = db.version
      ; kind = kind
      ; rollback = Blank rbid
      ; rollforward = Blank rfid
      ; target = id
      }
    in
    { db with active_migration = Some new_migration }

