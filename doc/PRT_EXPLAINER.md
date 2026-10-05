# The Judge Who Checks Four Steps

*A script for a narrated explainer of the Permissionless Refereed
Tournament: how a referee that can barely compute settles a dispute
about a computation it could never run, among any number of strangers,
most of whom may be lying.*

This is the narrative. It is written to be spoken over animation, for
viewers who have never heard of Cartesi, and it is also the text of an
interactive web page. It contains no code. Everything exact that an
implementer needs, the rules, the data structures, the algorithms, lives
in a separate companion document, the *implementer's reference*. This
script is self-contained without it.

## Production notes

### How to read the script

The plain text is the narration. Three kinds of block interrupt it.

> **On screen.** What the viewer sees while the following lines are
> spoken. The narration is written to these pictures: when it says
> "here" or "watch", this is what it points at.

> **Pause and ponder.** A question put to the viewer just before its
> answer. It stays on screen for a few seconds; the narrator reads it
> and waits a beat.

> **Web page.** Something the reader can manipulate, for the interactive
> version.

Text in `code font`, such as a hash, is shown on screen, not read aloud.

### Words that need a pronunciation

| Written | Spoken |
|---|---|
| PRT | "P R T" |
| 2<sup>62</sup> | "two to the sixty-two" |

### The visual vocabulary

These never change once introduced.

- **A machine state** is a small rounded square. **Its hash** is a
  colored dot whose color is derived from the hash, so equal hashes are
  visibly the same color.
- **A computation** is a horizontal line of states, time flowing left to
  right. **Repetition**, a state that no longer changes, is a faded
  trail, never a million identical dots.
- **A tree** grows upward from a row of leaves to one root.
- **The referee** is small: a notepad with room for a few dots, and a
  clock. It never holds a machine.
- **The honest claim** is blue. Each liar has its own warm color and an
  icon: an empty chair (quitter), an altered envelope (forger), a wrench
  (tamperer), a crossed-out leaf (fabulist).
- **The motif.** One image recurs at every scale and is always drawn the
  same way: **one green dot, then two dots of different colors.** A
  state both sides accept, followed by two rival accounts of what comes
  next. The whole protocol is a machine for producing this picture and
  then resolving it.

### The toy epoch

Real numbers here are astronomically large, so every idea is first shown
on a toy small enough to draw in full, and only then scaled up. The toy
is used consistently:

- **Toy machine state:** 8 boxes. Box 0 is the *position*: how far the
  machine is through the instruction it is carrying out (0 to 3). Box 1
  is the *total*. Box 2 is the *inbox*, where a request arrives. Box 3
  is the *stage*: which instruction the program has reached (0 = get
  ready, 1 = add, 2 = waiting). Boxes 4 to 6 are unused and hold 0. Box
  7 is *spare*: the program never reads or writes it.
- **Toy program:** a calculator that adds each request to the total. The
  first request is 40, the second is 2, so the total ends at 42.
- **Toy epoch:** 2 requests, 4 instructions per request, 4 micro-steps
  per instruction. That is 32 ticks. "State *n*" is the state after *n*
  ticks; state 0 is where everyone agrees.
- **Toy claims:** a coarse tree with 4 leaves (states 8, 16, 24, 32) and
  a fine tree with 8 leaves (for the third quarter: states 17 to 24).

**The toy's rules.** They are complete, so the toy is deterministic: the
next state depends only on the current state and on which tick it is.

- *A micro-step* reads the position and the stage. If the stage is 2
  (waiting) or the position is 3 (finished this instruction), it does
  nothing. If the position is 0 or 1, it adds one to the position. If
  the position is 2, it finishes the instruction: at stage 0 it sets the
  stage to 1; at stage 1 it adds the inbox to the total and sets the
  stage to 2; either way the position becomes 3.
- *The first tick of a request* first puts the request in: the inbox
  takes the request and the stage becomes 0. Then a micro-step.
- *The last tick of an instruction* is a micro-step, then a reset: the
  position becomes 0.
- *Every other tick* is one micro-step.

The trace, starting from state 0 = (position 0, total 0, inbox 0, stage
2, spare 0):

| After tick | What the tick did | position | total | inbox | stage | spare |
|---|---|---|---|---|---|---|
| 1 | request 40 goes in; micro-step | 1 | 0 | 40 | 0 | 0 |
| 2 | micro-step | 2 | 0 | 40 | 0 | 0 |
| 3 | micro-step: stage becomes 1 | 3 | 0 | 40 | 1 | 0 |
| 4 | micro-step (nothing); reset | 0 | 0 | 40 | 1 | 0 |
| 5 | micro-step | 1 | 0 | 40 | 1 | 0 |
| 6 | micro-step | 2 | 0 | 40 | 1 | 0 |
| 7 | micro-step: add, stage becomes 2 | 3 | 40 | 40 | 2 | 0 |
| 8 | micro-step (nothing); reset | 0 | 40 | 40 | 2 | 0 |
| 9–16 | waiting; nothing changes | 0 | 40 | 40 | 2 | 0 |
| 17 | request 2 goes in; micro-step | 1 | 40 | 2 | 0 | 0 |
| 18 | micro-step | 2 | 40 | 2 | 0 | 0 |
| 19 | micro-step: stage becomes 1 | 3 | 40 | 2 | 1 | 0 |
| 20 | micro-step (nothing); reset | 0 | 40 | 2 | 1 | 0 |
| 21 | micro-step | 1 | 40 | 2 | 1 | 0 |
| **22** | micro-step | 2 | 40 | 2 | 1 | 0 (**tamperer: 9**) |
| 23 | micro-step: add, stage becomes 2 | 3 | 42 | 2 | 2 | 0 (9) |
| 24 | micro-step (nothing); reset | 0 | 42 | 2 | 2 | 0 (9) |
| 25–32 | waiting; nothing changes | 0 | 42 | 2 | 2 | 0 (9) |

No two of the states 17 to 24 are equal, so the eight fine leaves are
eight different colors.

**The tamperer's lie, used throughout.** It runs the same toy, but going
from state 21 to state 22 it also puts a 9 in the spare box. Every state
from 22 on differs from the honest one in that box only. Its total is
still 42. So: the two agree at states 16, 20 and 21; they differ at 22,
24 and 32. In the coarse tree the first differing leaf is the third
(state 24), and the agreed leaf before it is the second (state 16). In
the fine tree over states 17 to 24 the first differing leaf is the sixth
(state 22), and the leaf before it (state 21) is agreed. The honest log
for tick 22 has three entries: read the position (1), read the stage
(1), write the position (2). No rule writes the spare box, on this tick
or any other.

