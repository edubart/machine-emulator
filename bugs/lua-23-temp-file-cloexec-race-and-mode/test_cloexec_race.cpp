// Proves cartesi.filesystem.new_temporary_file (os::create_temporary_file) is not atomically
// close-on-exec: mkstemp() returns an inheritable fd and FD_CLOEXEC is set later with fcntl(),
// so a fork+exec in another thread of the same process can inherit the temporary file's fd.
// Thread A: a Lua state repeatedly creating/closing temporary files through cartesi.filesystem.
// Thread B: repeatedly fork+exec's a probe that checks whether it inherited such a file.
#include <lua.hpp>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <chrono>
#include <sys/wait.h>
#include <unistd.h>

static std::atomic<bool> stop{false};

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    std::thread creator([&] {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        std::string code = "local fs = require('cartesi.filesystem'); local dir = ...;"
                           "return function() for i = 1, 200 do local t <close> = fs.new_temporary_file(dir, 'cloexecprobe.') end end";
        if (luaL_loadstring(L, code.c_str()) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); std::exit(2); }
        lua_pushstring(L, dir);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); std::exit(2); }
        while (!stop.load()) {
            lua_pushvalue(L, -1);
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); std::exit(2); }
        }
        lua_close(L);
    });
    int leaks = 0, probes = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline && leaks == 0) {
        pid_t pid = fork();
        if (pid == 0) {
            // exit status 0 if the exec'd shell holds an fd on a cloexecprobe file
            execl("/bin/sh", "sh", "-c", "ls -l /proc/$$/fd 2>/dev/null | grep -q cloexecprobe", (char *) nullptr);
            _exit(127);
        }
        int st = 0;
        waitpid(pid, &st, 0);
        ++probes;
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0) ++leaks;
    }
    stop = true;
    creator.join();
    printf("probes=%d leaks=%d\n", probes, leaks);
    if (leaks > 0) {
        printf("BUG: an exec'd child process inherited a file descriptor of a temporary file created by "
               "cartesi.filesystem.new_temporary_file (mkstemp without O_CLOEXEC, FD_CLOEXEC set later by fcntl)\n");
        return 1;
    }
    printf("OK: no inherited temporary file descriptor observed\n");
    return 0;
}
