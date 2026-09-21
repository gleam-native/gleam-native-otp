//// A supervisor where the number and types of the children are specified
//// once, and the supervisor manages them using a configured restart strategy.
////
//// For further detail see the Erlang documentation:
//// <https://www.erlang.org/doc/apps/stdlib/supervisor.html>.
////
//// # Example
////
//// ```gleam
//// import gleam/otp/actor
//// import gleam/otp/static_supervisor.{type Supervisor} as supervisor
//// import app/database_pool
//// import app/http_server
//// 
//// pub fn start_supervisor() -> actor.StartResult(Supervisor) {
////   supervisor.new(supervisor.OneForOne)
////   |> supervisor.add(database_pool.supervised())
////   |> supervisor.add(http_server.supervised())
////   |> supervisor.start
//// }
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{
  type ExitMessage, type Pid, Abnormal, ExitMessage, Normal,
}
import gleam/option.{type Option, None, Some}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}

/// A reference to the running supervisor. In future this could be used to send
/// commands to the supervisor to perform certain actions, but today no such
/// APIs have been exposed.
///
/// This supervisor wrap Erlang/OTP's `supervisor` module, and as such it does
/// not use subjects for message sending. If it was implemented in Gleam a
/// subject might be used instead of this type.
///
pub opaque type Supervisor {
  Supervisor(pid: Pid)
}

/// How the supervisor should react when one of its children terminates.
pub type Strategy {
  /// If one child process terminates and is to be restarted, only that child
  /// process is affected. This is the default restart strategy.
  OneForOne

  /// If one child process terminates and is to be restarted, all other child
  /// processes are terminated and then all child processes are restarted.
  OneForAll

  /// If one child process terminates and is to be restarted, the 'rest' of the
  /// child processes (that is, the child processes after the terminated child
  /// process in the start order) are terminated. Then the terminated child
  /// process and all child processes after it are restarted.
  RestForOne
}

/// A supervisor can be configured to automatically shut itself down with exit
/// reason shutdown when significant children terminate with the auto_shutdown
/// key in the above map.
pub type AutoShutdown {
  /// Automic shutdown is disabled. This is the default setting.
  ///
  /// With auto_shutdown set to never, child specs with the significant flag
  /// set to true are considered invalid and will be rejected.
  Never
  /// The supervisor will shut itself down when any significant child
  /// terminates, that is, when a transient significant child terminates
  /// normally or when a temporary significant child terminates normally or
  /// abnormally.
  AnySignificant
  /// The supervisor will shut itself down when all significant children have
  /// terminated, that is, when the last active significant child terminates.
  /// The same rules as for any_significant apply.
  AllSignificant
}

/// A builder for configuring and starting a supervisor. See each of the
/// functions that take this type for details of the configuration possible.
///
/// # Example
///
/// ```gleam
/// import gleam/erlang/actor
/// import gleam/otp/static_supervisor.{type Supervisor} as supervisor
/// import app/database_pool
/// import app/http_server
/// 
/// pub fn start_supervisor() -> actor.StartResult(Supervisor) {
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(database_pool.supervised())
///   |> supervisor.add(http_server.supervised())
///   |> supervisor.start
/// }
/// ```
///
pub opaque type Builder {
  Builder(
    strategy: Strategy,
    intensity: Int,
    period: Int,
    auto_shutdown: AutoShutdown,
    children: List(ChildSpecification(Nil)),
  )
}

/// Create a new supervisor builder, ready for further configuration.
///
pub fn new(strategy strategy: Strategy) -> Builder {
  Builder(
    strategy: strategy,
    intensity: 2,
    period: 5,
    auto_shutdown: Never,
    children: [],
  )
}

/// To prevent a supervisor from getting into an infinite loop of child
/// process terminations and restarts, supervisors have a maximum restart
/// tolerance.
///
/// Intensity is the maximum number of restarts permitted, and period is the
/// number of seconds the intensity is tracked within.
///
/// If more than `intensity` restarts occur within `period` seconds,
/// the supervisor terminates all child processes and then itself. The
/// termination reason for the supervisor itself in that case will be
/// `shutdown`. 
///
/// Intensity defaults to 2 and period defaults to 5.
///
pub fn restart_tolerance(
  builder: Builder,
  intensity intensity: Int,
  period period: Int,
) -> Builder {
  Builder(..builder, intensity: intensity, period: period)
}

