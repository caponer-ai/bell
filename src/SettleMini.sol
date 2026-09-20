// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC-20 surface (USDG on Robinhood Chain is 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 6 decimals).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBell {
    enum Verdict {
        ALLOW,
        WAIT,
        REJECT
    }

    function checkSettle(bytes32 feedId, uint32 tradingDate, bool isClose)
        external
        view
        returns (Verdict verdict, uint8 reason, int192 mid, bytes32 receiptId);
}

/// @title SettleMini
/// @notice One trade between two parties, settled in USDG on Bell's session reference price.
///
/// The point of this contract is not the payoff, which is deliberately the simplest one that can exist:
/// the long wins if the session reference is at or above the strike, otherwise the short wins. The point
/// is *where the number comes from*. Money only moves when Bell says ALLOW, which happens only when the
/// ladder for that trading day is FINAL, and the receipt id of the DON report behind the reference is
/// written into the settlement event, so anyone can check afterwards which signed statement paid them.
///
/// The mirror of that rule is `refund()`. If the session never resolves, because nobody posted the
/// reports or because two DON statements conflicted, the contract does not invent a price and does not
/// let either side wait forever: after the refund deadline both stakes go home. A poster who stays silent
/// can therefore cancel a settlement, but can never move it, and cannot keep the money hostage.
///
/// No owner, no upgrade, no fee.
contract SettleMini {
    IBell public immutable BELL;
    IERC20 public immutable USDG;

    bytes32 public immutable feedId;
    uint32 public immutable tradingDate; // YYYYMMDD, as Bell's calendar counts days
    bool public immutable isClose; // settle on the CLOSE reference instead of the OPEN one
    int192 public immutable strike; // 18 decimals, same unit as Bell's mid
    uint256 public immutable stake; // USDG units (6 decimals) from each side
    uint64 public immutable refundAfter; // unix time from which an unresolved session can be refunded

    address public immutable long; // paid when reference >= strike
    address public immutable short; // paid when reference <  strike

    bool public longFunded;
    bool public shortFunded;
    bool public closed;

    event Funded(address indexed who, uint256 amount);
    event Settled(address indexed winner, int192 referencePrice, bytes32 receiptId, uint256 payout);
    event Refunded(uint8 reason);

    error NotAParty();
    error AlreadyFunded();
    error NotFunded();
    error AlreadyClosed();
    error NotSettleable(uint8 reason);
    error TooEarly();

    constructor(
        IBell bell,
        IERC20 usdg,
        bytes32 feedId_,
        uint32 tradingDate_,
        bool isClose_,
        int192 strike_,
        uint256 stake_,
        uint64 refundAfter_,
        address long_,
        address short_
    ) {
        BELL = bell;
        USDG = usdg;
        feedId = feedId_;
        tradingDate = tradingDate_;
        isClose = isClose_;
        strike = strike_;
        stake = stake_;
        refundAfter = refundAfter_;
        long = long_;
        short = short_;
    }

    /// @notice Each side posts its stake. Requires an ERC-20 approval for `stake`.
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
        USDG.transferFrom(msg.sender, address(this), stake);
        emit Funded(msg.sender, stake);
    }

    /// @notice Pay the winner, but only if Bell hands out a reference for this session.
    function settle() external returns (address winner, int192 referencePrice) {
        if (closed) revert AlreadyClosed();
        if (!longFunded || !shortFunded) revert NotFunded();

        (IBell.Verdict verdict, uint8 reason, int192 mid, bytes32 receiptId) =
            BELL.checkSettle(feedId, tradingDate, isClose);
        if (verdict != IBell.Verdict.ALLOW) revert NotSettleable(reason);

        closed = true;
        winner = mid >= strike ? long : short;
        referencePrice = mid;
        uint256 payout = stake * 2;
        USDG.transfer(winner, payout);
        emit Settled(winner, mid, receiptId, payout);
    }

    /// @notice Give both stakes back when the session never produced a reference.
    function refund() external {
        if (closed) revert AlreadyClosed();
        if (block.timestamp < refundAfter) revert TooEarly();

        (IBell.Verdict verdict, uint8 reason,,) = BELL.checkSettle(feedId, tradingDate, isClose);
        if (verdict == IBell.Verdict.ALLOW) revert NotSettleable(reason); // resolvable: settle it instead

        closed = true;
        if (longFunded) USDG.transfer(long, stake);
        if (shortFunded) USDG.transfer(short, stake);
        emit Refunded(reason);
    }

    /// @notice What the contract would do right now, for a UI or a judge with a terminal.
    function quote()
        external
        view
        returns (IBell.Verdict verdict, uint8 reason, int192 referencePrice, address winner)
    {
        (verdict, reason, referencePrice,) = BELL.checkSettle(feedId, tradingDate, isClose);
        winner = verdict == IBell.Verdict.ALLOW ? (referencePrice >= strike ? long : short) : address(0);
    }
}
