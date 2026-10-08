// Ported from iPASide.App/Engine/EngineClient.cs.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:ipaside/platform/child_process_reaper.dart';

import 'async_mutex.dart';
import 'engine_exception.dart';
import 'engine_locator.dart';
import 'json_utils.dart';

/// A completed engine command: whether it succeeded, its decoded JSON payload
/// (null when the frame carried none), and any error text (empty when none).
class EngineResult {
  /// Creates a result frame.
  const EngineResult({required this.ok, this.data, this.error = ''});

  /// Whether the command exited zero.
  final bool ok;

  /// The decoded `data` payload: a `Map<String, dynamic>`, a `List<dynamic>`, a
  /// scalar, or null.
  final Object? data;

  /// The engine's error text, or empty when the frame carried none.
  final String error;

  @override
  String toString() =>
      'EngineResult(ok: $ok, data: ${data.runtimeType}, error: $error)';
}

/// The single operation [EngineApi]-style facades need from the transport.
///
/// Extracted from the C# design (where `EngineApi` took the concrete
/// `EngineClient`) so the typed layer can be unit-tested without spawning a real
/// Python process.
abstract mixin class EngineCommandRunner {
  /// Runs one command and returns its result frame.
  ///
  /// [onProgress] receives each raw progress line, [env] is applied to that one
  /// request only.
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  });

  /// Unsolicited serve frames (`type: event`). Empty for scripted fakes.
  Stream<Map<String, dynamic>> get events => const Stream.empty();
}

/// Whether [frame] is an unsolicited serve event rather than a request frame.
bool isUnsolicitedEngineEvent(Map<String, dynamic> frame) =>
    frame['type'] == 'event';