Leaves are counted from one in the narration ("the third leaf", "the
sixth leaf").

The toy is a drawing aid. In the real machine a waiting processor still
runs briefly and is reset inside every instruction slot; in the toy a
waiting machine does nothing at all.

The real epoch has the same shape with 2<sup>24</sup>, 2<sup>48</sup>
and 2<sup>20</sup> in place of 2, 4 and 4.

### How the story is told

The audience watches Veritasium and 3Blue1Brown for pleasure. The script
borrows from both on purpose, and an adaptation should keep these
intact.

**Tension, after Veritasium.**

- It opens on an impossibility with numbers in it, and names the
  viewer's wrong answers before giving the right one.
- The **eight players are introduced in the first three minutes** and
  never leave. Each of the four kinds of liar defeats one obvious
  defense, and each idea in the video is introduced as the thing that
  catches one of them.
- No section ends on a solution. Each ends on the problem the solution
  creates.
- Promises are made early and paid late. They are listed below and must
  not be cut without their payoffs.
- The final run is staged as an experiment with a prediction.

**Inevitability, after 3Blue1Brown.**

- Nothing is defined before it is needed. Each construction is the
  simplest thing that could work, tried, and repaired.
- One toy example and one real example, kept from start to finish.
- The pictures carry the argument. "These two subtrees are identical"
  is two dots of the same color, seen, not asserted.
- At each point where the viewer can take the next step unaided, the
  video stops and asks.
- The best moments are recognitions: two things already on screen turn
  out to be one thing.

**Open loops.**

| Promise | Made in | Paid in |
|---|---|---|
| The judge will execute exactly four steps | 1 | 20 |
| A liar will defend the truth against another liar | 1 | 20 |
| The size of a lie makes no difference to the price of catching it | 1 | 20 |
| "What would you check to catch each of the four?" | 2 | 6, 7, 10, 19, then 20 |
| Each liar defeats an obvious defense; something else will catch it | 2 | 6 and 16 (tamperer), 7 (forger), 10 (fabulist), 19 (quitter) |
| The guest list: why the largest systems would not let just anyone challenge | 3 | 9 (the reason), 22 (the door opens) |
| "Hold on to that": reading and writing a machine you do not have | 5 | 6, 21 |
| Tick 22, found three ways: by halving, by the trees, and checked by a log | 6, 8 | 15, 16 |
| Why a claim carries its two top branches and its last leaf | 12 | 13, 15 |

**Title and thumbnail.** State the impossibility, not the topic: *"The
Judge Who Checks 4 Steps to Settle 100 Billion"*
or *"How One Honest Computer Beats a Thousand Liars"*. The thumbnail is
the motif and a very small referee.

### Sections

| Act | Section | Minutes |
|---|---|---|
| Hook | 1. Four steps | 2 |
| | 2. Eight players | 2.5 |
| I. What the judge can do | 3. A judge who cannot do the work | 1.5 |
| | 4. A computer with no secrets | 1.5 |
| | 5. Thirty-two bytes | 2.5 |
| | 6. One step | 4 |
| | 7. The shape of an epoch | 4 |
| II. Finding the step | 8. Halving | 2.5 |
| | 9. The crowd | 4.5 |
| III. Claims | 10. A whole history in thirty-two bytes | 3 |
| | 11. The tree nobody can build | 3 |
| | 12. Joining | 1 |
| IV. The match | 13. Walking two trees | 2.5 |
| | 14. The seal | 2 |
| | 15. Inside the gap | 1.5 |
| | 16. One step, checked | 1.5 |
| | 17. Why the truth wins | 1.5 |
| V. The crowd, again | 18. Brackets | 1 |
| | 19. Silence | 2 |
| VI. The run | 20. Eight players, seven liars | 6 |
| | 21. What anyone actually wanted | 1 |
| Close | 22. What it asks | 3.5 |

About 55 minutes of narration at 150 words a minute (8286 words),
before pauses.

---

# Hook

## 1. Four steps

> **On screen.** Black. The number 100,000,000,000 appears, digit by
> digit.

Here is a number. A hundred billion. The computation we are about to
argue over takes more than that many tiny steps.

> **On screen.** Eight colored dots appear under the number. One is
> blue. The other seven flicker.

Eight players reported on it. They came back with eight different
accounts of what happened. Seven of them are lying.

> **On screen.** The small referee walks in with its notepad. Beside it,
> a counter: "steps checked: 0". It ticks up to 4 and stops.

And the judge who has to decide between them is a program so limited
that, by the end of this video, it will have checked exactly four
steps. Four, to settle a hundred billion. It will do some small
bookkeeping besides, a few thousand quick calculations. But moves of the
machine, actually checked: four. And yet its verdict will not be a guess,
or a vote. As long as
just one of the eight is honest, the judge will find the truth, and it
does not need to know which one that is.

How?

> **On screen.** Hold on black for a full second. Then three cards: a
> ballot box, a crown, and the referee flattened under the number. Each
> is struck through as it is named.

You might take a vote. But the liars outnumber the honest seven to one,
and where this judge lives, a liar can be a thousand people at almost no
cost.
You might look for someone trustworthy. The whole point is that there is
nobody to trust. You might have the judge check the work. It cannot. It
can barely afford to check a single step.

What actually happens is stranger. The judge will make the liars corner
*themselves*. At one point a liar will end up defending the truth
against another liar, because the truth is the only thing it can win
with. And you
will see that the size of a lie makes no difference at all: a liar who
rewrites an entire request, and a liar who changes a single moment, are
caught at exactly the same price.

This is called a *Permissionless Refereed Tournament*. My aim is that by
the end, it will not feel like something you were told. It will feel
like something you could have invented.

## 2. Eight players

> **On screen.** A small calculator program inside a box labelled "a
> computer". Three envelopes slide in one at a time. The second bounces
> back out. After the third, a very long number scrolls out of the box.

First, the computation itself. It is modest. A calculator program,
running on Linux, inside a virtual computer. It receives three requests.
It rejects the second one. The third asks for two to the power 2048, and
the answer is a number with 617 digits.

A calculator is a harmless example. In the systems this was built for,
the "answer" is who owns what. If a false result is accepted there,
somebody walks away with money that is not theirs. That is why anyone
would bother to lie, and why it matters that nobody can.

Eight players entered a result for this computation. Meet them.

> **On screen.** Eight portraits appear in a row as each is named, with
> its icon and color.

One is **honest**. It ran the machine and reports what happened.

Three are **quitters**. A quitter makes up a result out of thin air,
submits it, and disconnects. It has no intention of defending anything.
Its weapon is silence.

One is a **forger**. It runs the machine flawlessly, but on a doctored
third request: "two *plus* 2048" where the real one says "two *to the*
2048". Every single step of its computation is correct. It is simply a
different computation.

One is a **tamperer**. It runs the right requests, but partway through
the first, it overwrites a few bytes of memory that the program never
looks at. Every answer it produces is right. Only the machine's insides
are off.

And two are **fabulists**. A fabulist computes everything honestly, and
then lies about exactly one moment in the middle: one snapshot of the
machine, out of all the snapshots it reports. It tells the truth about
everything else, including how it all ends. It is the smallest lie there
can be, and it is here as the hardest test.

> **On screen.** Four "obvious defenses" appear as shields. Each liar
> walks through one of them untouched.

Now notice what each of them is built to defeat. Check that the work is
internally consistent? The forger's is, perfectly. Check that the
answers are right? The tamperer's are. Spot-check a few moments at
random? You will never land on the fabulist's one. Ask them to explain
themselves? The quitter has left the building.

And do not be reassured by "every answer is right". The next batch of
requests starts from wherever this one ended. Accept a corrupted machine
today, and everything after it is built on that.

Keep these four in mind. Every idea from here on exists because, without
it, one of them wins.

> **Pause and ponder.** Before going on: for each of the four, what
> would *you* check to catch it?

---

# Act I. What the judge can do

## 3. A judge who cannot do the work

> **On screen.** A chain of blocks. Around each block, a crowd of small
> computers all performing the same little calculation in unison, coins
> draining from a meter.

The judge is a program on a blockchain, a *smart contract*. A blockchain
is a computer that nobody has to take on trust, because everybody checks
it: every step it takes is repeated by thousands of machines, and paid
for by whoever asked. So it is, by design, one of the slowest computers
in the
world. It can move money from one account to another. It cannot boot
Linux.

And yet we want it to act on the results of real programs. So the real
program runs somewhere else, and only the result is posted. Anyone may
post one. Anyone who disagrees may challenge. And the contract, the
*referee*, must work out who is right.

Notice the word *anyone*. For years, the largest systems built this way
did something telling: they kept a guest list. Only approved parties
were allowed to challenge. We will come back to why, because the reason
is the heart of this video.

> **On screen.** A mountain of gears, "the computation". The referee
> stands beside it, tiny. The camera pushes into the mountain, past
> thousands of gears, and stops on one tooth of one gear, glowing
> yellow.

Every protocol of this kind rests on one insight. The referee never
checks the computation. It gets the players to corner their disagreement
into **one single step**, and then it checks only that step.

So we need four things: a computation that really is a line of states; a
way to name an enormous state in a few bytes; a step small enough to
check; and a way to find the step. We will take them in that order.

## 4. A computer with no secrets

> **On screen.** The toy machine: a row of 8 boxes, each holding a
> number. Five are labelled: "position", "total", "inbox", "stage", and,
> at the far end, "spare". They read: position 1, total 40, inbox 2,
> stage 1, spare 0.

The computation runs on a *Cartesi Machine*. It is an emulator of a real
processor, complete enough to run Linux and ordinary software. What
makes it unusual is three promises.

It is self-contained: nothing leaks in from outside. No clock, no
network, no dice. It is reproducible: start two copies in the same state
and they will
agree on the next state down to the last bit, always. And it has no
secrets: everything inside it, memory, disks, the processor's registers,
is laid out in one long row of bytes that anyone may inspect.

> **On screen.** A "step" arrow fires and the position box goes from 1
> to 2. The row shrinks into a small rounded square. More squares appear
> to its right, each an arrow away from the last.

That row *is* the state of the machine. Here is a toy one, with eight
boxes. One holds a running total. One is an inbox, where a request
arrives. Two say where the machine is in its work: a stage, and a
position within that stage. And the last one is spare: the program never
touches it. Keep an eye on that one.
In the real machine the row is two to the sixty-four bytes, almost all
of them zeros. A step turns one row into the next. So a computation is a
line of
states, each completely determined by the one before.

If two honest people ever disagree about a single bit of any state on
that line, one of them has a broken computer. That is what lets a
dispute end with a verdict instead of an argument.

There is just one problem with a state that long. How do you even tell
someone which state you mean?

## 5. Thirty-two bytes

> **On screen.** The 8 boxes pour into a funnel labelled "hash". Out
> comes a single colored dot. Change one box by one; the dot changes to
> a completely different color.

You give it a name. A *hash function* takes any amount of data and
returns thirty-two bytes. Change one bit going in and what comes out is
unrecognizable. And nobody knows how to find two different inputs that
give the same output. So a hash is a fingerprint: tiny, and for all
practical purposes unique.

We could hash the whole row end to end. But watch what we get if we hash
it as a tree instead.

> **On screen.** The 8 boxes in a row. A dot rises from each. Pairs of
> dots merge into a dot above them; those pair up again; one dot is left
> at the top.

Hash each box on its own. Then hash each pair of neighbors together.
Then pair those. For eight boxes, three rounds, and one hash is left at
the top. That is the *state hash*. This shape is a *Merkle tree*.

> **Pause and ponder.** I know only the dot at the top. You want to
> convince me that the total box holds 40. What is the least you could
> send me?

> **On screen.** The total box lights up. Its path to the root lights up. The
> three dots hanging *off* that path, one at each level, pulse.

You send me the box, and three hashes: one from each level of the tree,
the ones hanging just off the path from that box to the top. I hash the
box. I combine
it with the first, then the second, then the third. If what I get equals
the dot I already hold, you were telling the truth. You could not have
made those three hashes up; that would mean breaking the hash function.

Three hashes for eight boxes. The real machine's memory, cut into boxes
of thirty-two bytes, has two to the fifty-nine of them, and it takes
fifty-nine hashes. Under two kilobytes, to prove
one fact about a state eighteen billion gigabytes long.

> **On screen.** The total changes from 40 to 42. The same three side
> dots stay where they are; the path recolors from the bottom up, and a
> new dot appears at the top.

And now the part to hold on to. Those same three hashes let me *write*.
If the total becomes 42, I climb again from the new value, using the same
three neighbors, and what comes out at the top is the hash of the
changed machine.

So someone holding only thirty-two bytes can, with the right handful of
hashes, read from a machine they do not have, write to it, and learn the
name of the result. Hold on to that. It is how a blockchain will check a
step of a computer it cannot run.

> **Web page.** A sixteen-leaf tree. Click a leaf to see its proof.
> Tamper with the leaf or a neighbor and watch the climb miss the root.
> Type a new value and watch the same neighbors carry it to a new root.

Which leaves the question we have been putting off. What, exactly, is a
step?

## 6. One step

> **On screen.** A large gear, "the processor", about to advance one
> tooth. Thought bubbles show what one tooth can involve: a
> floating-point division, a walk through a table of memory mappings.

One instruction of a real processor is not a small thing. It might be a
floating-point division. It might set off a chain of memory lookups.
Teaching a smart contract to reproduce every instruction of a modern
processor, exactly, would be enormous and fragile.

> **On screen.** Zoom into the one tooth. Inside is a tiny gear train. It
> turns many times, stops, and snaps back to where it started. Zoom out:
> the large gear has advanced exactly one tooth.

So the Cartesi Machine hides a second, far simpler processor underneath
the first. It is called the *microarchitecture*, and it knows only
fifty-two basic instructions. Here is the trick. The rulebook of the big
processor, what each of its instructions does, is itself just a program.
The small processor runs that rulebook. Its entire job is to carry out
one instruction of the big processor, in hundreds or thousands of tiny
moves, and then stop. After that it is *reset*, ready for the next one.

Run the small processor until it stops, then reset it: that is one
instruction of the big one. We will call the tiny moves *micro-steps*.
And fifty-two simple rules are few enough to write into a smart
contract. The referee knows them.

> **On screen.** The toy machine, with its rule written beneath it in
> four lines: "position counts 0, 1, 2"; "at 2, the stage does its job
> (stage 1, *add*, adds the inbox to the total)"; "a waiting machine
> does nothing; a reset puts the position back to 0"; "nothing ever
> writes the spare box".

Our toy has a small processor too, and its rule fits on a card. The
position counts up: zero, one, two. At two, the current stage does its
job; stage one is called *add*, and it adds the inbox to the total. A
machine that is waiting does nothing at all. A reset puts the position
back to zero. And nothing, ever, writes to the spare box.

> **On screen.** The toy machine, with a three-line list beside it:
> "read the position: 1", "read the stage: 1", "write the position: 2".
> Caption: "tick 22". Each line has a small path of dots beside it.

Now, a micro-step touches very little: it reads a handful of boxes and
writes one or two. So a player who has the machine can write down a
*log*: every box the micro-step read, every box it wrote, each with the
handful of hashes that proves it. Here is one micro-step of our toy. We
will meet it again, so give it a name: tick twenty-two. You will see
where the number comes from in a minute. The machine is in stage one, at
position 1, so by the rule the position goes to 2, and that is all. Its
log has three entries: read the position, which is 1; read the stage, to
know it is not
waiting; write the position, now 2. A real one has about nine.

> **On screen.** The referee's notepad holds one green dot. The log
> feeds in line by line. On each "read", a path climbs and matches the
> dot. On each "write", the dot changes color. At the end the notepad
> holds a new dot.

And the referee replays it. Not with a machine; with the log. "I need
the position. The log must show that box, and its proof must
climb to the hash I am holding." "Now I write the new position. Same
neighbors, new hash." A few entries later the referee is holding the
state hash *after* the step. It never had the machine. It had a dot, and
a log.

> **On screen.** A second log feeds in from the same green dot. Its
> first line says the position was 2; the true value is 1. The path
> climbs from 2 and arrives at a dot of the wrong color. Rejected.

Suppose a liar's log says the position was 2, when really it was 1. The
referee climbs from 2, with whatever neighbors the liar supplies, and
does not arrive at the hash it is holding. The log is thrown out at that
line.

Here is the property everything else hangs on. **From a given state,
there is exactly one next state a log can prove.** The referee decides
what must be read and written, because it knows the rules. The proofs
decide what the values are. A
liar has no room left. A log either leads to the true next state, or it
is rejected.

> **On screen.** The toy machine again. During this same micro-step, a
> hand reaches in and changes the spare box from 0 to 9. A third log
> tries to include "write the spare box: 9". The referee's rulebook for
> this step has no such line.

That is what will catch the tamperer. Here is its trick on the toy:
during this very micro-step, it also slips a 9 into the spare box. The
total is untouched; every answer will still be right. But to get the
referee from the state before to *its* state after, a log would have to
write to the spare box, and the rule never does that. No log exists for
it.

If only we knew where to look. Our computation has rather more than one
step.

> **Web page.** A nine-entry log as a stepper, with a small state tree
> and a "current hash" readout. A toggle corrupts one entry three
> different ways and shows each rejection.

## 7. The shape of an epoch

> **On screen.** The box from section 2, with three envelopes waiting
> above it on a chain of blocks. They drop in one by one.

Back to our calculator. It does not run once and stop. It behaves like a
server: wait for a request, handle it, wait for the next. And every
request (the system itself calls it an *input*) is posted on the
blockchain *before* the machine sees it. So the
requests, and their order, are public. The referee has its own copy.

That is what will catch the forger. Its computation was flawless, on a
request that nobody posted. Sooner or later someone has to show the
request going in, and the referee will be holding the real one.

> **On screen.** The second envelope goes in; the machine works, then
> snaps back to exactly how it looked before, and the envelope pops out
> stamped "rejected".

When the program finishes a request it either accepts it, keeping its
changes, or rejects it, in which case the machine goes back to precisely
the state it had before, as if the request had never arrived. Requests
are grouped into batches called *epochs*. At the end of an epoch the
world must agree on one thing: the state hash of the machine. Everyone
agrees where the epoch started. Everyone has the requests. Only the
ending is in dispute.

Now, we are about to search an epoch for one bad step, and searching is
far easier when the thing has a regular shape. Real epochs do not. One
has three requests, another three thousand. One request takes a million
instructions, another a billion.

> **On screen.** The toy epoch drawn in full: a ruler of 32 ticks,
> grouped as 2 requests, each of 4 instructions, each of 4 micro-steps.

So we give it a shape, by decree. Here is the toy version: an epoch is
exactly two requests; a request is exactly four instructions; an
instruction is exactly four micro-steps. Thirty-two ticks, always, where
a tick is one move the referee could check. Our
toy calculator just adds. The first request says 40. The second says 2.
The total ends at 42.

And here is the forger, on the toy. Suppose it ran with a 3 in the
second envelope. The first tick of that request is the one that puts the
request into the inbox. But it is the referee who puts it in, from its
own copy, and its copy says 2. No log can make it a 3.

> **Pause and ponder.** Suppose the program is done with a request after
> two instructions. What should "the state after instruction three"
> mean?

> **On screen.** On the ruler, the first eight ticks of each request are
> lit, with the total ticking to 40 and then to 42; the rest of each
> request is a faded trail, one steady color per request.

The simplest thing possible. **When there is nothing left to do, the
state stays the same.** A processor that has stopped, stopped. A machine
waiting for its next request is still waiting: at the end of every
instruction it is back in exactly the state it started in. From there
on, instruction after instruction, the line keeps returning to the same
dot.

With the shape fixed, every tick is one of exactly three kinds, and its
position tells you which. The first tick of a request: put the request
in, then take a micro-step. The last tick of an instruction: take a
micro-step, then reset the small processor. Every other tick: just a
micro-step. Three small recipes. That is the referee's entire knowledge
of the machine.

> **On screen.** The ruler stretches. The labels change from 2, 4, 4 to
> 2<sup>24</sup>, 2<sup>48</sup>, 2<sup>20</sup>. The tick count becomes
> 2<sup>92</sup>. Almost the whole ruler is faded trail.

The real epoch has the same shape with bigger numbers: sixteen million
request slots, each with room for two to the forty-eight instructions,
each with room for a million micro-steps. Two to the ninety-two ticks.
About five thousand
trillion trillion.

Look at what we just did. The computation really takes about a hundred
billion steps. To make it searchable, we stretched the line until those
hundred billion are a few specks near the start of each request, and
everything else is the machine waiting. We made the haystack
unimaginably bigger, on purpose. Nobody will ever walk that line. We
only need it to be perfectly regular. And as you are about to see, its
size will cost us almost nothing.

Which leaves exactly one question, and it is the hard one. Out of two to
the ninety-two ticks, which?

---

# Act II. Finding the step

## 8. Halving

> **On screen.** The toy ruler of 32 ticks. Two players under it: blue
> (honest) and the tamperer. The left end is one green dot. The right
> end is two dots, blue and orange.

Put two players on the toy epoch: the honest one, and the tamperer, who
slipped that 9 into the spare box during tick twenty-two. Both say the
total is 42. Their answers are identical. But the 9 is still sitting in
the spare box at the end, so their final state hashes are not.

They agree on the state at the left end. They disagree at the right. The
referee asks both of them one question. What was the state at the
midpoint, after tick sixteen?

> **Pause and ponder.** If their answers match, which half do you throw
> away? And if they differ?

> **On screen.** Both hold up a dot for tick 16: the same color. The left
> half turns green and slides away. Tick 24: different colors; the right
> half slides away. Tick 20: same. Tick 22: different. Tick 21: same.

If they match, they agree at the midpoint, so the disagreement that
shows up at the end must begin somewhere in the second half. If they
differ, they have already parted ways by the midpoint, so there is
trouble in the first half. Either way, half the line
is gone, and what is left still starts where they agree and ends where
they do not.

> **On screen.** The interval has halved: 32, 16, 8, 4, 2, 1. What
> remains is tick 22 alone, with one green dot on its left and a blue
> and an orange dot on its right. Under the blue dot, the toy machine
> with spare 0; under the orange, the same machine with spare 9. Freeze.
> Caption: "the motif".

Sixteen, twenty-four, twenty, twenty-two, twenty-one. Five questions,
and thirty-two ticks have become one: tick twenty-two. Look at what is
left: one state they both accept, and two rival versions of what comes
next. Remember this picture. Everything from here on is a way of
arriving at it.

And we know what to do with it. It is a single step, so the referee asks
for the log. Read the position: 1. Read the stage: 1. Write the
position: 2.
That lands on the blue dot, the one with nothing in the spare box. The
orange dot cannot be reached. The tamperer is out, even though every
answer it gave was correct.

For the real epoch it takes ninety-two questions. Ninety-two, to search
five thousand trillion trillion steps. The idea of a refereed game like
this goes back to Uriel Feige and Joe Kilian in 1997. The form used
here, with hashes and bisection, is from Ran Canetti, Ben Riva and Guy
Rothblum in 2011: a weak client hands a computation to several servers
and gets the right answer as long as just one of them is honest. Between
two players, it is very hard to beat.

So what could possibly be wrong with it?

> **Web page.** Play the referee on the 32-tick line: see both midpoint
> answers each round and choose which half to keep. Choosing wrongly
> breaks the picture: either both ends agree and there is nothing to
> find, or both ends disagree and there is no agreed state to start
> from.

## 9. The crowd

> **On screen.** The two players are joined by a third, a tenth, a
> hundredth, all different warm colors, crowding the frame. The blue one
> is still there, somewhere.

What is wrong is that we assumed two players. On a public blockchain,
nobody decides who shows up.

> **On screen.** The crowd plays the halving game together. At the end
> one figure drops out. The whole game restarts. One more drops out. A
> clock in the corner spins.

With a crowd, a full game of halving ends with *at least one* liar
eliminated, and that is all it guarantees. So a thousand liars with a
thousand slightly different lies can force a thousand games. Play them
one after another, and the delay is a thousand games long. Play them all
at once, and the one honest player has to fight, and pay for, a thousand
games at the same time. Either way the cost grows in step with the
number of liars, and identities cost almost nothing. An attacker who
cannot win can still stall, or simply exhaust the honest side.

> **On screen.** A heavy door with a guest list pinned beside it. Behind
> the door, the referee. A queue of figures outside; only a few are let
> through.

This is not a thought experiment.

Arbitrum, one of the largest of these systems, allowed only approved
parties to take part in disputes, and its developers said plainly why.
People keep money in these systems, and can only take it back out once
a result is settled. With open admission, a malicious party could keep
that from happening, delaying everyone's withdrawals for as long as it
was willing to pay. The list stayed until
February 2025, when a new protocol, designed specifically to put a hard
ceiling on that delay, replaced it.

> **On screen.** A calendar. June 2024: the door swings open. August
> 2024: it swings shut. September 2024: the repair.

Stalling is one reason the door is hard to open. There is another. Once
anyone may walk in, every flaw in the judge is exposed to everyone.
Optimism, another of the largest, opened its door in June 2024. About
two months later it closed it again: community audits had found flaws in
the new dispute system, two of them rated serious. Nothing had been
exploited and no funds were lost, and a fix was scheduled for the
following month.
But for those weeks, the guest list was back.

These are careful teams, with a great deal at stake. Nor was it only
them: the earlier Cartesi system, too, restricted disputes to a small
committee. That is the point.
Letting anyone in the world walk up to the judge, in any number, is one
of the hardest problems in the field: the judge has to be simple enough
to get exactly right, and the dispute has to end on time no matter who
shows up. Most of this video is about the second. But keep the first in
mind. It is why the step, a few minutes ago, was made so small, and we
will come back to it at the end.

So, back to the halving game. Stalling is its first weakness. It has two
more.

The second: an answer is just whatever a player says at that moment.
Nothing ties it to what it said before. So you cannot safely let anyone
answer for you: a false friend who shares your result could lose the
game for both of you by answering wrongly.

> **On screen.** A thousand red figures; five hundred of them are
> visibly the same figure copied. A thousand blue figures, all
> identical.

And the third, the subtle one. The game eliminates *players*. But
a thousand honest computers all hold the same truth. And a thousand fake
accounts may all be telling the same lie. Keeping track of who said what
is keeping track of the wrong thing.

In December 2022, Diego Nehab and Augusto Teixeira, two of the
researchers behind the Cartesi Machine, published a different shape for
the dispute, built for a crowd from the start. Its promise is in one
sentence of the paper:
a single honest competitor can win while spending effort that grows with
the length of the computation, but only with the *logarithm* of the
number of dishonest competitors. It changes three
things.

> **On screen.** Three cards, turned over one at a time.

One: **commit first.** Before any question is asked, each player commits
to the *entire history* of the computation, with a single hash.

Two: **claims, not players.** The referee tracks the commitments. Two
players with the same commitment are one claim. And anyone who can
answer for a claim may answer for it.

Three: **a tournament, not a game.** Claims are paired off in a bracket
and compared two by two, all at once. A thousand claims take ten rounds,
not a thousand.

Everything else hangs on the first of these.

---

# Act III. Claims

## 10. A whole history in thirty-two bytes

> **Pause and ponder.** In the halving game a player answers each
> question when it is asked. Can you make a player answer *every
> possible question* before any is asked, using only thirty-two bytes?

> **On screen.** The toy line of 32 states. Each state shrinks to its
> dot. A tree grows upward from the row of 32 dots to a single dot at
> the top, which lifts off and is posted with a player's name.

You have already seen the tool. Take the line of states. Write down the
hash of each one. And now treat *that row of hashes* as the leaves of a
new Merkle tree.

> **On screen.** Side by side: the tree from section 5 over the 8 boxes
> of one state, labelled "a tree over space"; and this tree over 32
> moments, labelled "a tree over time". The root of the first is one
> leaf of the second.

This is a second tree, and it is worth keeping the two apart. Before,
the leaves were the boxes of *one* state. Now the leaves are *states*,
one for each moment. The first is a tree over space. This one is a tree
over time. Its root is called a *computation hash*, and a player who
posts one has made a *claim*.

Why does this change everything? Because of what a Merkle tree does.
Once the root is posted, the hash at every moment is fixed. If the
referee asks, "what did you say the state was at tick twenty-one?",
there is exactly one answer that fits the root, and it comes with a
proof. The player cannot improvise. It cannot tell one story now and
another later.

> **On screen.** The fabulist's tree. All leaves are blue except one,
> crossed out. That one leaf sends a streak of a different color up its
> path to the root. The root is not blue.

That is what will catch the fabulist. It lied about a single moment. But
that one false leaf is baked into its root, and it can never deny it.

And notice: the answer no longer has to come from that player. *Anyone*
holding the same tree can give the same answer with the same proof. The
referee does not need to trust who is speaking. The proof speaks.

> **On screen.** The tree over time, with its top two branches
> highlighted: "first half", "second half". Then the four below:
> quarters. Then eighths. Beside it, the halving game from section 8
> replays, each question lining up with one level of the tree.

Now look at this tree from the top. The root has two branches. One
summarizes the first half of the history, the other the second. If two
claims have the same left branch, they agree about the entire first
half. That is the halving game's midpoint question, asked more
strictly: not "do you agree *at* the midpoint?" but "do you agree at
every moment *up to* it?" The next level down asks it for each quarter.
The next, for each eighth.

**A tree over time is a stricter halving game, with every possible
answer fixed in advance.**

> **On screen.** Two players side by side holding the same final dot:
> one blue, one with a hidden grin. They are asked a midpoint question
> as a team; the second one answers wrongly, and the team's dot goes
> dark. Replay with a posted tree above them: the answer is read off the
> tree, and the grin has nothing to say.

And that fixes the false friend. In the old game, two players with the
same final answer are on the same side, and one of them can throw the
game by answering a midpoint question wrongly. Once the whole history is
committed, there is nothing left to answer wrongly. The answers are in
the root. Anyone can read them out, and nobody can change them.

One caution. A commitment is not evidence. A liar can commit to complete
nonsense as easily as to the truth; a quitter's claim is the same
made-up hash at every single leaf. Committing proves nothing about the
machine. What it does is pin the liar down.

There is a catch, though, and it is not a small one. Nobody can build
this tree.

## 11. The tree nobody can build

> **On screen.** The real ruler, 2<sup>92</sup> ticks. A counter labelled
> "hashes to compute" races upward and overflows the frame.

To build a tree over every tick, a player would need the state hash
after every single micro-step. A request that takes a billion
instructions, at about a thousand micro-steps each, needs a trillion
state hashes. For one request.

> **On screen.** The toy ruler. Coarse marks appear every 2
> instructions, after ticks 8, 16, 24 and 32. A small tree of 4 leaves
> grows over them. Blue's and the tamperer's trees are laid side by side
> with their leaves showing, a peek the referee does not get: green at
> 8, green at 16, yellow at 24, yellow at 32.

The cheapest thing is to sample. Take a snapshot only every so often;
on the toy, every two instructions. Four leaves instead of thirty-two.
Two such trees can still be compared, and, as we will see, the first
leaf where they differ can still be found.

But what we have cornered is no longer one step. It is a gap: we agree
at tick sixteen, disagree at twenty-four, and in between are two whole
instructions. The 9 went in somewhere in there.

> **On screen.** The camera dives into the gap between tick 16 and tick
> 24. Inside are the 8 ticks from 17 to 24. A second tree, of 8 leaves,
> grows over them.

So we do it again, inside the gap. Both sides now commit to a second,
fine tree, covering only that gap, with a leaf for every micro-step in
it. Eight leaves on the toy. Nobody builds this tree in advance. It is
built only when two coarse trees have been found to disagree, and only
for the gap they disagree about.

Coarse first, fine only where needed. On the real epoch the coarse tree
samples every 1,024 instructions and has two to the sixty-two leaves.
The fine tree covers one such stretch and has two to the thirty. Sixty-two
levels in one, thirty in the other: ninety-two in all. The same
ninety-two as the halving game's questions.

Wait. Two to the sixty-two leaves? That is four million trillion. We
made it coarser and it is still impossible.

> **On screen.** The real coarse row of leaves: a short stretch of
> varied colors, then an endless faded trail of one color.

Except look at what those leaves are. The calculator is done with a
request after about fifty million instructions. Its slot has room for
two hundred and eighty *trillion*. So after the first few tens of
thousands of leaves, every leaf in that slot is the same hash: the hash
of a machine waiting. You have seen this on the toy: states eight
through sixteen are one and the same dot. And the millions of empty
request slots after the last real request all repeat one dot too: the
one the last request ended on.

> **Pause and ponder.** A tree has a trillion leaves and every one of
> them is the same hash. How many hash operations does it take to
> compute its root?

> **On screen.** Over the faded trail, a single column of dots rises:
> each dot is the hash of two copies of the one below, and stands for a
> triangle twice as wide. A counter: "leaves covered" races into the
> trillions; "hashes computed" ticks 1, 2, 3, … 40.

Forty. Two copies of the leaf hash to one value. Two copies of *that*
hash to the next. Each level costs one operation, however many leaves
are underneath, and a trillion is about two to the forty.

So the impossible tree collapses. And the stretch that does vary can be
thinned too: keep one hash for every sixteen leaves, and if a dispute
ever reaches inside a group, re-run the machine from a saved copy and
rebuild just that group. For our whole three-request epoch, the honest
player stores about nine thousand hashes.

> **Web page.** A claim builder. Sliders for how long the program really
> runs and for the sampling interval; live counts of leaves covered,
> hashes computed, and hashes stored, for the coarse tree and one fine
> tree.

## 12. Joining

> **On screen.** A player's coarse tree. The top two branches glow and
> detach, along with a thin path from the rightmost leaf up to the root.
> They fly to the referee.

To enter the dispute, a player posts a claim, and it is small. Two
things: the two top branches of its tree, and a proof of its very last
leaf. The referee hashes the two branches together to get the root, and
checks that the proof climbs to that same root.

Why the last leaf? Because the last leaf is the state at the end of the
epoch, the thing in dispute. A claim does not just say "my history has
this fingerprint". It says "my history has this fingerprint, *and it
ends here*". Why the two top branches? You will see in a moment.

> **On screen.** Eight packages arrive. Their roots line up as eight
> dots of eight different colors. Then two more arrive with the same
> blue root, and stack onto the blue dot.

Claims with the same root are the same claim. The referee keeps one dot;
how many players stand behind it makes no difference to the dispute.

> **On screen.** The eight faces from section 2, in a row. Each now
> holds a small tree with a colored root. Three empty chairs still hold
> theirs.

So here is where we are. Eight players; each has posted the root of a
tree nobody could build leaf by leaf. Seven of those
trees have a lie in them somewhere. It is time to make two of them
fight.

---

# Act IV. The match

## 13. Walking two trees

> **On screen.** The honest player's and the tamperer's coarse toy
> trees, 4 leaves each, one above the other. Their roots are different
> colors. Their leaves are hidden.

Two claims, two different roots. Somewhere among the leaves is the first
place they differ. A *match* is how the referee finds it. Take the
honest player and the tamperer, with the trees they joined with: four
leaves each, on the toy.

> **Pause and ponder.** You may look at the two branches under any node,
> in either tree. What rule takes you to the *first* leaf where the
> trees differ?

> **On screen.** The two trees superimposed. At the top, the left
> branches are compared: same color. The whole left half turns green and
> dims; the walk steps right, and stops above the last two leaves. The
> opener's two are now showing; the other claim's are still hidden.

Compare the left branches. **If they differ, go left. If they are the
same, go right.**

If the left branches differ, there is a disagreement on the left, and it
comes before anything on the right. If they are the same, then the
entire left halves are identical, leaf for leaf, because equal hashes
mean equal contents, as far as anyone can find. But the two nodes we are
standing on differ, at the root and at every level after it. So the
disagreement must be on the right.

On the toy: the left branches match, so go right. Now we are standing
one level above two leaves, and that last comparison gets special
treatment, in a moment. But notice what the rule gives us for free.
Wherever the walk ends, *every leaf to its left is identical in both
trees.*

> **On screen.** The referee's notepad, with three slots: "to open",
> "the other's left", "the other's right". A turn marker flips between
> blue and orange as the walk steps down.

How does a referee do this while holding almost nothing? The two claims
take turns, and each turn *opens* one node.

Watch one turn on the toy. Blue goes first. It shows the two halves
under its root, and, because it can see the walk is about to step right,
the two leaves under its right half as well. The referee checks the one
thing it can: that each pair hashes to the node above it. It compares
blue's left half with the tamperer's left half, which the tamperer
posted when it joined. That is why every claim is posted with its two
top branches. They match. Step right.

Now it is the tamperer's turn, one level down, and blue's two leaves are
already on the table for it to be compared against. So at any moment the
referee is remembering just three hashes: the node to be opened next,
and the other side's two branches.

The toy tree takes one turn. The real one has sixty-two levels:
sixty-one turns, each a couple of hash operations.

> **Web page.** A match simulator on two 32-leaf trees. A slider sets
> the first differing leaf. Step through; the three slots update; each
> reply shows its hash checks. A "cheat" button reveals branches that do
> not hash to the node, and the reply is rejected.

The walk stops one level above the leaves. The last move is unlike the
others.

## 14. The seal

> **On screen.** The bottom of the two coarse toy trees: the right-hand
> pair of leaves, the third and the fourth, in each tree.

This last move is called the *seal*. The claim on turn reveals its last
two leaves, and the referee compares the left ones as before. If they
differ, the left leaf is where the claims part. If they match, it is the
right one. On the toy they differ. The third leaf: the state after tick
twenty-four.

But knowing *where* they part is only half of it. To check anything, the
referee needs somewhere to start: the state **just before**, which both
accept. That is the leaf immediately to the left.

> **On screen.** The yellow third leaf is the left one of its pair. The
> camera pans left, across the middle of the tree, to the second leaf,
> which glows green: the state after tick 16. A path lights up from that
> leaf to the root.

Here that leaf is not even in the pair. It is the second leaf, over in
the other half of the tree. So the seal always carries a proof of it: a
path from that leaf up to the claim's own root. (And if the claims part
at the very first leaf, there is nothing before it; the starting point
is then the state everyone agreed on before the dispute began.)

