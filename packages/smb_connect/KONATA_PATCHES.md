# Konata local patches

## Synchronous socket write errors (2026-11-08)

`SocketWriter.write` performs only synchronous work. Remove its `async` modifier
so a closed socket's `StateError` reaches the awaiting SMB transport/request
error handler, rather than escaping through an unobserved `async void` future.
Real SMB playback reproduced this when mpv cancelled a range request.

Regression: `test/smb_socket_writer_test.dart` uses an actual loopback socket
whose output has closed, and requires the immediate caller to receive the
failure. Real SMB playback/seek verification is tracked in the local BDRip
acceptance report; this patch alone does not prove all cancellation paths.

## Failed tree disconnect still releases transport (2026-11-08)

Always close the transport in `SmbConnect.close`, even if a server has already
closed its connection and a tree disconnect fails. Konata's SMB HTTP adapter
records this cleanup failure without allowing it to escape an already finished
request. Regressions cover failed tree disconnect and completed HTTP response
cleanup in `test/smb_socket_writer_test.dart` and `test/smb_source_test.dart`.

## Peer EOF during an active output stream (2026-11-08)

`SocketReader2.onDone` destroys the socket after peer EOF instead of calling
`Socket.close` from an unawaited listener callback. The latter throws while the
output sink is bound to an ongoing flush/stream. A real loopback peer EOF during
`Socket.addStream` reproduces the failure in `test/smb_socket_writer_test.dart`.

## Response arriving before its waiter (2026-11-08)

After registering a response waiter, process bytes already buffered by the
socket reader. A fast server can answer during the preceding `flush`; the
reader's callback previously found no registered waiter and left the response
unprocessed until an unrelated future packet. Real 1 MiB reads timed out after
partial data; the same source and range completed byte-exactly after this fix.
`integration_test/native_network_short_test.dart` verifies a 1 MiB initial range
before playback, plus later ranges, seek, pause/resume and disposal.

## Bounded streaming blocks and cancellation (2026-11-08)

Use the negotiated SMB2 receive limit, capped at the existing single-read
limit of 64936 bytes, instead of serial 4095-byte reads. Real tablet Wi-Fi
reads previously sustained about 0.45 MB/s and could not keep up with the
test clip. SMB1 keeps its former block limit. This changes the active read
buffer by at most about 60 KiB and adds no prefetch queue or dependency.

Each emitted chunk now owns its buffer, contains only the actual bytes read,
and closes its file handle in `finally`, including stream cancellation.
Retained chunks previously changed after subsequent reads; short reads could
emit stale bytes, and cancellation skipped the final close. The failing then
passing regressions are in `test/smb_file_stream_test.dart`. Real device
throughput and playback results belong to the local acceptance report.

## Transport teardown during ticket revocation (2026-11-09)

After tree teardown, destroy the socket instead of gracefully closing an output
sink that may still be bound to an in-flight flush. Real active-ticket cancellation
raised `StreamSink is bound to a stream` in this path. The application now owns a
separate SMB relay per revocable ticket and closes its active connections; the
remaining-network integration test asserts cancellation before the full body is
read and verifies the independent main playback survives. Unit regressions in
`test/smb_source_test.dart` cover repeated close and revocation during connection
establishment. No native library, dependency or prefetch buffer is added.

## Terminal socket errors and pending responses (2026-11-09)

`SocketReader2` handles socket error events, preserves the original error and
stack for awaiting reads, and stops polling after a terminal error or EOF.
Already buffered final bytes remain readable. The transport completes pending
response waiters with that error, catches asynchronous packet-parser failures,
serializes reader callbacks, observes output-sink errors, and removes timed-out
waiters. This prevents connection resets from escaping as unhandled zone errors
and prevents pending reads from waiting for the ordinary polling deadline.

`test/smb_socket_writer_test.dart` injects a socket error stream, checks pending
and future reads/response waiters, and checks buffered EOF/truncation. Existing
real-loopback EOF, stream cancellation, range and retained-byte tests remain in
the focused regression. No NAS/device playback was repeated for this patch.

## Failed connection setup owns its transport (2026-11-10)

`SmbConnect.connect` retains transport ownership until both negotiation and
session setup succeed. A thrown setup error or a false session result closes
the transport before returning failure; cleanup errors do not replace the
original failure. A false session result now raises `SmbAuthException` instead
of returning an unauthenticated connection.

Transport close is safe before socket/reader initialization, shares completion
across repeated calls, and destroys the socket even if reader cancellation
throws. A socket that arrives after close is destroyed before installing a
listener, and a closed transport cannot report its old negotiation as usable.
This does not change dialect selection, authentication tokens or request retries.

`test/smb_connect_cleanup_test.dart` covers TCP refusal, malformed negotiation,
partial listener setup, thrown/false authentication results, cleanup failure,
late TCP completion, repeated close and fresh attempts after failure. Real
loopback sockets verify peer EOF before test teardown; synthetic authentication
contexts test ownership, not NTLM interoperability with an actual NAS.

## Respect NO_RETRY after response timeout (2026-11-10)

`SmbTransport.sendrecv` uses one attempt when `RequestParam.NO_RETRY` is present;
otherwise it retains the existing five-attempt limit. The initial send, response
timeout, retained payload handling, error types and mutex release are unchanged.
No late-response parsing or other retry policy is modified.

`test/refactor_baseline_lifecycle_test.dart` replaces the previously recorded
five-send defect expectation with the authorized single-send behavior. It also
covers default/empty flags, combined flags, success after a timeout, first-response
success, non-timeout failures, repeated calls and queued callers. Before the fix,
the new expectations reproduce the extra sends; after the fix, the focused SMB
regression passes. Historical baseline reports retain their original results.