/// Text shown when the serve process dies or its stdout closes mid-request.
///
/// The headline stays stable so existing checks still match. The exit code and
/// the last stderr lines are what a screenshot has to carry: a native crash
/// (anisette's emulator, for one) never becomes a JSON error frame.
String describeEngineExit({
  required String headline,
  int? exitCode,
  bool stillRunning = false,
  List<String> stderrLines = const <String>[],
}) {
  final StringBuffer buffer = StringBuffer(headline);
  if (exitCode != null) {
    final String hex =
        (exitCode & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();
    buffer.write(' (exit $exitCode, 0x$hex)');
  } else if (stillRunning) {
    buffer.write(' (output closed while the process was still running)');
  }
  final List<String> shown = <String>[];
  for (final String raw in stderrLines) {
    var line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    line = line.replaceAll(
      RegExp('IPASIDE_APPLE_PASSWORD=\\S+'),
      'IPASIDE_APPLE_PASSWORD=(redacted)',
    );
    if (line.length > 240) {
      line = '${line.substring(0, 240)}…';
    }
    shown.add(line);
  }
  final List<String> tail =
      shown.length > 12 ? shown.sublist(shown.length - 12) : shown;
  if (tail.isEmpty) {
    buffer.write(
      '\nThe engine printed nothing before it stopped. '
      'Sign in once more and send this whole message.',
    );
  } else {
    buffer.write('\n${tail.join('\n')}');
  }
  return buffer.toString();
}

/// Destination for engine stderr and lifecycle diagnostics.
typedef EngineLogSink = void Function(String message);

/// Routes engine diagnostics to the observatory / IDE log.
void defaultEngineLog(String message) =>
    developer.log(message, name: 'ipaside.engine');

/// Drives the Python engine kept alive as a single persistent `serve` process
/// (newline-delimited JSON over stdio).
///
/// Requests are serialized through an [AsyncMutex]; the process starts lazily
/// and its `ready` frame - which pays the one-time import cost - is awaited with
/// a 90 second bound. There are no heartbeats and no per-request timeout: a
/// sideload legitimately runs for minutes. If the process died since the last
/// call, the next call restarts it.
///
/// [dispose] is idempotent and kill-first for the in-flight case. Afterwards
/// every call throws [EngineDisposedException], while the interrupted request
/// faults with [EngineShutdownException].
class EngineClient with EngineCommandRunner {
  /// Resolves a launch spec immediately (so bad configuration surfaces early)
  /// but starts nothing until the first request or [prewarm].
  EngineClient({
    required EngineLocator locator,
    required ChildProcessReaper reaper,
    EngineLogSink? log,
  })  :
        // A named parameter cannot be private, so this cannot become an
        // initializing formal for `_reaper`.
        // ignore: prefer_initializing_formals
        _reaper = reaper,
        _log = log ?? defaultEngineLog,
        _spec = locator.resolve();

  /// How long the `ready` frame may take; covers the Python import cost.
  static const Duration readyTimeout = Duration(seconds: 90);

  /// How long teardown waits for the process to exit at each stage.
  ///
  /// Measured on the release build: the serve loop breaks out on the shutdown
  /// frame and the process is gone ~70ms later (~30ms for an engine that has
  /// not imported anything yet), and `taskkill /T /F` returns in ~200ms. The
  /// engine does not linger - this ceiling exists only for one that has wedged,
  /// and the reaper's job object kills that one the moment we exit anyway. It
  /// is kept well under a noticeable wait because the stages compound: a wedged
  /// engine is charged this twice.
  static const Duration shutdownTimeout = Duration(seconds: 1);

  static const String _shutdownFrame = '{"type":"shutdown"}';

  final ChildProcessReaper _reaper;
  final EngineLogSink _log;
  final EngineLaunchSpec _spec;
  final AsyncMutex _gate = AsyncMutex();
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  Process? _process;
  IOSink? _stdin;
  _LineQueue? _stdout;
  StreamSubscription<String>? _stderr;
  bool _processExited = false;
  int? _lastExitCode;
  final List<String> _stderrTail = <String>[];
  int _nextId = 0;
  bool _disposed = false;
  Future<void>? _disposeTask;
  int? _enginePid;

  /// Unsolicited `type: event` frames from the live serve process.
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// How the engine will be launched; useful in diagnostics screens.
  EngineLaunchSpec get launchSpec => _spec;

  /// PID of the most recently started engine process, or null when not running.
  int? get enginePid => _enginePid;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Warms the engine ahead of the first request.
  ///
  /// Fire-and-forget: a failure here is swallowed because the first real request
  /// retries the start and reports properly.
  void prewarm() => unawaited(_prewarm());

  Future<void> _prewarm() async {
    if (_disposed) {
      return;
    }
    await _gate.acquire();
    try {
      if (_disposed) {
        return;
      }
      await _ensureStarted();
    } catch (error) {
      _log('prewarm failed: $error');
    } finally {
      _gate.release();
    }
  }

  /// Runs one command, resolving once its `result` frame arrives.
  ///
  /// Exactly one request is in flight at a time. Once the request line is
  /// written the loop drains to the matching result frame unconditionally, so
  /// ids stay correlated: frames tagged with any other id are discarded.
  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    // Pre-gate check: reject calls that arrive after teardown before we ever
    // touch the gate.
    if (_disposed) {
      throw EngineDisposedException();
    }

    await _gate.acquire();
    try {
      // Post-gate re-check: a caller that parked before teardown started lands
      // here after dispose's held-release.
      if (_disposed) {
        throw EngineDisposedException();
      }

      await _ensureStarted();

      final int id = ++_nextId;
      final IOSink sink = _stdin!;
      final _LineQueue lines = _stdout!;

      try {
        sink.writeln(encodeRequest(id, args, env));
        await sink.flush();
      } catch (error) {
        // Dart surfaces a write to a dead pipe as an exception here rather than
        // an I/O error frame; treat it as the engine having gone away.
        _log('request $id could not be written: $error');
        throw await _engineGone('engine exited unexpectedly');
      }

      while (true) {
        final String? raw = await lines.next();
        if (raw == null) {
          throw await _engineGone('engine exited unexpectedly');
        }

        final Map<String, dynamic>? frame = tryDecodeJsonObject(raw);
        if (frame == null) {
          continue;
        }
        if (isUnsolicitedEngineEvent(frame)) {
          continue;
        }
        if (frame['id'] != id) {
          continue;
        }

        final Object? type = frame['type'];
        if (type == 'progress') {
          final Object? line = frame['line'];
          if (onProgress != null && line is String) {
            onProgress(line);
          }
          continue;
        }
        if (type == 'result') {
          final Object? error = frame['error'];
          return EngineResult(
            ok: frame['ok'] == true,
            data: frame['data'],
            error: error is String ? error : '',
          );
        }
        // Anything else is ignored so a newer engine can add frame types.
      }
    } finally {
      _gate.release();
    }
  }

  /// Encodes one request line.
  ///
  /// `env` is omitted entirely when empty, and `--json` is never sent: the serve
  /// loop appends it to every request itself.
  static String encodeRequest(
    int id,
    List<String> args,
    Map<String, String>? env,
  ) =>
      jsonEncode(<String, Object?>{
        'id': id,
        'args': args,
        if (env != null && env.isNotEmpty) 'env': env,
      });

  Future<void> _ensureStarted() async {
    if (_process != null && !_processExited) {
      return;
    }
    await _cleanup();

    final Process process;
    try {
      process = await Process.start(
        _spec.fileName,
        <String>[..._spec.prefixArgs, 'serve'],
        // Interpreter launches carry `-E`, so these are for the frozen-executable
        // override, which takes no flags. Note the child inherits our environment,
        // which is why the interpreter must isolate itself rather than trust it:
        // a `PYTHONPATH` we never set would otherwise choose the engine for us.
        environment: <String, String>{
          'PYTHONUTF8': '1',
          'PYTHONUNBUFFERED': '1',
        },
        workingDirectory: _spec.workingDirectory,
      );
    } on ProcessException catch (error) {
      // A missing interpreter is the most common first-run failure; the C#
      // client let the raw Win32Exception escape, which the UI cannot bind.
      throw EngineException(
        'engine failed to start: ${error.executable} (${error.message})',
      );
    }

    // The OS tears the engine down with us, even if we crash.
    _reaper.adopt(process.pid);
    _process = process;
    _processExited = false;
    _lastExitCode = null;
    _stderrTail.clear();
    _enginePid = process.pid;
    unawaited(process.exitCode.then<void>((int code) {
      if (identical(_process, process)) {
        _processExited = true;
        _lastExitCode = code;
      }
      _log('engine pid ${process.pid} exited with code $code');
    }));

    final IOSink sink = process.stdin;
    // The engine reconfigures its stdin to UTF-8. Dart's IOSink defaults to the
    // OS encoding - a legacy code page on Windows - which would corrupt
    // non-ASCII paths, app names and passwords on the way in.
    sink.encoding = utf8;
    // A write to a dead engine also errors asynchronously on `done`; absorb it
    // so it never becomes an unhandled zone error. `run` reports the failure
    // itself from its own catch.
    unawaited(sink.done.catchError((Object error) {
      _log('engine stdin closed: $error');
    }));
    _stdin = sink;

    final _LineQueue lines = _LineQueue(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      _log,
      onEvent: _dispatchEvent,
    );
    _stdout = lines;

    // Drain the engine's stderr (library logging) so its pipe never blocks.
    _stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) {
            _rememberStderr(line);
            _log('[engine] $line');
          },
          onError: (Object error) => _log('[engine] stderr failed: $error'),
          cancelOnError: false,
        );

    await _awaitReady(lines);
  }

  void _rememberStderr(String line) {
    _stderrTail.add(line);
    if (_stderrTail.length > 40) {
      _stderrTail.removeAt(0);
    }
  }

  /// Wait briefly so a crash's stderr and exit code arrive before we report.
  Future<int?> _awaitExitCode() async {
    final Process? process = _process;
    if (process == null) {
      return _lastExitCode;
    }
    if (_processExited && _lastExitCode != null) {
      return _lastExitCode;
    }
    try {
      final int code = await process.exitCode.timeout(
        const Duration(milliseconds: 500),
      );
      _lastExitCode = code;
      _processExited = true;
      return code;
    } on TimeoutException {
      return _lastExitCode;
    }
  }

  void _writeFaultFile(String text) {
    try {
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      final String? home = Platform.environment['HOME'];
      final Directory dir;
      if (localAppData != null && localAppData.isNotEmpty) {
        dir = Directory('$localAppData${Platform.pathSeparator}iPASide');
      } else if (home != null && home.isNotEmpty) {
        dir = Directory(
          '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share${Platform.pathSeparator}iPASide',
        );
      } else {
        return;
      }
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}engine-fault.log')
          .writeAsStringSync('$text\n');
    } catch (error) {
      _log('could not write engine-fault.log: $error');
    }
  }

  /// The process died, or its stdout closed, during a request that is not shutdown.
  Future<EngineException> _engineGone(String headline) async {
    if (_disposed) {
      return EngineShutdownException();
    }
    final int? code = await _awaitExitCode();
    // Stderr is delivered on the event queue; one turn lets a fault dump land.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (_disposed) {
      return EngineShutdownException();
    }
    final bool stillRunning =
        code == null && _process != null && !_processExited;
    final String message = describeEngineExit(
      headline: headline,
      exitCode: code ?? _lastExitCode,
      stillRunning: stillRunning,
      stderrLines: List<String>.from(_stderrTail),
    );
    _writeFaultFile(message);
    final String saved = _faultLogPath();
    final String shown = saved.isEmpty
        ? message
        : '$message\nA copy was saved to $saved';
    await _cleanup();
    return EngineException(shown);
  }

  String _faultLogPath() {
    final String? localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return '$localAppData${Platform.pathSeparator}iPASide${Platform.pathSeparator}engine-fault.log';
    }
    final String? home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share${Platform.pathSeparator}iPASide${Platform.pathSeparator}engine-fault.log';
    }
    return '';
  }

  void _dispatchEvent(Map<String, dynamic> frame) {
    if (_events.isClosed) {
      return;
    }
    _events.add(frame);
  }

  Future<void> _awaitReady(_LineQueue lines) async {
    final DateTime deadline = DateTime.now().add(readyTimeout);
    while (true) {
      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        await _cleanup();
        throw EngineException('engine failed to start in time');
      }

      String? raw;
      try {
        raw = await lines.next().timeout(remaining);
      } on TimeoutException {
        // Always tear the half-started process down so a slow or cancelled
        // start never leaks a python.exe.
        await _cleanup();
        throw EngineException('engine failed to start in time');
      }

      if (raw == null) {
        throw await _engineGone('engine exited during startup');
      }

      final Map<String, dynamic>? frame = tryDecodeJsonObject(raw);
      if (frame != null && frame['type'] == 'ready') {
        _log('engine ready (version ${frame['version']})');
        return;
      }
      // Skip anything that is not the ready frame: a warning printed by an
      // imported library can land on stdout before it.
    }
  }

  /// Kills the engine if it is still running and drops every stream.
  ///
  /// Parked readers are woken with EOF, so an in-flight request never hangs on
  /// a stream nobody will feed again.
  Future<void> _cleanup() async {
    final Process? process = _process;
    final _LineQueue? lines = _stdout;
    final StreamSubscription<String>? stderr = _stderr;
    final bool exited = _processExited;

    _process = null;
    _stdin = null;
    _stdout = null;
    _stderr = null;
    _processExited = false;
    _enginePid = null;

    if (process != null && !exited) {
      await _killProcessTree(process);
    }
    await lines?.close();
    if (stderr != null) {
      try {
        await stderr.cancel();
      } catch (error) {
        // The pipe is already gone; nothing left to drain.
        _log('engine stderr cancel failed: $error');
      }
    }
  }

  Future<void> _killProcessTree(Process process) async {
    // Dart's Process.kill signals only the engine itself, but the engine spawns
    // its own helpers (zsign, pymobiledevice3 tooling). taskkill /T reproduces
    // C#'s Kill(entireProcessTree: true); the direct kill below is the fallback
    // and the whole story on non-Windows hosts.
    if (Platform.isWindows) {
      try {
        await Process.run(
          'taskkill',
          <String>['/PID', '${process.pid}', '/T', '/F'],
        );
      } catch (error) {
        // taskkill missing or refused; the direct kill still applies.
        _log('taskkill for pid ${process.pid} failed: $error');
      }
    }
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (error) {
      // Already gone.
      _log('kill for pid ${process.pid} failed: $error');
    }
  }

  /// Idempotent, kill-first teardown.
  ///
  /// Idle: sends the graceful `{"type":"shutdown"}` frame and waits. In-flight:
  /// kills the process tree FIRST to break the read loop, then reclaims the gate
  /// (bounded, never throwing). Every path converges on "process exited"; the
  /// returned future completes only once it has.
  Future<void> dispose() {
    _disposed = true;
    return _disposeTask ??= _disposeCore();
  }

  Future<void> _disposeCore() async {
    bool held = _gate.tryAcquire();
    if (held) {
      // Idle fast path: ask the engine to exit on its own. There can be no
      // parked waiter here - a free gate would already have admitted it.
      final IOSink? sink = _stdin;
      if (sink != null) {
        try {
          sink.writeln(_shutdownFrame);
          await sink.flush();
        } catch (error) {
          // Broken pipe: the wait-then-kill below still guarantees exit.
          _log('shutdown frame not delivered: $error');
        }
      }
    } else {
      // In-flight: kill the tree first to break the blocked read, then reclaim
      // the gate so we know the request has stopped touching the streams. A
      // timeout must neither throw nor hang - we fall through without the gate.
      final Process? process = _process;
      if (process != null && !_processExited) {
        await _killProcessTree(process);
      }
      held = await _gate.acquireWithin(shutdownTimeout);
    }

    final Process? process = _process;
    try {
      if (process != null) {
        try {
          await process.exitCode.timeout(shutdownTimeout);
        } on TimeoutException {
          await _killProcessTree(process);
          try {
            await process.exitCode.timeout(shutdownTimeout);
          } catch (error) {
            // Unkillable child: _cleanup below is the final best effort, and the
            // reaper still owns it. Never hang the app's close on this.
            _log('engine pid ${process.pid} did not exit after kill: $error');
          }
        }
      }
    } finally {
      await _cleanup();
      if (!_events.isClosed) {
        await _events.close();
      }
      if (held) {
        // Wake the one possibly-parked waiter so it throws the disposed error.
        _gate.release();
      }
    }
  }
}

