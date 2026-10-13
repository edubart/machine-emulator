// Host stand-in for risc0/cpp/zk-runtime.hpp. The real header only adapts printf/assert/abort to the rv32 zkVM
// runtime, which is not needed when the guest entry point (risc0/cpp/risc0-replay-steps.cpp) is compiled for the host.
// run.sh copies the guest source next to this file so that its #include "zk-runtime.hpp" resolves here.
#ifndef ZK_RUNTIME_HPP
#define ZK_RUNTIME_HPP
#endif