> **Pause and ponder.** Two claims are in dispute and the referee trusts
> neither. Yet it accepts the agreed state on the word of just one of
> them. Why is that safe?

Because of what the walk gave us for free. Everything to the left of the
parting leaf is identical in both trees. A leaf proven in one is the
same leaf in the other.

> **On screen.** Both trees fade out. Three dots remain: one green, and
> to its right one blue and one orange. Under them, the toy machine after
> tick 16, and its two rival versions after tick 24: both with total 42,
> one with spare 0, one with spare 9. The motif.

And there it is again. One state both accept. Two rival accounts of what
comes next. The same picture the halving game ended on. But this time
nobody was free to choose an answer along the way: every reply in this
walk was fixed the moment the two roots were posted, and anyone holding
the tree could have given it.

But look at what lies between the green dot and the other two. Not one
step. Eight ticks. On the real epoch, a thousand instructions. The
referee cannot check that.

## 15. Inside the gap

You already know what happens. We go inside.

> **On screen.** The yellow leaf swells into a window, ticks 17 to 24.
> Inside it, a smaller bracket appears. Two dots drop into it, blue and
> orange, each tagged with which of the two outer dots it ends in.

The match is paused, and a second tournament opens inside it.
Its subject is that one stretch. Its starting point is the green dot.
Anyone who stands behind either of the two claims may enter, with a fine
tree: one leaf for every tick of the stretch. Eight leaves, on the toy.
This is a new commitment, made now; the outer root fixed only where it
must end.

