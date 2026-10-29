#include "CDockShellPTY.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static void ds_zero(void *buffer, size_t length) {
    volatile unsigned char *position = buffer;
    while (length--) *position++ = 0;
}

// The helper itself never prints prompts, errors, arguments or credentials.
// Askpass writes only to ssh's private pipe and its route never launches a shell.
// Only the explicitly selected local-terminal modes may replace the helper with
// an interactive shell, after rejecting an SSH askpass credential context.
static int64_t monotonic_ms(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int wait_for(int fd, short events, int64_t deadline) {
    struct pollfd item = {.fd = fd, .events = events};
    int result;
    do {
        int64_t remaining = deadline - monotonic_ms();
        if (remaining <= 0) return -1;
        result = poll(&item, 1, (int)remaining);
    } while (result < 0 && errno == EINTR);
    return result > 0 && item.revents & events ? 0 : -1;
}

static int transfer(int fd, void *buffer, size_t length, int writing, int timed) {
    unsigned char *position = buffer;
    int64_t deadline = timed ? monotonic_ms() + 5000 : 0;
    while (length) {
        if (timed && wait_for(fd, writing ? POLLOUT : POLLIN, deadline) < 0) return -1;
        ssize_t count = writing ? write(fd, position, length) : read(fd, position, length);
        if (count < 0 && errno == EINTR) continue;
        if (timed && count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return -1;
        position += count;
        length -= (size_t)count;
    }
    return 0;
}

static int credential_request(unsigned char kind) {
    const char *path = getenv("DOCKSHELL_ASKPASS_SOCKET");
    const char *token = getenv("DOCKSHELL_ASKPASS_TOKEN");
    const char *prompt_kind = getenv("SSH_ASKPASS_PROMPT");
    if (kind == 'P' && prompt_kind && *prompt_kind) return 1;
    if (!path || !token || strlen(token) != 36) return 1;
    for (size_t i = 0; i < 36; ++i) {
        int hyphen = i == 8 || i == 13 || i == 18 || i == 23;
        char ch = token[i];
        if (hyphen ? ch != '-' : !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') ||
                                    (ch >= 'A' && ch <= 'F'))) return 1;
    }
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof(address.sun_path)) return 1;
    memcpy(address.sun_path, path, strlen(path) + 1);
    address.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 1;
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0 ||
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) { close(fd); return 1; }
    // Bound even a full local listener backlog. This SSH/askpass route never
    // connects to a remotely supplied address or invokes a shell.
    if (connect(fd, (struct sockaddr *)&address, address.sun_len) < 0) {
        if (errno != EINPROGRESS || wait_for(fd, POLLOUT, monotonic_ms() + 5000) < 0) {
            close(fd); return 1;
        }
        int connection_error = 0;
        socklen_t error_length = sizeof(connection_error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &connection_error, &error_length) < 0 || connection_error) {
            close(fd); return 1;
        }
    }
    unsigned char request[37];
    request[0] = kind;
    memcpy(request + 1, token, 36);
    uint32_t wire_length = 0;
    if (transfer(fd, request, sizeof(request), 1, 1) < 0 ||
        transfer(fd, &wire_length, sizeof(wire_length), 0, 1) < 0) { close(fd); return 1; }
    uint32_t length = ntohl(wire_length);
    if (kind == 'R') { close(fd); return length == 0 ? 0 : 1; }
    // OpenSSH's readpass.c has a 1024-byte buffer and strips CR/LF/NUL. The broker
    // validates the same limit, so no supplied password can be silently truncated.
    if (length == 0 || length > 1023) { close(fd); return 1; }
    unsigned char password[1024] = {0};
    int result = transfer(fd, password, length, 0, 1);
    close(fd);
    if (result == 0 && (memchr(password, 0, length) || memchr(password, '\r', length) ||
                        memchr(password, '\n', length))) result = -1;
    if (result == 0) result = transfer(STDOUT_FILENO, password, length, 1, 0);
    if (result == 0) {
        unsigned char newline = '\n';
        result = transfer(STDOUT_FILENO, &newline, 1, 1, 0);
    }
    ds_zero(password, sizeof(password));
    return result == 0 ? 0 : 1;
}

