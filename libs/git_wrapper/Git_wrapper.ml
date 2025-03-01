(* Yoann Padioleau
 *
 * Copyright (C) 2023 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)
open Common
open File.Operators

let logger = Logging.get_logger [ __MODULE__ ]

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Small wrapper around the 'git' command-line program.
 *
 * alternatives:
 *  - use https://github.com/fxfactorial/ocaml-libgit2, but
 *    most of the current Python code use 'git' directly
 *    so easier for now to just imitate the Python code.
 *    Morever we need services like 'git ls-files' and this
 *    does not seem to be supported by libgit.
 *  - use https://github.com/mirage/ocaml-git, which implements
 *    git purely in OCaml, but this currently seems to support only
 *    the "core" of git, not all the "porcelain" around such as
 *    'git ls-files' that we need.
 *
 * TODO: use Bos uniformly instead of Common.cmd_to_list and Lwt_process.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type status = {
  added : string list;
  modified : string list;
  removed : string list;
  unmerged : string list;
  renamed : (string * string) list;
}
[@@deriving show]

(*****************************************************************************)
(* Error management *)
(*****************************************************************************)

exception Error of string

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(*diff unified format regex https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html#Detailed-Unified
 * The above documentation isn't great, so unified diff format is
 * @@ -start,count +end,count @@
 * where count is optional
 * Start and end here are misnomers. Start here refers to where this line starts in the A file being compared
 * End refers to where this line starts in the B file being compared
 * So if we have a line that starts at line 10 in the A file, and starts at line 20 in the B file, then we have
 * @@ -10 +20 @@
 * If we have a multiline diff, then we have
 * @@ -10,3 +20,3 @@
 * where the 3 is the number of lines that were changed
 * We use a named capture group for the lines, and then split on the comma if it's a multiline diff *)
let _git_diff_lines_re = {|@@ -\d*,?\d* \+(?P<lines>\d*,?\d*) @@|}
let git_diff_lines_re = SPcre.regexp _git_diff_lines_re

(** Given some git diff ranges (see above), extract the range info *)
let range_of_git_diff lines =
  let range_of_substrings substrings =
    let line = Pcre.get_substring substrings 1 in
    let lines = Str.split (Str.regexp ",") line in
    let first_line =
      match lines with
      | [] -> assert false
      | h :: _ -> h
    in
    let start = int_of_string first_line in
    let change_count =
      if List.length lines > 1 then int_of_string (List.nth lines 1) else 1
    in
    let end_ = change_count + start in
    (start, end_)
  in
  let matched_ranges = SPcre.exec_all ~rex:git_diff_lines_re lines in
  (* get the first capture group, then optionally split the comma if multiline diff *)
  match matched_ranges with
  | Ok ranges ->
      Array.map
        (fun s ->
          try range_of_substrings s with
          | Not_found -> (-1, -1))
        ranges
  | Error _ -> [||]

(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)

(*****************************************************************************)
(* Use Common.cmd_to_list *)
(*****************************************************************************)

let files_from_git_ls ~cwd =
  let cmd = Bos.Cmd.(v "git" % "-C" % !!cwd % "ls-files") in
  let files_r = Bos.OS.Cmd.run_out cmd in
  let results = Bos.OS.Cmd.out_lines ~trim:true files_r in
  let files =
    match results with
    | Ok (files, (_, `Exited 0)) -> files
    | _ -> raise (Error "Could not get files from git ls-files")
  in
  files |> File.Path.of_strings

let status ~cwd ~commit =
  let cmd =
    Bos.Cmd.(
      v "git" % "-C" % !!cwd % "diff" % "--cached" % "--name-status"
      % "--no-ext-diff" % "-z" % "--diff-filter=ACDMRTUXB"
      % "--ignore-submodules" % "--relative" % commit)
  in
  let files_r = Bos.OS.Cmd.run_out cmd in
  let results = Bos.OS.Cmd.out_string ~trim:true files_r in
  let stats =
    match results with
    | Ok (str, (_, `Exited 0)) -> str |> String.split_on_char '\000'
    | _ -> raise (Error "Could not get files from git ls-files")
  in
  let check_dir_symlink file =
    try
      match ((Unix.lstat file).st_kind, (Unix.stat file).st_kind) with
      | Unix.S_LNK, Unix.S_DIR -> true
      | _ -> false
    with
    | _ -> false
  in
  let added = ref [] in
  let modified = ref [] in
  let removed = ref [] in
  let unmerged = ref [] in
  let renamed = ref [] in
  let rec parse = function
    | _ :: file :: tail when check_dir_symlink file ->
        logger#info "Skipping %s since it is a symlink to a directory: %s" file
          (Unix.realpath file);
        parse tail
    | "A" :: file :: tail ->
        added := file :: !added;
        parse tail
    | "M" :: file :: tail ->
        modified := file :: !modified;
        parse tail
    | "D" :: file :: tail ->
        removed := file :: !removed;
        parse tail
    | "U" :: file :: tail ->
        unmerged := file :: !unmerged;
        parse tail
    | typ :: before :: after :: tail when String.starts_with ~prefix:"R" typ ->
        removed := before :: !removed;
        added := after :: !added;
        renamed := (before, after) :: !renamed;
        parse tail
    | "!" (* ignored *) :: _ :: tail -> parse tail
    | "?" (* untracked *) :: _ :: tail -> parse tail
    | unknown :: file :: tail ->
        logger#warning "unknown type in git status: %s, %s" unknown file;
        parse tail
    | [ remain ] ->
        logger#warning "unknown data after parsing git status: %s" remain
    | [] -> ()
  in
  parse stats;
  {
    added = !added;
    modified = !modified;
    removed = !removed;
    unmerged = !unmerged;
    renamed = !renamed;
  }

let is_git_repo cwd =
  let cmd =
    Bos.Cmd.(v "git" % "-C" % !!cwd % "rev-parse" % "--is-inside-work-tree")
  in
  let run = Bos.OS.Cmd.run_status ~quiet:true cmd in
  match run with
  | Ok (`Exited 0) -> true
  | Ok _ -> false
  | Error (`Msg e) -> raise (Error e)

let dirty_lines_of_file file =
  (* In the future we can make the HEAD part a parameter, and allow users to scan against other branches *)
  let cwd = Fpath.parent file in
  let cmd =
    Bos.Cmd.(v "git" % "-C" % !!cwd % "ls-files" % "--error-unmatch" % !!file)
  in
  let status = Bos.OS.Cmd.run_status ~quiet:true cmd in
  match status with
  | Ok (`Exited 0) ->
      let cmd =
        Bos.Cmd.(v "git" % "-C" % !!cwd % "diff" % "-U0" % "HEAD" % !!file)
      in
      let out = Bos.OS.Cmd.run_out cmd in
      let lines_r = Bos.OS.Cmd.out_string ~trim:true out in
      let lines =
        match lines_r with
        | Ok (lines, (_, `Exited 0)) -> Some lines
        | _ -> None
      in
      Option.bind lines (fun l -> Some (range_of_git_diff l))
  | Ok _ -> None
  | Error (`Msg e) -> raise (Error e)

let dirty_files cwd =
  let cmd =
    Bos.Cmd.(
      v "git" % "-C" % !!cwd % "status" % "--porcelain" % "--ignore-submodules")
  in
  let lines_r = Bos.OS.Cmd.run_out cmd in
  let lines = Bos.OS.Cmd.out_lines ~trim:false lines_r in
  let lines =
    match lines with
    | Ok (lines, (_, `Exited 0)) -> lines
    | _ -> []
  in
  (* out_lines splits on newlines, so we always have an extra space at the end *)
  let files = List.filter (fun f -> not (String.trim f = "")) lines in
  let files = Common.map (fun l -> Fpath.v (Str.string_after l 3)) files in
  files