There is one rule for entry, and it is why claims carry a proof of their
last leaf. The last leaf of a fine tree is the state at the *end* of the
stretch. And the end of the stretch is exactly what the two outer claims
disagree about. So a fine claim is admitted only if it ends in one of
the two disputed dots. You have to be on one side or the other.

> **On screen.** The two fine toy trees, 8 leaves each, superimposed.
> Left branches: same; step right. Left branches: differ; step left.
> Left leaves: same; so the right one. The sixth leaf glows yellow, and
> the fifth, right beside it, glows green.

Then it all happens again, inside. Left branches match: go right.
Left branches differ: go left. And at the seal, the left leaves match,
so it is the right one. Right, left, right: the sixth leaf. The state
after tick twenty-two. This time the leaf before it is right there in
the pair: the state after tick twenty-one.

> **On screen.** The fine trees fade. Three dots: green, then blue and
> orange. Under them, the toy machine after tick 21, and its two rival
> versions after tick 22: spare 0, spare 9. The motif, for the third
> time.

Tick twenty-two. The halving game found it by asking five questions and
trusting the answers to be consistent. The trees found it with no answer
left to anyone's discretion.
And now the gap between the green dot and the other two is as small as
it can be.

## 16. One step, checked

One step. That is the moment all of this was for. The referee asks for
the log of that one step, replays it from the green dot, and gets a
hash. On the toy it is the log we have already seen: read the position,
1; read the stage, 1; write the position, 2.