// A deterministic local fixture, used only by dockshell-verify. It never executes
// user commands, reads private keys, contacts a host or receives real credentials.
static volatile sig_atomic_t resized = 0;
static void saw_resize(int signal_number) { (void)signal_number; resized = 1; }

static int verification_fixture(void) {
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0 || tcsetpgrp(STDIN_FILENO, getpgrp()) < 0) return 10;
    struct termios attributes;
    if (tcgetattr(STDIN_FILENO, &attributes) < 0) return 24;
    tcflag_t local = ECHO | ICANON | ISIG;
    tcflag_t output = OPOST | ONLCR;
    int initially_cooked = (attributes.c_lflag & local) == local &&
                           (attributes.c_oflag & output) == output;
    int initially_utf8 = (attributes.c_iflag & IUTF8) != 0;
    cfmakeraw(&attributes);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &attributes) < 0) return 25;
    struct sigaction action = {.sa_handler = saw_resize};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGWINCH, &action, NULL) < 0) return 11;
    struct winsize size;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) return 12;
    if (dprintf(STDOUT_FILENO, "READY %u %u %d %d %d\n", size.ws_row, size.ws_col,
                tcgetsid(STDIN_FILENO) == getsid(0) && getsid(0) == getpid(),
                initially_cooked, initially_utf8) < 0) return 13;
    for (;;) {
        unsigned char command;
        if (transfer(STDIN_FILENO, &command, 1, 0, 0) < 0) return 14;
        if (command == 'q') return 0;
        if (command == 's') {
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) return 15;
            if (dprintf(STDOUT_FILENO, "SIZE %u %u %d\n", size.ws_row, size.ws_col, resized != 0) < 0) return 16;
        } else if (command == 'b') {
            unsigned char bytes[4096];
            for (size_t i = 0; i < sizeof(bytes); ++i) bytes[i] = (unsigned char)i;
            for (int block = 0; block < 1024; ++block)
                if (transfer(STDOUT_FILENO, bytes, sizeof(bytes), 1, 0) < 0) return 17;
        } else if (command == 'e') {
            uint32_t wire_count;
            if (transfer(STDIN_FILENO, &wire_count, sizeof(wire_count), 0, 0) < 0) return 18;
            size_t remaining = ntohl(wire_count);
            if (remaining > 16 * 1024 * 1024) return 19;
            unsigned char bytes[4096];
            while (remaining) {
                size_t amount = remaining < sizeof(bytes) ? remaining : sizeof(bytes);
                if (transfer(STDIN_FILENO, bytes, amount, 0, 0) < 0 ||
                    transfer(STDOUT_FILENO, bytes, amount, 1, 0) < 0) return 20;
                remaining -= amount;
            }
        } else if (command == 'p') {
            for (;;) pause();
        } else if (command == 'd') {
            unsigned char bytes[1000]; memset(bytes, 'D', sizeof(bytes));
            for (int i = 0; i < 40; ++i)
                if (transfer(STDERR_FILENO, bytes, sizeof(bytes), 1, 0) < 0) return 21;
            const char tail[] = "\nM5-final-diagnostic\n";
            if (transfer(STDERR_FILENO, (void *)tail, sizeof(tail) - 1, 1, 0) < 0) return 21;
            if (transfer(STDOUT_FILENO, "DONE\n", 5, 1, 0) < 0) return 22;
        } else return 23;
    }
}

