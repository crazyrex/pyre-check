(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open OUnit2
open Core

open Configuration
open Server

open Pyre


let write_content ~root ~filename content =
  Path.create_relative ~root ~relative:filename
  |> File.create ~content:(Test.trim_extra_indentation content)
  |> File.write


let test_saved_state context =
  let open Server.Protocol in
  (* Set up a directory for the server to run in. *)
  let local_root =
    bracket_tmpdir context
    |> Path.create_absolute
  in
  let content =
    {|
      class C:
        pass
      class D:
        pass
      def foo(d: D) -> C:
        return d
      x = C()
    |}
    |> Test.trim_extra_indentation
  in
  write_content ~root:local_root ~filename:"a.py" content;
  let configuration = Configuration.create ~local_root () in
  let saved_state_path =
    Path.create_relative ~root:local_root ~relative:"saved_state"
    |> Path.absolute
  in

  (* Spawn a server that saves its state on initialization. *)
  let server_configuration =
    Operations.create_configuration
      ~saved_state:(ServerConfiguration.Save saved_state_path)
      configuration
  in
  let _ = Commands.Start.run server_configuration in

  (* Wait until the server initializes before stopping. *)
  let socket = Operations.connect ~retries:3 ~configuration in
  Network.Socket.write socket (Request.FlushTypeErrorsRequest);
  let _ = Network.Socket.read socket in
  CommandTest.stop_server server_configuration;

  (* A saved state was created. *)
  assert_equal `Yes (Sys.file_exists saved_state_path);

  (* No server is running. *)
  assert_raises
    Operations.ConnectionFailure
    (fun () -> Operations.connect ~retries:1 ~configuration);

  (* A server loads from the saved state successfully. *)
  let server_configuration =
    let saved_state =
      let changed_files_path =
        Test.write_file ("changed_files", "")
        |> File.path
      in
      ServerConfiguration.Load
        (ServerConfiguration.LoadFromFiles {
            ServerConfiguration.shared_memory_path = Path.create_absolute saved_state_path;
            changed_files_path;
          })
    in
    Operations.create_configuration ~saved_state configuration
  in
  let _ = Commands.Start.run server_configuration in

  let socket = Operations.connect ~retries:3 ~configuration in
  (* Query the new server for environment information. *)
  Network.Socket.write socket (Commands.Query.parse_query ~root:local_root "type(a.x)");
  let query_response = Network.Socket.read socket in
  CommandTest.stop_server server_configuration;

  (* The server loaded from a saved state has the information we expect. *)
  let expected_response =
    TypeQueryResponse
      (TypeQuery.Response
         (TypeQuery.Type (Analysis.Type.primitive "a.C")))
  in
  assert_equal expected_response query_response;
  (* Errors are preserved when loading from a saved state. *)
  let _ =
    let saved_state =
      let changed_files_path =
        Test.write_file ("changed_files", "")
        |> File.path
      in
      ServerConfiguration.Load
        (ServerConfiguration.LoadFromFiles {
            ServerConfiguration.shared_memory_path = Path.create_absolute saved_state_path;
            changed_files_path;
          })
    in
    Commands.Start.run
      (Operations.create_configuration ~saved_state configuration)
  in
  let socket = Operations.connect ~retries:3 ~configuration in
  Network.Socket.write socket (Request.FlushTypeErrorsRequest);
  let errors = Network.Socket.read socket in
  CommandTest.stop_server server_configuration;

  let expected_errors =
    CommandTest.make_errors ~handle:"a.py" ~qualifier:(Ast.Expression.Access.create "a") content
    |> CommandTest.associate_errors_and_filenames
    |> fun errors -> Protocol.TypeCheckResponse errors
  in
  assert_equal ~printer:show_response expected_errors errors;

  (* The server reanalyzed changed files when they are passed in and banishes errors. *)
  write_content ~root:local_root ~filename:"a.py" "x = 1";
  let _ =
    let saved_state =
      let changed_files_path =
        Test.write_file
          ("changed_files",
           Path.absolute (Path.create_relative ~root:local_root ~relative:"a.py"))
        |> File.path
      in
      ServerConfiguration.Load
        (ServerConfiguration.LoadFromFiles {
            ServerConfiguration.shared_memory_path = Path.create_absolute saved_state_path;
            changed_files_path;
          })
    in
    Commands.Start.run
      (Operations.create_configuration ~saved_state configuration)
  in
  let socket = Operations.connect ~retries:3 ~configuration in
  Network.Socket.write socket (Request.FlushTypeErrorsRequest);
  let errors = Network.Socket.read socket in
  CommandTest.stop_server server_configuration;
  assert_equal ~printer:show_response (TypeCheckResponse []) errors


let test_invalid_configuration context =
  (* Setup two incompatible roots. *)
  let local_root =
    bracket_tmpdir context
    |> Path.create_absolute
  in
  (* Create an incompatible directory. *)
  let other_root =
    bracket_tmpdir context
    |> Path.create_absolute
  in

  let saved_state_path =
    Path.create_relative ~root:local_root ~relative:"saved_state"
    |> Path.absolute
  in
  let configuration = Configuration.create ~local_root () in
  let incompatible_configuration = Configuration.create ~local_root:other_root () in
  let connect () =
    let socket = Operations.connect ~retries:3 ~configuration in
    Network.Socket.write socket Server.Protocol.Request.FlushTypeErrorsRequest;
    let _ = Network.Socket.read socket in
    ()
  in
  (* Generate a saved state. *)
  let server_configuration =
    Operations.create_configuration
      ~saved_state:(ServerConfiguration.Save saved_state_path)
      configuration
  in
  let _ = Commands.Start.run server_configuration in
  connect ();
  CommandTest.stop_server server_configuration;

  (* We built the saved state. *)
  assert_equal `Yes (Sys.file_exists saved_state_path);
  (* No server is running. *)
  assert_raises Operations.ConnectionFailure connect;

  let socket =
    let path = Operations.socket_path ~create:true configuration in
    Network.Socket.initialize_unix_socket path
  in
  let connections = ref {
      State.socket;
      persistent_clients = Network.Socket.Table.create ();
      file_notifiers = [];
      watchman_pid = None;
    }
  in
  (* Trying to load from an incompatible configuration raises an exception. *)
  let saved_state =
    let changed_files_path =
      Test.write_file ("changed_files", "")
      |> File.path
    in
    ServerConfiguration.Load
      (ServerConfiguration.LoadFromFiles {
          ServerConfiguration.shared_memory_path = Path.create_absolute saved_state_path;
          changed_files_path;
        })
  in
  assert_raises
    (Server.SavedState.IncompatibleState "configuration mismatch")
    (fun () ->
       Server.SavedState.load
         ~server_configuration:(
           Operations.create_configuration
             ~saved_state
             incompatible_configuration)
         ~lock:(Mutex.create ())
         ~connections)


let () =
  CommandTest.run_command_tests
    "saved_state"
    [
      "saved_state", test_saved_state;
      "invalid_configuration", test_invalid_configuration;
    ]