/// Pull-based reader over the engine's stdout lines.
///
/// The request loop needs "give me the next frame" semantics, which a bare
/// `Stream` subscription does not offer and which `package:async`'s StreamQueue
/// would - but that is not a declared dependency. Event frames are stripped
/// here so they reach [EngineClient.events] even while a request is in flight,
/// and so they are never buffered for the next `run` to discard.
class _LineQueue {
  _LineQueue(
    Stream<String> lines,
    this._log, {
    this._onEvent,
  }) {
    _subscription = lines.listen(
      _onLine,
      onError: _onError,
      onDone: _finish,
      cancelOnError: false,
    );
  }

  final EngineLogSink _log;
  final void Function(Map<String, dynamic> frame)? _onEvent;
  final Queue<String> _buffer = Queue<String>();
  late final StreamSubscription<String> _subscription;
  Completer<String?>? _waiter;
  bool _closed = false;

  /// Completes with the next line, or null once the stream ended or [close] ran.
  Future<String?> next() {
    if (_buffer.isNotEmpty) {
      return Future<String?>.value(_buffer.removeFirst());
    }
    if (_closed) {
      return Future<String?>.value();
    }
    assert(_waiter == null, 'engine stdout is read by one request at a time');
    final Completer<String?> waiter = Completer<String?>();
    _waiter = waiter;
    return waiter.future;
  }

  /// Stops reading and unblocks any parked [next] with EOF.
  Future<void> close() async {
    _finish();
    _buffer.clear();
    try {
      await _subscription.cancel();
    } catch (error) {
      // The process is already gone.
      _log('engine stdout cancel failed: $error');
    }
  }

  void _onLine(String line) {
    final Map<String, dynamic>? frame = tryDecodeJsonObject(line);
    if (frame != null && isUnsolicitedEngineEvent(frame)) {
      _onEvent?.call(frame);
      return;
    }
    final Completer<String?>? waiter = _waiter;
    if (waiter != null) {
      _waiter = null;
      waiter.complete(line);
      return;
    }
    _buffer.add(line);
  }

  void _onError(Object error) {
    _log('engine stdout failed: $error');
    _finish();
  }

  void _finish() {
    if (_closed) {
      return;
    }
    _closed = true;
    final Completer<String?>? waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }
}