static int prepare_local_terminal(void) {
    // OpenSSH controls the prompt argument. Reject its credential context before
    // interpreting a prompt such as "--local-shell" as a local-terminal mode.
    const char *askpass_context[] = {"DOCKSHELL_ASKPASS_SOCKET", "DOCKSHELL_ASKPASS_TOKEN",
        "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "SSH_ASKPASS_PROMPT"};
    for (size_t i = 0; i < sizeof(askpass_context) / sizeof(askpass_context[0]); ++i) {
        if (getenv(askpass_context[i]) != NULL) return -1;
    }
    if (getsid(0) != getpid() ||
        ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0 ||
        tcsetpgrp(STDIN_FILENO, getpgrp()) < 0 ||
        dup2(STDIN_FILENO, STDERR_FILENO) < 0) return -1;
    // Defense in depth: a local shell never receives this app's SSH broker route.
    const char *keys[] = {"DOCKSHELL_ASKPASS_SOCKET", "DOCKSHELL_ASKPASS_TOKEN",
        "DOCKSHELL_AGENT_SOCKET", "DOCKSHELL_IDENTITY_FILE", "DOCKSHELL_KNOWN_HOSTS",
        "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "SSH_ASKPASS_PROMPT"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) unsetenv(keys[i]);
    return setenv("TERM", "xterm-256color", 1) || setenv("COLORTERM", "truecolor", 1) ? -1 : 0;
}

static int local_shell(void) {
    if (prepare_local_terminal() < 0) return 126;
    long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t capacity = suggested > 0 && suggested <= 1024 * 1024 ? (size_t)suggested : 4096;
    char *buffer = NULL;
    struct passwd account, *found = NULL;
    int error = 0;
    for (;;) {
        buffer = malloc(capacity);
        if (!buffer) return 126;
        error = getpwuid_r(getuid(), &account, buffer, capacity, &found);
        if (error != ERANGE) break;
        free(buffer); buffer = NULL;
        if (capacity >= 1024 * 1024) return 126;
        capacity *= 2;
    }
    if (error || !found || !account.pw_dir || account.pw_dir[0] != '/' ||
        !account.pw_name || !*account.pw_name) { free(buffer); return 126; }
    const char *shell = account.pw_shell && *account.pw_shell ? account.pw_shell : "/bin/sh";
    const char *name = strrchr(shell, '/');
    if (shell[0] != '/' || !name || !name[1] || chdir(account.pw_dir) < 0 ||
        setenv("HOME", account.pw_dir, 1) || setenv("PWD", account.pw_dir, 1) ||
        setenv("USER", account.pw_name, 1) || setenv("LOGNAME", account.pw_name, 1) ||
        setenv("SHELL", shell, 1)) { free(buffer); return 126; }
    ++name;
    size_t length = strlen(name);
    char *login_name = malloc(length + 2);
    if (!login_name) { free(buffer); return 126; }
    login_name[0] = '-';
    memcpy(login_name + 1, name, length + 1);
    // Leading '-' is the traditional login-shell convention. -i also handles
    // shells whose interactive detection differs when launched by a GUI app.
    char *arguments[] = {login_name, "-i", NULL};
    extern char **environ;
    execve(shell, arguments, environ);
    free(login_name); free(buffer);
    return 126;
}

static int local_shell_verification(const char *directory) {
    struct stat information;
    // A fixed shell in an owned temporary directory. Never accept a command
    // string or source the real user's HOME/ZDOTDIR startup configuration.
    if (!directory || directory[0] != '/' || lstat(directory, &information) < 0 ||
        !S_ISDIR(information.st_mode) || information.st_uid != getuid() ||
        (information.st_mode & 0022) != 0 || prepare_local_terminal() < 0 ||
        chdir(directory) < 0) return 126;
    unsetenv("BASH_ENV"); unsetenv("ENV"); unsetenv("ZDOTDIR");
    if (setenv("HOME", directory, 1) || setenv("PWD", directory, 1) ||
        setenv("ZDOTDIR", directory, 1) || setenv("USER", "dockshell-verification", 1) ||
        setenv("LOGNAME", "dockshell-verification", 1) || setenv("SHELL", "/bin/zsh", 1) ||
        setenv("LANG", "en_US.UTF-8", 1) || setenv("LC_CTYPE", "UTF-8", 1)) return 126;
    char *arguments[] = {"zsh", "-f", "-i", NULL};
    extern char **environ;
    execve("/bin/zsh", arguments, environ);
    return 126;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--local-shell") == 0) return local_shell();
    if (argc == 3 && strcmp(argv[1], "--verify-local-shell") == 0) return local_shell_verification(argv[2]);
    if (argc >= 2 && strcmp(argv[1], "--launch") == 0) {
        argv[1] = "/usr/bin/ssh";
        return ds_pty_exec_system_ssh(argv + 1) ? 126 : 0;
    }
    if (argc == 2 && strcmp(argv[1], "--ready") == 0) return credential_request('R');
    if (argc == 2 && strcmp(argv[1], "--verify-pty") == 0) return verification_fixture();
    // OpenSSH supplies the prompt as argv[1]. Its contents are deliberately unused.
    return credential_request('P');
}
