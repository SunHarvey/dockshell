#include "CDockShellPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static void ds_zero(void *buffer, size_t length) {
    volatile unsigned char *position = buffer;
    while (length--) *position++ = 0;
}
#include <util.h>

#define DS_RING_CAPACITY 65536
#define DS_DIAGNOSTIC_CAPACITY 32768

struct ds_ring {
    unsigned char bytes[DS_RING_CAPACITY];
    size_t head, count, high;
};

struct ds_pty_session {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned refs;
    int master, diagnostic, wake_read, wake_write;
    pid_t pid;
    int closing, eof, write_eof, finished, exit_status, failure, reader_active;
    int local_shell;
    struct ds_ring incoming, outgoing;
    unsigned char diagnostics[DS_DIAGNOSTIC_CAPACITY];
    size_t diagnostic_count;
    uint64_t received, consumed, enqueued, sent;
    ds_pty_read_completion read_completion;
    void *read_context;
    ds_pty_operation *read_operation;
    size_t read_capacity;
};

struct ds_pty_operation {
    ds_pty_session *session;
    int canceled; // Protected by session->lock, including before operation begins.
};

static void ring_append(struct ds_ring *ring, const void *source, size_t count) {
    size_t tail = (ring->head + ring->count) % DS_RING_CAPACITY;
    size_t first = count < DS_RING_CAPACITY - tail ? count : DS_RING_CAPACITY - tail;
    memcpy(ring->bytes + tail, source, first);
    if (first < count) memcpy(ring->bytes, (const unsigned char *)source + first, count - first);
    ring->count += count;
    if (ring->count > ring->high) ring->high = ring->count;
}

static void ring_take(struct ds_ring *ring, void *destination, size_t count) {
    size_t first = count < DS_RING_CAPACITY - ring->head ? count : DS_RING_CAPACITY - ring->head;
    memcpy(destination, ring->bytes + ring->head, first);
    if (first < count) memcpy((unsigned char *)destination + first, ring->bytes, count - first);
    ring->head = (ring->head + count) % DS_RING_CAPACITY;
    ring->count -= count;
}

static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return errno;
    return 0;
}

// The pipe is nonblocking: one byte is enough to wake poll; a full pipe already
// guarantees a wakeup. Calls hold session->lock so destruction cannot race.
static void wake_supervisor(ds_pty_session *session) {
    unsigned char byte = 1;
    ssize_t ignored = write(session->wake_write, &byte, 1);
    (void)ignored;
}

// Detach under lock; invoke afterwards. Only the detached owner can finish a
// continuation, including a cancellation racing IO or a session close.
static void complete_pending_read(ds_pty_session *session) {
    unsigned char bytes[DS_RING_CAPACITY];
    ds_pty_read_completion completion = NULL;
    void *context = NULL;
    size_t count = 0;
    int error = 0;
    pthread_mutex_lock(&session->lock);
    if (session->read_completion && (session->read_operation->canceled || session->closing ||
        session->incoming.count || session->eof || session->failure)) {
        error = session->read_operation->canceled || (session->closing && !session->failure) ? ECANCELED :
                !session->incoming.count ? session->failure : 0;
        if (!error) {
            count = session->incoming.count;
            if (count > session->read_capacity) count = session->read_capacity;
            if (count) {
                ring_take(&session->incoming, bytes, count);
                session->consumed += count;
                if (!session->finished) wake_supervisor(session);
            }
        }
        completion = session->read_completion;
        context = session->read_context;
        session->read_completion = NULL;
        session->read_context = NULL;
        session->read_operation = NULL;
        session->reader_active = 0;
    }
    pthread_mutex_unlock(&session->lock);
    if (completion) completion(context, count ? bytes : NULL, count, error);
}

void ds_pty_session_retain(ds_pty_session *session) {
    pthread_mutex_lock(&session->lock);
    ++session->refs;
    pthread_mutex_unlock(&session->lock);
}

void ds_pty_session_release(ds_pty_session *session) {
    int destroy;
    pthread_mutex_lock(&session->lock);
    destroy = --session->refs == 0;
    pthread_mutex_unlock(&session->lock);
    if (destroy) {
        // The supervisor keeps its own reference until all descriptors are closed.
        pthread_cond_destroy(&session->changed);
        pthread_mutex_destroy(&session->lock);
        ds_zero(session, sizeof(*session));
        free(session);
    }
}

