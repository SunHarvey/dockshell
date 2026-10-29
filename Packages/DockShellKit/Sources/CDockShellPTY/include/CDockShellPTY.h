#ifndef DOCKSHELL_PTY_RUNTIME_H
#define DOCKSHELL_PTY_RUNTIME_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#if __has_include("DockShellCredentialBroker.h")
#include "DockShellCredentialBroker.h"
#endif

/// All handles are reference-counted and internally synchronized. The detached
/// supervisor owns the descriptors and reaps its child before releasing its ref.
typedef struct ds_pty_session ds_pty_session;
typedef struct ds_pty_operation ds_pty_operation;

typedef struct {
    size_t incoming_bytes;
    size_t outgoing_bytes;
    size_t incoming_high_watermark;
    size_t outgoing_high_watermark;
    uint64_t bytes_received;
    uint64_t bytes_consumed;
    uint64_t bytes_enqueued;
    uint64_t bytes_sent;
    int finished;
} ds_pty_statistics;

/// Starts a freshly executed helper, never a post-fork Swift process. argv/envp
/// must be null terminated. Does not invoke a shell. Returns an errno value.
int ds_pty_session_spawn(const char *helper, char *const argv[], char *const envp[],
                         uint16_t rows, uint16_t columns, ds_pty_session **result);
/// Local-shell variant: closing also terminates the PTY's own foreground job
/// group, which interactive job control may separate from the shell's group.
int ds_pty_session_spawn_local(const char *helper, char *const argv[], char *const envp[],
                              uint16_t rows, uint16_t columns, ds_pty_session **result);
/// Binary subsystem variant. Executes only /usr/bin/ssh, with independent stdin,
/// stdout and bounded stderr pipes. Uses the same owned lifecycle and rings, but
/// never allocates a PTY or invokes the terminal launch helper. argv[0] must be
/// the fixed system SSH path; no shell is involved. Returns an errno value.
int ds_pipe_session_spawn_system_ssh(char *const argv[], char *const envp[],
                                    ds_pty_session **result);
pid_t ds_pty_session_pid(ds_pty_session *session);
void ds_pty_session_retain(ds_pty_session *session);
void ds_pty_session_release(ds_pty_session *session);
/// Nonblocking, idempotent. Discards pending IO and wakes every waiter.
void ds_pty_session_close(ds_pty_session *session);

/// An operation retains its session. Cancellation never closes another user's FD.
ds_pty_operation *ds_pty_operation_create(ds_pty_session *session);
void ds_pty_operation_cancel(ds_pty_operation *operation);
void ds_pty_operation_destroy(ds_pty_operation *operation);
/// Callback bytes are valid only during the call. Exactly one completion follows
/// a successful registration, including cancellation and explicit close. Callback
/// invocation is outside every internal mutex and may happen before return.
typedef void (*ds_pty_read_completion)(void *context, const void *bytes, size_t count, int error);
int ds_pty_session_read_async(ds_pty_operation *operation, size_t capacity,
                             ds_pty_read_completion completion, void *context);
/// Blocking on a condition variable, intended only for a dedicated worker thread.
/// Returns byte count, zero at EOF, or -1 with errno. Exactly one active reader.
ssize_t ds_pty_session_read(ds_pty_operation *operation, void *buffer, size_t capacity);
/// Enqueues every byte with bounded backpressure, or -1 with errno on cancellation.
/// Callers serialize writes to define FIFO ordering between separate operations.
int ds_pty_session_write(ds_pty_operation *operation, const void *buffer, size_t count);
int ds_pty_session_resize(ds_pty_session *session, uint16_t rows, uint16_t columns);
/// Waits for the supervisor to reap the child. Status is exit code or 128+signal.
int ds_pty_session_wait(ds_pty_operation *operation, int *exit_status);
/// Raw diagnostics are bounded to 32 KiB; never print this buffer or credentials.
size_t ds_pty_session_diagnostics(ds_pty_session *session, void *buffer, size_t capacity);
void ds_pty_session_statistics(ds_pty_session *session, ds_pty_statistics *result);

/// Helper-only entry: establishes controlling PTY, then execs the fixed system ssh.
int ds_pty_exec_system_ssh(char *const ssh_arguments[]);

#endif