/// A supervisor can be configured to automatically shut itself down with
/// exit reason shutdown when significant children terminate.
///
pub fn auto_shutdown(builder: Builder, value: AutoShutdown) -> Builder {
  Builder(..builder, auto_shutdown: value)
}

/// Start a new supervisor process with the configuration and children
/// specified within the builder.
///
/// Typically you would use the `supervised` function to add your supervisor to
/// a supervision tree instead of using this function directly.
///
/// The supervisor will be linked to the parent process that calls this
/// function.
///
/// If any child fails to start the supervisor first terminates all already
/// started child processes with reason shutdown and then terminate itself and
/// returns an error.
///
@target(erlang)
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let flags =
    make_erlang_start_flags([
      Strategy(builder.strategy),
      Intensity(builder.intensity),
      Period(builder.period),
      AutoShutdown(builder.auto_shutdown),
    ])

  let module = atom.create("gleam@otp@static_supervisor")
  let children =
    builder.children |> list.reverse |> list.index_map(convert_child)
  case erlang_start_link(module, #(flags, children)) {
    Ok(pid) -> Ok(actor.Started(pid:, data: Supervisor(pid)))
    Error(error) -> Error(convert_erlang_start_error(error))
  }
}

/// Create a `ChildSpecification` that adds this supervisor as the child of
/// another, making it fault tolerant and part of the application's supervision
/// tree. You should prefer this to starting unsupervised supervisors with the
/// `start` function.
///
/// If any child fails to start the supervisor first terminates all already
/// started child processes with reason shutdown and then terminate itself and
/// returns an error.
///
pub fn supervised(builder: Builder) -> ChildSpecification(Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

@target(erlang)
@external(erlang, "gleam_otp_external", "convert_erlang_start_error")
fn convert_erlang_start_error(dynamic: Dynamic) -> actor.StartError

@target(erlang)
@external(erlang, "supervisor", "start_link")
fn erlang_start_link(
  module: Atom,
  args: #(ErlangStartFlags, List(ErlangChildSpec)),
) -> Result(Pid, Dynamic)

/// Add a child to the supervisor.
pub fn add(builder: Builder, child: ChildSpecification(data)) -> Builder {
  Builder(..builder, children: [
    supervision.map_data(child, fn(_) { Nil }),
    ..builder.children
  ])
}

@target(erlang)
fn convert_child(child: ChildSpecification(data), id: Int) -> ErlangChildSpec {
  let mfa = #(
    atom.create("gleam@otp@static_supervisor"),
    atom.create("start_child_callback"),
    [child.start],
  )

  let #(type_, shutdown) = case child.child_type {
    supervision.Supervisor -> #(atom.create("supervisor"), make_timeout(-1))
    supervision.Worker(ms) -> #(atom.create("worker"), make_timeout(ms))
  }

  make_erlang_child_spec([
    Id(id),
    Start(mfa),
    Restart(child.restart),
    Significant(child.significant),
    Type(type_),
    Shutdown(shutdown),
  ])
}

type ErlangStartFlags

@target(erlang)
@external(erlang, "maps", "from_list")
fn make_erlang_start_flags(
  flags: List(ErlangStartFlag(data)),
) -> ErlangStartFlags

type ErlangStartFlag(data) {
  Strategy(Strategy)
  Intensity(Int)
  Period(Int)
  AutoShutdown(AutoShutdown)
}

type ErlangChildSpec

@target(erlang)
@external(erlang, "maps", "from_list")
fn make_erlang_child_spec(
  properties: List(ErlangChildSpecProperty(data)),
) -> ErlangChildSpec

type ErlangChildSpecProperty(data) {
  Id(Int)
  Start(
    #(Atom, Atom, List(fn() -> Result(actor.Started(data), actor.StartError))),
  )
  Restart(supervision.Restart)
  Significant(Bool)
  Type(Atom)
  Shutdown(Timeout)
}

type Timeout

/// Negative numbers mean an infinite timeout
@target(erlang)
@external(erlang, "gleam_otp_external", "make_timeout")
fn make_timeout(amount: Int) -> Timeout

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
  start: fn() -> Result(actor.Started(anything), actor.StartError),
) -> Result(Pid, actor.StartError) {
  case start() {
    Ok(started) -> Ok(started.pid)
    Error(error) -> Error(error)
  }
}

