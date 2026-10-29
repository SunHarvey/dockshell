#ifndef DOCKSHELL_CREDENTIAL_BROKER_H
#define DOCKSHELL_CREDENTIAL_BROKER_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/// Thread-safe, reference-counted local credential rendezvous. No secret is written to disk.
typedef struct ds_credential_broker ds_credential_broker;

/// Creates a private temporary directory and socket; helper_path is canonicalized.
/// OpenSSH askpass accepts at most 1023 bytes and treats NUL/CR/LF as terminators.
/// NULL secret with size zero creates a READY-only rendezvous; all P requests fail.
/// A non-NULL empty secret and a NULL nonempty secret are invalid.
int ds_credential_create(const char *temporary_root, const char *helper_path,
                         const char *token, const void *secret, size_t secret_size,
                         ds_credential_broker **result);
const char *ds_credential_socket_path(ds_credential_broker *broker);
void ds_credential_retain(ds_credential_broker *broker);
void ds_credential_release(ds_credential_broker *broker);

/// Pins the freshly spawned SSH PID and its birth time before any reply is permitted.
int ds_credential_bind_ssh(ds_credential_broker *broker, pid_t ssh_pid);
/// Runs on a dedicated thread. Returns 0 only after an authenticated LocalCommand READY.
/// Protocol request: ('P' password | 'R' ready), then the 36-byte UUID nonce.
/// Response: UInt32 network-order length, then secret bytes; READY has length zero.
int ds_credential_serve(ds_credential_broker *broker);
/// Called by the serving thread after serve returns; removes its socket and directory.
void ds_credential_retire(ds_credential_broker *broker);
/// Wakes the listener or an incomplete request immediately. Idempotent.
void ds_credential_cancel(ds_credential_broker *broker);
int ds_credential_was_delivered(ds_credential_broker *broker);
int ds_credential_is_ready(ds_credential_broker *broker);

#endif
