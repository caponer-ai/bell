# Threat model

Every entry here is a way to take money out of a user, raised by a reviewer or by us, and answered by a
test that runs rather than by a paragraph. Where the attack works, it says so and says what bounds it. A
threat model that only lists threats the code already survives is marketing.

Run the whole set:

```bash
forge test --match-path "test/Adversarial.t.sol" -vv
forge test --match-path "test/BellRobustness.t.sol"
forge test --match-path "test/SessionCalendarSchedule.t.sol"
```

## Scope

The system under attack is a trade that settles on a recorded closing mark:

| Contract | Role in the attack surface |
|---|---|
| `SessionLog` | permissionless, write-once record of what a feed said at a bell. First writer wins. |
| `PushFeedGuard` | stateless verdict on whether a feed reading is admissible. No owner, no state. |
| `SettleOnMark` | holds two USDG stakes, pays the winner from the recorded mark, refunds when it cannot. |
| `Bell` | verifies DON-signed reports and resolves a session reference by the ladder policy. |

Out of scope, stated so nobody assumes otherwise: the correctness of Chainlink's feeds themselves, the
sequencer's ordering policy, and anything an attacker does off this chain.

---

## 1. A losing party censors the mark

**Attack.** The side about to lose runs the only keeper and simply does not write the closing mark, hoping
the trade cannot settle.

**Result: fails.** `SessionLog.mark` takes no permissions and costs only gas, so the winner writes it, or
any passer-by does. The trade settles against the party that stayed silent.

Tests: `test_a_losing_party_cannot_censor_the_closing_mark`,
`test_the_winner_can_write_the_mark_without_anyone_s_help`.

## 2. Everybody stays silent

**Attack.** Nobody writes the mark at all. No mark, no settlement, and after `refundAfter` both stakes go
back. A loss becomes a draw.

**Result: this one works.** It is a property of the design, not a bug: the contract cannot mark a bell that
nobody told it about, and inventing a price is precisely what this repo refuses to do. Guessing a closing
price to avoid a refund would be a worse failure than the refund.

**What bounds it.** The mark is permissionless and cheap, the window is five minutes wide, and `quote()`
tells any watcher exactly what will happen. The winning side has a direct financial motive to spend one
transaction. The mitigation is operational: if you are the counterparty in a trade like this, write the
mark yourself or pay someone to watch. A product built on this should ship a keeper and say so.

Test: `test_silence_from_everyone_turns_a_loss_into_a_draw`.

## 3. Choosing which second becomes the mark

**Attack.** Whoever writes first picks a moment inside the mark window. If the feed publishes twice in that
window, two candidate observations can name different winners.

**Result: the lever is real.** With `markWindow` at 120 seconds, a mark at `C - 100` on 334.90 pays the
short and a mark at `C - 30` on 335.10 pays the long, on the same trade and the same strike.

**What bounds it.** `SettleOnMark` requires `markedAt + markWindow >= closeUtc`, which cuts the choice from
the log's 300-second window down to the trade's own budget; both candidate observations stay onchain and
comparable after the fact; and because anyone may write the mark, the lever belongs to whoever is fastest
rather than to a privileged role. A trade that cannot tolerate this should set `markWindow` smaller, at the
cost of refunding more often.

Test: `test_the_second_chosen_inside_the_window_can_decide_the_winner`.

## 4. The guard refuses forever and the money is trapped

**Attack.** Several reviewers raised this about oracle adapters in general: a contract that reverts when the
oracle is inadmissible can block the very operation that releases funds, turning a safety check into a
freeze.

**Result: fails, because the exit never reads the oracle.** Three versions are tested:

- a trading date outside the tabulated calendar years, where `SessionCalendar` fails closed and no
  admissible mark can ever exist: `test_money_leaves_even_when_the_calendar_can_never_say_yes`;
- a mark the guard refused outright, here a feed answering zero: `test_a_mark_the_guard_refused_does_not_trap_the_stakes`;
- a mark the guard passed but whose price is older than the trade's own budget:
  `test_a_mark_older_than_the_trade_s_budget_does_not_trap_the_stakes`.

Note the split, because it is the design and not an accident: `SessionLog` records with an unlimited age
budget (`type(uint64).max`), since the log's job is to state what the session was. The age budget belongs
to the consumer, so a mark can be admissible to the log and still unusable by the trade.

**The converse must also hold**, or the refund path becomes an escape hatch from a loss: while an admissible
mark exists, `refund()` reverts no matter how long the loser waits.
Test: `test_the_loser_cannot_escape_through_refund`.

## 5. Selective submission of DON reports

**Attack.** A submitter holds several signed reports and publishes only the one that suits them, or
withholds an early admissible report to wait for a more favourable rung. A valid signature proves the
report is authentic, not that it is the best one available.

**Result: the payout does not move.** The ladder's rungs are fixed by the calendar, not by arrival order,
so the canonical price is a function of which rungs are covered rather than of what the submitter chose to
send. Withholding does not raise the payout; it produces `UNRESOLVED`.

Tests in `test/BellRobustness.t.sol`: `test_every_subset_pays_the_canonical_price_or_nothing`,
`test_poster_cannot_lift_the_payout_by_publishing_a_higher_rung`,
`test_every_permutation_pays_the_same`, `test_late_reports_cannot_move_a_settled_payout`,
`test_same_rung_conflict_refuses_in_both_orders`.

**What remains true anyway:** a submitter who publishes nothing leaves the reference unresolved, which is
threat 2 in another costume, with the same operational answer.

## 6. A wrong calendar, quietly

**Attack.** The nastiest oracle bug is not a revert: it is a calendar that calls a closed day open, or an
early close a full session, on exactly the day when settlements are most sensitive.

**Result: checked day by day.** `SessionCalendarSchedule.t.sol` walks every day of 2026 and 2027 against
NYSE's own published holiday and early-closing schedule, asserting existence, open, close and the early
flag, with 251 trading days per year and the three half-days tabulated explicitly.

**Stated limit.** The calendar is a table, so it is right only for the years in it. Outside 2026 and 2027
`SessionCalendar` fails closed, which is why threat 4's harshest test uses a 2028 date. It also cannot know
about an unscheduled trading halt, because nothing onchain tells it about one.

## 7. Impostor tokens and impostor feeds

**Attack.** A pool pairs USDG with a token whose `symbol()` says `AAPL`. A symbol is a string anyone can
choose.

**Result: filtered by lineage, not by name.** Genuine stock tokens on this chain are 283-byte beacon
proxies with the beacon `0xe10b6f6b275de231345c20d14ab812db62151b00` burned into the runtime code. Four of
the sixty-two symbol-matched pools failed that test: a fake AMD, two fake SLV and a fake USO, all of them
3,877 to 8,120 bytes of unrelated code.

**Stated limit.** Anyone can deploy an identical proxy on the same beacon, so this proves lineage and not
issuance. What closes the practical gap here is that the 58 surviving pools carry 17 tickers across 17
distinct addresses, with no ticker claimed twice. Absent a registry published by the issuer, that is the
strongest check available from the chain alone.

## 8. What this project does not defend against

Said plainly, because a threat model is only useful if it has edges:

- **A feed that lies.** If Chainlink publishes a wrong price inside the regular session, every contract
  here passes it through. The guard judges admissibility, never accuracy.
- **Sequencer ordering.** Whoever gets ordered first inside a block wins threat 3's race. Nothing here
  changes that.
- **An unscheduled halt.** The exchange can stop trading on a day the calendar calls open.
- **Economic manipulation of the underlying market.** Out of scope entirely.
