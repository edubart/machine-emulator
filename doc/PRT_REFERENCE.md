# Permissionless Refereed Tournaments: implementer's reference

*The exact rules, data structures and algorithms of the Permissionless
Refereed Tournament (PRT), as implemented by the Lua model that
accompanies the Cartesi Machine emulator's documentation.
The companion to the narrated explainer "The Judge Who Checks Four
Steps".*

## 0. Scope and status

**What this is.** A specification by example. The Cartesi Machine
emulator's documentation includes a Lua model of the PRT contracts: a *referee* that stands in for the on-chain dispute
contracts, an *honest player*, and four kinds of dishonest player. This
document states the rules that model implements and reproduces its code.
Every Lua listing here is copied verbatim from the model or from the
emulator's hash-tree library. Where prose and code disagree, the code is
right.

**Who it is for.** Someone who wants to implement a participant in a
PRT dispute over a Rolling Cartesi Machine: something that computes
claims, answers the referee's requests, and produces the proofs. It
assumes familiarity with hashes, Merkle trees, and the general idea of
fraud proofs. The explainer covers those from scratch.

**What it covers, and how firmly.**

| Part | Content | Status |
|---|---|---|
| 1–3 | Geometry, trees, the state-transition function | Normative for the model. The proof structure and the three transition kinds are what the production contracts verify; the period and the sizes are the model's |
| 4–5 | Claims and the referee's rules | Normative for the model |
| 6 | The honest player: execution, claim storage, responses, outputs | The model's implementation; other implementations are possible |
| 7 | A real chain: how the model differs from the production contracts (Dave), and a *proposed* mapping from contract events to player actions | Informative. The mapping is a design proposal, not a deployed interface |
| 8–10 | Test adversaries, checklists, glossary | Informative |

