//// A supervisor where child processes are started dynamically from a
//// pre-specified template, so new processes can be created as needed
//// while the program is running.
////
//// When the supervisor is shut down it shuts down all its children
//// concurrently and in no specified order.
////
//// For further detail see the Erlang documentation, particularly the parts
//// about the `simple_one_for_one` restart strategy, which is the Erlang
//// equivilent of the factory supervisor.
//// <https://www.erlang.org/doc/apps/stdlib/supervisor.html>.
////
//// ## Usage
////
//// Add the factory supervisor to your supervision tree using the `supervised`
//// function and a name created at the start of the program. The `new`
//// function takes a "template function", which is a function that takes one
//// argument and starts a linked child process.
////
//// You most likely want to give the factory supervisor a name, and to pass
//// that name to any other processes that will want to cause new child
//// processes to be started under the factory supervisor. In this example a
//// web server is used.
////
//// ```gleam
//// import gleam/erlang/process.{type Name}
//// import gleam/otp/actor.{type StartResult}
//// import gleam/otp/factory_supervisor as factory
//// import gleam/otp/static_supervisor as supervisor
//// import my_app
//// 
//// /// This function starts the application's supervision tree.
//// ///
//// /// It takes a name as an argument that is used by the factory supervisor.
//// ///
//// pub fn start_supervision_tree(reporters_name: Name(_)) -> StartResult(_) {
////   // Define a named factory supervisor that can create new child processes
////   // using the `my_app.start_reporter_actor` function, which is defined
////   // elsewhere in the program.
////   let reporter_factory_supervisor =
////     factory.worker_child(my_app.start_reporter_actor)
////     |> factory.named(reporters_name)
////     |> factory.supervised
//// 
////   // This web server process takes the name, so it can contact the factory
////   // supervisor to command it to start new processes as needed.
////   let web_server = my_app.supervised_web_server(reporters_name)
//// 
////   // Create the top-level static supervisor with the supervisor and web
////   // server as its children
////   supervisor.new(supervisor.RestForOne)
////   |> supervisor.add(reporter_factory_supervisor)
////   |> supervisor.add(web_server)
////   |> supervisor.start
//// }
//// ```
////
//// Any process with the name of the factory supervisor can use the
//// `get_by_name` function to get a reference to the supervisor, and then use
//// the `start_child` function to have it start new child processes.
////
//// Remember! Each process name created with `process.new_name` is unique.
//// Two names created by calling the function twice are different names, even
//// if the same string is given as an argument. You must create the name value
//// at the start of your program and then pass it down into application code
//// and library code that uses names.
////
//// ```gleam
//// import gleam/http/request.{type Request}
//// import gleam/http/response.{type Response}
//// import gleam/otp/factory_supervisor
//// import my_app
//// 
//// /// In our example this function is called each time a HTTP request is 
//// /// received by the web server.
//// pub fn handle_request(req: Request(_), reporters: Name(_)) -> Response(_) {
////   // Get a reference to the supervisor using the name
////   let supervisor = factory_supervisor.get_by_name(reporters)
//// 
////   // Start a new child process under the supervisor, passing the request path 
////   // to use as the argument for the child-starting template function.
////   let start_result = factory_supervisor.start_child(supervisor, request.path)
//// 
////   // A response is sent to the HTTP client.
////   // The child starting template function returns a result, with the error case
////   // being used when children fail to start. Because of this the `start_child`
////   // function also returns a result, so it must be handled too.
////   case start_result {
////     Ok(_) -> response.new(200)
////     Error(_) -> response.new(500)
////   }
//// }
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{
  type ExitMessage, type Pid, Abnormal, ExitMessage, Normal,
}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/internal/result2.{type Result2}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

const default_intensity = 2

const default_period = 5

const default_restart_strategy = supervision.Transient

/// A reference to the running supervisor
///
/// This supervisor wrap Erlang/OTP's `supervisor` module, and as such it does
/// not use subjects for message sending. If it was implemented in Gleam a
/// subject might be used instead of this type.
///
pub opaque type Supervisor(child_argument, child_data) {
  Supervisor(handle: SupervisorHandle)
}

/// An external type that is the union of the pid and the name of a supervisor,
/// seeing as Erlang functions will accept either. In Gleam a subject would be
/// used.
type SupervisorHandle

@target(erlang)
@external(erlang, "gleam_otp_external", "identity")
fn pid_to_supervisor_handle(pid: Pid) -> SupervisorHandle