> **Pause and ponder.** Suppose the only player still at the table is
> the liar, and the referee asks *it* for the log. What are its options?

> **On screen.** The three dots. A log slides in from the blue player.
> The green dot on the notepad holds its color through the two reads,
> changes on the write, and comes to rest as blue. The orange dot shatters. Rewind. The log slides in from
> the *orange* player instead. The result is still blue.

It has two. It can stay silent, which loses, as we will see. Or it can
send a log. But from the green dot, only one next state can be proven.
Any log that the referee accepts lands on blue. The liar's only valid
move is to prove itself wrong.

So the referee does not care who sends the log. Whichever claim
committed to the hash that comes out wins. The other is eliminated. And
if neither committed to it, both are.

> **On screen.** The surviving blue fine tree's last leaf floats up out
> of the window and lands on the blue outer dot, which lights up. The
> orange outer dot goes dark. The window closes.

And the result travels back up. The fine claim that survives ends in one
of the two disputed outer dots, and whichever outer claim committed to
that dot wins the match. The tamperer is out: over one 9, in a box
nobody reads, with every answer correct.

The inner tournament is the outer tournament again. The same idea, used
on itself.

## 17. Why the truth wins

It worked on the toy. Why should we believe it *always* works?

> **On screen.** A blue tree labelled "true at every leaf". An arbitrary
> red tree is laid over it. A yellow leaf appears where they first
> differ, with a green leaf before it.