void ds_pty_session_close(ds_pty_session *session) {
    pthread_mutex_lock(&session->lock);
    if (!session->finished) {
        session->closing = 1;
        session->incoming.count = 0;
        session->outgoing.count = 0;
        wake_supervisor(session);
        pthread_cond_broadcast(&session->changed);
    }
    pthread_mutex_unlock(&session->lock);
    complete_pending_read(session);
}

static void terminate_local_jobs(ds_pty_session *session) {
    // A job-controlled shell gives top/vim/sleep a different process group. Only
    // signal the group currently owned by this PTY and this unreaped session.
    pid_t foreground = tcgetpgrp(session->master);
    if (tcgetsid(session->master) == session->pid && foreground > 0 &&
        foreground != session->pid && getsid(foreground) == session->pid) {
        kill(-foreground, SIGKILL);
    }
    // Let the shell propagate hangup to its ordinary background jobs before the
    // final bounded kill below. This delay is only in the dedicated teardown
    // worker, never an idle timer or a wait on Swift's cooperative executor.
    kill(-session->pid, SIGHUP);
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000};
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

static void *supervise(void *context) {
    ds_pty_session *session = context;
    int pty_eof = 0, diagnostic_eof = 0;
    unsigned char temporary[16384];
    for (;;) {
        pthread_mutex_lock(&session->lock);
        int closing = session->closing;
        size_t room = DS_RING_CAPACITY - session->incoming.count;
        short pty_events = 0;
        if (!pty_eof && room) pty_events |= POLLIN;
        if (!pty_eof && !session->write_eof && session->outgoing.count) pty_events |= POLLOUT;
        pthread_mutex_unlock(&session->lock);
        if (closing) {
            // The process is our unreaped session leader. Its PID cannot be reused
            // before waitpid below. Kill its group to include an askpass descendant.
            if (session->local_shell) terminate_local_jobs(session);
            if (kill(-session->pid, SIGKILL) < 0) kill(session->pid, SIGKILL);
            break;
        }
        if (pty_eof && diagnostic_eof) break;
        struct pollfd items[3] = {
            {.fd = pty_events ? session->master : -1, .events = pty_events},
            {.fd = diagnostic_eof ? -1 : session->diagnostic, .events = POLLIN},
            {.fd = session->wake_read, .events = POLLIN},
        };
        int ready;
        do { ready = poll(items, 3, -1); } while (ready < 0 && errno == EINTR);
        if (ready < 0) {
            pthread_mutex_lock(&session->lock);
            session->failure = errno;
            session->closing = 1;
            pthread_mutex_unlock(&session->lock);
            continue;
        }
        if ((items[0].revents | items[1].revents | items[2].revents) & POLLNVAL) {
            pthread_mutex_lock(&session->lock);
            session->failure = EBADF;
            session->closing = 1;
            pthread_mutex_unlock(&session->lock);
            continue;
        }
        if (items[2].revents) while (read(session->wake_read, temporary, sizeof(temporary)) > 0) {}
        if (items[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            // Bound each drain pass so a noisy stderr cannot starve PTY IO or cancellation.
            for (int pass = 0; pass < 16; ++pass) {
                ssize_t count = read(session->diagnostic, temporary, sizeof(temporary));
                if (count > 0) {
                    pthread_mutex_lock(&session->lock);
                    // Keep the tail: a later timeout or key error must survive an earlier long banner.
                    size_t total = session->diagnostic_count + (size_t)count;
                    if (total > DS_DIAGNOSTIC_CAPACITY) {
                        size_t discard = total - DS_DIAGNOSTIC_CAPACITY;
                        memmove(session->diagnostics, session->diagnostics + discard,
                                session->diagnostic_count - discard);
                        session->diagnostic_count -= discard;
                    }
                    memcpy(session->diagnostics + session->diagnostic_count, temporary, (size_t)count);
                    session->diagnostic_count += (size_t)count;
                    pthread_mutex_unlock(&session->lock);
                } else if (count == 0) { diagnostic_eof = 1; break; }
                else if (errno == EINTR) continue;
                else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                else { diagnostic_eof = 1; break; }
            }
        }
        // Holding the lock across a nonblocking descriptor call prevents resize
        // or close from racing FD lifetime. No blocking syscall holds this lock.
        pthread_mutex_lock(&session->lock);
        if (!session->closing && items[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            size_t available = DS_RING_CAPACITY - session->incoming.count;
            if (available > sizeof(temporary)) available = sizeof(temporary);
            if (available) {
                ssize_t count = read(session->master, temporary, available);
                if (count > 0) {
                    ring_append(&session->incoming, temporary, (size_t)count);
                    session->received += (uint64_t)count;
                    pthread_cond_broadcast(&session->changed);
                } else if (count == 0 || (count < 0 && errno == EIO)) {
                    pty_eof = 1;
                    session->eof = session->write_eof = 1;
                    session->outgoing.count = 0;
                    pthread_cond_broadcast(&session->changed);
                } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    session->failure = errno;
                    session->closing = 1;
                }
            }
        }
        if (!session->closing && !pty_eof && items[0].revents & POLLOUT && session->outgoing.count) {
            size_t amount = DS_RING_CAPACITY - session->outgoing.head;
            if (amount > session->outgoing.count) amount = session->outgoing.count;
            ssize_t count = write(session->master, session->outgoing.bytes + session->outgoing.head, amount);
            if (count > 0) {
                session->outgoing.head = (session->outgoing.head + (size_t)count) % DS_RING_CAPACITY;
                session->outgoing.count -= (size_t)count;
                session->sent += (uint64_t)count;
                pthread_cond_broadcast(&session->changed);
            } else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                // A dead slave is normal when the remote session exits. Existing
                // received output remains readable before EOF.
                session->outgoing.count = 0;
                session->write_eof = 1;
                pthread_cond_broadcast(&session->changed);
            }
        }
        pthread_mutex_unlock(&session->lock);
        complete_pending_read(session);
    }
    pthread_mutex_lock(&session->lock);
    // Darwin may keep a killed SSH process in slave-tty close/drain until its
    // master is released. Waiting for that process first would deadlock teardown.
    // Invalidate under the resize lock, then close outside it before waitpid.
    int master = session->master, diagnostic = session->diagnostic;
    session->master = session->diagnostic = -1;
    session->eof = session->write_eof = 1;
    session->outgoing.count = 0;
    pthread_cond_broadcast(&session->changed);
    pthread_mutex_unlock(&session->lock);
    if (master >= 0) close(master);
    if (diagnostic >= 0) close(diagnostic);
    complete_pending_read(session);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(session->pid, &status, 0); } while (waited < 0 && errno == EINTR);
    pthread_mutex_lock(&session->lock);
    // Keep wake descriptors alive through reaping: a cancel or read completion
    // may still need them until finished is published under this same lock.
    close(session->wake_read);
    close(session->wake_write);
    session->wake_read = session->wake_write = -1;
    session->exit_status = waited < 0 ? 255 : WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    session->finished = session->eof = 1;
    session->outgoing.count = 0;
    pthread_cond_broadcast(&session->changed);
    pthread_mutex_unlock(&session->lock);
    complete_pending_read(session);
    ds_zero(temporary, sizeof(temporary));
    ds_pty_session_release(session);
    return NULL;
}

