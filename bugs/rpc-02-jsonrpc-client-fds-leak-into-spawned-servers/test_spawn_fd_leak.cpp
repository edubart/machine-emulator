// Proof: client fds (keep-alive sockets, other threads' spawn acceptors) leak into spawned servers.
#include <cm.h>
#include <cm-jsonrpc.h>
#include <arpa/inet.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <netinet/in.h>
#include <set>
#include <signal.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

static std::set<std::string> socket_inodes(const std::string &pid) {
    std::set<std::string> s;
    std::string dir = "/proc/" + pid + "/fd";
    DIR *d = opendir(dir.c_str());
    if (!d) return s;
    while (auto *e = readdir(d)) {
        char buf[256];
        ssize_t n = readlink((dir + "/" + e->d_name).c_str(), buf, sizeof(buf) - 1);
        if (n <= 0) continue;
        buf[n] = 0;
        if (strncmp(buf, "socket:[", 8) == 0) s.insert(buf);
    }
    closedir(d);
    return s;
}

// state of a TCP socket inode from /proc/net/tcp (hex state), "" if not found
static std::string tcp_state(const std::string &sockname) {
    std::string inode = sockname.substr(8, sockname.size() - 9);
    std::ifstream f("/proc/net/tcp");
    std::string line;
    std::getline(f, line);
    while (std::getline(f, line)) {
        char la[64], ra[64], st[8];
        unsigned long ino = 0;
        int n = sscanf(line.c_str(), "%*d: %63s %63s %7s %*s %*s %*s %*s %*s %lu", la, ra, st, &ino);
        if (n == 4 && std::to_string(ino) == inode) return std::string(st) + " local=" + la + " remote=" + ra;
    }
    return "";
}

// pids holding a LISTEN socket on the given port
static std::string listen_holders(int port) {
    char hexp[8];
    snprintf(hexp, sizeof(hexp), "%04X", port);
    std::set<std::string> inodes;
    std::ifstream f("/proc/net/tcp");
    std::string line;
    std::getline(f, line);
    while (std::getline(f, line)) {
        char la[64], ra[64], st[8];
        unsigned long ino = 0;
        if (sscanf(line.c_str(), "%*d: %63s %63s %7s %*s %*s %*s %*s %*s %lu", la, ra, st, &ino) == 4 &&
            strcmp(st, "0A") == 0 && strstr(la, (std::string(":") + hexp).c_str()))
            inodes.insert("socket:[" + std::to_string(ino) + "]");
    }
    std::string out;
    DIR *d = opendir("/proc");
    while (auto *e = readdir(d)) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        for (auto &s : socket_inodes(e->d_name))
            if (inodes.count(s)) {
                std::ifstream c(std::string("/proc/") + e->d_name + "/comm");
                std::string comm;
                std::getline(c, comm);
                out += std::string(" pid=") + e->d_name + "(" + comm + ")";
            }
    }
    closedir(d);
    return out.empty() ? " none" : out;
}