// ---------------------------------------------------------------------------
// The native target's implementation: a pure Gleam supervisor over
// `gleam/erlang/process`, with the same behavior as Erlang/OTP's
// `supervisor` module — ordered starts, the three restart strategies,
// per-child restart kinds, shutdown timeouts with escalation to kill, and
// restart-intensity limits.

@target(native)
@external(native, "runtime", "gleam_native_process_monotonic_ms")
fn monotonic_ms() -> Int

@target(native)
@external(native, "runtime", "gleam_native_process_exit_self")
fn exit_self(reason: String) -> Nil

@target(native)
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let ack = process.new_subject()
  let pid = process.spawn(fn() { initialise(builder, ack) })
  case process.receive_forever(ack) {
    Ok(Nil) -> Ok(actor.Started(pid: pid, data: Supervisor(pid)))
    Error(error) -> Error(error)
  }
}

/// One child slot: its specification and the pid it is currently running
/// as, if it is running.
@target(native)
type Tracked {
  Tracked(specification: ChildSpecification(Nil), pid: Option(Pid))
}

@target(native)
type State {
  State(
    strategy: Strategy,
    intensity: Int,
    period: Int,
    children: List(Tracked),
    /// Monotonic timestamps (milliseconds) of recent restarts, newest
    /// first, for the intensity window.
    restarts: List(Int),
    /// Exit messages received while waiting for a specific child to shut
    /// down, to be handled by the main loop.
    pending: List(ExitMessage),
  )
}

@target(native)
fn initialise(
  builder: Builder,
  ack: process.Subject(Result(Nil, actor.StartError)),
) -> Nil {
  process.trap_exits(True)
  let specifications = list.reverse(builder.children)
  case start_children(specifications, []) {
    Ok(children) -> {
      process.send(ack, Ok(Nil))
      loop(State(
        strategy: builder.strategy,
        intensity: builder.intensity,
        period: builder.period,
        children: children,
        restarts: [],
        pending: [],
      ))
    }
    Error(#(error, started)) -> {
      // Stop what did start, in reverse start order, then report failure.
      let _pending = list.fold(started, [], shutdown_child)
      process.send(ack, Error(error))
      Nil
    }
  }
}

