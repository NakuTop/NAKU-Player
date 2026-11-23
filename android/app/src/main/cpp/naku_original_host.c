#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

// Android extracts both signed executables to the read-only nativeLibraryDir.
// Flutter owns the stdin lease. A closed pipe also signals an application crash.
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }

int main(int argc, char **argv) {
    (void)argc;
    char path[PATH_MAX];
    ssize_t size = readlink("/proc/self/exe", path, sizeof(path)-1);
    if (size < 1 || size >= (ssize_t)sizeof(path)-1) return 1;
    path[size] = 0;
    char *end = strrchr(path, '/');
    const char engine[] = "/libnaku_torrserver.so";
    if (!end || sizeof(path)-(size_t)(end-path) < sizeof(engine)) return 1;
    memcpy(end, engine, sizeof(engine));
    pid_t host = getpid(), child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != host) _exit(1);
        int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, STDIN_FILENO) < 0) _exit(1);
        if (input != STDIN_FILENO) close(input);
        argv[0] = path;
        execv(path, argv);
        _exit(127);
    }
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop);
    struct pollfd lease = {.fd=STDIN_FILENO, .events=POLLIN};
    int status = 0;
    while (!stopping) {
        if (waitpid(child, &status, WNOHANG) == child)
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (poll(&lease, 1, 300) > 0 || getppid() == 1) break;
    }
    kill(child, SIGTERM);
    for (int i = 0; i < 20; ++i) {
        if (waitpid(child, &status, WNOHANG) == child) return 0;
        usleep(100000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    return 0;
}
