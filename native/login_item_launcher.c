#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    uint32_t size = PATH_MAX;
    char executable[PATH_MAX];
    char resolved[PATH_MAX];
    const char suffix[] =
        "/Contents/Library/LoginItems/McSpeechfaceLoginItem.app"
        "/Contents/MacOS/McSpeechfaceLoginItem";

    if (_NSGetExecutablePath(executable, &size) != 0 || realpath(executable, resolved) == NULL) {
        fputs("could not locate the McSpeechface login helper\n", stderr);
        return 71;
    }

    size_t path_length = strlen(resolved);
    size_t suffix_length = sizeof(suffix) - 1;
    if (path_length <= suffix_length
        || strcmp(resolved + path_length - suffix_length, suffix) != 0) {
        fputs("McSpeechface login helper is outside its expected app bundle\n", stderr);
        return 71;
    }

    resolved[path_length - suffix_length] = '\0';
    if (argc == 2 && strcmp(argv[1], "--print-app-path") == 0) {
        puts(resolved);
        return 0;
    }
    if (argc != 1) {
        fputs("usage: McSpeechfaceLoginItem [--print-app-path]\n", stderr);
        return 64;
    }

    execl("/usr/bin/open", "open", "-g", resolved, (char *)NULL);
    int error = errno;
    perror("could not open McSpeechface");
    return error == ENOENT ? 127 : 71;
}