@target(erlang)
@external(erlang, "gleam_otp_external", "identity")
fn name_to_supervisor_handle(
  name: process.Name(Message(child_argument, child_data)),
) -> SupervisorHandle

/// The message type of a factory supervisor. This message type is not used
/// directly, but if you are using a name with a factory supervisor then this
/// will be the message type of the name.
pub type Message(child_argument, child_data)

/// Get a reference to a supervisor using its registered name.
///
/// If no supervisor has been started using this name then functions
/// using this reference will fail.
///
/// # Panics
///
/// Functions using the `Supervisor` reference returned by this function
/// will panic if there is no factory supervisor registered with the name
/// when they are called. Always make sure your supervisors are themselves
/// supervised.
///
@target(erlang)
pub fn get_by_name(
  name: process.Name(Message(child_argument, child_data)),
) -> Supervisor(child_argument, child_data) {
  Supervisor(name_to_supervisor_handle(name))
}

@target(native)
pub fn get_by_name(
  name: process.Name(Message(child_argument, child_data)),
) -> Supervisor(child_argument, child_data) {
  Supervisor(coerce(process.named_subject(name)))
}

/// A builder for configuring and starting a supervisor. See each of the
/// functions that take this type for details of the configuration possible.
///
pub opaque type Builder(child_argument, child_data) {
  Builder(
    child_type: supervision.ChildType,
    template: fn(child_argument) -> actor.StartResult(child_data),
    restart_strategy: supervision.Restart,
    intensity: Int,
    period: Int,
    name: option.Option(process.Name(Message(child_argument, child_data))),
  )
}

/// Configure a supervisor with a child-starting template function.
///
/// You should use this unless the child processes are also supervisors.
///
/// The default shutdown timeout is 5000ms. This can be changed with the
/// `timeout` function.
///
pub fn worker_child(
  template: fn(child_argument) -> actor.StartResult(child_data),
) -> Builder(child_argument, child_data) {
  Builder(
    template:,
    child_type: supervision.Worker(5000),
    restart_strategy: default_restart_strategy,
    intensity: default_intensity,
    period: default_period,
    name: option.None,
  )
}

/// Configure a supervisor with a template that will start children that are
/// also supervisors.
///
/// You should only use this if the child processes are also supervisors.
///
/// Supervisor children have an unlimited amount of time to shutdown, there is
/// no timeout.
///
pub fn supervisor_child(
  template: fn(child_argument) -> actor.StartResult(child_data),
) -> Builder(child_argument, child_data) {
  Builder(
    template:,
    child_type: supervision.Supervisor,
    restart_strategy: default_restart_strategy,
    intensity: default_intensity,
    period: default_period,
    name: option.None,
  )
}

/// Provide a name for the supervisor to be registered with when started,
/// enabling it be more easily contacted by other processes. This is useful for
/// enabling processes that can take over from an older one that has exited due
/// to a failure.
///
/// If the name is already registered to another process then the factory
/// supervisor will fail to start.
///
pub fn named(
  builder: Builder(child_argument, child_data),
  name: process.Name(Message(child_argument, child_data)),
) -> Builder(child_argument, child_data) {
  Builder(..builder, name: option.Some(name))
}

/// To prevent a supervisor from getting into an infinite loop of child
/// process terminations and restarts, a maximum restart tolerance is
/// defined using two integer values specified with keys intensity and
/// period in the above map. Assuming the values MaxR for intensity and MaxT
/// for period, then, if more than MaxR restarts occur within MaxT seconds,
/// the supervisor terminates all child processes and then itself. The
/// termination reason for the supervisor itself in that case will be
/// shutdown. 
///
/// Intensity defaults to 2 and period defaults to 5.
///
pub fn restart_tolerance(
  builder: Builder(child_argument, child_data),
  intensity intensity: Int,
  period period: Int,
) -> Builder(child_argument, child_data) {
  Builder(..builder, intensity: intensity, period: period)
}

/// Configure the amount of milliseconds a child has to shut down before
/// being brutal killed by the supervisor.
///
/// If not set the default for a child is 5000ms.
///
/// This will be ignored if the child is a supervisor itself.
///
pub fn timeout(
  builder: Builder(argument, data),
  ms ms: Int,
) -> Builder(argument, data) {
  case builder.child_type {
    supervision.Worker(_) ->
      Builder(..builder, child_type: supervision.Worker(ms))
    _ -> builder
  }
}

