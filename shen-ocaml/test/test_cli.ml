let read_file path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let run binary args input =
  let input_path = Filename.temp_file "shen-cli-input-" ".txt" in
  let output_path = Filename.temp_file "shen-cli-output-" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove input_path; Sys.remove output_path) (fun () ->
    let file = open_out_bin input_path in output_string file input; close_out file;
    let stdin = Unix.openfile input_path [Unix.O_RDONLY] 0 in
    let stdout = Unix.openfile output_path [Unix.O_WRONLY; Unix.O_TRUNC] 0 in
    let pid = Unix.create_process binary (Array.of_list (binary :: args)) stdin stdout stdout in
    Unix.close stdin; Unix.close stdout;
    let deadline = Unix.gettimeofday () +. 10. in
    let rec wait () = match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ ->
          if Unix.gettimeofday () > deadline then (
            Unix.kill pid Sys.sigkill; ignore (Unix.waitpid [] pid);
            failwith ("CLI timeout: " ^ read_file output_path));
          Unix.sleepf 0.01; wait ()
      | _, status -> status
    in
    let status = wait () in
    status, read_file output_path)

let contains text part =
  try ignore (Str.search_forward (Str.regexp_string part) text 0); true
  with Not_found -> false

let () =
  let binary = Sys.argv.(1) in
  let cases = [
    ["eval"; "(+ 20 22)"], "", "42\n";
    ["eval"; "(define cli.double X -> (* X 2)) (cli.double 21)"], "", "42\n";
    ["eval"; "(tc +) (define cli.bool { number --> boolean } _ -> true) (cli.bool 1)"], "", "true\n";
    ["eval"; "(define cli.h X -> (+ X 1)) (define cli.f X -> (cli.h X)) (define cli.h X -> (+ X 100)) (cli.f 1)"], "", "101\n";
    ["repl"], "(+ 20 22)\n", "42";
  ] in
  List.iter (fun (args, input, expected) ->
    match run binary args input with
    | Unix.WEXITED 0, output when contains output expected -> ()
    | _, output -> failwith ("CLI failed: " ^ output)) cases;
  let absolute = Filename.temp_file "shen-cli-absolute-" ".shen" in
  Fun.protect ~finally:(fun () -> Sys.remove absolute) (fun () ->
    let channel = open_out absolute in
    output_string channel "(define cli-absolute-loaded X -> (+ X 1))\n";
    close_out channel;
    match run binary ["eval"; "(load \"" ^ absolute ^ "\") (cli-absolute-loaded 41)"] "" with
    | Unix.WEXITED 0, output when contains output "42" -> ()
    | _, output -> failwith ("absolute load failed: " ^ output));
  (match run binary ["eval"; "(hd 42)"] "" with
  | Unix.WEXITED 1, output when contains output "Error:" -> ()
  | _, output -> failwith ("CLI did not fail correctly: " ^ output));
  print_endline "CLI_RESULT eval=pass multi_form=pass typed=pass redefine=pass repl_eof=pass errors=pass"
