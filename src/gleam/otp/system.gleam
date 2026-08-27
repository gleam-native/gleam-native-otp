import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

pub type Mode {
  /// Currently handling message as normal.
  Running
  /// Termporarily not handling messages, other than system messages.
  Suspended
}

pub type DebugOption {
  NoDebug
}

pub type DebugState

@external(erlang, "sys", "debug_options")
pub fn debug_state(a: List(DebugOption)) -> DebugState {
  let _ = a
  coerce(Nil)
}

@external(erlang, "gleam_otp_external", "identity")
@external(native, "runtime", "gleam_native_identity")
fn coerce(a: a) -> b

/// Sends a system message to an OTP compatible process and waits for its
/// acknowledgement through the given reply function. The native target's
/// system messages are ordinary messages under a reserved tag.
@target(native)
fn system_request(
  pid: Pid,
  message: fn(fn(reply) -> Nil) -> SystemMessage,
) -> reply {
  let reply_subject = process.new_subject()
  let message = message(fn(reply) { process.send(reply_subject, reply) })
  let assert True =
    process.send_raw_tagged(pid, process.system_message_tag, message)
    as "System message sent to a dead process"
  process.receive_forever(reply_subject)
}

pub type StatusInfo {
  StatusInfo(
    module: Atom,
    parent: Pid,
    mode: Mode,
    debug_state: DebugState,
    state: Dynamic,
  )
}

// TODO: document
// TODO: implement remaining messages
pub type SystemMessage {
  // {replace_state, StateFn}
  // {change_code, Mod, Vsn, Extra}
  // {terminate, Reason}
  // {debug, {log, Flag}}
  // {debug, {trace, Flag}}
  // {debug, {log_to_file, FileName}}
  // {debug, {statistics, Flag}}
  // {debug, no_debug}
  // {debug, {install, {Func, FuncState}}}
  // {debug, {install, {FuncId, Func, FuncState}}}
  // {debug, {remove, FuncOrId}}
  Resume(fn() -> Nil)
  Suspend(fn() -> Nil)
  GetState(fn(Dynamic) -> Nil)
  GetStatus(fn(StatusInfo) -> Nil)
}

type DoNotLeak

/// Get the state of a given OTP compatible process. This function is only
/// intended for debugging.
///
/// Requires Erlang/OTP 26.1 or newer, as the underlying interface changed
/// in [OTP-18633][1] from a literal type to a result type.
///
/// For more information see the [Erlang documentation][2].
///
/// [1]: https://www.erlang.org/patches/otp-26.1#stdlib-5.1
/// [2]: https://erlang.org/doc/man/sys.html#get_state-1
///
@target(erlang)
@external(erlang, "sys", "get_state")
pub fn get_state(from from: Pid) -> Dynamic

@target(native)
pub fn get_state(from from: Pid) -> Dynamic {
  system_request(from, GetState)
}

@target(erlang)
@external(erlang, "sys", "suspend")
fn erl_suspend(a: Pid) -> DoNotLeak

/// Request an OTP compatible process to suspend, causing it to only handle
/// system messages.
///
/// For more information see the [Erlang documentation][1].
///
/// [1]: https://erlang.org/doc/man/sys.html#suspend-1
///
@target(erlang)
pub fn suspend(pid: Pid) -> Nil {
  erl_suspend(pid)
  Nil
}

@target(native)
pub fn suspend(pid: Pid) -> Nil {
  system_request(pid, fn(ack) { Suspend(fn() { ack(Nil) }) })
}

@target(erlang)
@external(erlang, "sys", "resume")
fn erl_resume(from from: Pid) -> DoNotLeak

/// Request a suspended OTP compatible process to resume, causing it to handle
/// all messages rather than only system messages.
///
/// For more information see the [Erlang documentation][1].
///
/// [1]: https://erlang.org/doc/man/sys.html#resume-1
///
@target(erlang)
pub fn resume(pid: Pid) -> Nil {
  erl_resume(pid)
  Nil
}

@target(native)
pub fn resume(pid: Pid) -> Nil {
  system_request(pid, fn(ack) { Resume(fn() { ack(Nil) }) })
}