let init cwd =
  let cmd = Bos.Cmd.(v "git" % "-C" % !!cwd % "init") in
  match Bos.OS.Cmd.run_status cmd with
  | Ok (`Exited 0) -> ()
  | _ -> raise (Error "Error running git init")

let add cwd files =
  let files = Common.map Fpath.to_string files in
  let files = String.concat " " files in
  let cmd = Bos.Cmd.(v "git" % "-C" % !!cwd % "add" % files) in
  match Bos.OS.Cmd.run_status cmd with
  | Ok (`Exited 0) -> ()
  | _ -> raise (Error "Error running git add")

let commit cwd msg =
  let cmd = Bos.Cmd.(v "git" % "-C" % !!cwd % "commit" % "-m" % msg) in
  match Bos.OS.Cmd.run_status cmd with
  | Ok (`Exited 0) -> ()
  | _ -> raise (Error "Error running git commit")

let get_project_url () =
  let cmd = Bos.Cmd.(v "git" % "ls-remote" % "--get-url") in
  let out = Bos.OS.Cmd.run_out cmd in
  match Bos.OS.Cmd.out_string ~trim:true out with
  | Ok (url, _) -> Some url
  | Error _ ->
      File.find_first_match_with_whole_line (Fpath.v ".git/config") ".com"
(* TODO(dinosaure): this line is pretty weak due to the [".com"] (what happens
   when the domain is [".io"]?). We probably should handle that by a new
   environment variable. I just copied what [pysemgrep] does.
   [git ls-remote --get-url] is also enough and if we can not get such
   information, that's fine - the metadata is used only [Metrics_] actually. *)
