#include "PTYShim.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int ds_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 uint16_t rows, uint16_t columns, int *master_fd, pid_t *child_pid) {
    int master = -1, slave = -1, error = 0;
    char slave_name[128] = {0};
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    struct termios attributes;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t spawn_attributes;
    if (openpty(&master, &slave, slave_name, NULL, &size) < 0) return errno;
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 || tcgetattr(slave, &attributes) < 0) {
        error = errno; goto close_pty;
    }
    cfmakeraw(&attributes);
    if (tcsetattr(slave, TCSANOW, &attributes) < 0) { error = errno; goto close_pty; }
    if ((error = posix_spawn_file_actions_init(&actions))) goto close_pty;
    if ((error = posix_spawnattr_init(&spawn_attributes))) goto destroy_actions;
    // Darwin applies SETSID after file actions. The fresh executable must still
    // acquire the inherited slave using TIOCSCTTY before it execs the target.
    sigset_t empty_mask, default_signals;
    sigemptyset(&empty_mask);
    sigemptyset(&default_signals);
    sigaddset(&default_signals, SIGWINCH);
    sigaddset(&default_signals, SIGINT);
    sigaddset(&default_signals, SIGQUIT);
    sigaddset(&default_signals, SIGTERM);
    sigaddset(&default_signals, SIGTSTP);
    sigaddset(&default_signals, SIGTTIN);
    sigaddset(&default_signals, SIGTTOU);
    error = posix_spawnattr_setflags(&spawn_attributes,
                                     POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                     POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (!error) error = posix_spawnattr_setsigmask(&spawn_attributes, &empty_mask);
    if (!error) error = posix_spawnattr_setsigdefault(&spawn_attributes, &default_signals);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO,
                                                        slave_name, O_RDWR, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO);
    if (!error) error = posix_spawn(child_pid, executable, &actions, &spawn_attributes, argv, envp);
    posix_spawnattr_destroy(&spawn_attributes);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
close_pty:
    close(slave);
    if (error) close(master);
    else *master_fd = master;
    return error;
}

int ds_pty_exec(const char *executable, char *const argv[]) {
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0) return errno;
    if (tcsetpgrp(STDIN_FILENO, getpgrp()) < 0) return errno;
    extern char **environ;
    execve(executable, argv, environ);
    return errno;
}

ssize_t ds_pty_read(int fd, void *bytes, size_t capacity, int timeout_ms) {
    struct pollfd item = {.fd = fd, .events = POLLIN};
    int ready;
    do { ready = poll(&item, 1, timeout_ms); } while (ready < 0 && errno == EINTR);
    if (ready == 0) { errno = ETIMEDOUT; return -1; }
    if (ready < 0) return -1;
    ssize_t count;
    do { count = read(fd, bytes, capacity); } while (count < 0 && errno == EINTR);
    // BSD PTYs can report EIO when their final slave descriptor closes.
    if (count < 0 && errno == EIO) return 0;
    return count;
}

int ds_pty_resize(int fd, uint16_t rows, uint16_t columns) {
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(fd, TIOCSWINSZ, &size) < 0 ? errno : 0;
}

int ds_pty_write_command(int fd, unsigned char command) {
    ssize_t written;
    do { written = write(fd, &command, 1); } while (written < 0 && errno == EINTR);
    return written == 1 ? 0 : errno;
}

int ds_pty_wait(pid_t pid, int *exit_status) {
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 0;
}

void ds_pty_abort(pid_t pid) {
    if (pid <= 0) return;
    // The fixture is a new session; terminate only that probe process.
    kill(pid, SIGKILL);
    int ignored;
    ds_pty_wait(pid, &ignored);
}

static volatile sig_atomic_t saw_resize = 0;
static void resized(int signal_number) { (void)signal_number; saw_resize = 1; }

static int write_all(int fd, const void *buffer, size_t size) {
    const unsigned char *position = buffer;
    while (size > 0) {
        ssize_t count = write(fd, position, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        position += count;
        size -= (size_t)count;
    }
    return 0;
}

int ds_pty_fixture(void) {
    struct sigaction action = {.sa_handler = resized};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGWINCH, &action, NULL) < 0) return 10;
    int controlling = open("/dev/tty", O_RDWR | O_NOCTTY);
    int controlling_open_error = controlling < 0 ? errno : 0;
    struct winsize size;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) return 11;
    if (dprintf(STDOUT_FILENO, "READY rows=%u cols=%u ctty=%d leader=%d devtty_errno=%d\n",
                size.ws_row, size.ws_col, tcgetsid(STDIN_FILENO) == getsid(0),
                getsid(0) == getpid(), controlling_open_error) < 0) return 12;
    if (controlling >= 0) close(controlling);
    for (;;) {
        unsigned char command;
        ssize_t count = read(STDIN_FILENO, &command, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 13;
        if (command == 's') {
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) return 14;
            if (dprintf(STDOUT_FILENO, "SIZE rows=%u cols=%u winch=%d\n",
                        size.ws_row, size.ws_col, saw_resize != 0) < 0) return 15;
        } else if (command == 't') {
            unsigned char bytes[4096];
            for (size_t i = 0; i < sizeof(bytes); ++i) bytes[i] = (unsigned char)i;
            for (int block = 0; block < 512; ++block)
                if (write_all(STDOUT_FILENO, bytes, sizeof(bytes)) < 0) return 16;
        } else if (command == 'q') {
            return 0;
        } else {
            return 17;
        }
    }
}
