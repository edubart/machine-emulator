// The risc0 guest calls interpret<replay_step_state_access &>, which is only instantiated in ZKARCHITECTURE builds of
// interpret.cpp. On the host, forward it to the by-value instantiation that libcartesi.a provides (the one used by
// cm_verify_step). replay_step_state_access keeps all of its state in the shared context object (apart from a page
// lookup cache), so passing a copy is equivalent to passing a reference.
#include "interpret.hpp"
#include "replay-step-state-access.hpp"

namespace cartesi {

template <>
interpreter_break_reason interpret<replay_step_state_access &>(replay_step_state_access &a, uint64_t mcycle_end) {
    return interpret<replay_step_state_access>(a, mcycle_end);
}

} // namespace cartesi
