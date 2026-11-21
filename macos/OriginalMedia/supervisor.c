// stdin is a lease held by the Flutter process. Closing it (including a crash)
// retires the local engine even when the app cannot run its disposal handlers.
#include <mach-o/dyld.h>
#include <limits.h>
#include <poll.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
extern char **environ;
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
int main(int argc, char **argv) {
    (void)argc;
    char path[PATH_MAX], resolved[PATH_MAX];
    unsigned int length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) || !realpath(path, resolved)) return 1;
    char *last = strrchr(resolved, '/');
    if (!last || sizeof(resolved) - (last - resolved) < sizeof("/TorrServer")) return 1;
    strcpy(last, "/TorrServer");
    argv[0] = resolved;
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    pid_t child;
    int failure = posix_spawn(&child, resolved, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (failure) return 1;
    struct pollfd pipe = {.fd=STDIN_FILENO, .events=POLLIN};
    int status = 0;
    while (!stopping) {
        if (waitpid(child, &status, WNOHANG) == child) return WIFEXITED(status)?WEXITSTATUS(status):1;
        if (poll(&pipe, 1, 500)>0) break;
        if (getppid()==1) break;
    }
    kill(child, SIGTERM);
    for (int i=0; i<30; i++) {
        if (waitpid(child, &status, WNOHANG)==child) return 0;
        usleep(100000);
    }
    kill(child, SIGKILL); waitpid(child,&status,0);
    return 0;
}