**What it does not cover.** The Cartesi Machine itself (its instruction
set, devices, configuration); the ABI of the production contracts; the
on-chain encoding of state-transition proofs; transaction management.
For those, the production contracts and their repository are the
authority: <https://github.com/cartesi/dave>. The algorithm is that of
*Permissionless Refereed Tournaments*
(<https://arxiv.org/abs/2212.12439>), on which *Dave*
(<https://doi.org/10.1145/3734698>) improves further. The Lua model is a
model of the PRT contracts that Dave deploys. It follows those contracts
rather than the paper where the two differ in detail: in the paper, for
instance, both sides reveal at every level, and the join proof is of the
first state.

**Which source to trust.** For everything in sections 1 to 6 the Lua
model and the emulator are the authority. Where the public contracts
repository and the model disagree, this document follows the model.

**Conventions.** Hashes are 32 bytes, Keccak-256, written `keccak(a, b)`
for the hash of the concatenation of two hashes. All offsets and indices
are zero-based unless a Lua array is being indexed. `2^n` is a power of
two. "The machine" is a Cartesi Machine instance driven through its Lua
API.

---

## 1. Geometry

### 1.1 The fixed shape of an epoch

An *epoch* is a batch of inputs (advance-state requests) processed by a
Rolling Cartesi Machine. For the purposes of a dispute it has a fixed
shape, independent of what actually ran:

| Level | Count | Constant |
|---|---|---|
| Input slots per epoch | 2^24 | `ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH = 24` |
| Mcycles per input slot | 2^48 | `ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE = 48` |
| Uarch transitions per mcycle | 2^20 | `ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE = 20` |

An *mcycle* is one fetch-execute iteration of the main processor. A
*uarch transition* is one of the 2^20 positions of an mcycle: a step of
the microarchitecture (uarch), the minimal RV64I processor that executes
one mcycle per run, fused with input delivery at an input boundary and
with the uarch reset at the last position; see section 3.
`UARCH_CYCLE_MAX = 2^20 - 1`. The epoch therefore has 2^92 transitions.

Each input slot's 2^48 mcycles are counted from the *boundary*: the
machine state that receives the input, before delivery.

### 1.2 Periods and the two claim levels

The dispute has two levels. The single free parameter is *p*,
`log2_mcycles_per_period`. A *period* is 2^p consecutive mcycles.

- An **mcycle claim** covers the whole epoch with one leaf per period.
- A **uarch claim** covers one period with one leaf per uarch
  transition.

```lua
local function new_geometry(log2_mcycles_per_period)
    local mcycle_height = LOG2_MAX_ADVANCE_STATES_PER_EPOCH
        + LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
        - log2_mcycles_per_period
    local uarch_height = log2_mcycles_per_period + LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
    assert(mcycle_height < 63 and uarch_height < 63, "claim leaf counts must fit in signed 64-bit integers")
    return {
        log2_mcycles_per_period = log2_mcycles_per_period,
        mcycles_per_period = 1 << log2_mcycles_per_period,
        mcycle_height = mcycle_height,
        uarch_height = uarch_height,
        periods_per_input = 1 << (LOG2_MAX_MCYCLES_PER_ADVANCE_STATE - log2_mcycles_per_period),
    }
end
```

The model uses *p* = 10:

| Quantity | Formula | *p* = 10 |
|---|---|---|
| `mcycles_per_period` | 2^p | 1,024 |
| `periods_per_input` | 2^(48 − p) | 2^38 |
| `mcycle_height` (leaves: 2^height) | 24 + 48 − p | 62 |
| `uarch_height` | p + 20 | 30 |

`mcycle_height + uarch_height = 92`. Both heights must be below 63 so
that leaf counts fit in signed 64-bit integers.

*Choosing p.* An mcycle claim costs one state hash per period, so it
favours a long period. A uarch claim expands one whole period into uarch
transitions, so it favours a short one.

### 1.3 Coordinates

| Name | Range | Meaning |
|---|---|---|
| `epoch_input_offset` | 0 … 2^24 − 1 | Input slot within the epoch |
| `input_period_offset` | 0 … 2^(48−p) − 1 | Period within that input slot |
| `epoch_period_offset` | 0 … 2^(72−p) − 1 | **Leaf index of an mcycle claim** |
| `period_mcycle_offset` | 0 … 2^p − 1 | Mcycle within that period |
| `uarch_cycle` | 0 … 2^20 − 1 | Uarch transition within that mcycle |
| `state_transition_offset` | 0 … 2^(p+20) − 1 | **Leaf index of a uarch claim** |
| `input_mcycle_offset` | 0 … 2^48 − 1 | Mcycles from the input's boundary |

```lua
local function split_epoch_period_offset(periods_per_input, epoch_period_offset)
    return epoch_period_offset // periods_per_input, epoch_period_offset % periods_per_input
end

local function combine_epoch_period_offset(periods_per_input, epoch_input_offset, input_period_offset)
    return epoch_input_offset * periods_per_input + input_period_offset
end

local function split_state_transition_offset(state_transition_offset)
    return state_transition_offset >> LOG2_MAX_UARCH_CYCLES_PER_MCYCLE, state_transition_offset & UARCH_CYCLE_MAX
end

local function combine_input_mcycle_offset(mcycles_per_period, input_period_offset, period_mcycle_offset)
    return input_period_offset * mcycles_per_period + period_mcycle_offset
end
```

The epoch-wide and period-wide indices are kept as two integers because
their combination needs 92 bits. These offsets are *logical*: they index
positions in the committed computation, including padding during which
the machine does not advance. They are distinct from the machine's
absolute `mcycle` register and from any global input index a contract
may use.

### 1.4 A toy geometry

Useful for tests and diagrams: 2 input slots, 4 mcycles per slot, 4
uarch transitions per mcycle, *p* = 1. Then an epoch has 32 transitions,
an mcycle claim has 4 leaves (height 2), and a uarch claim has 8 leaves
(height 3). The pure match functions of section 5 can be exercised on
synthetic trees of any height without a machine.

---

## 2. Trees and proofs

### 2.1 The proof structure

One structure serves every tree in the protocol.

```lua
proof ::= {
  target_address   ::= number,  -- where the target node starts
  log2_target_size ::= number,  -- log2 of the span of the target node
  log2_root_size   ::= number,  -- log2 of the span of the root
  target_hash      ::= string,  -- label of the target node
  root_hash        ::= string,  -- label of the root
  sibling_hashes   ::= { ... }  -- bottom-up: [1] is the target's sibling
}
```

```lua
local function roll_hash_up_tree(proof, target_hash, hash_type)
    local hash_function = cartesi[hash_type or "keccak256"]
    local hash = target_hash
    for log2_size = proof.log2_target_size, proof.log2_root_size - 1 do
        local sibling = assert(proof.sibling_hashes[log2_size - proof.log2_target_size + 1], "too few siblings")
        local bit = (proof.target_address & (1 << log2_size)) ~= 0
        local first, second
        if bit then
            first, second = sibling, hash
        else
            first, second = hash, sibling
        end
        hash = hash_function(first, second)
    end
    return hash
end

local function verify_slice(proof, hash_type)
    assert(roll_hash_up_tree(proof, proof.target_hash, hash_type) == proof.root_hash, "target node not in tree")
end

local function verify_splice(proof, new_target_hash, new_root_hash, hash_type)
    verify_slice(proof, hash_type)
    assert(roll_hash_up_tree(proof, new_target_hash, hash_type) == new_root_hash, "target node not in tree")
end
```

*Slicing* proves that a node has a given label. *Splicing* proves the
root that results from replacing that node. Both use the same siblings.

### 2.2 The three trees

| Tree | Leaves | Height | Leaf label | Empty leaf |
|---|---|---|---|---|
| **Machine state** | 32-byte words of the 2^64-byte address space | 59 above the words (`log2_root_size` 64, `log2_target_size` 5 for a word) | `keccak(word)` | `keccak` of 32 zero bytes |
| **Claim** (mcycle or uarch) | State hashes along the computation | `mcycle_height` or `uarch_height` | The state hash itself | Not applicable: a claim tree is always full |
| **Outputs** | One per output ever emitted, in order | 63 (`ROLLUP_LOG2_MAX_OUTPUT_COUNT`) | `keccak(output)` | 32 literal zero bytes |

In a claim-tree proof, `target_address` is the leaf index,
`log2_target_size` is 0, `log2_root_size` is the tree height, and there
are exactly `height` siblings.

For the machine state tree, proofs come from
`machine:get_proof(address, log2_target_size)`. The root of a byte
string laid at the base of a subtree, zero-padded, is:

```lua
local function get_data_root_hash(data, log2_root_size, hash_type)
    local hash_function = cartesi[hash_type or "keccak256"]
    assert(#data <= (1 << log2_root_size), "data does not fit in the tree")
    -- Level zero is one hash per word, a trailing partial word zero-padded after the loop.
    local level = {}
    local full = #data - #data % WORD_LENGTH
    for i = 1, full, WORD_LENGTH do
        level[#level + 1] = hash_function(data:sub(i, i + WORD_LENGTH - 1))
    end
    if full < #data then
        local word = data:sub(full + 1)
        level[#level + 1] = hash_function(word .. string.rep("\0", WORD_LENGTH - #word))
    end
    -- Pair upward to the root, the pristine hash standing in for every node the data misses.
    local pristine = hash_function(string.rep("\0", WORD_LENGTH))
    for _ = WORD_LOG2_SIZE, log2_root_size - 1 do
        local parents = {}
        for i = 1, #level, 2 do
            parents[#parents + 1] = hash_function(level[i], level[i + 1] or pristine)
        end
        level, pristine = parents, hash_function(pristine, pristine)
    end
    return level[1]
end
```

---

## 3. The state-transition function

Everything the referee knows about the machine is in this section.

### 3.1 The uarch

In normal operation the emulator runs an interpreter compiled for the
host. The same interpreter, compiled for the uarch, executes exactly one
fetch-execute iteration of the main processor and then halts the uarch.
Therefore: **run the uarch until it halts, then reset the uarch to its
pristine state. That is one mcycle.**

The uarch implements RV64I only (52 instructions). Its registers
(`uarch_pc`, `uarch_cycle`, `uarch_halt`, `uarch_x0`…`uarch_x31`) and
its private RAM are part of the machine state and are covered by the
state hash.

### 3.2 Fixed points

A *fixed point* is a state that a transition leaves unchanged.

- **Uarch level.** A halted uarch, or one whose cycle counter has
  reached its maximum. A further uarch step is a no-op.
- **Mcycle level.** A machine that has yielded manually, has halted, or
  whose `mcycle` has reached `imcyclemax` (*mcycle overflow*).
  `imcyclemax` is an inclusive per-input limit: delivering an input sets
  it to the current `mcycle` plus 2^48 − 1 (saturating). A further
  mcycle leaves the state at the mcycle boundary unchanged.

```lua
local function is_at_fixed_point(break_reason)
    return is_halted(break_reason) or is_yielded_manual(break_reason) or is_mcycle_overflow(break_reason)
end
```

Two cautions.

1. At an mcycle-level fixed point the uarch still runs inside each
   mcycle slot: it executes a short no-progress iteration, halts, and is
   reset. The state hash wanders within the slot and returns. Only the
   hash *at mcycle boundaries* repeats.
2. An input that uses up its slot stops at *mcycle overflow*, which is a
   fixed point like the others: its leaves repeat to the end of the
   slot, and, since the machine is not waiting on an accepted yield, no
   later input is delivered. The model's assertions that an input
   "stopped at a fixed point" are sanity checks, not an unhandled case.

### 3.3 The three kinds of transition

The position of a transition determines its kind. Let
`(epoch_input_offset, input_period_offset)` locate the period and
`state_transition_offset` the transition within it.

| Condition | Operations verified, in order |
|---|---|
| `state_transition_offset == 0` and `input_period_offset == 0` and the epoch has an input in this slot | input delivery, then one uarch step |
| `uarch_cycle == UARCH_CYCLE_MAX` | one uarch step (by then at a uarch fixed point), then the uarch reset |
| otherwise | one uarch step |

The first two conditions cannot both hold: offset zero has `uarch_cycle`
zero.

```lua
local function validate_state_transition_response(
    dapp_contract,
    root_hash_before,
    epoch_period_offset,
    state_transition_offset,
    response
)
    local periods_per_input = dapp_contract.geometry.periods_per_input
    local epoch_input_offset, input_period_offset = split_epoch_period_offset(periods_per_input, epoch_period_offset)
    local _, uarch_cycle = split_state_transition_offset(state_transition_offset)
    local obtained_root_hash = root_hash_before
    local input_data = dapp_contract.inputs[epoch_input_offset + 1]
    if state_transition_offset == 0 and input_period_offset == 0 and input_data then
        obtained_root_hash = cartesi.machine:verify_send_cmio_response(
            HTIF_YIELD_REASON_ADVANCE_STATE,
            input_data,
            root_hash_before,
            response.send_cmio_log,
            root_hash_before
        )
    end
    obtained_root_hash = cartesi.machine:verify_step_uarch(obtained_root_hash, response.step_log)
    if uarch_cycle == UARCH_CYCLE_MAX then
        obtained_root_hash = cartesi.machine:verify_reset_uarch(obtained_root_hash, response.reset_uarch_log)
    end
    return obtained_root_hash
end
```

Notes.

- The input bytes are `dapp_contract.inputs[...]`, the referee's own
  copy, never anything supplied by a player.
- The revert root hash passed to the delivery verification is
  `root_hash_before`: the state the input is delivered to is the state a
  rejection returns to.
- Each `verify_*` returns the state hash its log provably advances to,
  or raises an error. None needs a machine instance.
- From a given `root_hash_before` and position, at most one result can
  be obtained. This uniqueness is what the whole protocol relies on.

### 3.4 Input delivery

On the machine, delivery is
`machine:send_cmio_response(HTIF_YIELD_REASON_ADVANCE_STATE, input_data, revert_root_hash)`.
It:

1. sets `imcyclemax` to the current `mcycle` plus 2^48 − 1
   (saturating), the limit for this input;
2. records `revert_root_hash` in the machine state (at
   `AR_SHADOW_REVERT_ROOT_HASH_START`);
3. writes `input_data` into the CMIO receive buffer (skipped when the
   input is empty);
4. records the reason and the length in `htif_fromhost`;
5. clears `iflags_Y`, so the machine can resume.

That is the order of the writes, and so the order of the accesses in the
delivery's log.

When a manual yield with reason rx-accepted is pending,
`revert_root_hash` must equal the machine's root hash at that moment;
the call validates this before changing anything. Delivery is a
**no-op**, leaving the state unchanged, when no manual yield is pending,
when the pending yield is not rx-accepted (after an exception, for
instance), or when the input exceeds the receive buffer. The logged
form, `machine:log_send_cmio_response(reason, data, revert_root_hash)`,
is a no-op in exactly the same cases and never fails.

Inputs are ABI-encoded as
`EvmAdvance(uint256 chainId, address appContract, address msgSender, uint256 blockNumber, uint256 blockTimestamp, uint256 prevRandao, uint256 index, bytes payload)`.
Outputs are ABI-encoded as `Voucher(address destination, uint256 value, bytes payload)`,
`DelegateCallVoucher(address destination, bytes payload)`, or
`Notice(bytes payload)`.

### 3.5 How an input ends

The guest signals through the HTIF yield device.

| Yield | `tohost` command / reason | Meaning for the host |
|---|---|---|
| Automatic | `TX_OUTPUT` | An output is in the CMIO transmit buffer; collect it and resume |
| Automatic | `TX_REPORT`, `PROGRESS` | Not relevant to the dispute; resume |
| Manual | `RX_ACCEPTED` | Input accepted. The transmit buffer holds the outputs Merkle root. Fixed point |
| Manual | `RX_REJECTED` | Input rejected. State must revert to the boundary. Fixed point |
| Manual | `TX_EXCEPTION` | Irrecoverable. No further input can be delivered. Fixed point |

A halt and an mcycle overflow are also fixed points after which no input
can be delivered.

### 3.6 Rejection and the revert root hash

When the instruction that performs the rx-rejected manual yield
completes, **the uarch reset that closes that mcycle substitutes the
recorded revert root hash for the state hash**. The verification of the
reset reads the revert root hash from the state, with a proof, and
returns it as the hash after.

So, in the committed history, the state hash immediately after a
rejecting instruction is the pre-delivery boundary hash, and from there
on the history is that of the boundary machine sitting at its fixed
point. The physical machine does not transform itself; a host that needs
the reverted machine restores a snapshot taken before delivery, and
should assert that its root hash equals the revert root hash.

### 3.7 Access logs

A log is produced by performing an operation on a machine while
recording every access.

| Produce (needs a machine) | Verify (needs no machine) |
|---|---|
| `machine:log_step_uarch()` | `cartesi.machine:verify_step_uarch(root_hash_before, log)` |
| `machine:log_reset_uarch()` | `cartesi.machine:verify_reset_uarch(root_hash_before, log)` |
| `machine:log_send_cmio_response(reason, data, revert_root_hash)` | `cartesi.machine:verify_send_cmio_response(reason, data, root_hash_before, log, revert_root_hash)` |

```lua
access_log ::= {
  log_type ::= { annotations ::= boolean, large_data ::= boolean },
  accesses ::= { [1] ::= access, ... },
  notes    ::= { [1] ::= string, ... },   -- with annotations
  brackets ::= { [1] ::= bracket, ... }   -- with annotations
}

access ::= {
  type         ::= "read" | "write",
  address      ::= number,
  log2_size    ::= number,
  read_hash    ::= string,
  read         ::= string,
  written_hash ::= string,   -- writes only
  written      ::= string,   -- writes only
  proof        ::= proof
}
```

`read` and `written` carry `2^log2_size` bytes when `log2_size >= 5`,
and the whole enclosing 32-byte word for smaller accesses.

Verification walks the accesses in order. For each, it checks that this
is the access the operation must perform next (address, size, type);
that `read` hashes to `read_hash`; that `read_hash` with the proof's
siblings rolls up to the current root hash; and, for a write, it rolls
`written_hash` up the same siblings to obtain the new current root hash.
The result after the last access is returned.

To position a machine at a transition before logging: run to the mcycle
with `machine:run(mcycle)`, then to the uarch cycle with
`machine:run_uarch(uarch_cycle)`. Logging performs the operation as well
as recording it.

---

## 4. Claims

### 4.1 What a leaf holds

**A leaf holds the state hash *after* its stretch of the timeline.** The
state before leaf 0 is not a leaf; it is supplied from outside.

- **Mcycle claim.** Leaf `i = epoch_period_offset` is the state hash
  after period `i`: after `(input_period_offset + 1) * 2^p` mcycles
  counted from the boundary of input slot `epoch_input_offset`. The
  state before leaf 0 is the epoch's initial state. The last leaf,
  `2^mcycle_height - 1`, is the epoch's final state.
- **Uarch claim** over period *P*. Leaf `j = state_transition_offset` is
  the state hash after transition `j` of the period. The state before
  leaf 0 is mcycle-claim leaf *P* − 1 (or the epoch's initial state when
  *P* = 0). The last leaf, `2^uarch_height - 1`, must equal mcycle-claim
  leaf *P*.

### 4.2 What the leaves are, case by case

**Mcycle claim, within one input slot.**

1. While the machine runs, one leaf per 2^p mcycles: the state hash at
   that sampling point.
2. When the machine reaches a fixed point before the next sampling
   point, the fixed-point state hash is the value of that leaf and of
   every remaining leaf of the slot.
3. If the fixed point is an rx-rejected manual yield, the repeated value
   is the revert root hash (the boundary hash) instead.

**Mcycle claim, across slots.**

4. After an accepted input, the next slot starts from the machine as it
   is. After a rejected input, from the restored boundary.
5. After an exception, a halt, or an mcycle overflow, no later input can
   be delivered. Every remaining leaf of the epoch repeats that state
   hash.
6. Slots past the last input of the epoch repeat the epoch's final state
   hash.

**Uarch claim, within one mcycle (2^20 leaves).**

7. One leaf after each uarch cycle while the uarch runs.
8. After the uarch halts, the halted state hash repeats up to leaf
   2^20 − 2.
9. Leaf 2^20 − 1 is the state hash after the uarch reset. If the mcycle
   was a rejecting instruction, it is the revert root hash.

**Uarch claim, across mcycles.**

10. At an mcycle-level fixed point, every further mcycle of the period
    contributes the same 2^20 leaves: those of one no-progress mcycle at
    that fixed point.
11. After a rejecting instruction, the further mcycles are those of the
    *reverted* machine at its fixed point (its "uarch tail"), which the
    builder must have captured from the boundary machine before
    delivery.
12. In the first mcycle of an input slot (period 0), leaf 0 is the state
    after delivering the input and taking the first uarch step, when the
    epoch has an input in that slot; otherwise after the step alone.

### 4.3 The claim on the wire

```lua
Claim ::= {
  computation_hash_left  ::= string,
  computation_hash_right ::= string,
  final_state_hash_proof ::= proof
}
```

The computation hash is `keccak(left, right)`. The proof targets the
last leaf.

```lua
local function validate_claim_response(submitted_claim, height)
    local computation_hash = keccak(submitted_claim.computation_hash_left, submitted_claim.computation_hash_right)
    local final_state_hash_proof = submitted_claim.final_state_hash_proof
    assert(final_state_hash_proof.target_address == (1 << height) - 1, "final state proof not at last leaf")
    assert(final_state_hash_proof.log2_target_size == 0, "final state proof target not a leaf")
    assert(final_state_hash_proof.log2_root_size == height, "final state proof height mismatch")
    assert(#final_state_hash_proof.sibling_hashes == height, "final state proof sibling count mismatch")
    assert(final_state_hash_proof.root_hash == computation_hash, "final state proof root mismatch")
    hash_tree.verify_slice(final_state_hash_proof)
    return {
        computation_hash = computation_hash,
        computation_hash_left = submitted_claim.computation_hash_left,
        computation_hash_right = submitted_claim.computation_hash_right,
        final_state_hash = final_state_hash_proof.target_hash,
    }
end
```

The two children are stored by the referee because the first move of
every match compares against them. The final-state proof binds the claim
to a final state hash: for an mcycle claim, the result of the epoch; for
a uarch claim, the hash that must be one of the two contested values.

---

## 5. The referee

The referee holds only what a blockchain would: the agreed initial state
hash, the epoch's inputs, the geometry, and, per match, three hashes and
two clocks.

```lua
local function make_dapp_contract(initial_state_hash, input_paths)
    local max_allowance = 4
    return {
        initial_state_hash = initial_state_hash,
        inputs = map(input_paths, util.read_file),
        input_paths = input_paths,
        geometry = new_geometry(10),
        max_allowance = max_allowance,
        response_budget = max_allowance,
    }
end
```

### 5.1 Requests and time

The model's referee talks to players through three primitives, which
stand in for contract events and transactions.

| Primitive | Meaning |
|---|---|
| `notify_all(audience, event, arguments)` | Publish an event with no response |
| `request_all(audience, event, arguments, validator)` | Collect one validated response per member of a fixed audience; returns a future |
| `request_first_valid(audience, event, arguments, validator)` | Take the first response the validator accepts; returns a future |

A validator receives `(response, sender, received_at)`. It accepts by
returning a value and rejects by raising an error or returning `nil` or
`false`. `future:wait_at_most(deadline)` returns the accepted result or
`nil` at the deadline; `future:wait_at_least(block)` waits until that
block has been reached *and* a valid result exists.

An *audience* is a subscription hash, a list of them, or `EVERYONE`. A
claim's subscription is `keccak(tournament_id, computation_hash)`:

```lua
local function subscription_hash(tournament_id, claim)
    return keccak(tournament_id, claim.computation_hash)
end
```

The mcycle tournament's ID is the initial state hash. A uarch
tournament's ID is the hash of the two mcycle computation hashes whose
match opened it.

Time is counted in logical blocks. A request emitted in block B cannot
be answered before block B + 1. **A deadline is the first block at which
a clock has run out, so a response must arrive strictly before it.**

No validator's accept-or-reject decision depends on the sender (claim
validators do record the sender, to subscribe it to its claim). The
model's transport does discard responses from connections outside a
request's audience; on a
chain, anyone can send a transaction and only the validation matters.

### 5.2 Opening a tournament

```lua
local function open_mcycle_tournament(dapp_contract)
    local geometry = dapp_contract.geometry
    local tournament_id = dapp_contract.initial_state_hash
    local start_instant = current_time()
    local max_allowance = dapp_contract.max_allowance
    local joining_deadline = start_instant + max_allowance
    local collection <close> = request_all(
        dapp_contract.initial_state_hash,
        EVENTS.commit_mcycle_claim,
        {},
        function(response, connection, received_at)
            return {
                claim = validate_claim_response(response, geometry.mcycle_height),
                connection = connection,
                received_at = received_at,
            }
        end
    )
    local responses, order = collection:wait_at_most(joining_deadline)
    wait_until(joining_deadline)
    local claims = partition_claims(responses, order, tournament_id, start_instant, max_allowance)
    local tournament = {
        level = "mcycle",
        id = tournament_id,
        height = geometry.mcycle_height,
        initial_state_hash = dapp_contract.initial_state_hash,
        dapp_contract = dapp_contract,
        settle_state_hash = settle_mcycle_state_hash,
        claims = claims,
    }
    story.report_claims(tournament, responses, order)
    return tournament
end
```

```lua
local function partition_claims(responses, order, tournament_id, start_instant, allowance)
    local claims = {}
    local by_hash = {}
    for _, sender in ipairs(order) do
        local response = responses[sender]
        local claim = by_hash[response.claim.computation_hash]
        if not claim then
            claim = response.claim
            claim.allowance = allowance - (response.received_at - start_instant)
            by_hash[claim.computation_hash] = claim
            claims[#claims + 1] = claim
        end
        subscribe_connection(subscription_hash(tournament_id, claim), response.connection)
    end
    return claims
end
```

- The audience is fixed when the tournament opens: the players
  subscribed to the initial state hash.
- Claims are collected until `joining_deadline = start + allowance`. The
  model enforces lateness by stopping collection, not in the validator.
  A real participant must have its claim included before that deadline.
- Equal computation hashes are one claim. Claims are ordered by the
  admission order of their first posters.
- A claim's clock starts as the allowance less the blocks elapsed since
  the tournament opened.

### 5.3 The match walk

A match walks two claim trees down to the leftmost leaf where they
differ. The claims alternate, one response per turn.

```lua
local function new_match(claim1, claim2, height)
    return {
        claims = { claim1, claim2 },
        turn_index = 1,
        turn_parent_node = claim1.computation_hash,
        other_left_node = claim2.computation_hash_left,
        other_right_node = claim2.computation_hash_right,
        height = height,
        position = 0,
    }
end
```

`turn_parent_node` is the node the on-turn claim must open, located by
(`position`, `height`): `position` is the index of its first leaf and is
aligned to `2^height`. `other_left_node` and `other_right_node` are the
other claim's children at the same location.

```lua
local function validate_bisection_response(match, response)
    assert(match.height > 1, "match not bisecting")
    assert(keccak(response.turn_left_node, response.turn_right_node) == match.turn_parent_node, "wrong children")
    local turn_child_node = (response.turn_left_node ~= match.other_left_node) and response.turn_left_node
        or response.turn_right_node
    assert(keccak(response.turn_next_left_node, response.turn_next_right_node) == turn_child_node, "wrong next nodes")
    return response
end

local function advance_bisection(match, response)
    assert(match.height > 1, "match not bisecting")
    match.height = match.height - 1
    local descend_left = response.turn_left_node ~= match.other_left_node
    if descend_left then
        match.turn_parent_node = match.other_left_node
    else
        match.turn_parent_node = match.other_right_node
        match.position = match.position + (1 << match.height)
    end
    match.other_left_node = response.turn_next_left_node
    match.other_right_node = response.turn_next_right_node
    match.turn_index = get_other_turn_index(match.turn_index)
end
```

A response therefore carries four hashes: the two children of the node
to open, and the two children of whichever of them the walk descends
into. The rule: **descend left if the on-turn claim's left child differs
from the other claim's left child; otherwise descend right.**

*Invariant.* Before every move, `turn_parent_node` differs from
`keccak(other_left_node, other_right_node)`, and every leaf left of
`position` is identical in both claims. It holds initially because
distinct claims have distinct roots. Each move preserves it: if the left
children differ, descend there; if they are equal and the parents
differ, the right children differ.

A tree of height H takes H − 1 such moves, then one seal.

*Worked example.* Height 3, leaves 0–7. Claims A and B agree on leaves
0–4 and first differ at leaf 5. `A[pos,h]` is A's node with first leaf
`pos` and height `h`.

| Step | Turn | To open | Standing pair | Revealed | Comparison | Result |
|---|---|---|---|---|---|---|
| start | A | A[0,3] | B[0,2], B[4,2] | | | height 3, position 0 |
| reveal | A | A[0,3] | B[0,2], B[4,2] | A[0,2], A[4,2]; A[4,1], A[6,1] | A[0,2] = B[0,2] | right: position 4, height 2 |
| reveal | B | B[4,2] | A[4,1], A[6,1] | B[4,1], B[6,1]; B[4,0], B[5,0] | B[4,1] ≠ A[4,1] | left: position 4, height 1 |
| seal | A | A[4,1] | B[4,0], B[5,0] | A[4,0], A[5,0]; proof of leaf 4 | A[4,0] = B[4,0] | divergent leaf 5 |

```lua
local function reveal_divergence(tournament, match)
    while match.height > 1 do
        local turn_claim = match.claims[match.turn_index]
        local start_instant = current_time()
        local responder_deadline = start_instant + turn_claim.allowance
        local eliminable_at = responder_deadline + match.claims[get_other_turn_index(match.turn_index)].allowance
        local timeout <close> = emit_schedule_match_timeout_win(tournament, match, responder_deadline, eliminable_at)
        local elimination <close> = emit_schedule_match_elimination(match, eliminable_at)
        local reveal <close> = request_first_valid(
            subscription_hash(tournament.id, turn_claim),
            EVENTS.reveal_bisection,
            { turn_claim.computation_hash, match.position, match.height, match.other_left_node },
            function(response, _, received_at)
                assert(received_at < responder_deadline, "late bisection")
                return validate_bisection_response(match, response)
            end
        )
        local response = reveal:wait_at_most(responder_deadline)
        if not response then
            return timeout:wait_at_most(eliminable_at) or elimination:wait_at_least(eliminable_at)
        end
        charge_turn_time(tournament, match, start_instant)
        advance_bisection(match, response)
        story.report_match_progress(match)
    end
end
```

### 5.4 The seal

At height 1 the on-turn claim reveals its two leaves and proves the
agreed state: the leaf immediately before the divergent one.

```lua
local function validate_seal_response(tournament, match, response)
    assert(match.height == 1, "match not ready to seal")
    assert(keccak(response.turn_left_node, response.turn_right_node) == match.turn_parent_node, "wrong leaves")
    local descend_left = response.turn_left_node ~= match.other_left_node
    local leaf_index = match.position + (descend_left and 0 or 1)
    local agreed_state_hash
    if leaf_index ~= 0 then
        local proof = response.agreed_state_hash_proof
        assert(proof.target_address == leaf_index - 1, "agreed state proof not at leaf before divergence")
        assert(proof.log2_target_size == 0, "agreed state proof target not a leaf")
        assert(proof.log2_root_size == tournament.height, "agreed state proof height mismatch")
        assert(#proof.sibling_hashes == tournament.height, "agreed state proof sibling count mismatch")
        assert(proof.root_hash == match.claims[match.turn_index].computation_hash, "agreed state proof root mismatch")
        assert(descend_left or proof.target_hash == response.turn_left_node, "wrong agreed state")
        hash_tree.verify_slice(proof)
        agreed_state_hash = proof.target_hash
    else
        agreed_state_hash = tournament.initial_state_hash
    end
    local turn_state_hash = descend_left and response.turn_left_node or response.turn_right_node
    local other_state_hash = descend_left and match.other_left_node or match.other_right_node
    local next_state_hashes = {}
    next_state_hashes[match.turn_index] = turn_state_hash
    next_state_hashes[get_other_turn_index(match.turn_index)] = other_state_hash
    return {
        leaf_index = leaf_index,
        agreed_state_hash = agreed_state_hash,
        next_state_hashes = next_state_hashes,
    }
end
```

- The proof is against the on-turn claim's computation hash only. That
  suffices because every leaf left of the divergence is identical in
  both trees.
- The proof is required even when the divergent leaf is the right one
  and the agreed state was therefore already revealed as the left leaf;
  its target must then equal that left leaf.
- When the divergent leaf is leaf 0, no proof is needed: the agreed
  state is the tournament's initial state.

The outcome is `{ leaf_index, agreed_state_hash, next_state_hashes }`,
with one contested hash per claim.

```lua
local function seal_divergence(tournament, match)
    local turn_claim = match.claims[match.turn_index]
    local start_instant = current_time()
    local responder_deadline = start_instant + turn_claim.allowance
    local eliminable_at = responder_deadline + match.claims[get_other_turn_index(match.turn_index)].allowance
    local timeout <close> = emit_schedule_match_timeout_win(tournament, match, responder_deadline, eliminable_at)
    local elimination <close> = emit_schedule_match_elimination(match, eliminable_at)
    local seal <close> = request_first_valid(
        subscription_hash(tournament.id, turn_claim),
        EVENTS.seal_divergence,
        { turn_claim.computation_hash, match.position, match.other_left_node },
        function(response, _, received_at)
            assert(received_at < responder_deadline, "late seal")
            return validate_seal_response(tournament, match, response)
        end
    )
    local divergence = seal:wait_at_most(responder_deadline)
    if not divergence then
        return nil, timeout:wait_at_most(eliminable_at) or elimination:wait_at_least(eliminable_at)
    end
    charge_turn_time(tournament, match, start_instant)
    return divergence
end
```

### 5.5 Settling

```lua
local function settle_divergence(tournament, match, divergence)
    story.report_divergence(match, divergence)
    local settled_state_hash = tournament:settle_state_hash(
        match,
        divergence.leaf_index,
        divergence.agreed_state_hash,
        divergence.next_state_hashes
    )
    for claim_index = 1, 2 do
        if settled_state_hash == divergence.next_state_hashes[claim_index] then
            return claim_index
        end
    end
    return 0
end
```

A match result is 1 or 2 for the surviving claim, or 0 when neither
survives.

**Mcycle level.** `leaf_index` is an `epoch_period_offset`. A uarch
tournament opens over that period.

```lua
local function settle_mcycle_state_hash(
    mcycle_tournament,
    mcycle_match,
    epoch_period_offset,
    agreed_state_hash,
    next_state_hashes
)
    local uarch_tournament = open_uarch_tournament(
        mcycle_tournament,
        mcycle_match,
        epoch_period_offset,
        agreed_state_hash,
        next_state_hashes
    )
    local uarch_winner = run_tournament(uarch_tournament)
    return propagate_uarch_result(mcycle_match, uarch_winner, next_state_hashes)
end
```

```lua
local function open_uarch_tournament(
    mcycle_tournament,
    mcycle_match,
    epoch_period_offset,
    agreed_state_hash,
    next_state_hashes
)
    local geometry = mcycle_tournament.dapp_contract.geometry
    local epoch_input_offset, input_period_offset =
        split_epoch_period_offset(geometry.periods_per_input, epoch_period_offset)
    local mcycle_tournament_id = mcycle_tournament.id
    local tournament_id = keccak(mcycle_match.claims[1].computation_hash, mcycle_match.claims[2].computation_hash)
    local start_instant = current_time()
    local allowance = math.max(mcycle_match.claims[1].allowance, mcycle_match.claims[2].allowance)
    local joining_deadline = start_instant + allowance
    local collection <close> = request_all(
        {
            subscription_hash(mcycle_tournament_id, mcycle_match.claims[1]),
            subscription_hash(mcycle_tournament_id, mcycle_match.claims[2]),
        },
        EVENTS.commit_uarch_claim,
        { epoch_input_offset, input_period_offset, next_state_hashes },
        function(response, connection, received_at)
            local claim = validate_claim_response(response, geometry.uarch_height)
            local final = claim.final_state_hash
            assert(final == next_state_hashes[1] or final == next_state_hashes[2], "final state not contested")
            return { claim = claim, connection = connection, received_at = received_at }
        end
    )
    local responses, order = collection:wait_at_most(joining_deadline)
    wait_until(joining_deadline)
    local claims = partition_claims(responses, order, tournament_id, start_instant, allowance)
    local tournament = {
        level = "uarch",
        id = tournament_id,
        height = geometry.uarch_height,
        initial_state_hash = agreed_state_hash,
        dapp_contract = mcycle_tournament.dapp_contract,
        settle_state_hash = settle_uarch_state_hash,
        claims = claims,
        epoch_period_offset = epoch_period_offset,
        epoch_input_offset = epoch_input_offset,
        input_period_offset = input_period_offset,
    }
    story.report_uarch_tournament(tournament, mcycle_match, agreed_state_hash)
    story.report_claims(tournament, responses, order)
    return tournament
end
```

- Audience: the holders of the two mcycle claims.
- Admission: a valid claim of height `uarch_height` whose final state is
  one of the two contested hashes.
- Initial state: the agreed state hash from the seal.
- Allowance: the larger of the two clocks left on the parent match.
- It runs through the same `run_tournament`. More than two uarch claims
  may enter, since holders of one mcycle claim need not agree about the
  inside of a period.
- Result: the uarch winner's `final_state_hash`, or `nil` when the uarch
  tournament has no winner, in which case both mcycle claims are
  eliminated. The model applies this result to the parent match
  immediately.

**Uarch level.** `leaf_index` is a `state_transition_offset`. The
referee asks the holders of *both* claims for the transition's logs and
takes the first response that verifies (section 3.3).

```lua
local function settle_uarch_state_hash(tournament, match, state_transition_offset, root_hash_before, next_state_hashes)
    local subscriptions = {
        subscription_hash(tournament.id, match.claims[1]),
        subscription_hash(tournament.id, match.claims[2]),
    }
    local start_instant = current_time()
    local deadline_one = start_instant + match.claims[1].allowance
    local deadline_two = start_instant + match.claims[2].allowance
    local proof_deadline = math.min(deadline_one, deadline_two)
    local eliminable_at = math.max(deadline_one, deadline_two)
    local elimination <close> = request_first_valid(
        EVERYONE,
        EVENTS.schedule_match_elimination,
        { eliminable_at },
        function(_, _, received_at)
            assert(received_at >= eliminable_at, "early elimination")
            return true
        end
    )
    local proof <close> = request_first_valid(
        subscriptions,
        EVENTS.prove_state_transition,
        { tournament.epoch_input_offset, tournament.input_period_offset, state_transition_offset },
        function(response, _, received_at)
            assert(received_at < proof_deadline, "late state transition proof")
            return validate_state_transition_response(
                tournament.dapp_contract,
                root_hash_before,
                tournament.epoch_period_offset,
                state_transition_offset,
                response
            )
        end
    )
    local obtained_root_hash = proof:wait_at_most(proof_deadline)
    if not obtained_root_hash then
        elimination:wait_at_least(eliminable_at)
    end
    story.report_state_transition(tournament, match, state_transition_offset, obtained_root_hash, next_state_hashes)
    return obtained_root_hash
end
```

- Both clocks run from the seal. A proof must arrive before
  `min(deadline_one, deadline_two)`; the window is bounded by the
  opponent's clock as well as one's own.
- If no proof verifies in time, anyone may eliminate both claims from
  `max(deadline_one, deadline_two)`.
- If the proven hash matches neither contested hash, both claims are
  eliminated.

### 5.6 Rounds

```lua
local function run_match(tournament, match)
    local winner = reveal_divergence(tournament, match)
    if winner then
        return winner
    end
    local divergence
    divergence, winner = seal_divergence(tournament, match)
    if winner then
        return winner
    end
    return settle_divergence(tournament, match, divergence)
end

local function pair_claims(tournament, round)
    local claims = tournament.claims
    local matches = {}
    for i = 1, #claims - 1, 2 do
        local match = new_match(claims[i], claims[i + 1], tournament.height)
        story.report_match(tournament, round, match)
        matches[#matches + 1] = match
    end
    return matches
end

local function run_round(tournament, round)
    local claims = tournament.claims
    local matches = pair_claims(tournament, round)
    local unmatched_claim = #claims % 2 == 1 and claims[#claims] or nil
    run_matches(tournament, matches)
    story.report_round(tournament, round, matches, unmatched_claim)
    local surviving_claims = { unmatched_claim } -- unmatched_claim may be nil
    for _, match in ipairs(matches) do
        surviving_claims[#surviving_claims + 1] = match.claims[match.winner] -- match.claims[match.winner] may be nil
    end
    tournament.claims = surviving_claims
end

function run_tournament(tournament)
    local round = 0
    while #tournament.claims > 1 do
        round = round + 1
        run_round(tournament, round)
    end
    return tournament.claims[1]
end
```

- Claims are paired in order: 1 with 2, 3 with 4, and so on. With an odd
  count, the last claim advances unmatched.
- All matches of a round run concurrently.
- The next round's list is the unmatched claim, if any, followed by the
  match winners in bracket order. A match that eliminated both sides
  contributes nothing.
- The bracket is therefore a function of the claims and their admission
  order, not of which match finished first.

```lua
local function run_referee(dapp_contract)
    local tournament = open_mcycle_tournament(dapp_contract)
    local winner = run_tournament(tournament)
    story.report_winner(winner)
    if winner then
        wait_for_outputs(winner.final_state_hash)
    end
end
```

### 5.7 Clocks

For a move given to a claim at block *b*, with *c* blocks on its clock
and *w* on the waiting claim's:

| Window | Blocks | Who | What |
|---|---|---|---|
| Response | before *b* + *c* | holders of the on-turn claim | a valid reveal or seal |
| Timeout win | [*b* + *c*, *b* + *c* + *w*) | holders of the waiting claim | the waiting claim's two root children |
| Elimination | from *b* + *c* + *w* | anyone | nothing to supply |

The three requests are emitted together, before the referee waits on any
of them. A valid response ends the scope of that move's timeout and
elimination requests.

```lua
local function emit_schedule_match_timeout_win(tournament, match, responder_deadline, eliminable_at)
    local other_turn_index = get_other_turn_index(match.turn_index)
    local other_claim = match.claims[other_turn_index]
    return request_first_valid(
        subscription_hash(tournament.id, other_claim),
        EVENTS.schedule_match_timeout_win,
        { responder_deadline, other_claim.computation_hash },
        function(response, _, received_at)
            assert(received_at >= responder_deadline and received_at < eliminable_at, "timeout win outside its window")
            validate_timeout_win_response(response, other_claim.computation_hash)
            story.report_timeout_win(match)
            return other_turn_index
        end
    )
end

local function validate_timeout_win_response(children, computation_hash)
    local left = children.computation_hash_left
    local right = children.computation_hash_right
    assert(keccak(left, right) == computation_hash, "wrong children")
end

local function emit_schedule_match_elimination(match, eliminable_at)
    return request_first_valid(
        EVERYONE,
        EVENTS.schedule_match_elimination,
        { eliminable_at },
        function(_, sender, received_at)
            assert(received_at >= eliminable_at, "early elimination")
            story.report_match_eliminated(match, sender.label)
            return 0
        end
    )
end
```

After a valid response, the on-turn claim is charged only for blocks
beyond the response budget:

```lua
local function charge_turn_time(tournament, match, start_instant)
    local turn_claim = match.claims[match.turn_index]
    local elapsed = current_time() - start_instant
    turn_claim.allowance = turn_claim.allowance - math.max(elapsed - tournament.dapp_contract.response_budget, 0)
end
```

In the model the allowance is 4 blocks and the response budget equals
it, so no clock runs down: mcycle claims play with 3 blocks, uarch
claims with 2.

### 5.8 Events

| Event (arguments) | Audience | Response | Accepted when |
|---|---|---|---|
| `input_added(epoch_input_offset, path)` | subscribers to the initial state hash | none | |
| `epoch_sealed(input_count)` | same | none | |
| `commit_mcycle_claim()` | same | `Claim` | collected before the joining deadline; `validate_claim_response(_, mcycle_height)` |
| `reveal_bisection(computation_hash, position, height, other_left_node)` | holders of the on-turn claim | `{turn_left_node, turn_right_node, turn_next_left_node, turn_next_right_node}` | before `responder_deadline`; `validate_bisection_response` |
| `seal_divergence(computation_hash, position, other_left_node)` | holders of the on-turn claim | `{turn_left_node, turn_right_node, agreed_state_hash_proof}` | before `responder_deadline`; `validate_seal_response` |
| `commit_uarch_claim(epoch_input_offset, input_period_offset, next_state_hashes)` | holders of the two mcycle claims | `Claim` | collected before the joining deadline; `validate_claim_response(_, uarch_height)`; final state contested |
| `prove_state_transition(epoch_input_offset, input_period_offset, state_transition_offset)` | holders of the two uarch claims | `{send_cmio_log?, step_log, reset_uarch_log?}` | before the earlier deadline; `validate_state_transition_response` |
| `schedule_match_timeout_win(responder_deadline, computation_hash)` | holders of the waiting claim | `{computation_hash_left, computation_hash_right}` | in [`responder_deadline`, `eliminable_at`); children hash to the claim |
| `schedule_match_elimination(eliminable_at)` | everyone | `{}` | at or after `eliminable_at` |
| `prove_outputs_merkle_root(final_state_hash)` | everyone | three words and three proofs (section 6.9) | `validate_outputs_merkle_root_response` |
| `prove_output(outputs_merkle_root)` | everyone | `{output_index, output_data, output_proof}` | index not yet accepted; `validate_output_response` |

Each request carries everything needed to compute its answer from the
responder's own tree, with no memory of earlier moves.

### 5.9 What the referee stores

| Scope | Stored |
|---|---|
| Deployment | Initial state hash; the epoch's inputs; geometry; allowance; response budget |
| Tournament | Level; ID; height; initial (agreed) state hash; surviving claims; for a uarch tournament, its `epoch_period_offset` |
| Claim | Computation hash; its two children; final state hash; clock |
| Match | Node to open; other claim's left and right children; height; position; whose turn |
| After the verdict | Outputs Merkle root; accepted output indices |

---

## 6. The player

This section is the model's honest player. It is one way to meet the
rules of sections 3–5; the rules, not this code, are what a participant
must satisfy.

### 6.1 Lifecycle

```text
construct      load the machine snapshot named by the initial state hash; verify
               its hash; verify it is waiting on an rx-accepted manual yield;
               start the mcycle claim builder

input_added    for each input, as it is posted: run it on a clone of the latest
               boundary, appending samples to the claim; collect outputs;
               commit or revert; offer the new boundary to the checkpoint cache

epoch_sealed   pad the claim to the end of the epoch; freeze the cache; build
               the proofs of this epoch's outputs

commit         answer commit_mcycle_claim with the claim

respond        answer reveal_bisection, seal_divergence, commit_uarch_claim,
               prove_state_transition, the two scheduled requests, and the
               output requests, each from stored trees, replaying a machine
               only when a query enters a part of a tree that was not kept
```

Process inputs as they arrive. A participant that waits for the seal
must compute the entire epoch inside the joining window.

```lua
local function new_player(dapp_contract, label, last_output_proof)
    local self <close> = setmetatable({
        event_handler = event_handler,
        label = label or "honest",
        dapp_contract = dapp_contract,
        geometry = dapp_contract.geometry,
        input_paths = {},
        trees = {},
    }, player_meta)
    self.machine_cache = prt.new_machine_cache(prt.new_machine(dapp_contract.initial_state_hash))
    local machine, owner <close> = self:clone_at_epoch_input_offset(0) -- luacheck: ignore 211
    assert(machine:get_root_hash() == self.dapp_contract.initial_state_hash, "epoch initial state hash mismatch")
    assert_rolling_template(machine)
    self.revert_root_hash = machine:get_root_hash()
    self.epoch_builder = self:make_mcycle_computation_hash_builder()
    self.epoch_builder:begin_epoch(machine)
    self.outputs = {}
    if last_output_proof then
        assert(
            last_output_proof.log2_root_size == cartesi.ROLLUP_LOG2_MAX_OUTPUT_COUNT
                and last_output_proof.log2_target_size == 0,
            "last_output_proof is not an outputs proof"
        )
    end
    self.previous_outputs_frontier =
        hash_tree.frontier(last_output_proof or cartesi.ROLLUP_LOG2_MAX_OUTPUT_COUNT, "keccak256")
    self.outputs_frontier = hash_tree.frontier_copy(self.previous_outputs_frontier)
    return self:move()
end
```

```lua
local function assert_rolling_template(machine)
    assert(
        machine:read_reg("iflags_Y") ~= 0
            and machine:read_reg("htif_tohost_dev") == cartesi.HTIF_DEV_YIELD
            and machine:read_reg("htif_tohost_cmd") == cartesi.HTIF_YIELD_CMD_MANUAL
            and machine:read_reg("htif_tohost_reason") == cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        "initial machine is not waiting on an rx-accepted manual yield"
    )
end
```

### 6.2 Machine calls used

| Call | Use |
|---|---|
| `machine:get_root_hash()` | State hash |
| `machine:read_reg(name)` | `mcycle`, `uarch_cycle`, `iflags_Y`, `iflags_H`, `htif_tohost_*` |
| `machine:run(mcycle_end)` → break reason | Advance the main processor |
| `machine:run_uarch(uarch_cycle_end)` | Advance the uarch within the current mcycle |
| `machine:send_cmio_response(reason, data, revert_root_hash)` | Deliver an input (section 3.4) |
| `machine:receive_cmio_request()` → `cmd, reason, data` | Read a yield: an output, or the outputs Merkle root on accept |
| `machine:log_step_uarch()`, `machine:log_reset_uarch()`, `machine:log_send_cmio_response(...)` | Produce access logs |
| `machine:get_proof(address, log2_size)`, `machine:read_memory(address, length)` | Machine-state proofs for outputs |
| `machine:collect_mcycle_root_hashes(mcycle_end, log2_period, mcycle_phase, log2_bundle_mcycle_count[, partial_bundle])` | Sample an mcycle claim (6.4) |
| `machine:collect_mcycle_bundle(bundle_offset, log2_period, log2_bundle_mcycle_count)` | Recompute one bundle of mcycle samples (6.6) |
| `machine:collect_uarch_cycle_root_hashes(mcycle_end, log2_bundle_uarch_cycle_count[, revert_uarch_tail])` | Sample a uarch claim (6.5) |
| `machine:collect_uarch_cycle_bundle(bundle_offset, log2_bundle_uarch_cycle_count[, revert_uarch_tail])` | Recompute one bundle of uarch leaves (6.6) |
| `machine:fork_server()`, `machine:swap(other)`, `machine:shutdown_server()` | Clones, snapshots, rollback (remote machines) |

Break reasons of interest: `HALTED`, `YIELDED_MANUALLY`,
`YIELDED_AUTOMATICALLY`, `MCYCLE_OVERFLOW`, `REACHED_TARGET_MCYCLE`.

### 6.3 Running an input

One driver serves forward execution, dispute replay, and proof
generation. It delivers the input when leaving offset zero, runs to a
fixed point or to a target mcycle, collects outputs at automatic yields,
and commits or reverts at the terminal manual yield.

```lua
local function load_cmio_input(machine, input_data, revert_root_hash)
    if input_data ~= nil then
        machine:send_cmio_response(HTIF_YIELD_REASON_ADVANCE_STATE, input_data, revert_root_hash)
    end
end

local function begin_input(player, builder, machine, epoch_input_offset, input_data, revert_root_hash)
    local input_mcycle_base = machine:read_reg("mcycle")
    builder.input_mcycle_base = input_mcycle_base
    builder.pending_outputs = {}
    builder.input_result = nil
    builder:begin_input(machine, epoch_input_offset, input_mcycle_base)
    player.machine_cache:snapshot(machine)
    load_cmio_input(machine, input_data, revert_root_hash)
end

local function run_to_stop(builder, machine, mcycle_end, on_yield_automatic)
    while true do
        local break_reason = builder:run(machine, mcycle_end)
        if is_at_fixed_point(break_reason) or is_target_mcycle(break_reason) then
            return break_reason
        elseif is_yielded_automatic(break_reason) then
            if on_yield_automatic then
                local yield_reason, data = receive_cmio_request(machine)
                on_yield_automatic(yield_reason, data)
            end
        end
        -- Other reasons (soft yields or console breaks) just keep going.
    end
end

local function flush_pending_outputs(pending, outputs, outputs_frontier, yield_reason, outputs_merkle_root)
    if not outputs or not is_rx_accepted(yield_reason) then
        return
    end
    for _, output_data in ipairs(pending) do
        outputs[#outputs + 1] = output_data
        hash_tree.frontier_push_back(outputs_frontier, keccak(output_data))
    end
    assert(hash_tree.frontier_get_root_hash(outputs_frontier) == outputs_merkle_root, "outputs Merkle root mismatch")
end
```

```lua
function player_meta.__index:run_to_input_mcycle_offset(
    builder,
    machine,
    epoch_input_offset,
    input_data,
    input_mcycle_offset_begin,
    input_mcycle_offset_end,
    revert_root_hash,
    outputs,
    outputs_frontier
)
    assert(input_mcycle_offset_begin <= input_mcycle_offset_end, "agreed machine is past desired state")
    if input_mcycle_offset_begin == input_mcycle_offset_end then
        return
    end
    if input_mcycle_offset_begin == 0 then
        begin_input(self, builder, machine, epoch_input_offset, input_data, revert_root_hash)
    end
    local input_mcycle_base = builder.input_mcycle_base
    if builder.input_result then
        return builder.input_result.break_reason, builder.input_result.yield_reason, input_mcycle_base
    end
    local on_yield_automatic
    if outputs then
        function on_yield_automatic(yield_reason, output_data)
            if is_tx_output(yield_reason) then
                builder.pending_outputs[#builder.pending_outputs + 1] = output_data
            end
        end
    end
    local mcycle_end = usaturating_add(input_mcycle_base, input_mcycle_offset_end)
    local break_reason = run_to_stop(builder, machine, mcycle_end, on_yield_automatic)
    if not is_at_fixed_point(break_reason) then
        return break_reason, nil, input_mcycle_base
    end
    local yield_reason, outputs_merkle_root
    if is_yielded_manual(break_reason) then
        yield_reason, outputs_merkle_root = receive_cmio_request(machine)
    end
    if is_rx_rejected(yield_reason) then
        self.machine_cache:revert(machine)
        assert(machine:get_root_hash() == revert_root_hash, "rollback did not restore the input boundary")
    else
        flush_pending_outputs(builder.pending_outputs, outputs, outputs_frontier, yield_reason, outputs_merkle_root)
        self.machine_cache:commit(machine)
    end
    builder.pending_outputs = {}
    builder:end_input(machine)
    builder.input_result = { break_reason = break_reason, yield_reason = yield_reason }
    return break_reason, yield_reason, input_mcycle_base
end
```

```lua
function player_meta.__index:run_to_uarch_cycle(
    builder,
    machine,
    epoch_input_offset,
    input_data,
    input_mcycle_offset,
    uarch_cycle_begin,
    uarch_cycle_end,
    revert_root_hash
)
    assert(uarch_cycle_begin <= uarch_cycle_end, "agreed machine is past desired state")
    assert(machine:read_reg("uarch_cycle") <= uarch_cycle_end, "agreed machine is past desired state")
    if uarch_cycle_begin == uarch_cycle_end then
        return
    end
    if input_mcycle_offset == 0 and uarch_cycle_begin == 0 then
        begin_input(self, builder, machine, epoch_input_offset, input_data, revert_root_hash)
    end
    return machine:run_uarch(uarch_cycle_end)
end
```

The `builder` argument decides what is collected along the way. A *null
builder* just runs the machine; the two claim builders of 6.4 and 6.5
sample it.

```lua
function event_handler.input_added(self, epoch_input_offset, path)
    local builder = self.epoch_builder
    self.epoch_builder = nil
    self.input_paths[epoch_input_offset + 1] = path
    local machine, owner <close> = self:clone_at_epoch_input_offset(epoch_input_offset) -- luacheck: ignore 211
    if not self.epoch_stopped then
        local break_reason, yield_reason = self:run_to_input_mcycle_offset(
            builder,
            machine,
            epoch_input_offset,
            util.read_file(path),
            0,
            MAX_MCYCLES_PER_ADVANCE_STATE,
            self.revert_root_hash,
            self.outputs,
            self.outputs_frontier
        )
        if is_rx_accepted(yield_reason) then
            self.revert_root_hash = machine:get_root_hash()
        elseif not is_rx_rejected(yield_reason) then
            assert(is_at_fixed_point(break_reason), "input stopped outside a fixed point")
            self.epoch_stopped = true
        end
    end
    self.machine_cache:consider(epoch_input_offset + 1, machine)
    self.epoch_builder = builder
end
```

```lua
function event_handler.epoch_sealed(self)
    local builder = self.epoch_builder
    self.epoch_builder = nil
    self.mcycle_forest = builder:end_epoch()
    local leaves = map(self.outputs, keccak)
    self.output_proofs = hash_tree.frontier_next_proofs(self.previous_outputs_frontier, leaves)
    self.previous_outputs_frontier = self.outputs_frontier
    self.outputs_frontier = nil
end
```

Replay to a later boundary uses the same driver with the null builder:

```lua
function player_meta.__index:run_to_epoch_input_offset(machine, epoch_input_offset_begin, epoch_input_offset_end)
    local builder = self:make_null_computation_hash_builder()
    epoch_input_offset_end = math.min(epoch_input_offset_end, #self.input_paths)
    -- Keep the expected boundary across rejections. Only acceptance establishes a new one.
    local revert_root_hash = machine:get_root_hash()
    builder:begin_epoch(machine)
    for epoch_input_offset = epoch_input_offset_begin, epoch_input_offset_end - 1 do
        local input_data = util.read_file(self.input_paths[epoch_input_offset + 1])
        local break_reason, yield_reason = self:run_to_input_mcycle_offset(
            builder,
            machine,
            epoch_input_offset,
            input_data,
            0,
            MAX_MCYCLES_PER_ADVANCE_STATE,
            revert_root_hash
        )
        if is_rx_accepted(yield_reason) then
            revert_root_hash = machine:get_root_hash()
        elseif not is_rx_rejected(yield_reason) then
            assert(is_at_fixed_point(break_reason), "input stopped outside a fixed point")
            break
        end
    end
    return builder:end_epoch()
end
```

Rules embodied here:

- `revert_root_hash` is the boundary hash. It advances only on
  acceptance. After a rejection the next input is delivered against the
  same hash.
- A rejection restores the snapshot, and the restored machine's hash
  must equal the revert root hash.
- Outputs of a rejected input are discarded. Accepted outputs are pushed
  onto the outputs frontier, whose root must then equal the root the
  guest reported at the accept yield.
- After an exception, halt, or overflow the epoch has stopped. Later
  inputs are not run; their leaves repeat the stopped state.
- Input files are re-read on replay and must remain readable and
  unchanged for the life of the player, disputes included.

### 6.4 Building the mcycle claim

`machine:collect_mcycle_root_hashes` runs the machine up to `mcycle_end`
and returns:

| Field | Meaning |
|---|---|
| `hashes` | With bundling off, one state hash per sampling point. With `log2_bundle_mcycle_count = b`, one *bundle root* per 2^b consecutive samples |
| `mcycle_phase` | Mcycles elapsed in the current, incomplete period. Pass it back to continue |
| `partial_bundle` | The incomplete bundle, to pass back to continue. Absent at a fixed point |
| `break_reason` | As `machine:run` would return |

Sampling points are 2^p mcycles apart; given a phase, the next is
reached after `2^p - mcycle_phase` mcycles. **At a fixed point**, the
fixed-point state hash is the last sample; with bundling it completes
the current bundle (its remaining positions filled with copies), and
then one more entry is appended: the root of a bundle made only of
copies of the fixed-point hash. That final entry is the *padding value*
and describes repetition, not additional coverage. At an rx-rejected
yield, both are derived from the revert root hash.

```lua
local function mcycle_computation_hash_push_collected(builder, collected)
    local count = #collected.hashes
    local at_fixed_point = is_at_fixed_point(collected.break_reason)
    if at_fixed_point then
        -- The last root describes the fixed-point repetition, not additional coverage.
        builder.pad_bundle = collected.hashes[count]
        count = count - 1
    end
    assert(
        count <= builder.max_bundles_per_input - builder.input_bundle_count,
        "mcycle collection exceeds the input's bundle capacity"
    )
    hash_tree.frontier_forest_append(builder.frontier, collected.hashes, 1, count + 1, builder.bundle_height)
    builder.input_bundle_count = builder.input_bundle_count + count
    if at_fixed_point then
        local pad_count = builder.max_bundles_per_input - builder.input_bundle_count
        hash_tree.frontier_forest_pad_back(builder.frontier, builder.pad_bundle, pad_count, builder.bundle_height)
        builder.input_bundle_count = builder.max_bundles_per_input
    end
end

local function mcycle_computation_hash_begin_epoch(builder, machine)
    builder.frontier = hash_tree.frontier_forest(builder.height, "keccak256")
    builder.input_bundle_count = 0
    local collected =
        machine:collect_mcycle_root_hashes(machine:read_reg("mcycle"), builder.log2_period, 0, builder.bundle_height)
    assert(is_at_fixed_point(collected.break_reason), "mcycle computation hash started outside a fixed point")
    builder.pad_bundle = collected.hashes[#collected.hashes]
end

local function mcycle_computation_hash_begin_input(builder, _, epoch_input_offset)
    builder.epoch_input_offset = epoch_input_offset
    assert(
        hash_tree.frontier_forest_get_leaf_count(builder.frontier) == epoch_input_offset * builder.periods_per_input,
        "mcycle computation hash input is out of order"
    )
    builder.input_bundle_count = 0
    builder.mcycle_phase = 0
    builder.partial_bundle = nil
end

local function mcycle_computation_hash_run(builder, machine, mcycle_end)
    local collected = { mcycle_phase = builder.mcycle_phase, partial_bundle = builder.partial_bundle }
    local chunk_end = machine:read_reg("mcycle")
    repeat
        chunk_end = usaturating_add(chunk_end, builder.collection_chunk_size, mcycle_end)
        collected = machine:collect_mcycle_root_hashes(
            chunk_end,
            builder.log2_period,
            collected.mcycle_phase,
            builder.bundle_height,
            collected.partial_bundle
        )
        mcycle_computation_hash_push_collected(builder, collected)
    until not is_target_mcycle(collected.break_reason) or chunk_end == mcycle_end
    builder.mcycle_phase = collected.mcycle_phase
    builder.partial_bundle = collected.partial_bundle
    return collected.break_reason
end

local function mcycle_computation_hash_end_input(builder)
    assert(builder.input_bundle_count == builder.max_bundles_per_input, "mcycle computation hash input is incomplete")
    builder.input_bundle_count = 0
end

local function mcycle_computation_hash_end_epoch(builder)
    assert(builder.input_bundle_count == 0, "mcycle computation hash input was not closed")
    builder.machine_cache:freeze()
    hash_tree.frontier_forest_pad_back(builder.frontier, builder.pad_bundle, nil, builder.bundle_height)
    return builder.frontier
end
```

```lua
local function make_mcycle_computation_hash_builder(log2_mcycles_per_period, machine_cache)
    local log2_periods_per_input = LOG2_MAX_MCYCLES_PER_ADVANCE_STATE - log2_mcycles_per_period
    local height = LOG2_MAX_ADVANCE_STATES_PER_EPOCH + log2_periods_per_input
    return {
        periods_per_input = 1 << log2_periods_per_input,
        machine_cache = machine_cache,
        height = height,
        bundle_height = LOG2_BUNDLE_MCYCLE_COUNT,
        log2_period = log2_mcycles_per_period,
        collection_chunk_size = mcycle_hashes_collection_chunk_size(log2_mcycles_per_period, LOG2_BUNDLE_MCYCLE_COUNT),
        max_bundles_per_input = (1 << log2_periods_per_input) >> LOG2_BUNDLE_MCYCLE_COUNT,
        begin_epoch = mcycle_computation_hash_begin_epoch,
        begin_input = mcycle_computation_hash_begin_input,
        run = mcycle_computation_hash_run,
        end_input = mcycle_computation_hash_end_input,
        end_epoch = mcycle_computation_hash_end_epoch,
    }
end
```

The model's bundle size is 2^4 samples (`LOG2_BUNDLE_MCYCLE_COUNT = 4`).
Each call collects at most 2^8 bundle roots, to bound temporary storage.

### 6.5 Building a uarch claim

`machine:collect_uarch_cycle_root_hashes` runs uarch cycle by uarch
cycle, resetting the uarch between mcycles, up to `mcycle_end` or a
fixed point, and returns:

| Field | Meaning |
|---|---|
| `hashes` | With bundling off, one state hash after each uarch cycle. With `log2_bundle_uarch_cycle_count = b`, bundle roots of 2^b consecutive leaves |
| `mcycle_hash_offsets` | Half-open offsets delimiting each mcycle's entries in `hashes` |
| `break_reason` | As `machine:run` would return |

Within the entries of one mcycle, `[begin, end)`:

- `hashes[end - 2]` is the state hash after the uarch halted (with
  bundling: the root of a bundle of copies of it). It pads the mcycle up
  to its final entry.
- `hashes[end - 1]` is the state hash immediately after the uarch reset
  (with bundling: the root of the final bundle, which ends with it).

At a fixed point, the call executes one additional mcycle at that fixed
point and returns it as the last range; that range is what the builder
repeats. At an rx-rejected yield, the hash after the final reset is
replaced by the revert root hash, and the extra range returned is that
of the reverted machine, taken from `revert_uarch_tail`.

`revert_uarch_tail` is obtained by calling the same function, with no
bundling, on the boundary machine while it still waits for the input. It
must be captured **before delivery**.

```lua
local function uarch_computation_hash_push_mcycle(builder, frontier, hashes, mcycle_hashes_begin, mcycle_hashes_end)
    local halt_hash = hashes[mcycle_hashes_end - 2]
    local reset_hash = hashes[mcycle_hashes_end - 1]
    local height = LOG2_MAX_UARCH_CYCLES_PER_MCYCLE - builder.bundle_height
    local bundles_per_mcycle = 1 << height
    local transient_bundle_count = mcycle_hashes_end - mcycle_hashes_begin - 2
    hash_tree.frontier_forest_append(
        frontier,
        hashes,
        mcycle_hashes_begin,
        mcycle_hashes_end - 2,
        builder.bundle_height
    )
    hash_tree.frontier_forest_pad_back(
        frontier,
        halt_hash,
        bundles_per_mcycle - 1 - transient_bundle_count,
        builder.bundle_height
    )
    hash_tree.frontier_forest_push_back(frontier, reset_hash, builder.bundle_height)
end

local function uarch_computation_hash_push_collected(builder, collected)
    local offsets = collected.mcycle_hash_offsets
    local available = #offsets - 1
    local log2_cycles = LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
    local remaining = builder.mcycles_per_period - builder.mcycle_count
    local count = available
    local at_fixed_point = is_at_fixed_point(collected.break_reason)
    if at_fixed_point then
        count = count - 1
    end
    assert(count <= remaining, "uarch collection exceeds the claim's mcycle capacity")
    for i = 1, count do
        uarch_computation_hash_push_mcycle(builder, builder.frontier, collected.hashes, offsets[i], offsets[i + 1])
    end
    builder.mcycle_count = builder.mcycle_count + count
    if not at_fixed_point or builder.mcycle_count == builder.mcycles_per_period then
        return
    end
    local pad_frontier = hash_tree.frontier_forest(log2_cycles, "keccak256")
    uarch_computation_hash_push_mcycle(
        builder,
        pad_frontier,
        collected.hashes,
        offsets[available],
        offsets[available + 1]
    )
    hash_tree.frontier_forest_pad_back(builder.frontier, pad_frontier)
    builder.mcycle_count = builder.mcycles_per_period
end
```

So each mcycle contributes: its execution bundles; then copies of the
halted bundle up to the second-to-last position; then the reset-ending
bundle. With bundles of 2^16 transitions an mcycle has 2^4 bundle
positions, of which about three are stored.

```lua
local function uarch_computation_hash_begin_input(builder, machine, epoch_input_offset, input_mcycle_base)
    builder.epoch_input_offset = epoch_input_offset
    builder.input_mcycle_base = input_mcycle_base
    local collected = machine:collect_uarch_cycle_root_hashes(cartesi.MCYCLE_MAX, 0)
    builder.revert_uarch_tail = collected.hashes
    builder.collection_mcycle_begin = usaturating_add(
        builder.input_mcycle_base,
        combine_input_mcycle_offset(builder.mcycles_per_period, builder.input_period_offset, 0)
    )
    builder.collection_mcycle_end = usaturating_add(
        builder.collection_mcycle_begin,
        builder.mcycles_per_period,
        usaturating_add(builder.input_mcycle_base, MAX_MCYCLES_PER_ADVANCE_STATE)
    )
end

local function uarch_computation_hash_run(builder, machine, mcycle_end)
    mcycle_end = umin(mcycle_end, builder.collection_mcycle_end)
    local chunk_end = machine:read_reg("mcycle")
    if math.ult(chunk_end, builder.collection_mcycle_begin) then
        local wanted_mcycle = umin(mcycle_end, builder.collection_mcycle_begin)
        local break_reason = machine:run(wanted_mcycle)
        if not is_target_mcycle(break_reason) or wanted_mcycle ~= builder.collection_mcycle_begin then
            return break_reason
        end
        chunk_end = builder.collection_mcycle_begin
    end
    local collected
    repeat
        chunk_end = usaturating_add(chunk_end, builder.collection_chunk_size, mcycle_end)
        collected = machine:collect_uarch_cycle_root_hashes(chunk_end, builder.bundle_height, builder.revert_uarch_tail)
        builder:push_collected(collected)
    until not is_target_mcycle(collected.break_reason) or chunk_end == mcycle_end
    return collected.break_reason
end

local function uarch_computation_hash_end_input(builder, machine)
    if builder.mcycle_count < builder.mcycles_per_period then
        -- An input stopped before the selected period contributes its fixed-point history.
        -- Rejection has already restored the pre-delivery boundary.
        builder:push_collected(machine:collect_uarch_cycle_root_hashes(cartesi.MCYCLE_MAX, builder.bundle_height))
    end
    assert(builder.mcycle_count == builder.mcycles_per_period, "uarch computation hash is incomplete")
end

local function uarch_computation_hash_begin_epoch(builder)
    builder.frontier = hash_tree.frontier_forest(builder.height, "keccak256")
    builder.mcycle_count = 0
end
```

```lua
local function make_uarch_cycle_computation_hash_builder(log2_mcycles_per_period, epoch_period_offset)
    local periods_per_input = 1 << (LOG2_MAX_MCYCLES_PER_ADVANCE_STATE - log2_mcycles_per_period)
    local _, input_period_offset = split_epoch_period_offset(periods_per_input, epoch_period_offset)
    local height = log2_mcycles_per_period + LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
    return {
        mcycles_per_period = 1 << log2_mcycles_per_period,
        height = height,
        input_period_offset = input_period_offset,
        bundle_height = LOG2_BUNDLE_UARCH_CYCLE_COUNT,
        collection_chunk_size = uarch_hashes_collection_chunk_size(LOG2_BUNDLE_UARCH_CYCLE_COUNT),
        begin_epoch = uarch_computation_hash_begin_epoch,
        begin_input = uarch_computation_hash_begin_input,
        run = uarch_computation_hash_run,
        push_collected = uarch_computation_hash_push_collected,
        end_input = uarch_computation_hash_end_input,
        end_epoch = function(self)
            return self.frontier
        end,
    }
end
```

```lua
function player_meta.__index:build_uarch_claim(epoch_input_offset, input_period_offset)
    local machine, _ <close> = self:clone_at_epoch_input_offset(epoch_input_offset)
    local revert_root_hash = machine:get_root_hash()
    local builder = self:make_uarch_cycle_computation_hash_builder(
        combine_epoch_period_offset(self.geometry.periods_per_input, epoch_input_offset, input_period_offset)
    )
    builder:begin_epoch(machine)
    local path = self.input_paths[epoch_input_offset + 1]
    self:run_to_input_mcycle_offset(
        builder,
        machine,
        epoch_input_offset,
        path and util.read_file(path),
        0,
        (input_period_offset + 1) * self.geometry.mcycles_per_period,
        revert_root_hash
    )
    return builder:end_epoch()
end
```

### 6.6 Storing a claim

A claim tree has 2^62 or 2^30 leaves. Two facts make it storable.

**Repetition.** A subtree of 2^k identical leaves *h* has root
`r_k`, where `r_0 = h` and `r_(i+1) = keccak(r_i, r_i)`: *k* hashes.

**Bundles.** The player stores bundle roots, which are interior nodes of
the claim tree, and reconstructs a bundle's leaves by replaying a
machine only when a query descends below one.

The model's container is a *frontier forest*: an appendable Merkle
accumulator of fixed height that retains the complete subtrees it has
built, so that a finished forest can answer node and proof queries.
Appended values accumulate in a pending array whose last value
implicitly fills any padded positions; they are materialized as maximal
aligned complete subtrees and folded upward by binary carry. Each level
of a materialized subtree stores its distinct nodes plus the first
repeated one, and an index past the end of a level reads its last entry.

```lua
local function new_dense_tree(hash_function, base_height, log2_count, values, first)
    first = math.min(first, #values)
    local tree = { table.move(values, first, math.min(first + (1 << log2_count) - 1, #values), 1, {}) }
    for relative_height = 1, log2_count do
        local children = tree[relative_height]
        local parents = {}
        for i = 1, math.min((#children >> 1) + 1, 1 << (log2_count - relative_height)) do
            local left = get_or_last(children, 2 * i - 2)
            local right = get_or_last(children, 2 * i - 1)
            parents[i] = hash_function(get_value_hash(left), get_value_hash(right))
        end
        tree[relative_height + 1] = parents
    end
    tree.kind = "dense"
    tree.height = base_height + log2_count
    tree.base_height = base_height
    tree.hash = get_value_hash(tree[#tree][1])
    return tree
end
```

| Operation | Contract |
|---|---|
| `frontier_forest(height, "keccak256")` | An empty forest for 2^height leaves; height below 63 |
| `frontier_forest_append(forest, hashes, begin, end, hash_height)` | Append `hashes[begin, end)`, each the root of a subtree of `hash_height` |
| `frontier_forest_push_back(forest, value, value_height)` | Append one hash, or one completed forest as a subtree |
| `frontier_forest_pad_back(forest, value, count, value_height)` | Append `count` copies of a hash or completed forest; omit `count` to fill the forest |
| `frontier_forest_get_leaf_count(forest)` | Leaves covered so far |
| `frontier_forest_get_root_hash(forest)` | Root of a full forest |
| `frontier_forest_get_node_hash(forest, position, height)` | Node hash, or `nil` plus a message if the node lies below an opaque (unexpanded) hash |
| `frontier_forest_get_siblings(forest, position, height)` | Proof siblings from that node upward, or `nil` plus a message likewise |
| `frontier_forest_expand_leaf(forest, position, subtree)` | Replace an opaque hash by a completed forest of the same height **after checking its root equals the committed hash**. Repeated occurrences share the expansion |

Any structure that can answer `get_node_hash(position, height)` and
`get_siblings(position, height)` for the committed tree will do.

The model's claim tree is a forest plus a callback that reconstructs one
bundle:

```lua
local function open_bundle(tree, position)
    local bundle_index = position >> tree.bundle_height
    local bundle = tree:collect_bundle(bundle_index)
    hash_tree.frontier_forest_expand_leaf(tree.forest, bundle_index << tree.bundle_height, bundle)
end

function tree_meta.__index:get_node_hash(position, height)
    local hash = hash_tree.frontier_forest_get_node_hash(self.forest, position, height)
    if not hash then
        open_bundle(self, position)
        hash = assert(hash_tree.frontier_forest_get_node_hash(self.forest, position, height))
    end
    return hash
end

function tree_meta.__index:get_proof(position, height)
    height = height or 0
    local siblings = hash_tree.frontier_forest_get_siblings(self.forest, position, height)
    if not siblings then
        open_bundle(self, position)
        siblings = assert(hash_tree.frontier_forest_get_siblings(self.forest, position, height))
    end
    return {
        target_address = position,
        log2_target_size = height,
        target_hash = self:get_node_hash(position, height),
        log2_root_size = self.height,
        root_hash = self:get_root_hash(),
        sibling_hashes = siblings,
    }
end

function tree_meta.__index:get_child_hashes(position, height)
    local child_height = height - 1
    return self:get_node_hash(position, child_height), self:get_node_hash(position + (1 << child_height), child_height)
end
```

```lua
function player_meta.__index:make_mcycle_tree()
    return new_tree(
        self.geometry.mcycle_height,
        LOG2_BUNDLE_MCYCLE_COUNT,
        self.mcycle_forest,
        function(_, epoch_bundle_offset)
            local bundles_per_input = self.geometry.periods_per_input >> LOG2_BUNDLE_MCYCLE_COUNT
            local epoch_input_offset = epoch_bundle_offset // bundles_per_input
            local input_bundle_offset = epoch_bundle_offset % bundles_per_input
            return self:collect_mcycle_bundle(epoch_input_offset, input_bundle_offset)
        end
    )
end

function player_meta.__index:make_uarch_tree(epoch_input_offset, input_period_offset)
    return new_tree(
        self.geometry.uarch_height,
        LOG2_BUNDLE_UARCH_CYCLE_COUNT,
        self:build_uarch_claim(epoch_input_offset, input_period_offset),
        function(_, period_bundle_offset)
            return self:collect_uarch_cycle_bundle(epoch_input_offset, input_period_offset, period_bundle_offset)
        end
    )
end
```

Reconstructing a bundle:

```lua
function player_meta.__index:collect_mcycle_bundle(epoch_input_offset, input_bundle_offset)
    local machine, _ <close> = self:clone_at_epoch_input_offset(epoch_input_offset)
    local revert_root_hash = machine:get_root_hash()
    local builder = self:make_null_computation_hash_builder()
    -- Deliver the input and stay at its boundary. The machine advances to the bundle and pads it
    -- with its fixed-point state hash when the input stops early.
    local path = self.input_paths[epoch_input_offset + 1]
    begin_input(self, builder, machine, epoch_input_offset, path and util.read_file(path), revert_root_hash)
    local hashes = machine:collect_mcycle_bundle(
        input_bundle_offset,
        self.geometry.log2_mcycles_per_period,
        LOG2_BUNDLE_MCYCLE_COUNT
    )
    local forest = hash_tree.frontier_forest(LOG2_BUNDLE_MCYCLE_COUNT, "keccak256")
    hash_tree.frontier_forest_append(forest, hashes, 1, #hashes + 1)
    return forest
end
```

```lua
function player_meta.__index:collect_uarch_cycle_bundle(epoch_input_offset, input_period_offset, period_bundle_offset)
    local machine, _ <close> = self:clone_at_epoch_input_offset(epoch_input_offset)
    local revert_root_hash = machine:get_root_hash()
    local tail = machine:collect_uarch_cycle_root_hashes(cartesi.MCYCLE_MAX, 0)
    local revert_uarch_tail = tail.hashes
    local bundles_per_mcycle = 1 << (LOG2_MAX_UARCH_CYCLES_PER_MCYCLE - LOG2_BUNDLE_UARCH_CYCLE_COUNT)
    local period_mcycle_offset = period_bundle_offset // bundles_per_mcycle
    local bundle_offset = period_bundle_offset % bundles_per_mcycle
    local builder = self:make_null_computation_hash_builder()
    local path = self.input_paths[epoch_input_offset + 1]
    local input_data = path and util.read_file(path)
    local input_mcycle_offset =
        combine_input_mcycle_offset(self.geometry.mcycles_per_period, input_period_offset, period_mcycle_offset)
    if input_mcycle_offset == 0 then
        begin_input(self, builder, machine, epoch_input_offset, input_data, revert_root_hash)
    else
        self:run_to_input_mcycle_offset(
            builder,
            machine,
            epoch_input_offset,
            input_data,
            0,
            input_mcycle_offset,
            revert_root_hash
        )
    end
    -- Replay may already have rolled back a rejected input. Its restored boundary
    -- supplies the same uarch history as the tail captured before delivery.
    local hashes = machine:collect_uarch_cycle_bundle(bundle_offset, LOG2_BUNDLE_UARCH_CYCLE_COUNT, revert_uarch_tail)
    local forest = hash_tree.frontier_forest(LOG2_BUNDLE_UARCH_CYCLE_COUNT, "keccak256")
    hash_tree.frontier_forest_append(forest, hashes, 1, #hashes + 1)
    return forest
end
```

`machine:collect_mcycle_bundle` advances from the current mcycle to the
start of the selected bundle and returns its 2^b samples, filling with
the fixed-point hash if the machine stops first.
`machine:collect_uarch_cycle_bundle` returns the 2^b leaves of the
selected bundle of the *current* mcycle, following the same rules as the
stream collector without bundling.

### 6.7 Answering the referee

```lua
local function make_claim(tree)
    local final_leaf_index = (1 << tree.height) - 1
    local computation_hash_left, computation_hash_right = tree:get_child_hashes(0, tree.height)
    local final_state_hash_proof = tree:get_proof(final_leaf_index)
    return {
        computation_hash_left = computation_hash_left,
        computation_hash_right = computation_hash_right,
        final_state_hash_proof = final_state_hash_proof,
    }
end

function event_handler.commit_mcycle_claim(self)
    local tree = self:make_mcycle_tree()
    self.trees[tree:get_root_hash()] = tree
    return make_claim(tree)
end

function event_handler.commit_uarch_claim(self, epoch_input_offset, input_period_offset)
    local tree = self:make_uarch_tree(epoch_input_offset, input_period_offset)
    self.trees[tree:get_root_hash()] = tree
    return make_claim(tree)
end
```

```lua
function event_handler.reveal_bisection(self, computation_hash, position, height, other_left_node)
    local tree = self.trees[computation_hash]
    local turn_left_node, turn_right_node = tree:get_child_hashes(position, height)
    local descend_left = turn_left_node ~= other_left_node
    local child_position = descend_left and position or position + (1 << (height - 1))
    local turn_next_left_node, turn_next_right_node = tree:get_child_hashes(child_position, height - 1)
    return {
        turn_left_node = turn_left_node,
        turn_right_node = turn_right_node,
        turn_next_left_node = turn_next_left_node,
        turn_next_right_node = turn_next_right_node,
    }
end
```

```lua
function event_handler.seal_divergence(self, computation_hash, position, other_left_node)
    local tree = self.trees[computation_hash]
    local turn_left_node, turn_right_node = tree:get_child_hashes(position, 1)
    local response = { turn_left_node = turn_left_node, turn_right_node = turn_right_node }
    local descend_left = turn_left_node ~= other_left_node
    local leaf_index = position + (descend_left and 0 or 1)
    if leaf_index ~= 0 then
        local agreed_leaf_index = leaf_index - 1
        response.agreed_state_hash_proof = tree:get_proof(agreed_leaf_index)
        assert(
            descend_left or response.agreed_state_hash_proof.target_hash == turn_left_node,
            "right divergence has the wrong agreed state"
        )
    end
    return response
end
```

```lua
function event_handler.prove_state_transition(self, epoch_input_offset, input_period_offset, state_transition_offset)
    local period_mcycle_offset, uarch_cycle = split_state_transition_offset(state_transition_offset)
    local machine, _ <close> = self:clone_at_epoch_input_offset(epoch_input_offset)
    local revert_root_hash = machine:get_root_hash()
    local path = self.input_paths[epoch_input_offset + 1]
    local input_data = path and util.read_file(path)
    if state_transition_offset == 0 and input_period_offset == 0 and path then
        -- Logging never fails. A machine that is not waiting for the input logs the no-op delivery.
        local send_cmio_log =
            machine:log_send_cmio_response(HTIF_YIELD_REASON_ADVANCE_STATE, input_data, revert_root_hash)
        return { send_cmio_log = send_cmio_log, step_log = machine:log_step_uarch() }
    end
    local builder = self:make_null_computation_hash_builder()
    local input_mcycle_offset =
        combine_input_mcycle_offset(self.geometry.mcycles_per_period, input_period_offset, period_mcycle_offset)
    self:run_to_input_mcycle_offset(
        builder,
        machine,
        epoch_input_offset,
        input_data,
        0,
        input_mcycle_offset,
        revert_root_hash
    )
    self:run_to_uarch_cycle(
        builder,
        machine,
        epoch_input_offset,
        input_data,
        input_mcycle_offset,
        0,
        uarch_cycle,
        revert_root_hash
    )
    if uarch_cycle == UARCH_CYCLE_MAX then
        local step_log = machine:log_step_uarch()
        return { step_log = step_log, reset_uarch_log = machine:log_reset_uarch() }
    end
    return { step_log = machine:log_step_uarch() }
end
```

```lua
function event_handler.schedule_match_timeout_win(self, deadline, computation_hash)
    return prtu.schedule_response(self, deadline, function()
        local tree = self.trees[computation_hash]
        local left, right = tree:get_child_hashes(0, tree.height)
        return { computation_hash_left = left, computation_hash_right = right }
    end)
end

function event_handler.schedule_match_elimination(self, deadline)
    return prtu.schedule_response(self, deadline, function()
        return {}
    end)
end
```

A player keeps every tree it has committed, indexed by computation hash
(`self.trees`). Successive opponents can open uarch tournaments over
different periods, each needing its own uarch claim, and earlier ones
must be retained.

### 6.8 Checkpoints

A checkpoint is the machine at an input boundary, before delivery.
Callers ask for a boundary, not for a checkpoint: the cache clones the
nearest earlier one and replays the inputs in between.

```lua
function machine_cache_meta.__index:clone_at_epoch_input_offset(epoch_input_offset, run_to_epoch_input_offset)
    assert(not self.closed, "machine cache is closed")
    local closest = self.checkpoints[1]
    for i = 2, #self.checkpoints do
        if self.checkpoints[i].epoch_input_offset > epoch_input_offset then
            break
        end
        closest = self.checkpoints[i]
    end
    if
        self.latest.epoch_input_offset <= epoch_input_offset
        and self.latest.epoch_input_offset >= closest.epoch_input_offset
    then
        closest = self.latest
    end
    local machine, owner <close> = new_machine_owner(self, fork_server(closest.machine))
    run_to_epoch_input_offset(machine, closest.epoch_input_offset, epoch_input_offset)
    return machine, owner:move()
end
```

```lua
local function update_latest(self, epoch_input_offset, machine)
    local latest = self.latest
    if machine:get_root_hash() == latest.machine:get_root_hash() then
        latest.epoch_input_offset = epoch_input_offset
    else
        local clone, owner <close> = new_machine_owner(self, fork_server(machine))
        self.latest = { epoch_input_offset = epoch_input_offset, machine = clone, owner = owner:move() }
        latest.owner:close()
    end
end

local function update_checkpoints(self, epoch_input_offset, machine)
    local checkpoints = self.checkpoints
    local last_checkpoint = checkpoints[#checkpoints]
    if epoch_input_offset - last_checkpoint.epoch_input_offset < self.input_gap then
        return
    end
    local replace_index
    if #checkpoints == self.capacity then
        replace_index = self.replace_cursor
        while replace_index <= #checkpoints do
            local previous = checkpoints[replace_index - 1].epoch_input_offset
            if checkpoints[replace_index].epoch_input_offset - previous < self.input_gap then
                break
            end
            replace_index = replace_index + 1
        end
        if replace_index > #checkpoints then
            self.input_gap = self.input_gap << 1
            self.replace_cursor = 2
            return
        end
    end
    local clone, owner <close> = new_machine_owner(self, fork_server(machine))
    if replace_index then
        local replaced = table.remove(checkpoints, replace_index)
        replaced.owner:close()
        self.replace_cursor = replace_index
    end
    checkpoints[#checkpoints + 1] = { epoch_input_offset = epoch_input_offset, machine = clone, owner = owner:move() }
end

function machine_cache_meta.__index:consider(epoch_input_offset, machine)
    assert(not self.closed, "machine cache is closed")
    if self.frozen then
        return
    end
    assert(
        math.type(epoch_input_offset) == "integer" and epoch_input_offset > self.latest.epoch_input_offset,
        "machine checkpoints are not ordered"
    )
    local working_owner = self.owners[machine]
    assert(not working_owner or not working_owner.backup, "input boundary has a pending rollback snapshot")
    update_latest(self, epoch_input_offset, machine)
    update_checkpoints(self, epoch_input_offset, machine)
end
```

Policy: boundary zero is always kept; the latest boundary is always
kept, as one extra machine; up to `capacity` historical boundaries
(default 8, boundary zero included) are kept with a minimum gap between
them that doubles each time the set is full. The cache also holds the
per-machine rollback snapshot used by `snapshot`, `commit` and `revert`.

Checkpoints are an optimization. With only the initial snapshot and the
stored forest, replay must reproduce the same claim. What checkpoints
buy is answering within the response window.

### 6.9 Outputs

The guest maintains the outputs Merkle tree and, at each accept, writes
its root into the CMIO transmit buffer. The host mirrors it with a
*frontier*: the roots of the complete left subtrees standing over the
leaves so far, one per set bit of the leaf count.

```lua
local function frontier_push_back(frontier, hash, height)
    local hash_function = assert(frontier.hash_function)
    local level = (height or 0) + 1
    assert_aligned_below(frontier, level, "frontier is not aligned to the subtree size")
    assert(not frontier[#frontier], "too many leaves")
    local right = hash
    while frontier[level] do
        right = hash_function(frontier[level], right)
        frontier[level] = false
        level = level + 1
    end
    frontier[level] = right
end
```

```lua
local function frontier_get_root_hash(frontier, pad, pad_height)
    local hash_function = assert(frontier.hash_function)
    local height = #frontier - 1
    if frontier[height + 1] then return frontier[height + 1] end
    pad = pad or pristine_leaf
    local root = pad
    assert_aligned_below(frontier, (pad_height or 0) + 1, "frontier is not aligned to the pad size")
    -- pad doubles into the all-pad subtree of each level, the right sibling of every empty one
    for level = (pad_height or 0) + 1, height do
        if frontier[level] then
            root = hash_function(frontier[level], root)
        else
            root = hash_function(root, pad)
        end
        pad = hash_function(pad, pad)
    end
    return root
end
```

At the seal, the proofs of the epoch's outputs are built in one batch
from the frontier as it stood when the epoch began:

```lua
local function frontier_node(frontier_entry, base, active, pristine_entry, index)
    local lo, hi = base, base + #active - 1
    if index < lo then
        return frontier_entry -- fell left: a complete left subtree from the frontier
    elseif index > hi then
        return pristine_entry -- fell right: an all-pristine subtree
    else
        return active[index - lo + 1] -- inside the active region
    end
end
```

```lua
local function frontier_next_proofs(frontier, next_output_hashes)
    local hash_function = assert(frontier.hash_function)
    local log2_max_leaves = #frontier - 1
    local next_output_count = #next_output_hashes
    if next_output_count == 0 then return {} end
    local leaf_count = frontier_get_leaf_count(frontier)
    -- Allocate each proof's sibling array.
    local siblings = {}
    for i = 1, next_output_count do
        siblings[i] = {}
    end
    -- Start with the new leaves at their global indices.
    local active = next_output_hashes
    local base = leaf_count
    -- Track the pristine subtree at the current level.
    local pristine = pristine_leaf
    for level = 1, log2_max_leaves do
        local bit = level - 1
        local frontier_entry = frontier[level]
        -- Add each output's sibling at this level.
        for i = 1, next_output_count do
            local node = (leaf_count + i - 1) >> bit
            siblings[i][level] = frontier_node(frontier_entry, base, active, pristine, node ~ 1)
        end
        -- Hash the active nodes into their parents.
        local parents = {}
        local parents_base = base >> 1
        for p = parents_base, (base + #active - 1) >> 1 do
            local left = frontier_node(frontier_entry, base, active, pristine, 2 * p)
            local right = frontier_node(frontier_entry, base, active, pristine, 2 * p + 1)
            parents[p - parents_base + 1] = hash_function(left, right)
        end
        active, base = parents, parents_base
        pristine = hash_function(pristine, pristine)
    end
    -- The final active node is the root.
    local root_hash = active[1]
    local proofs = {}
    for i = 1, next_output_count do
        proofs[i] = {
            target_address = leaf_count + i - 1,
            log2_target_size = 0,
            log2_root_size = log2_max_leaves,
            target_hash = next_output_hashes[i],
            root_hash = root_hash,
            sibling_hashes = siblings[i],
        }
    end
    return proofs
end
```

The frontier that starts an epoch is empty at genesis, or is rebuilt
from the previous epoch's last output proof:

```lua
local function frontier(log2_max_leaves_or_last_proof, hash_type)
    assert(hash_type ~= nil, "hash type is required")
    if is_proof(log2_max_leaves_or_last_proof) then
        local proof = log2_max_leaves_or_last_proof
        local log2_max_leaves = proof.log2_root_size
        local f = frontier_genesis(log2_max_leaves, hash_type)
        local hash_function = f.hash_function
        local leaf_count = proof.target_address + 1
        local lowest_complete_level = 1
        while (leaf_count & (1 << (lowest_complete_level - 1))) == 0 do
            lowest_complete_level = lowest_complete_level + 1
        end
        -- Above the lowest complete level, where the leaf count's bit at that level is set, the last leaf
        -- is a right child, so its proof sibling there is exactly the complete left subtree we need.
        for level = lowest_complete_level + 1, log2_max_leaves do
            local bit = level - 1
            if (leaf_count & (1 << bit)) ~= 0 then f[level] = proof.sibling_hashes[level] end
        end
        -- At the lowest complete level, the last leaf is a right child at every lower level, so rolling it
        -- up through the siblings below rebuilds that level's complete left subtree, which ends at the leaf
        -- count.
        local hash = proof.target_hash
        for level = 1, lowest_complete_level - 1 do
            hash = hash_function(proof.sibling_hashes[level], hash)
        end
        f[lowest_complete_level] = hash
        return f
    end
    return frontier_genesis(log2_max_leaves_or_last_proof, hash_type)
end
```

**From the settled state hash to the outputs root.** Three words of the
final machine state are proven:

```lua
local function get_machine_leaf(machine, address)
    local target_address = address & ~WORD_MASK
    return machine:read_memory(target_address, WORD_SIZE),
        machine:get_proof(target_address, cartesi.HASH_TREE_LOG2_WORD_SIZE)
end

local function get_outputs_merkle_root_proof(machine)
    local iflags_y_data, iflags_y_proof = get_machine_leaf(machine, IFLAGS_Y_ADDRESS)
    local htif_tohost_data, htif_tohost_proof = get_machine_leaf(machine, HTIF_TOHOST_ADDRESS)
    local tx_buffer_data, tx_buffer_proof = get_machine_leaf(machine, CMIO_TX_BUFFER_ADDRESS)
    return {
        iflags_y_data = iflags_y_data,
        iflags_y_proof = iflags_y_proof,
        htif_tohost_data = htif_tohost_data,
        htif_tohost_proof = htif_tohost_proof,
        tx_buffer_data = tx_buffer_data,
        tx_buffer_proof = tx_buffer_proof,
    }
end

function event_handler.prove_outputs_merkle_root(self)
    local machine, owner <close> = self:clone_at_epoch_input_offset(#self.input_paths) -- luacheck: ignore 211
    return get_outputs_merkle_root_proof(machine)
end
```

```lua
local function verify_machine_word(data, proof, address, final_state_hash)
    assert(proof.root_hash == final_state_hash, "machine word proof root mismatch")
    assert(proof.log2_root_size == cartesi.HASH_TREE_LOG2_ROOT_SIZE, "machine word proof not whole-machine")
    assert(proof.target_address == (address & ~WORD_MASK), "machine word proof address mismatch")
    assert(proof.log2_target_size == cartesi.HASH_TREE_LOG2_WORD_SIZE, "machine word proof target not a word")
    assert(#data == 1 << proof.log2_target_size, "machine word data not a word")
    assert(hash_tree.get_data_root_hash(data, proof.log2_target_size) == proof.target_hash, "word data hash mismatch")
    hash_tree.verify_slice(proof)
end

local function get_uint64(data, offset)
    return string.unpack("<I8", data, 1 + offset)
end

local function split_tohost(tohost)
    local dev = (tohost & cartesi.HTIF_DEV_MASK) >> cartesi.HTIF_DEV_SHIFT
    local cmd = (tohost & cartesi.HTIF_CMD_MASK) >> cartesi.HTIF_CMD_SHIFT
    local reason = (tohost & cartesi.HTIF_REASON_MASK) >> cartesi.HTIF_REASON_SHIFT
    return dev, cmd, reason
end

local function validate_outputs_merkle_root_response(result, final_state_hash)
    verify_machine_word(result.iflags_y_data, result.iflags_y_proof, IFLAGS_Y_ADDRESS, final_state_hash)
    assert(get_uint64(result.iflags_y_data, IFLAGS_Y_ADDRESS & WORD_MASK) ~= 0, "final state not yielded")

    verify_machine_word(result.htif_tohost_data, result.htif_tohost_proof, HTIF_TOHOST_ADDRESS, final_state_hash)
    local htif_tohost = get_uint64(result.htif_tohost_data, HTIF_TOHOST_ADDRESS & WORD_MASK)
    local dev, cmd, reason = split_tohost(htif_tohost)
    assert(dev == cartesi.HTIF_DEV_YIELD, "tohost not a yield")
    assert(cmd == cartesi.HTIF_YIELD_CMD_MANUAL, "yield not manual")
    assert(reason == cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, "yield reason not rx-accepted")

    verify_machine_word(result.tx_buffer_data, result.tx_buffer_proof, CMIO_TX_BUFFER_ADDRESS, final_state_hash)
    return result.tx_buffer_data
end
```

| Word | Establishes |
|---|---|
| `iflags_Y` | The machine has yielded manually |
| `htif_tohost` | The yield is from the yield device, manual, with reason rx-accepted |
| First word of the CMIO transmit buffer | Its 32 bytes are the outputs Merkle root |

**From the outputs root to one output.**

```lua
function player_meta.__index:prove_output(output_index)
    assert(math.type(output_index) == "integer", "invalid output index")
    local index = output_index - hash_tree.frontier_get_leaf_count(self.previous_outputs_frontier) + #self.outputs + 1
    if index < 1 or index > #self.outputs then
        return {}
    end
    return {
        output_index = output_index,
        output_data = self.outputs[index],
        output_proof = self.output_proofs[index],
    }
end
```

```lua
local function validate_output_response(output, outputs_merkle_root)
    local output_proof = output.output_proof
    assert(output.output_index == output_proof.target_address, "output proof index mismatch")
    assert(output_proof.log2_target_size == 0, "output proof target not a leaf")
    assert(output_proof.log2_root_size == cartesi.ROLLUP_LOG2_MAX_OUTPUT_COUNT, "output proof height mismatch")
    assert(output_proof.root_hash == outputs_merkle_root, "output proof root mismatch")
    assert(keccak(output.output_data) == output_proof.target_hash, "output hash mismatch")
    hash_tree.verify_slice(output_proof)
    return output
end
```

The outputs tree is cumulative across epochs and is never reset. An
epoch with no outputs still settles its outputs root.

```lua
local function wait_for_outputs(final_state_hash)
    local root_proof <close> = request_first_valid(
        EVERYONE,
        EVENTS.prove_outputs_merkle_root,
        { final_state_hash },
        function(response)
            return validate_outputs_merkle_root_response(response, final_state_hash)
        end
    )
    local outputs_merkle_root = root_proof:wait_at_most(FOREVER)
    local accepted_output_indices = {}
    while true do
        local output_proof <close> = request_first_valid(
            EVERYONE,
            EVENTS.prove_output,
            { outputs_merkle_root },
            function(response)
                if not accepted_output_indices[response.output_index] then
                    return validate_output_response(response, outputs_merkle_root)
                end
            end
        )
        local output = output_proof:wait_at_most(FOREVER)
        accepted_output_indices[output.output_index] = true
        story.report_output(output)
    end
end
```

### 6.10 Easy to get wrong

- **Leaf convention.** A leaf is the state *after* its stretch. Off by
  one here and every proof is at the wrong index.
- **Sibling order.** `sibling_hashes[1]` is the target's own sibling;
  the list runs bottom-up.
- **The seal's proof index** is `leaf_index - 1`, at full tree height,
  against the on-turn claim's root, and is omitted only for leaf 0.
- **Descent direction** is decided by comparing *left* children only.
- **Deadlines are exclusive.** A response at the deadline block is late.
- **The revert tail** must be captured from the boundary machine before
  the input is delivered.
- **The revert root hash** advances only on acceptance.
- **Fixed points repeat at mcycle boundaries only.** Within a
  fixed-point mcycle the uarch still runs and resets.
- **Running out the slot is mcycle overflow**, a fixed point: `mcycle`
  reaches the `imcyclemax` that delivery set.
- **Delivery to a machine that cannot take input is a no-op**, and must
  be logged as one.
- **The final transition proof** is due before the *earlier* of the two
  deadlines.
- **Opened bundles must be authenticated** against the committed root
  before use.
- **Holding the same commitment as someone else** does not make their
  deposit yours (section 7).

---

## 7. On a real chain

The Lua referee is one trusted process. In production the referee is a
family of contracts, *Dave*. This section is informative. Its event
mapping is a design proposal for a node built around the model's player,
and names fields that the contracts may not emit as written. Treat the
deployed contracts as the authority.

### 7.1 How the model differs from the contracts

| Aspect | Model | Contracts |
|---|---|---|
| Referee | One process | Contracts executed by the chain |
| Bonds | None | Joining a tournament requires a bond, which the claimer of the winning commitment recovers |
| Pairing | Claims gathered, then paired in rounds in admission order | A claim is paired with whichever is waiting as it arrives; a winner is paired with the next to arrive |
| Clocks | Logical blocks; equal clocks per level; response budget equal to the allowance, so no clock runs down | Full chess-clock accounting |
| Silence | A timeout needs a disconnect or a scheduled response; a silent connected player stalls the run | Timeouts follow chain time |
| Inner result | Applied to the parent match immediately | A separate call with its own window; an unpropagated winner expires |
| Levels and size | Two levels; the geometry of section 1 | Its own constants; the production dispute covers a larger epoch but is otherwise analogous |
| Joining | A fixed audience; claims gathered until the joining deadline, then matches start | A tournament stays open for joining for its whole allowance while matches already run; a late claim may meet one that has already won |
| Duplicate claims | Merged; every poster is subscribed to the claim | A commitment can be joined only once per tournament; a second join reverts, and the first joiner is the claimer |
| Addressing | Requests routed to the holders of a claim | Events are public; each node derives its own actions |

Function names in the model follow their on-chain counterparts where one
exists: the walk follows the match contract, the seal `sealDivergence`,
the join check `joinTournament`, the contested-final-state rule
`validContestedFinalState`, and the transition kinds the Cartesi
state-transition contract.

### 7.2 Geometry of a deployment

The model's player handles two levels only. A node built on it should
validate the deployment's tournament table before computing or joining
anything, and must refuse a table it cannot serve:

- exactly two levels;
- root height plus root stride exponent equal to 92;
- leaf stride exponent zero;
- leaf height equal to the root stride exponent;
- both heights below 63.

Then *p* is the root stride exponent (`log2step`) minus 20. The exact
heights and strides are a deployment choice; a two-level table with
heights 55 and 37, for example, gives *p* = 17. With this geometry the
contracts address the epoch with a single 92-bit *meta-cycle*, which
splits into the player's coordinates as:

```text
input_index             = cycle >> 68
mcycle_in_input         = (cycle >> 20) & (2^48 - 1)
period_index            = mcycle_in_input >> log2_period
state_transition_offset =
    ((mcycle_in_input & (2^log2_period - 1)) << 20) |
    (cycle & (2^20 - 1))
```

A leaf position converts to a cycle as
`baseCycle + (position << log2Stride)`.

### 7.3 From events to actions (proposed)

**This table describes proposed events, not the deployed ones.** At the
baseline the proposal was written against, the contracts emit less: `MatchCreated` carries the two
commitments, the left child of the second and `eliminableAt`;
`MatchAdvanced` carries the match id, the other parent, the left node,
the segment start position and `eliminableAt`, with no height;
`LeafMatchSealed` and `NewInnerTournament` carry little beyond the match
id (and the child tournament). Heights, the agreed state, the contested
final states and the responder deadlines must today be folded from earlier events
or read from the contracts' views. The fields shown below are what a
node would need in order to act on each event alone.

H is the tournament height from its descriptor. "Holder of x" means the
node holds commitment x. "Claimer of x" means the node's own join
established x.

| Event | Action | Computation | Window |
|---|---|---|---|
| `InputAdded` | Verify and store the input | `input_added` on the open epoch's player | as inputs arrive |
| `EpochSealed` with its root tournament | Join the root tournament | `epoch_sealed`, then `commit_mcycle_claim` | before the joining deadline (`startInstant + allowance`) |
| `MatchCreated(one, two, leftOfTwo, …)` | Holder of `one` responds at height H, position 0; holder of `two` may win by timeout; anyone may eliminate | `reveal_bisection(one, 0, H, leftOfTwo)`, or `seal_divergence` when H is 1 | respond before the responder deadline; timeout in [deadline, eliminableAt); eliminate from eliminableAt |
| `MatchAdvanced(…, leftNode, pos, currentHeight, …)` | Responder is `one` when H − currentHeight is even, else `two`; same three actions | `reveal_bisection(r, pos, currentHeight, leftNode)`, or `seal_divergence(r, pos, leftNode)` at height 1 | same |
| `LeafMatchSealed(…, agreeState, pos, f1, f2, d1, d2, …)` | Either holder proves; holder of the longer clock may win by timeout; anyone may eliminate | `prove_state_transition` at the split of `baseCycle + (pos << log2Stride)` | prove before min(d1, d2); timeout in [min, max); eliminate from max |
| `NewInnerTournament(child, one, two, f1, f2, …)` | Holders of `one` or `two` join the child; everyone watches it | `commit_uarch_claim(input_index, period_index, {f1, f2})` | before the child's joining deadline |
| `MatchDeleted` | Cancel that match's actions | none | |
| Child tournament finished | Holder of the parent-side claim propagates the winner to the parent; anyone eliminates after expiry; the claimer recovers its bond | the parent claim's root children | propagate before the winner expires |
| Root tournament finished | Holder of the winning claim stages the result; the claimer recovers its bond. Staging is followed by a staging period before the result is accepted | `prove_outputs_merkle_root` | from the result instant |

### 7.4 What a node must add to the player

- **Chain observation.** Fetch logs for the consensus, the factory, the
  epoch's root tournament, and every child discovered through events;
  apply them in block, transaction and log order; tolerate reorgs by
  re-deriving actions from a consistent head.
- **Timing under real clocks.** Computation time consumes allowance.
  Refresh the observation after computing and before sending.
- **Claim persistence.** Persist the forest, heights, expected root,
  root children and final-state proof, bound to the deployment, the
  epoch's initial hash, the exact inputs, the geometry, and, for a uarch
  claim, its input and period. On restart, rebuild the tree with fresh
  bundle-collection callbacks and re-verify the root. A saved
  computation hash alone does not restore the ability to answer.
- **Successive opponents.** One mcycle claim may meet several opponents,
  each opening a child over a different period. Keep earlier child
  claims until the root settlement is final.
- **Bonds.** Attach the bond to every join; budget for the root bond,
  the active child's bond, and gas. Recovery pays the recorded claimer.
- **Transactions.** Simulate before sending; track nonces across reorgs;
  never let cached computation authorize a transaction that the current
  events no longer call for.
- **Proof encoding.** The contracts take the transition's access logs
  and input bytes in their own encoding, which must be matched exactly.

### 7.5 Stale joins

This subsection is this document's own analysis, not a statement found
in the contracts' documentation. A join checks the bond, the claim's last leaf, and the joining deadline.
It does not check that the claim was computed over the epoch's current
inputs. A join broadcast before a reorg that changes the inputs can
still execute, posting a claim over inputs the chain no longer has. A
node should detect this, not defend that claim, and join again with the
correct one if the window is still open.

---

## 8. Adversaries and test cases

### 8.1 The four strategies

The model ships four dishonest players, each built from the honest
player with a small part wrapped. They make good test opponents.

| Strategy | What it changes | Where it is caught | Settled by |
|---|---|---|---|
| **Quitter** | Never runs the guest; every leaf is one made-up hash; disconnects after joining | Its first move | Timeout win, or elimination when its opponent is also absent |
| **Forger** | Substitutes its own bytes for one input | Leaf 0 of period 0 of that input slot | Input delivery plus a uarch step, against the referee's input |
| **Tamperer** | Overwrites bytes of RAM at a chosen mcycle; repeats it on every replay | The first transition after the corruption point | An ordinary uarch step |
| **Fabulist** | Computes honestly, then replaces one mcycle-claim leaf; in the uarch claim for that period, replaces the last leaf | The last leaf of that period | A uarch step plus the reset |

A fabulist is honest everywhere but its one leaf, and so will defend the
truth, correctly, in any dispute that does not reach it.

### 8.2 The reference run

One honest player and seven dishonest ones over a three-input epoch,
*p* = 10. Claims in admission order:

```text
Claim 0x1a22b0c7..., with final state 0xdd2e60cd..., joined (posted by quitter).
Claim 0x4f4b4987..., with final state 0xf0fb49ec..., joined (posted by tamperer).
Claim 0x56d98314..., with final state 0x5d4ca486..., joined (posted by fabulist).
Claim 0x923b6eb7..., with final state 0x5d4ca486..., joined (posted by fixed_fabulist).
Claim 0x98e1ce81..., with final state 0xbd6f4f4e..., joined (posted by forger).
Claim 0xc75bbba2..., with final state 0x5d4ca486..., joined (posted by honest).
Claim 0x0e6cdf5f..., with final state 0x2743a118..., joined (posted by quitter 1).
Claim 0x87f38778..., with final state 0x66eed701..., joined (posted by quitter 2).
```

| Match | Claims | Parted at | Settled by | Survivor |
|---|---|---|---|---|
| 1 | quitter – tamperer | never opened | timeout win | tamperer |
| 2 | fabulist – fixed_fabulist | input 2, period 2000, transition 2^30 − 1 | uarch step + reset | fixed_fabulist |
| 3 | forger – honest | input 2, period 0, transition 0 | input delivery + uarch step | honest |
| 4 | quitter 1 – quitter 2 | never opened | elimination | none |
| 5 | tamperer – fixed_fabulist | input 0, period 1600, transition 0 | ordinary uarch step | fixed_fabulist |
| 6 | honest – fixed_fabulist | input 2, period 60000, transition 2^30 − 1 | uarch step + reset at a fixed point | honest |

Round 2 pairs matches 1 and 2's winners; the honest claim advances
unmatched. Round 3 is match 6.

```text
Winner computation hash: 0xc75bbba25fef709d149eeb65a911bd7a7877713f2984164409da12118631b41e
Winner final state hash: 0x5d4ca486a943799b75423a1763daf881fa064e2115309f98ab22096cbcb3ec7c
```

The winner's computation hash equals the mcycle computation hash that
the `cartesi-machine` command computes directly for the same epoch with
a period of 2^10.

### 8.3 Transitions worth covering

Ordinary uarch steps; input delivery; delivery to a machine that cannot
take input (a no-op); a slot with no input; the reset closing an
instruction; the reset closing a *rejecting* instruction; transitions
after a rejected input; consecutive rejected inputs; a fixed-point
mcycle; the first and last leaves of a period; a divergence at leaf 0; a
divergence at the first leaf of a bundle (the agreed-state proof then
opens the preceding bundle).

---

## 9. Checklist of referee checks

1. **Join.** Children hash to the computation hash. The final-state
   proof targets leaf 2^H − 1, is a leaf proof of height H with H
   siblings, is rooted at the computation hash, and verifies. Collected
   before the joining deadline. For a uarch claim: the final state is
   one of the two contested hashes.
2. **Reveal.** Height above 1. Children hash to the node to open.
   Grandchildren hash to the child on the side of descent. Before the
   responder deadline.
3. **Seal.** Height 1. Leaves hash to the node to open. Unless the
   divergent leaf is leaf 0: the agreed-state proof targets the leaf
   before it, is a leaf proof of height H with H siblings, is rooted at
   the on-turn claim, verifies, and, for a right-leaf divergence, equals
   the revealed left leaf. Before the responder deadline.
4. **Transition.** The logs verify in order from the agreed state hash,
   using the referee's own input. Before the earlier of the two
   deadlines. The result is compared with the two contested hashes.
5. **Timeout win.** Inside the timeout window. Children hash to the
   waiting claim's computation hash.
6. **Elimination.** At or after the elimination block.
7. **Outputs root.** Three word proofs against the settled final state.
8. **Output.** A leaf proof of height 63 against the outputs root, whose
   target is the hash of the output data, at an index not accepted
   before.

## 10. Glossary

| Term | Definition |
|---|---|
| **Access log** | The reads and writes of one logged operation, each with a Merkle proof |
| **Agreed state hash** | The leaf before the divergent leaf, identical in both claims; the tournament's initial state when the divergent leaf is 0 |
| **Allowance, clock** | A claim's remaining time budget, in blocks |
| **Boundary** | The machine state between two inputs, before the next is delivered |
| **Bundle** | A subtree of 2^4 mcycle samples or 2^16 uarch transitions, stored as its root |
| **Claim** | A computation hash together with its final state hash |
| **Computation hash** | Root of a Merkle tree whose leaves are state hashes along a computation |
| **Contested state hashes** | The two different leaves at the divergent position |
| **Divergent leaf** | The leftmost leaf at which two claim trees differ |
| **Epoch** | A batch of consecutive inputs, settled together |
| **Fixed point** | A state a transition leaves unchanged |
| **Frontier** | The roots of the complete left subtrees over the leaves appended so far |
| **Frontier forest** | A frontier that retains its subtrees, so it can answer queries |
| **Holder** | A player that posted a given claim and has its tree |
| **Match** | The alternating walk down two claim trees, then its settlement |
| **mcycle** | One fetch-execute iteration of the main processor; also that counter |
| **Outputs Merkle root** | Root of the tree of hashes of all outputs ever emitted |
| **Period** | 2^p consecutive mcycles |
| **Revert root hash** | The pre-delivery state hash recorded in the machine |
| **Seal** | The last response of a walk: the two bottom leaves and a proof of the agreed state |
| **uarch** | The microarchitecture: an RV64I processor that executes one mcycle per run |