/// Configure the strategy for restarting children when they exit. See the
/// documentation for the `supervision.Restart` for details.
///
/// If not set the default strategy is `supervision.Transient`, so children
/// will be restarted if they terminate abnormally.
///
pub fn restart_strategy(
  builder: Builder(argument, data),
  restart_strategy: supervision.Restart,
) -> Builder(argument, data) {
  case builder.child_type {
    supervision.Worker(_) -> Builder(..builder, restart_strategy:)
    _ -> builder
  }
}

/// Start a new supervisor process with the configuration and child template
/// specified within the builder.
///
/// Typically you would use the `supervised` function to add your supervisor to
/// a supervision tree instead of using this function directly.
///
/// The supervisor will be linked to the parent process that calls this
/// function.
///
@target(erlang)
pub fn start(
  builder: Builder(child_argument, child_data),
) -> actor.StartResult(Supervisor(child_argument, child_data)) {
  let flags =
    make_erlang_start_flags([
      Strategy(SimpleOneForOne),
      Intensity(builder.intensity),
      Period(builder.period),
    ])

  let module_atom = atom.create("gleam@otp@factory_supervisor")
  let function_atom = atom.create("start_child_callback")
  let mfa = #(module_atom, function_atom, [builder.template])

  let #(type_, shutdown) = case builder.child_type {
    supervision.Supervisor -> #(atom.create("supervisor"), make_timeout(-1))
    supervision.Worker(ms) -> #(atom.create("worker"), make_timeout(ms))
  }

  let child =
    make_erlang_child_spec([
      Id(0),
      Start(mfa),
      Restart(builder.restart_strategy),
      Type(type_),
      Shutdown(shutdown),
    ])

  let configuration = #(flags, [child])
  let start_result = case builder.name {
    option.None -> unnamed_start(module_atom, configuration)
    option.Some(name) -> named_start(Local(name), module_atom, configuration)
  }

  case start_result {
    Ok(pid) -> {
      let supervisor = Supervisor(pid_to_supervisor_handle(pid))
      Ok(actor.Started(pid:, data: supervisor))
    }
    Error(error) -> Error(convert_erlang_start_error(error))
  }
}

@target(erlang)
@external(erlang, "maps", "from_list")
fn make_erlang_start_flags(
  flags: List(ErlangStartFlag(data)),
) -> ErlangStartFlags

type ErlangStartFlags

@target(erlang)
@external(erlang, "gleam_otp_external", "convert_erlang_start_error")
fn convert_erlang_start_error(dynamic: Dynamic) -> actor.StartError

@target(erlang)
@external(erlang, "supervisor", "start_link")
fn unnamed_start(
  module: Atom,
  args: #(ErlangStartFlags, List(ErlangChildSpec)),
) -> Result(Pid, Dynamic)

@target(erlang)
@external(erlang, "supervisor", "start_link")
fn named_start(
  name: ErlangSupervisorName(child_argument, child_data),
  module: Atom,
  args: #(ErlangStartFlags, List(ErlangChildSpec)),
) -> Result(Pid, Dynamic)

type ErlangSupervisorName(child_argument, child_data) {
  Local(process.Name(Message(child_argument, child_data)))
}

type Strategy {
  SimpleOneForOne
}

type ErlangStartFlag(data) {
  Strategy(Strategy)
  Intensity(Int)
  Period(Int)
}

type ErlangChildSpec

@target(erlang)
@external(erlang, "maps", "from_list")
fn make_erlang_child_spec(
  properties: List(ErlangChildSpecProperty(argument, data)),
) -> ErlangChildSpec

type ErlangChildSpecProperty(argument, data) {
  Id(Int)
  Start(
    #(
      Atom,
      Atom,
      List(fn(argument) -> Result(actor.Started(data), actor.StartError)),
    ),
  )
  Restart(supervision.Restart)
  Type(Atom)
  Shutdown(Timeout)
}

type Timeout

/// Negative numbers mean an infinite timeout
@target(erlang)
@external(erlang, "gleam_otp_external", "make_timeout")
fn make_timeout(amount: Int) -> Timeout

/// Create a `ChildSpecification` that adds this supervisor as the child of
/// another, making it fault tolerant and part of the application's supervision
/// tree. You should prefer this to starting unsupervised supervisors with the
/// `start` function.
///
/// If any child fails to start the supervisor first terminates all already
/// started child processes with reason shutdown and then terminate itself and
/// returns an error.
///
pub fn supervised(
  builder: Builder(child_argument, child_data),
) -> ChildSpecification(Supervisor(child_argument, child_data)) {
  supervision.supervisor(fn() { start(builder) })
}