@target(native)
fn start_children(
  specifications: List(ChildSpecification(Nil)),
  started: List(Tracked),
) -> Result(List(Tracked), #(actor.StartError, List(Tracked))) {
  case specifications {
    [] -> Ok(list.reverse(started))
    [specification, ..rest] ->
      case specification.start() {
        Ok(child) ->
          start_children(rest, [
            Tracked(specification, Some(child.pid)),
            ..started
          ])
        Error(error) -> Error(#(error, started))
      }
  }
}

@target(native)
fn loop(state: State) -> Nil {
  case state.pending {
    [exit, ..rest] -> handle_exit(State(..state, pending: rest), exit)
    [] -> {
      let exit =
        process.new_selector()
        |> process.select_trapped_exits(fn(exit) { exit })
        |> process.selector_receive_forever
      handle_exit(state, exit)
    }
  }
}

@target(native)
fn handle_exit(state: State, exit: ExitMessage) -> Nil {
  let ExitMessage(pid, reason) = exit
  let position =
    list.index_map(state.children, fn(child, index) { #(index, child) })
    |> list.find(fn(entry) { { entry.1 }.pid == Some(pid) })
  case position {
    // An exit signal that is not from a running child: the parent (or
    // another linked process) telling the supervisor to shut down.
    Error(Nil) -> terminate(state, reason)

    Ok(#(index, child)) -> {
      let state = mark_stopped(state, index)
      case should_restart(child.specification, reason) {
        False -> loop(state)
        True -> {
          let state =
            State(..state, restarts: [monotonic_ms(), ..state.restarts])
          case within_intensity(state) {
            False -> terminate(state, Abnormal(dynamic.string("shutdown")))
            True ->
              case restart(state, index) {
                Ok(state) -> loop(state)
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
fn mark_stopped(state: State, index: Int) -> State {
  let children =
    list.index_map(state.children, fn(child, position) {
      case position == index {
        True -> Tracked(..child, pid: None)
        False -> child
      }
    })
  State(..state, children: children)
}

@target(native)
fn should_restart(
  specification: ChildSpecification(Nil),
  reason: process.ExitReason,
) -> Bool {
  case specification.restart {
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
fn within_intensity(state: State) -> Bool {
  let cutoff = monotonic_ms() - state.period * 1000
  let recent = list.filter(state.restarts, fn(timestamp) { timestamp > cutoff })
  list.length(recent) <= state.intensity
}

/// Restarts after the child at `index` failed, per the strategy: the
/// child alone, it and everything after it, or every child.
@target(native)
fn restart(state: State, index: Int) -> Result(State, Nil) {
  let from = case state.strategy {
    OneForOne -> index
    RestForOne -> index
    OneForAll -> 0
  }
  let only_failed = state.strategy == OneForOne
  // Stop the other children implicated by the strategy, in reverse start
  // order; buffered exits from the shutdowns join the pending list.
  let indexed = list.index_map(state.children, fn(child, i) { #(i, child) })
  let to_stop = case only_failed {
    True -> []
    False ->
      list.filter(indexed, fn(entry) { entry.0 >= from && entry.0 != index })
      |> list.reverse
  }
  let pending =
    list.fold(to_stop, state.pending, fn(pending, entry) {
      case { entry.1 }.pid {
        Some(pid) -> shutdown_tracked(pending, pid, { entry.1 }.specification)
        None -> pending
      }
    })
  // Restart the implicated children in start order.
  let children =
    list.index_map(state.children, fn(child, i) {
      let implicated = case only_failed {
        True -> i == index
        False -> i >= from
      }
      case implicated {
        False -> Ok(child)
        True ->
          case child.specification.start() {
            Ok(started) -> Ok(Tracked(..child, pid: Some(started.pid)))
            Error(_) -> Error(Nil)
          }
      }
    })
  let state = State(..state, pending: pending)
  // Any failed restart aborts the supervisor.
  case list.try_map(children, fn(child) { child }) {
    Ok(children) -> Ok(State(..state, children: children))
    Error(Nil) -> Error(Nil)
  }
}

/// Shuts every child down (in reverse start order) and exits with the
/// given reason.
@target(native)
fn terminate(state: State, reason: process.ExitReason) -> Nil {
  let _pending =
    list.reverse(state.children)
    |> list.fold(state.pending, fn(pending, child) {
      case child.pid {
        Some(pid) -> shutdown_tracked(pending, pid, child.specification)
        None -> pending
      }
    })
  case reason {
    Normal -> Nil
    _ -> exit_self("shutdown")
  }
}

@target(native)
fn shutdown_child(
  pending: List(ExitMessage),
  child: Tracked,
) -> List(ExitMessage) {
  case child.pid {
    Some(pid) -> shutdown_tracked(pending, pid, child.specification)
    None -> pending
  }
}

/// Stops one child: an exit signal with reason shutdown, waiting up to the
/// child's shutdown timeout for its exit, then a kill. Exit messages from
/// other processes that arrive while waiting are buffered and returned.
@target(native)
fn shutdown_tracked(
  pending: List(ExitMessage),
  pid: Pid,
  specification: ChildSpecification(Nil),
) -> List(ExitMessage) {
  let timeout = case specification.child_type {
    supervision.Worker(shutdown_ms) -> shutdown_ms
    supervision.Supervisor -> 5000
  }
  process.send_abnormal_exit(pid, "shutdown")
  case await_exit(pending, pid, timeout) {
    Ok(pending) -> pending
    Error(pending) -> {
      process.kill(pid)
      case await_exit(pending, pid, 5000) {
        Ok(pending) -> pending
        Error(pending) -> pending
      }
    }
  }
}

/// Waits for the exit message from a specific pid, buffering exits from
/// other processes. `Ok` when it arrived, `Error` on timeout.
@target(native)
fn await_exit(
  pending: List(ExitMessage),
  pid: Pid,
  timeout: Int,
) -> Result(List(ExitMessage), List(ExitMessage)) {
  let selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
  case process.selector_receive(selector, timeout) {
    Ok(ExitMessage(from, _) as exit) ->
      case from == pid {
        True -> Ok(pending)
        False -> await_exit(list.append(pending, [exit]), pid, timeout)
      }
    Error(Nil) -> Error(pending)
  }
}
