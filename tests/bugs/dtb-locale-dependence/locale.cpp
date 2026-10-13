// The DTB unit addresses, the /aliases targets and the stored-machine file names follow the host process's C++
// global locale.
//
// Usage: locale <work-dir>
//
// A default-constructed std::ostringstream is imbued with the C++ global locale, and libstdc++ applies
// numpunct::grouping() to integers in every base, std::hex included. The library formats with such streams:
//   src/fdt-builder.hpp FDTBuilder::begin_node_num   name << "@" << std::hex << n   (clint, plic, htif, memory, pmem...)
//   src/dtb.cpp dtb_init                             /aliases targets "/pmem@..." and "/uio@..."
//   src/machine-config.cpp get_data_filename / get_dht_filename / get_dpt_filename   (store and load)
// So a C++ host that adopts a grouping locale (std::locale::global(std::locale("")) with LANG=en_US.UTF-8, for
// example) builds "clint@2,000,000" into the hashed DTB: the same config gives a different root hash, and stored
// directories use file names ("0000000000000000-8,000.bin") that a classic-locale process cannot load (and vice
// versa).
//
// No system locale data is needed: the grouping locale is the classic locale plus a numpunct facet with grouping
// "\3" and separator ',' (the LC_NUMERIC rules of en_US.UTF-8), set as the C++ global locale in this process between
// machine creations. The DTB is decoded by walking the FDT structure block.
// Property checked (what a fix restores): under the grouping global locale the root hash, every DTB unit address and
// /aliases target, and the stored file names are the same as under the classic locale, and stored directories load
// across the two locales.
//
// Exit codes: 0 = fixed, 1 = bug reproduced, 2 = setup failure.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <locale>
#include <string>
#include <vector>

#include <cm.h>

namespace fs = std::filesystem;

namespace {

struct grouping_punct final : std::numpunct<char> {
    char do_thousands_sep() const override {
        return ',';
    }
    std::string do_grouping() const override {
        return "\3";
    }
};

const char *const CONFIG = R"({
  "ram": {"length": 131072},
  "flash_drive": [{"length": 4096, "label": "inputs"}, {"length": 65536}],
  "nvram": [{"length": 4096, "label": "state"}],
  "dtb": {"bootargs": "console=hvc0 quiet", "init": "true", "entrypoint": "true"}
})";

constexpr uint64_t DTB_START = UINT64_C(0x7ff00000);
constexpr size_t DTB_LENGTH = 0x100000;

[[noreturn]] void fail(const char *what) {
    std::fprintf(stderr, "setup failed: %s: %s\n", what, cm_get_last_error_message());
    std::exit(2);
}

std::string hexhash(const cm_hash &h) {
    static const char *d = "0123456789abcdef";
    std::string s;
    for (unsigned char c : h) {
        s += d[c >> 4];
        s += d[c & 15];
    }
    return s;
}

uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

// Node names with a unit address and /aliases values, in DTB order
std::vector<std::string> decode_dtb(cm_machine *m) {
    std::vector<uint8_t> b(DTB_LENGTH);
    if (cm_read_memory(m, DTB_START, b.data(), b.size()) != CM_ERROR_OK) {
        fail("cm_read_memory(dtb)");
    }
    if (be32(&b[0]) != 0xd00dfeed) {
        std::fprintf(stderr, "setup failed: bad FDT magic\n");
        std::exit(2);
    }
    const uint32_t off_struct = be32(&b[8]);
    const uint32_t off_strings = be32(&b[12]);
    std::vector<std::string> out;
    std::vector<std::string> path;
    for (uint32_t p = off_struct; p + 4 <= b.size();) {
        const uint32_t tok = be32(&b[p]);
        p += 4;
        if (tok == 1) { // FDT_BEGIN_NODE
            const std::string name(reinterpret_cast<const char *>(&b[p]));
            p += (name.size() + 1 + 3) & ~3u;
            path.push_back(name);
            if (name.find('@') != std::string::npos) {
                out.push_back("node " + name);
            }
        } else if (tok == 2) { // FDT_END_NODE
            path.pop_back();
        } else if (tok == 3) { // FDT_PROP
            const uint32_t len = be32(&b[p]);
            const uint32_t nameoff = be32(&b[p + 4]);
            p += 8;
            if (path.size() == 2 && path[1] == "aliases") {
                const std::string pname(reinterpret_cast<const char *>(&b[off_strings + nameoff]));
                out.push_back("alias " + pname + "=" + std::string(reinterpret_cast<const char *>(&b[p])));
            }
            p += (len + 3) & ~3u;
        } else if (tok == 4) { // FDT_NOP
        } else if (tok == 9) { // FDT_END
            return out;
        } else {
            std::fprintf(stderr, "setup failed: bad FDT token %u\n", tok);
            std::exit(2);
        }
    }
    std::fprintf(stderr, "setup failed: unterminated FDT\n");
    std::exit(2);
}