/// Start a new child using the supervisor's child template and the given
/// argument. The start result of the child is returned.
///
@target(erlang)
pub fn start_child(
  supervisor: Supervisor(child_argument, child_data),
  argument: child_argument,
) -> actor.StartResult(child_data) {
  case erlang_start_child(supervisor.handle, [argument]) {
    result2.Ok(pid, data) -> Ok(actor.Started(pid, data))
    result2.Error(reason) -> Error(reason)
  }
}

@target(native)
pub fn start_child(
  supervisor: Supervisor(child_argument, child_data),
  argument: child_argument,
) -> actor.StartResult(child_data) {
  process.call_forever(handle_subject(supervisor), fn(reply) {
    coerce(NativeStartChild(argument, reply))
  })
}

/// Returns the number of children under the supervisor.
///
/// This function runs the same speed regardless of how many children the
/// supervisor has.
///
/// If the supervisor is heavily overloaded this number could be inaccurate due
/// to the supervisor still processing the termination of some of its children.
///
@target(erlang)
pub fn count_children(factory: Supervisor(child_argument, child_data)) -> Int {
  erlang_count_children(factory.handle)
  |> list.key_find(atom.create("active"))
  |> result.unwrap(0)
}

@target(native)
pub fn count_children(factory: Supervisor(child_argument, child_data)) -> Int {
  process.call_forever(handle_subject(factory), fn(reply) {
    coerce(NativeCountChildren(reply))
  })
}