Take a claim that is honest: every leaf is the true state at that
moment. Put it against any other claim whatsoever.

The walk finds the first leaf where they differ. The leaf before is
agreed, so it equals the honest claim's leaf there, so it is the *true*
state at that moment.

> **On screen.** An arrow, "one true step", runs from the green leaf and
> lands on blue. The red tree is swapped for a dozen others in quick
> succession, the yellow leaf jumping around. The arrow always lands on
> blue.

So the check starts from a true state. From a true state, the one step
that can be proven leads to the true next state. That is the honest
claim's leaf. The honest claim wins. And one level up it is the same
argument: the inner tournament starts from a true state, the honest fine
claim wins every match in it, and it ends in the honest dot.

Notice what the argument does not need. It does not need the liar to be
clumsy: the honest player never has to show the other side wrong in
general, only to be right at one leaf. It does not care whether liars
beat other liars along the way; the winner still has to meet the honest
claim. And it does not depend on how many liars there are.

It does need one thing, and we have been taking it for granted: that
somebody is there to play the honest claim's moves. That, and a world
with rather more than two claims, is what is left.

---

# Act V. The crowd, again

## 18. Brackets

> **On screen.** The eight faces again; each becomes a dot and drops
> into a tournament bracket. Round one:
> all four matches flash at once and half the dots vanish. Round two.
> Round three. One dot is left.

A tournament is nothing more than this. While more than one claim
survives, pair up the survivors, play all the matches at once, keep the
winners. If the number is odd, one claim sits the round out.

Every round halves the field. Eight claims, three rounds. A thousand,
ten. A million, twenty.

> **On screen.** A graph: claims along the bottom, doubling at each
> mark; rounds up the side. A straight line. Beside it, a thousand
> identical red figures collapse into one red dot.

That is what takes the stalling attack away. Within one tournament, to
double the number of rounds an attacker has to *square* the number of
different lies it tells. A crowd can pile into the inner tournaments
too, and those are brackets as well, so in a bracket like this one the
delay grows with logarithms of the crowd, not with the crowd itself. And
fake
accounts count for nothing unless they hold *different* claims. A
thousand accounts repeating one lie are one claim, and fall in one
match.

But all of this quietly assumes that when the referee asks, somebody
answers. What if nobody does?

## 19. Silence

> **On screen.** A match in progress. It is the quitter's turn. Its
> chair is empty. The referee waits. A clock beside the chair starts to
> run.

This is the quitter's whole plan. Enter a claim, say nothing, and let
the dispute hang forever.

So every claim carries a **clock**. While it is a claim's turn, the
clock is ticking against it.

> **On screen.** A time axis with three colored bands, one after the
> other: "answer", "opponent claims the win", "anyone clears the table".
> Three short plays: a reply lands in the first band and the bands
> reset; nothing lands in the first, and the opponent drops a token in
> the second; nothing lands in either, and a passer-by drops a token in
> the third.

There are three windows, one after another. In the first, a valid reply
moves the match on. If that window closes, the second opens: the claim
on turn has forfeited, and its opponent may step up and take the win.
And if *that* window closes too, because the opponent has also gone, a
third opens in which anybody at all, even a player with nothing at
stake in this match, may clear both claims off the table. Otherwise two
abandoned claims could hold a tournament open forever.

That is what catches the quitter.

Now the word in the name: *permissionless*. Who is allowed to answer for
a claim?

Anyone. What makes a reply valid is never who sent it. It is what the
reply contains.

> **Pause and ponder.** If anyone may answer for a claim, then your
> opponent may answer for *yours*. What is the worst it can do?

> **On screen.** An orange hand reaches over and places two branches
> under the blue node. They do not hash to it: rejected. It tries the
> only pair that does: accepted, and it is exactly what blue would have
> played.

Nothing. To open a node you must show two branches that hash to it, and
only one such pair can be found. The only reply the referee will accept
on behalf of a claim is that claim's own true reply. An enemy who makes
your move for you has simply made your move.

There is one more thing an enemy can try: enter a bogus fine tree on
*your* side of an inner tournament, or a hundred of them. Each is just
one more claim in that inner bracket, and the true fine tree, entered by
anyone honest, beats them all like any other lie.