// Is every unit address (after the last '@') lowercase hex, as the devicetree spec requires?
int count_invalid(const std::vector<std::string> &entries) {
    int bad = 0;
    for (const auto &e : entries) {
        const auto unit = e.substr(e.rfind('@') + 1);
        if (unit.empty() || unit.find_first_not_of("0123456789abcdef") != std::string::npos) {
            ++bad;
        }
    }
    return bad;
}

std::string root_hash(cm_machine *m) {
    cm_hash h;
    if (cm_get_root_hash(m, &h) != CM_ERROR_OK) {
        fail("cm_get_root_hash");
    }
    return hexhash(h);
}

std::vector<std::string> file_names(const std::string &dir) {
    std::vector<std::string> v;
    for (const auto &e : fs::directory_iterator(dir)) {
        v.push_back(e.path().filename().string());
    }
    std::sort(v.begin(), v.end());
    return v;
}

// Empty string on success (and the loaded root hash in *h), else the error message
std::string try_load(const std::string &dir, std::string *h) {
    cm_machine *m = nullptr;
    if (cm_load_new(dir.c_str(), nullptr, CM_SHARING_NONE, &m) != CM_ERROR_OK) {
        return cm_get_last_error_message();
    }
    *h = root_hash(m);
    cm_delete(m);
    return {};
}

struct snapshot {
    std::string hash;
    std::vector<std::string> dtb;
    std::vector<std::string> files;
    std::string dir;
};

// Creates a machine from CONFIG and stores it, all under the given C++ global locale
snapshot make(const std::locale &loc, const std::string &dir) {
    std::locale::global(loc);
    cm_machine *m = nullptr;
    if (cm_create_new(CONFIG, nullptr, nullptr, &m) != CM_ERROR_OK) {
        fail("cm_create_new");
    }
    snapshot s{root_hash(m), decode_dtb(m), {}, dir};
    if (cm_store(m, dir.c_str(), CM_SHARING_ALL) != CM_ERROR_OK) {
        fail("cm_store");
    }
    s.files = file_names(dir);
    cm_delete(m);
    std::locale::global(std::locale::classic());
    return s;
}

} // namespace

int main(int argc, char **argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    const std::string work = argc > 1 ? argv[1] : ".";
    const std::locale classic = std::locale::classic();
    const std::locale grouping(classic, new grouping_punct);
    int bug = 0;

    const snapshot c = make(classic, work + "/stored-classic");
    const snapshot g = make(grouping, work + "/stored-grouping");
    if (count_invalid(c.dtb) != 0 || c.dtb.empty()) {
        std::printf("ERROR: unexpected DTB under the classic locale\n");
        return 2;
    }
    std::printf("classic  global locale: root hash %.16s...  invalid unit addresses: %d\n", c.hash.c_str(),
        count_invalid(c.dtb));
    std::printf("grouping global locale: root hash %.16s...  invalid unit addresses: %d\n", g.hash.c_str(),
        count_invalid(g.dtb));
    if (g.hash != c.hash) {
        std::printf("  -> same config, same process, different root hash\n");
        bug = 1;
    }
    if (g.dtb != c.dtb) {
        bug = 1;
        int shown = 0;
        for (size_t i = 0; i < c.dtb.size() && i < g.dtb.size() && shown < 6; ++i) {
            if (c.dtb[i] != g.dtb[i]) {
                std::printf("  %-28s -> %s\n", c.dtb[i].c_str(), g.dtb[i].c_str());
                ++shown;
            }
        }
    }
    if (g.files != c.files) {
        bug = 1;
        int shown = 0;
        for (size_t i = 0; i < c.files.size() && i < g.files.size() && shown < 3; ++i) {
            if (c.files[i] != g.files[i]) {
                std::printf("  stored file %-28s -> %s\n", c.files[i].c_str(), g.files[i].c_str());
                ++shown;
            }
        }
    }
    // stored under one locale, loaded under the other (both directions)
    std::string h;
    std::locale::global(classic);
    std::string err = try_load(g.dir, &h);
    std::printf("load of the grouping-stored dir under classic: %s\n", err.empty() ? ("ok " + h.substr(0, 16)).c_str() : err.c_str());
    if (!err.empty()) {
        bug = 1;
    }
    std::locale::global(grouping);
    err = try_load(c.dir, &h);
    std::locale::global(classic);
    std::printf("load of the classic-stored dir under grouping: %s\n", err.empty() ? ("ok " + h.substr(0, 16)).c_str() : err.c_str());
    if (!err.empty()) {
        bug = 1;
    }
    if (bug) {
        std::printf("BUG REPRODUCED: DTB unit addresses, /aliases targets and stored file names follow the host's C++ "
                    "global locale (same config -> different root hash; stores not portable across locales)\n");
        return 1;
    }
    std::printf("OK: root hash, DTB and stored file names do not depend on the C++ global locale\n");
    return 0;
}