@target(erlang)
@external(erlang, "supervisor", "count_children")
fn erlang_count_children(supervisor: SupervisorHandle) -> List(#(Atom, Int))

@target(erlang)
@external(erlang, "supervisor", "start_child")
fn erlang_start_child(
  supervisor: SupervisorHandle,
  argument: List(child_argument),
) -> Result2(Pid, data, actor.StartError)

// Callback used by the Erlang supervisor module.
@target(erlang)
@internal
pub fn init(start_data: Dynamic) -> Result(Dynamic, never) {
  Ok(start_data)
}

// Callback used by the Erlang supervisor module.
@target(erlang)
@internal
pub fn start_child_callback(
  start: fn(argument) -> Result(actor.Started(data), actor.StartError),
  argument: argument,
) -> Result2(Pid, data, actor.StartError) {
  case start(argument) {
    Ok(started) -> result2.Ok(started.pid, started.data)
    Error(error) -> result2.Error(error)
  }
}

// ---------------------------------------------------------------------------
// The native target's implementation: the supervisor is a process holding
// the child template, addressed through a subject stored (coerced) in the
// `SupervisorHandle`. Its message protocol is the private
// `NativeFactoryMessage` type, coerced through the public opaque
// `Message` type.

@target(native)
@external(erlang, "gleam_otp_external", "identity")
@external(native, "runtime", "gleam_native_identity")
fn coerce(value: a) -> b

@target(native)
@external(native, "runtime", "gleam_native_process_monotonic_ms")
fn monotonic_ms() -> Int

@target(native)
@external(native, "runtime", "gleam_native_process_exit_self")
fn exit_self(reason: String) -> Nil

@target(native)
type NativeFactoryMessage(child_argument, child_data) {
  NativeStartChild(
    argument: child_argument,
    reply: process.Subject(actor.StartResult(child_data)),
  )
  NativeCountChildren(reply: process.Subject(Int))
}

@target(native)
fn handle_subject(
  supervisor: Supervisor(child_argument, child_data),
) -> process.Subject(NativeFactoryMessage(child_argument, child_data)) {
  coerce(supervisor.handle)
}

@target(native)
pub fn start(
  builder: Builder(child_argument, child_data),
) -> actor.StartResult(Supervisor(child_argument, child_data)) {
  let ack = process.new_subject()
  let pid = process.spawn(fn() { initialise(builder, ack) })
  case process.receive_forever(ack) {
    Ok(subject) -> Ok(actor.Started(pid:, data: Supervisor(coerce(subject))))
    Error(error) -> Error(error)
  }
}

@target(native)
type NativeState(child_argument, child_data) {
  NativeState(
    builder: Builder(child_argument, child_data),
    subject: process.Subject(NativeFactoryMessage(child_argument, child_data)),
    /// Running children with the argument each was started from.
    children: List(#(Pid, child_argument)),
    /// Monotonic timestamps (milliseconds) of recent restarts.
    restarts: List(Int),
  )
}

@target(native)
type Incoming(child_argument, child_data) {
  Api(NativeFactoryMessage(child_argument, child_data))
  Exit(ExitMessage)
}

@target(native)
fn initialise(
  builder: Builder(child_argument, child_data),
  ack: process.Subject(
    Result(
      process.Subject(NativeFactoryMessage(child_argument, child_data)),
      actor.StartError,
    ),
  ),
) -> Nil {
  process.trap_exits(True)
  let registration = case builder.name {
    option.None -> Ok(process.new_subject())
    option.Some(name) ->
      case process.register(process.self(), name) {
        Ok(Nil) -> Ok(coerce(process.named_subject(name)))
        Error(_) -> Error(actor.InitFailed("already started"))
      }
  }
  case registration {
    Ok(subject) -> {
      process.send(ack, Ok(subject))
      loop(NativeState(builder:, subject:, children: [], restarts: []))
    }
    Error(error) -> {
      process.send(ack, Error(error))
      Nil
    }
  }
}

@target(native)
fn loop(state: NativeState(child_argument, child_data)) -> Nil {
  let message =
    process.new_selector()
    |> process.select_map(state.subject, Api)
    |> process.select_trapped_exits(Exit)
    |> process.selector_receive_forever
  case message {
    Api(NativeStartChild(argument, reply)) ->
      case state.builder.template(argument) {
        Ok(started) -> {
          process.send(reply, Ok(started))
          loop(
            NativeState(..state, children: [
              #(started.pid, argument),
              ..state.children
            ]),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          loop(state)
        }
      }
    Api(NativeCountChildren(reply)) -> {
      process.send(reply, list.length(state.children))
      loop(state)
    }
    Exit(ExitMessage(pid, reason)) -> handle_exit(state, pid, reason)
  }
}

@target(native)
fn handle_exit(
  state: NativeState(child_argument, child_data),
  pid: Pid,
  reason: process.ExitReason,
) -> Nil {
  case list.key_find(state.children, pid) {
    // An exit signal from something that is not a child: the parent (or
    // another linked process) telling the supervisor to shut down.
    Error(Nil) -> terminate(state, reason)

    Ok(argument) -> {
      let children = list.filter(state.children, fn(child) { child.0 != pid })
      let state = NativeState(..state, children: children)
      case should_restart(state.builder.restart_strategy, reason) {
        False -> loop(state)
        True -> {
          let state =
            NativeState(..state, restarts: [monotonic_ms(), ..state.restarts])
          case within_intensity(state) {
            False -> terminate(state, Abnormal(dynamic.string("shutdown")))
            True ->
              case state.builder.template(argument) {
                Ok(started) ->
                  loop(
                    NativeState(..state, children: [
                      #(started.pid, argument),
                      ..state.children
                    ]),
                  )
                Error(_) ->
                  terminate(state, Abnormal(dynamic.string("shutdown")))
              }
          }
        }
      }
    }
  }
}

@target(native)
fn should_restart(
  restart: supervision.Restart,
  reason: process.ExitReason,
) -> Bool {
  case restart {
    supervision.Permanent -> True
    supervision.Temporary -> False
    supervision.Transient ->
      case reason {
        Normal -> False
        _ -> reason != Abnormal(dynamic.string("shutdown"))
      }
  }
}

@target(native)
fn within_intensity(state: NativeState(child_argument, child_data)) -> Bool {
  let cutoff = monotonic_ms() - state.builder.period * 1000
  let recent = list.filter(state.restarts, fn(timestamp) { timestamp > cutoff })
  list.length(recent) <= state.builder.intensity
}

@target(native)
fn terminate(
  state: NativeState(child_argument, child_data),
  reason: process.ExitReason,
) -> Nil {
  let timeout = case state.builder.child_type {
    supervision.Worker(shutdown_ms) -> shutdown_ms
    supervision.Supervisor -> 5000
  }
  list.each(state.children, fn(child) {
    process.send_abnormal_exit(child.0, "shutdown")
    await_exit(child.0, timeout)
  })
  case reason {
    Normal -> Nil
    _ -> exit_self("shutdown")
  }
}

@target(native)
fn await_exit(pid: Pid, timeout: Int) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
  case process.selector_receive(selector, timeout) {
    Ok(ExitMessage(from, _)) if from == pid -> Nil
    Ok(_other) -> await_exit(pid, timeout)
    Error(Nil) -> {
      process.kill(pid)
      Nil
    }
  }
}