> **On screen.** Five identical blue computers around the world, each
> holding the same tree. Four go dark one by one. The fifth makes the
> move. The blue dot in the bracket stays lit.

And this is what makes honesty robust. Every honest computer builds the
same claim. They need not coordinate, or even know the others exist. If
one is offline, or slow, or being blocked, any other can make the move.
The claim falls only if every last one of them fails.

Enough theory. Let us put seven liars in a room.

> **Web page.** A clock sandbox: two claims, a block counter to advance
> by hand, and three buttons that are only live in their own windows.

---

# Act VI. The run

## 20. Eight players, seven liars

> **On screen.** The eight portraits from section 2 drop into a bracket
> as eight dots. Three of them share a thin line: "same ending,
> different history".

This is an actual run of a working model of the protocol, on the real
calculator, with its real numbers. Eight claims enter. Three of
them end in the very same state: the honest claim and both fabulists.
The fabulists agree with the truth about how the epoch ends. But a claim
is a commitment to the whole history, so they are still different
claims, and they still have to be fought. If a fabulist won, the ending
would still be right, this time. But the referee cannot tell a harmless
false history from a harmful one without checking, and what was entered
is the whole history. So it is checked.

Earlier I asked how you would catch each of these four. Here is how the
tournament does it.

> **Pause and ponder.** Eight claims, six matches. Before it starts: how
> many of those matches do you think the honest player will have to
> fight?

**Round one.** Four matches at once.

> **On screen.** Match 1. An empty chair. The clock runs out; the
> tamperer drops a token in the second band.

The first quitter meets the tamperer. It is the quitter's move, and it
has gone. Its window closes, and the tamperer takes the win. A liar
advances. That is fine.

> **On screen.** Match 4. Two empty chairs. Both windows close. A token
> drops in from outside the match and both dots vanish.

The other two quitters meet each other. Nobody moves; nobody claims the
win. So a bystander clears the table. Neither survives.

> **On screen.** Match 3. A band narrows across the real coarse tree, a
> counter spinning from 62 down to 1. It lands at the left edge of the
> third request. A window opens; a second band narrows, 30 down to 1, and
> lands on the very first tick. The referee holds the real envelope; the
> forger holds one that is slightly different.

The forger meets the honest claim. A real fight: sixty-one turns down
the coarse tree, and a seal. They part at the very first stretch of the
third request, and an inner tournament opens there. Thirty more replies,
all the way to the *first* tick of it.

The first tick of a request. That is the kind of step that puts the
request in. And the referee puts in *its own* copy, the one posted on
the chain. The forger's version is never consulted. The step leads where
the honest claim said. The forger is out, on the first of our four
steps.

> **On screen.** Match 2. Two fabulist trees, each blue but for one
> crossed-out leaf, in different places. The walk lands on the leftmost
> of the two.

And the two fabulists meet each other. The walk finds the leftmost of
their two lies, the first fabulist's. An inner tournament opens over
that stretch.

Now watch the second fabulist. It did not lie about this stretch. Here
it has nothing to defend but the truth. So it enters the *truthful*
fine claim. The first fabulist's fine tree is true right up to its last
leaf, and that leaf has to be its false dot. So that is where they
part. The step that settles it is the very last
tick of that stretch: a micro-step that does nothing, and a reset. The
first fabulist is eliminated, by a liar, telling the truth. Step two.

**Round two.** Three claims are left. The tamperer meets the surviving
fabulist; the honest claim sits out.

> **On screen.** Match 5. The band lands early in the first request, on
> the wrench icon. Inner window; the band lands on one ordinary tick.

They part exactly where the tamperer changed its machine. The fabulist,
truthful here too, enters the true fine claim. The check is one ordinary
micro-step, and it does not lead where the tamperer said, because what
the tamperer did to get there was not a step at all. Step three.

**Round three: the final.** The honest claim against the last fabulist.

> **On screen.** Match 6. The band stays near the left, just past the
> lit part of the third request, and stops on the crossed-out leaf in
> the faded trail. A machine icon beside it shows "waiting".

Its lie sits in the quiet stretch, a little after the calculator
finished the third request. It claims that a machine which was doing
nothing somehow changed.

> **On screen.** Inner window. The small processor turns a few times,
> stops, and snaps back. The dot at the start of the instruction and the
> dot after the reset are the same color; the green dot just before the
> reset is not.

The inner walk goes to the very *last* tick of the stretch: a micro-step
and a reset. Earlier I drew the waiting stretch as one steady color.
Instruction by instruction, it is. Tick by tick, not quite. Even a
waiting machine is not perfectly still. Inside each
instruction its small processor stirs, finds nothing to do, and is
reset. The machine does its tiny nothing, is reset, and comes back to
exactly the state it was in. That is not what the fabulist committed
to. Step four.

> **On screen.** The bracket, complete. One blue dot. The counter from
> the opening: "steps checked: 4".

The claim that survives is the honest one, and the state it ends in is
exactly what one honest machine computes by itself.

One thing may surprise you. One fabulist reached the final, winning twice
on the way, both times by telling the truth, both times against another
liar. But do not read too much into that: the other fabulist lied
exactly as little and went out in round one. How far a liar got was the
luck of the draw.

> **On screen.** Three walks side by side: the forger's, the tamperer's,
> a fabulist's. Each band narrows from the whole epoch to one tick. Under
> each, the same thing: one log, one checked step.

What was *not* luck is the price. The forger changed a whole request.
The tamperer changed a few bytes. A fabulist changed one leaf out of
four million trillion, placed where nothing was happening. Each of them
had to commit to its lie, each walk found it, and each fell to exactly
one checked step. The size of the lie made no difference.

And the referee? Of six matches, the honest player fought two. The
others were liars eliminating liars, or eliminating themselves by
leaving. One checked step for each match fought to the bottom. Four such
matches, four steps: on a line stretched to two to the ninety-two, to
settle a hundred billion steps of real work. With more liars there would
be more matches, and more steps. But every walk to the bottom, however
long the computation, ends in just one.

It did do other work: it checked a few thousand small hash
calculations along the way, about ninety replies for each match fought.
What it never did was run the computation.

> **Web page.** The bracket as a replay. Click a match to scrub through
> its walk, its inner walk, and the step that settled it. Each liar's
> card shows what it changed and the exact leaf where that first shows.

And yet a hash is not what anyone came for.

## 21. What anyone actually wanted

> **On screen.** The winning dot. A path descends from it into the tree
> over the machine's memory and lands on one box. Inside the box is
> another dot.

Somebody asked a calculator for two to the 2048. They want the answer,
not thirty-two bytes. Getting there is the first trick in this video,
used twice more.

Each time the program accepts a request, it writes into a known box of
its own memory the root of yet another tree: a tree of everything it has
ever answered. So a few short proofs against the winning state hash show
two things: that the machine stopped having accepted its last request,
and what that box contains.

> **On screen.** That inner dot becomes the root of a third tree. A path
> descends to one leaf, which unfolds into the 617-digit number.

And a second short proof, against *that* root, shows that this
particular answer is one of its leaves.

One tool, proving a leaf against a root, did every job today. It read a
machine's memory. It wrote to it. It pinned down a moment in a history.
And now it has handed over an answer.

---

# Close

## 22. What it asks

> **On screen.** The mountain of gears from section 3. It folds into a
> line. The line folds into a tree. The tree folds into a dot. Many dots
> enter a bracket. One is left. The referee writes it down.

So here is the whole thing.

A computation is a line of states, and each step along it can be checked
by a referee that owns no machine. To dispute a computation, do not
argue about it: commit to all of it, as the root of a tree over time.
Two commitments that differ must differ at some first leaf, so walk the
two trees to find it. If that leaf is too big to check, commit again
inside it. When it is one step, check the step. Do it for every pair at
once, in a bracket. Give every claim a clock, and accept any reply that
proves itself, from anyone.

> **On screen.** Four pillars rise under the bracket: "hashes do not
> collide", "one step, checked correctly", "the right requests and
> starting point", "one honest player, in time".

It is not magic, and it is worth saying what it rests on. Four things.
That the hash function does not collide; every "same hash, same
contents" depended on it. That the referee's idea of one step agrees
exactly with the machine honest players really run; that is why the
step was made so small, and flaws in the judge itself are what closed
Optimism's door for a while. This system carries that risk like any
other. That the requests and the starting state the referee holds are
the right ones, and that the honest player can get hold of them. And
that somebody honest shows up, and gets their replies in before the
clock runs out. The protocol protects a
claim that is defended. It cannot protect one that everybody has
abandoned.

Who wins does *not* depend on how many liars there are, or on their
strategy, or on their money. How long it takes does, but only slowly.

And it has a price. A contested result is slow and not free: every
reply is a transaction on the blockchain, paid for by whoever sends it,
and a match fought to the bottom is about ninety of them. An honest
player has to be willing to pay that, and to stay online. When nobody
lies, none of it happens.

