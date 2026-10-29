#ifndef DOCKSHELL_PTY_SHIM_H
#define DOCKSHELL_PTY_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/// Creates a raw PTY and starts an executable without a shell in a new session.
/// Returns an errno value. argv and envp must be null-terminated arrays.
int ds_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 uint16_t rows, uint16_t columns, int *master_fd, pid_t *child_pid);
/// Launcher entry: acquires the inherited PTY as controlling tty, then execs.
/// It executes only in a freshly spawned process, never in a post-fork Swift context.
int ds_pty_exec(const char *executable, char *const argv[]);
/// Waits for data, returning byte count, 0 on EOF, or -1 with errno set.
ssize_t ds_pty_read(int fd, void *bytes, size_t capacity, int timeout_ms);
int ds_pty_resize(int fd, uint16_t rows, uint16_t columns);
int ds_pty_write_command(int fd, unsigned char command);
/// Reaps the child, converting signal termination to 128 + signal number.
int ds_pty_wait(pid_t pid, int *exit_status);
/// Terminates a probe child and reaps it; only used for failure cleanup.
void ds_pty_abort(pid_t pid);
/// Local fixture: checks its controlling tty and emits a deterministic 2 MiB byte stream.
int ds_pty_fixture(void);

#endif
