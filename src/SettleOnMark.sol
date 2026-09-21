// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SessionLog} from "./SessionLog.sol";
import {PushFeedGuard} from "./PushFeedGuard.sol";
import {SessionCalendar} from "./SessionCalendar.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SettleOnMark
/// @notice One trade between two parties, escrowed in USDG, settled on the closing mark that
///         `SessionLog` recorded for a feed on a given trading day.
///
/// This is the consumer that can exist today. Its sibling `SettleMini` settles on Bell's DON-signed
/// session reference and is waiting for a Data Streams subscription; this one settles on the public
/// record of what a Chainlink push feed said at the closing bell, which needs no subscription at all and
/// is already accumulating on mainnet.
///
/// Three rules decide whether money moves, and all three are checks on the *record*, not on a price:
///   1. the closing mark for (feed, tradingDate) must exist, and marks are write-once;
///   2. its verdict must be ALLOW, so the exchange was open and the number was a real price;
///   3. the price behind it must have been younger than `maxPriceAge` at the moment of the mark, which
///      is the caller's risk budget, chosen when the trade is written rather than argued about after.
///
/// Fail any of them and there is no settlement, only `refund()`. The contract never invents a price, and
/// it cannot be made to settle on a day the exchange was shut: that is exactly the failure the audit in
/// `docs/REPLAY.md` found in the only live stock market on this chain.
///
/// Units, because mixing them is how this goes wrong: the equity feeds here report **8 decimals**, so the
/// strike is 8 decimals too. USDG has **6**. Nothing multiplies a price by a stake; the payoff is binary.
///
/// No owner, no upgrade, no fee.
contract SettleOnMark {
    SessionLog public immutable LOG;
    IERC20 public immutable USDG;

    address public immutable feed;
    uint32 public immutable tradingDate; // YYYYMMDD
    int192 public immutable strike; // 8 decimals, like the feed
    uint64 public immutable maxPriceAge; // seconds: how stale the marked price may be
    uint64 public immutable markWindow; // seconds before the bell within which the mark must have been taken
    uint256 public immutable stake; // USDG units (6 decimals) per side
    uint64 public immutable refundAfter;

    address public immutable long; // paid when the closing mark is at or above the strike
    address public immutable short;

    bool public longFunded;
    bool public shortFunded;
    bool public closed;

    event Funded(address indexed who, uint256 amount);
    event Settled(address indexed winner, int192 closingPrice, uint64 priceAge, uint256 payout);
    event Refunded(string reason);

    error NotAParty();
    error AlreadyFunded();
    error NotFunded();
    error AlreadyClosed();
    error NoMark();
    error MarkNotAdmissible(uint8 reason);
    error PriceTooOld(uint64 age);
    error TooEarly();
    error StillSettleable();
    error NoSession();
    error MarkTooFarFromTheBell(uint64 markedAt, uint64 closeUtc);
    error TransferFailed();

    constructor(
        SessionLog log_,
        IERC20 usdg_,
        address feed_,
        uint32 tradingDate_,
        int192 strike_,
        uint64 maxPriceAge_,
        uint64 markWindow_,
        uint256 stake_,
        uint64 refundAfter_,
        address long_,
        address short_
    ) {
        LOG = log_;
        USDG = usdg_;
        feed = feed_;
        tradingDate = tradingDate_;
        strike = strike_;
        maxPriceAge = maxPriceAge_;
        markWindow = markWindow_;
        stake = stake_;
        refundAfter = refundAfter_;
        long = long_;
        short = short_;
    }

    function fund() external {
        if (closed) revert AlreadyClosed();
        if (msg.sender == long) {
            if (longFunded) revert AlreadyFunded();
            longFunded = true;
        } else if (msg.sender == short) {
            if (shortFunded) revert AlreadyFunded();
            shortFunded = true;
        } else {
            revert NotAParty();
        }
        if (!USDG.transferFrom(msg.sender, address(this), stake)) revert TransferFailed();
        emit Funded(msg.sender, stake);
    }

    /// @notice Pay the winner from the recorded closing mark, or revert with the reason it cannot.
    function settle() external returns (address winner, int192 closingPrice) {
        if (closed) revert AlreadyClosed();
        if (!longFunded || !shortFunded) revert NotFunded();

        SessionLog.Mark memory m = LOG.getMark(feed, tradingDate, SessionLog.Kind.CLOSE);
        if (!m.set) revert NoMark();
        if (m.verdict != uint8(PushFeedGuard.Verdict.ALLOW)) revert MarkNotAdmissible(m.reason);

        // The mark window is 300 s wide, so whoever calls first chooses a second inside it. For a
        // settlement that is a lever: a party could wait for a favourable tick. Require the mark to sit
        // close to the bell, which removes most of the choice and makes the rest visible onchain.
        SessionCalendar.Session memory s = LOG.GUARD().sessionForDate(tradingDate);
        if (!s.exists) revert NoSession();
        if (m.markedAt + markWindow < s.closeUtc) revert MarkTooFarFromTheBell(m.markedAt, s.closeUtc);

        uint64 age = m.markedAt - m.updatedAt;
        if (age > maxPriceAge) revert PriceTooOld(age);

        closed = true;
        winner = m.answer >= strike ? long : short;
        closingPrice = m.answer;
        uint256 payout = stake * 2;
        if (!USDG.transfer(winner, payout)) revert TransferFailed();
        emit Settled(winner, m.answer, age, payout);
    }

    /// @notice Return both stakes when the day produced no admissible closing mark.
    function refund() external {
        if (closed) revert AlreadyClosed();
        if (block.timestamp < refundAfter) revert TooEarly();

        if (_settleable()) revert StillSettleable();
        SessionLog.Mark memory m = LOG.getMark(feed, tradingDate, SessionLog.Kind.CLOSE);

        closed = true;
        if (longFunded && !USDG.transfer(long, stake)) revert TransferFailed();
        if (shortFunded && !USDG.transfer(short, stake)) revert TransferFailed();
        emit Refunded(!m.set ? "no closing mark" : "mark not settleable");
    }

    /// @notice What would happen right now, for a UI, a judge, or the other side of the trade.
    function quote()
        external
        view
        returns (bool settleable, string memory reason, int192 closingPrice, uint64 priceAge, address winner)
    {
        SessionLog.Mark memory m = LOG.getMark(feed, tradingDate, SessionLog.Kind.CLOSE);
        if (!m.set) return (false, "no closing mark yet", 0, 0, address(0));
        uint64 age = m.markedAt - m.updatedAt;
        if (m.verdict != uint8(PushFeedGuard.Verdict.ALLOW)) {
            return (false, "mark not admissible", m.answer, age, address(0));
        }
        SessionCalendar.Session memory s = LOG.GUARD().sessionForDate(tradingDate);
        if (!s.exists) return (false, "no session on that date", m.answer, age, address(0));
        if (m.markedAt + markWindow < s.closeUtc) {
            return (false, "mark taken too far from the bell", m.answer, age, address(0));
        }
        if (age > maxPriceAge) return (false, "marked price older than the budget", m.answer, age, address(0));
        return (true, "ok", m.answer, age, m.answer >= strike ? long : short);
    }

    function _settleable() internal view returns (bool) {
        SessionLog.Mark memory m = LOG.getMark(feed, tradingDate, SessionLog.Kind.CLOSE);
        if (!m.set || m.verdict != uint8(PushFeedGuard.Verdict.ALLOW)) return false;
        SessionCalendar.Session memory s = LOG.GUARD().sessionForDate(tradingDate);
        if (!s.exists || m.markedAt + markWindow < s.closeUtc) return false;
        return (m.markedAt - m.updatedAt) <= maxPriceAge;
    }
}