What you have seen is a model, built to be understood. The contracts
that run in production add what a real blockchain demands: deposits put
up with each claim, clocks that really run down, like chess clocks,
pairing claims as they arrive rather than in tidy rounds, and their own
sizes for the epoch and its levels.
The logic underneath is the logic you just followed.

> **On screen.** The heavy door from section 9, now standing open. The
> guest list is on the floor. More than one path leads up to it.

Remember the guest list. The door is open now, and more than one design
opened it: Arbitrum's, which we met, is a different protocol from this
one, built for the same crowd. And the tournament in this video is no
longer only on paper either. In 2025, a first application secured by a
tournament of this kind went live on a public blockchain, open to any
challenger.

> **On screen.** Pull back. The bracket is one of many, one per epoch,
> strung along a chain of blocks, each handing its blue dot to the next.

A real computer, one that boots Linux and runs ordinary software, made
small enough at one point to be judged by a referee that can barely
compute. And a tournament built so that the crowd does not matter. One
honest computer, anywhere, and the truth survives.

> **On screen.** The opening frame again: a hundred billion, eight dots,
> one of them blue, and the counter. "Steps checked: 4."


> **Web page.** Five closing questions, each answerable in a sentence
> and linked to its section: what a state hash commits to; why halving
> fails in public; what a claim is; why the leaf before the parting is
> agreed; what happens when nobody answers.

---

# For the producer

## What the script simplifies

The narration is accurate but not exhaustive. These are the places where
it says less than the full rule; each is spelled out in the
implementer's reference.

- **Rejection.** The script says the machine "goes back". Precisely: the
  state hash just before a request is delivered is recorded inside the
  machine, and the reset that closes the rejecting instruction makes
  that recorded hash the next state hash.
- **Fixed points.** "Nothing left to do" covers a stopped small
  processor, and a machine that is waiting for a request, has halted, or
  has used up the instruction budget of its request. Inside each instruction
  slot of a waiting machine the small processor still runs briefly and
  is reset; only at instruction boundaries does the hash repeat. The
  final match depends on this.
- **The last tick of an instruction** is a micro-step that changes
  nothing followed by a reset. **The first tick of a request** puts the
  request in only if the epoch has one in that slot and the machine is
  able to take it; otherwise the delivery changes nothing and only the
  micro-step runs.
- **Stored hashes.** The honest player stores roots of small groups of
  leaves ("bundles"), sixteen coarse samples or 65,536 micro-steps each,
  and rebuilds a group by replaying the machine when a dispute enters
  it.
- **Each reply in the walk** reveals four hashes: the two branches of
  the node, and the two branches under whichever of them the walk
  descends into.
- **Who may answer.** Validity never depends on the sender. In the model
  a request is nevertheless delivered only to the players who posted
  the claim concerned, since they hold its tree.
- **Clocks** are measured in blocks. The single step at the bottom has a
  slightly different rule: either side may prove it, before the earlier
  of the two deadlines.
- **"The judge will find the truth"** means: under the assumptions of
  section 22. A fuller list would add that the tournament's parameters
  describe one consistent decomposition of the epoch, and, for
  liveness, that censorship of the honest player is bounded.
- **Delay.** "Rounds grow with the logarithm" is exact within one
  tournament. Inner tournaments are brackets too, and more than two fine
  claims may enter one, so the script says only that the total delay
  grows with logarithms of the crowd.
- **The paper and the model.** The script follows the Lua model, which
  differs from the 2022 paper in details: in the paper both sides reveal
  at each level, and the join proof is of the first state.
- **Sources.** Where the public contracts repository and the Lua model
  disagree, the script follows the model.
- **Numbers.** The real coarse tree has 62 levels and the fine tree 30;
  a walk takes 61 or 29 turns plus a seal. The sampling interval of
  1,024 instructions is a parameter of the model. The nine thousand
  stored hashes are for this three-request epoch.

## The human story, and its sources

The script tells one true story: for years the largest fraud-proof
systems restricted who could challenge, and opening the door proved
hard, for two separate reasons that the script keeps apart. Arbitrum's
list existed because of the stalling attack. Optimism's door closed
because of flaws found in its proof system, which is a different lesson
and is told as one. It is told
without judgement, and it must stay that way: no funds were lost in any
of these events, and the teams involved fixed what was found.

Facts as used, checked against the sources below in October 2026.

| Claim in the script | Source |
|---|---|
| Arbitrum's validators were allow-listed because a malicious validator could repeatedly delay withdrawals; BoLD, which bounds that delay, went live on Arbitrum One and Nova on 12 February 2025 | [The Block](https://www.theblock.co/post/340278/offchain-labs-releases-arbitrum-bold-on-mainnet-for-permissionless-validation); [Arbitrum documentation](https://docs.arbitrum.io/how-arbitrum-works/bold/bold-economics-of-disputes) |
| Optimism's permissionless fault proofs went live on 10 June 2024 and were reverted to permissioned on 17 August 2024 after community-driven audits found several bugs, two of high severity; none exploited, no user assets at risk | [The Block](https://www.theblock.co/post/311702/optimism-foundation-disables-permissionless-fraud-proofs-plans-hard-fork-following-security-audits) |
| The fix, the Granite hard fork, was scheduled for 10 September 2024 (the script says only that a fix "was scheduled for the following month") | [The Block](https://www.theblock.co/post/311702/optimism-foundation-disables-permissionless-fraud-proofs-plans-hard-fork-following-security-audits); [Messari, State of OP Mainnet Q3 2024](https://messari.io/report/state-of-op-mainnet-q3-2024) |
| *Permissionless Refereed Tournaments*, by Diego Nehab and Augusto Teixeira, was submitted on 23 December 2022; its abstract states the single-honest-competitor, logarithmic-effort result | [arXiv:2212.12439](https://arxiv.org/abs/2212.12439) |
| Canetti, Riva and Rothblum: "Practical delegation of computation using multiple servers" (2011) and "Refereed delegation of computation" (2013); correct as long as one server is honest | [Information and Computation 226 (2013)](https://doi.org/10.1016/j.ic.2013.03.003) |
| A first PRT-secured application (the Cartesi Honeypot) went live on Ethereum mainnet in June 2025, with permissionless challenges. The script does not name it | [HackerNoon](https://hackernoon.com/why-cartesis-honeypot-launch-matters-for-the-future-of-blockchain-security) |

Two cautions. The return of Optimism's permissionless proofs after the
September fix rests on a secondary summary and should be confirmed
against Optimism's own announcement; the narration no longer relies on
it. And the 2025 launch rests on press coverage; someone at Cartesi
should confirm the date before "went live" is recorded.

## The script's words and the authors' words

The script uses plain words of its own. Each maps to a term the authors
use, which the web page should show on hover and the video may show once
as a caption.

| In the script | The authors' term |
|---|---|
| request | input (advance-state request) |
| instruction | mcycle: one instruction of the main processor |
| micro-step | uarch step, or uarch cycle |
| small processor | microarchitecture (uarch) |
| tick | state transition; uarch transition; a position on the 92-bit meta-cycle |
| halving game | verification game; bisection |
| tree over time | computation hash (its root) |
| coarse tree, fine tree | mcycle claim, uarch claim |
| stretch, gap | period |
| inner tournament | uarch tournament |
| takes the win, clears the table | timeout win, elimination |
| log | access log |
| branches | children |
| guest list | permissioned validation; an allow-list |
| self-contained, reproducible, no secrets | self-contained, reproducible, transparent |

## What should be verified before release

- The two cautions under *The human story, and its sources*.
- "Four steps" counts the four verified transitions of the model's
  eight-player run, one per match fought to the bottom: one request
  delivery, two resets, one ordinary micro-step. It is a property of
  this bracket, not of the protocol. Two of the four are the
  do-nothing-and-reset tick that ends an instruction, and one of those
  lies in the padding after the calculator finished; that is why the
  script says "checked four steps to settle a hundred billion" and not
  "four of the hundred billion". If the run changes, so does the title.
- "Two of the researchers behind the Cartesi Machine" for Nehab and
  Teixeira is from general knowledge, not from a checked source.
- "The earlier Cartesi system, too, restricted disputes to a small
  committee" follows the 2022 paper's own introduction, which cites
  Cartesi Rollups as an example; confirm the wording with the authors.
- The 2025 application: the script says only that it "went live", "open
  to any challenger". Confirm both before recording.
- "A hundred billion" is an estimate of the real work, not a measured
  figure: three requests, each finished within about fifty million
  instructions, at roughly a thousand micro-steps per instruction. The
  three requests run about 51, 46 and 49 million instructions (the
  rejected second one is as long as the others), about 146 million in
  all. The instruction count is measured; the thousand micro-steps per
  instruction is an assumption (the model itself assumes about 1,024).
  That gives about 1.5 × 10<sup>11</sup>, which is why the script says
  "more than" a hundred billion. Measure it on the actual run and adjust
  sections 1, 7 and 20 and the title. The figure
  2<sup>92</sup> is the length of the padded line, and the script says
  so in section 7.