static int spawn_session(const char *helper, char *const argv[], char *const envp[],
                         uint16_t rows, uint16_t columns, int local_shell, ds_pty_session **result) {
    if (!helper || !argv || !envp || !result || !rows || !columns) return EINVAL;
    *result = NULL;
    int master = -1, slave = -1, diagnostics[2] = {-1, -1}, wake[2] = {-1, -1};
    int error = 0;
    char slave_name[128] = {0};
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    ds_pty_session *session = calloc(1, sizeof(*session));
    if (!session) return ENOMEM;
    if (openpty(&master, &slave, slave_name, NULL, &size) < 0 ||
        pipe(diagnostics) < 0 || pipe(wake) < 0) { error = errno; goto cleanup; }
    if ((error = nonblocking(master)) || (error = nonblocking(diagnostics[0])) ||
        (error = nonblocking(wake[0])) || (error = nonblocking(wake[1]))) goto cleanup;
    if (fcntl(diagnostics[1], F_SETFD, FD_CLOEXEC) < 0) {
        error = errno; goto cleanup;
    }
    // Leave the fresh slave in its normal cooked mode. OpenSSH snapshots these
    // attributes for the remote PTY request before putting its local tty into raw
    // mode. Pre-setting raw here would disable remote OPOST/ONLCR/ECHO/ICANON and
    // turn ordinary command output into staircase text. Binary fixtures set raw
    // themselves after checking these production defaults.
    struct termios attributes;
    if (tcgetattr(slave, &attributes) < 0) { error = errno; goto cleanup; }
    // OpenSSH forwards IUTF8 to the remote PTY. Enable UTF-8 aware canonical
    // erase without changing any of the normal cooked input/output settings.
    attributes.c_iflag |= IUTF8;
    if (tcsetattr(slave, TCSANOW, &attributes) < 0) { error = errno; goto cleanup; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t spawn_attributes;
    if ((error = posix_spawn_file_actions_init(&actions))) goto cleanup;
    if ((error = posix_spawnattr_init(&spawn_attributes))) {
        posix_spawn_file_actions_destroy(&actions); goto cleanup;
    }
    sigset_t empty_mask, default_signals;
    sigemptyset(&empty_mask);
    sigemptyset(&default_signals);
    const int signals[] = {SIGWINCH, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) sigaddset(&default_signals, signals[i]);
    if (local_shell) {
        sigaddset(&default_signals, SIGHUP);
        sigaddset(&default_signals, SIGCHLD);
    }
    error = posix_spawnattr_setflags(&spawn_attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                    POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (!error) error = posix_spawnattr_setsigmask(&spawn_attributes, &empty_mask);
    if (!error) error = posix_spawnattr_setsigdefault(&spawn_attributes, &default_signals);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slave_name, O_RDWR, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, diagnostics[1], STDERR_FILENO);
    if (!error) error = posix_spawn(&session->pid, helper, &actions, &spawn_attributes, argv, envp);
    posix_spawnattr_destroy(&spawn_attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (error) goto cleanup;
    close(slave); slave = -1;
    close(diagnostics[1]); diagnostics[1] = -1;
    error = pthread_mutex_init(&session->lock, NULL);
    if (error) {
        if (kill(-session->pid, SIGKILL) < 0) kill(session->pid, SIGKILL);
        while (waitpid(session->pid, NULL, 0) < 0 && errno == EINTR) {}
        goto cleanup;
    }
    error = pthread_cond_init(&session->changed, NULL);
    if (error) {
        if (kill(-session->pid, SIGKILL) < 0) kill(session->pid, SIGKILL);
        while (waitpid(session->pid, NULL, 0) < 0 && errno == EINTR) {}
        pthread_mutex_destroy(&session->lock);
        goto cleanup;
    }
    session->refs = 2; // The caller and the detached supervisor.
    session->local_shell = local_shell;
    session->master = master; session->diagnostic = diagnostics[0];
    session->wake_read = wake[0]; session->wake_write = wake[1];
    pthread_t thread;
    error = pthread_create(&thread, NULL, supervise, session);
    if (error) {
        if (kill(-session->pid, SIGKILL) < 0) kill(session->pid, SIGKILL);
        while (waitpid(session->pid, NULL, 0) < 0 && errno == EINTR) {}
        pthread_cond_destroy(&session->changed);
        pthread_mutex_destroy(&session->lock);
        goto cleanup;
    }
    pthread_detach(thread);
    *result = session;
    return 0;
cleanup:
    if (master >= 0) close(master);
    if (slave >= 0) close(slave);
    if (diagnostics[0] >= 0) close(diagnostics[0]);
    if (diagnostics[1] >= 0) close(diagnostics[1]);
    if (wake[0] >= 0) close(wake[0]);
    if (wake[1] >= 0) close(wake[1]);
    free(session);
    return error;
}

int ds_pty_session_spawn(const char *helper, char *const argv[], char *const envp[],
                         uint16_t rows, uint16_t columns, ds_pty_session **result) {
    return spawn_session(helper, argv, envp, rows, columns, 0, result);
}

int ds_pty_session_spawn_local(const char *helper, char *const argv[], char *const envp[],
                              uint16_t rows, uint16_t columns, ds_pty_session **result) {
    return spawn_session(helper, argv, envp, rows, columns, 1, result);
}

pid_t ds_pty_session_pid(ds_pty_session *session) { return session->pid; }

ds_pty_operation *ds_pty_operation_create(ds_pty_session *session) {
    ds_pty_operation *operation = calloc(1, sizeof(*operation));
    if (!operation) return NULL;
    ds_pty_session_retain(session);
    operation->session = session;
    return operation;
}

void ds_pty_operation_cancel(ds_pty_operation *operation) {
    ds_pty_session *session = operation->session;
    pthread_mutex_lock(&session->lock);
    operation->canceled = 1;
    pthread_cond_broadcast(&session->changed);
    pthread_mutex_unlock(&session->lock);
    complete_pending_read(session);
}

void ds_pty_operation_destroy(ds_pty_operation *operation) {
    ds_pty_session_release(operation->session);
    free(operation);
}

int ds_pty_session_read_async(ds_pty_operation *operation, size_t capacity,
                             ds_pty_read_completion completion, void *context) {
    if (!capacity || !completion) return EINVAL;
    ds_pty_session *session = operation->session;
    pthread_mutex_lock(&session->lock);
    if (session->reader_active) { pthread_mutex_unlock(&session->lock); return EBUSY; }
    session->reader_active = 1;
    session->read_operation = operation;
    session->read_capacity = capacity > DS_RING_CAPACITY ? DS_RING_CAPACITY : capacity;
    session->read_context = context;
    session->read_completion = completion;
    if (!session->finished) wake_supervisor(session);
    pthread_mutex_unlock(&session->lock);
    complete_pending_read(session);
    return 0;
}

ssize_t ds_pty_session_read(ds_pty_operation *operation, void *buffer, size_t capacity) {
    ds_pty_session *session = operation->session;
    if (!capacity || !buffer) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&session->lock);
    if (session->reader_active) { pthread_mutex_unlock(&session->lock); errno = EBUSY; return -1; }
    session->reader_active = 1;
    while (!operation->canceled && !session->closing && !session->incoming.count && !session->eof)
        pthread_cond_wait(&session->changed, &session->lock);
    int error = operation->canceled ? ECANCELED : session->closing ? ECANCELED : session->failure;
    size_t count = error ? 0 : session->incoming.count;
    if (count > capacity) count = capacity;
    if (count) {
        ring_take(&session->incoming, buffer, count);
        session->consumed += count;
        if (!session->finished) wake_supervisor(session);
    }
    session->reader_active = 0;
    pthread_mutex_unlock(&session->lock);
    if (error) { errno = error; return -1; }
    return (ssize_t)count;
}

int ds_pty_session_write(ds_pty_operation *operation, const void *buffer, size_t count) {
    ds_pty_session *session = operation->session;
    const unsigned char *position = buffer;
    pthread_mutex_lock(&session->lock);
    while (count) {
        while (!operation->canceled && !session->closing && !session->write_eof && !session->eof &&
               session->outgoing.count == DS_RING_CAPACITY)
            pthread_cond_wait(&session->changed, &session->lock);
        int error = operation->canceled ? ECANCELED : session->closing || session->eof || session->write_eof ? EPIPE : session->failure;
        if (error) { pthread_mutex_unlock(&session->lock); errno = error; return -1; }
        size_t amount = DS_RING_CAPACITY - session->outgoing.count;
        if (amount > count) amount = count;
        ring_append(&session->outgoing, position, amount);
        position += amount; count -= amount;
        session->enqueued += amount;
        wake_supervisor(session);
    }
    pthread_mutex_unlock(&session->lock);
    return 0;
}

int ds_pty_session_resize(ds_pty_session *session, uint16_t rows, uint16_t columns) {
    if (!rows || !columns) return EINVAL;
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    pthread_mutex_lock(&session->lock);
    int result = session->closing || session->finished || session->master < 0 ? EPIPE :
                 ioctl(session->master, TIOCSWINSZ, &size) < 0 ? errno : 0;
    pthread_mutex_unlock(&session->lock);
    return result;
}

int ds_pty_session_wait(ds_pty_operation *operation, int *exit_status) {
    ds_pty_session *session = operation->session;
    pthread_mutex_lock(&session->lock);
    while (!operation->canceled && !session->finished) pthread_cond_wait(&session->changed, &session->lock);
    int error = operation->canceled ? ECANCELED : 0;
    if (!error) *exit_status = session->exit_status;
    pthread_mutex_unlock(&session->lock);
    return error;
}

size_t ds_pty_session_diagnostics(ds_pty_session *session, void *buffer, size_t capacity) {
    pthread_mutex_lock(&session->lock);
    size_t amount = session->diagnostic_count < capacity ? session->diagnostic_count : capacity;
    if (amount) memcpy(buffer, session->diagnostics, amount);
    pthread_mutex_unlock(&session->lock);
    return amount;
}

void ds_pty_session_statistics(ds_pty_session *session, ds_pty_statistics *result) {
    pthread_mutex_lock(&session->lock);
    *result = (ds_pty_statistics){session->incoming.count, session->outgoing.count,
        session->incoming.high, session->outgoing.high, session->received, session->consumed,
        session->enqueued, session->sent, session->finished};
    pthread_mutex_unlock(&session->lock);
}

int ds_pty_exec_system_ssh(char *const ssh_arguments[]) {
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0 || tcsetpgrp(STDIN_FILENO, getpgrp()) < 0) return errno;
    extern char **environ;
    execve("/usr/bin/ssh", ssh_arguments, environ);
    return errno;
}