static int free_port() {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(s, (sockaddr *) &a, sizeof(a));
    socklen_t l = sizeof(a);
    getsockname(s, (sockaddr *) &a, &l);
    int p = ntohs(a.sin_port);
    close(s);
    return p;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    int bugs = 0;
    std::string self = std::to_string(getpid());
    const auto inherited_at_start = socket_inodes(self); // ignore sockets inherited from our own parent

    // ---------- Part A: single-thread, keep-alive socket to server 1 leaks into server 2 ----------
    {
        cm_machine *m1 = nullptr, *m2 = nullptr;
        const char *addr = nullptr;
        uint32_t pid1 = 0, pid2 = 0;
        if (cm_jsonrpc_spawn_server("127.0.0.1:0", 10000, &m1, &addr, &pid1) != 0) {
            printf("spawn m1 failed: %s\n", cm_get_last_error_message());
            return 2;
        }
        const char *ver = nullptr;
        cm_jsonrpc_get_server_version(m1, &ver); // opens keep-alive connection to m1
        auto before = socket_inodes(self);
        for (auto &s : inherited_at_start) before.erase(s);
        if (cm_jsonrpc_spawn_server("127.0.0.1:0", 10000, &m2, &addr, &pid2) != 0) {
            printf("spawn m2 failed: %s\n", cm_get_last_error_message());
            return 2;
        }
        auto in2 = socket_inodes(std::to_string(pid2));
        std::vector<std::string> leaked;
        for (auto &s : before)
            if (in2.count(s)) leaked.push_back(s);
        printf("[A] client sockets before spawning m2: %zu, of which held by server2 (pid %u): %zu\n", before.size(),
            pid2, leaked.size());
        for (auto &s : leaked) printf("    leaked %s  tcp: %s\n", s.c_str(), tcp_state(s).c_str());
        // Now delete m1 (client closes its socket with linger 0, server1 shuts down)
        cm_delete(m1);
        usleep(300000);
        int still = 0;
        for (auto &s : leaked) {
            auto in2b = socket_inodes(std::to_string(pid2));
            if (in2b.count(s)) {
                ++still;
                printf("    after cm_delete(m1): server2 still holds %s  tcp: %s\n", s.c_str(), tcp_state(s).c_str());
            }
        }
        if (!leaked.empty()) {
            printf("BUG: spawned server2 inherited %zu client socket(s) (keep-alive connection to server1); %d still "
                   "held after server1 was deleted\n",
                leaked.size(), still);
            ++bugs;
        }
        cm_delete(m2);
    }

    // ---------- Part B: concurrent spawns on fixed addresses -> EADDRINUSE ----------
    {
        const int threads = 4, rounds = 8;
        std::atomic<int> fails{0}, eaddr{0}, total{0};
        std::vector<std::thread> ts;
        std::vector<int> ports;
        for (int i = 0; i < threads; ++i) ports.push_back(23461 + i); // outside ephemeral range
        for (int t = 0; t < threads; ++t) {
            ts.emplace_back([&, t] {
                std::string a = "127.0.0.1:" + std::to_string(ports[t]);
                for (int r = 0; r < rounds; ++r) {
                    cm_machine *m = nullptr;
                    const char *bound = nullptr;
                    uint32_t pid = 0;
                    ++total;
                    if (cm_jsonrpc_spawn_server(a.c_str(), 10000, &m, &bound, &pid) != 0) {
                        std::string msg = cm_get_last_error_message();
                        ++fails;
                        if (msg.find("already in use") != std::string::npos) ++eaddr;
                        if (fails <= 3) printf("    [B] thread %d round %d spawn on %s failed: %s\n        LISTEN holders of port %d now:%s\n", t, r, a.c_str(),
                            msg.substr(0, 40).c_str(), ports[t], listen_holders(ports[t]).c_str());
                        continue;
                    }
                    cm_delete(m); // shuts the server down
                }
            });
        }
        for (auto &t : ts) t.join();
        printf("[B] concurrent spawns: %d/%d failed (%d with 'Address already in use')\n", fails.load(), total.load(),
            eaddr.load());
        // sequential control
        int sfails = 0;
        std::string a = "127.0.0.1:23471";
        for (int r = 0; r < threads * rounds; ++r) {
            cm_machine *m = nullptr;
            const char *bound = nullptr;
            uint32_t pid = 0;
            if (cm_jsonrpc_spawn_server(a.c_str(), 10000, &m, &bound, &pid) != 0) {
                ++sfails;
                continue;
            }
            cm_delete(m);
        }
        printf("[B] sequential control on one fixed port: %d/%d failed\n", sfails, threads * rounds);
        if (eaddr > 0) {
            printf("BUG: %d concurrent cm_jsonrpc_spawn_server calls failed with EADDRINUSE because other threads' "
                   "spawned servers inherited their listening acceptors\n",
                eaddr.load());
            ++bugs;
        }
    }
    return bugs ? 1 : 0;
}
