// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SessionCalendar} from "./SessionCalendar.sol";

/// @notice Chainlink Data Streams VerifierProxy (Robinhood Chain: 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7).
interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
    function getVerifier(bytes32 configDigest) external view returns (address);
}

/// @notice ERC-8056 Scaled UI Amount + Robinhood corporate-action pause flag (Stock.sol).
interface IStockToken {
    function uiMultiplier() external view returns (uint256);
    function oraclePaused() external view returns (bool);
}

/// @title Bell
/// @notice Onchain session status and settlement reference for tokenized US equities,
///         fed by DON-signed Chainlink Data Streams v11 reports.
///
/// One contract, no owner, no upgrade. Anyone posts a signed report; Bell verifies it
/// through the official VerifierProxy and records:
///   - the latest admissible observation per feed (status, mid, freshness);
///   - the session reference price (Bell policy v2) for OPEN and CLOSE of each trading day, which is
///     Bell's own selection from DON reports and not the exchange's official print;
///   - a receipt for every accepted report (proof of price selection).
///
/// Reference policy v2, "the ladder". Every fixing has RUNGS target seconds fixed by the
/// calendar alone: OPEN rung i = O + 30 i, CLOSE rung i = C - 1 - 30 i, i in [0, RUNGS).
/// A DON report is evidence for rung i when its signed interval covers the target
/// (validFromTimestamp <= T_i <= observationsTimestamp). Eligible evidence (regular session,
/// fresh mid) is the candidate for that rung; ineligible evidence proves the rung out.
/// The reference is the candidate at the lowest rung whose lower rungs are all proven out.
/// Nobody can pick a price by choosing which second to publish: for every rung the DON has
/// exactly one statement, and skipping a rung leaves the fixing UNRESOLVED, never a
/// different price. Policy v1 (minimum observationsTimestamp inside the window) was
/// withdrawn for exactly that reason: a poster could withhold the earliest report.
///
/// Spec: docs/SPEC-v0.1.uk.md. No candidate -> UNRESOLVED, never a fallback.
contract Bell {
    // ------------------------------------------------------------------
    // Constants (policy v2)
    // ------------------------------------------------------------------
    uint32 public constant POLICY_VERSION = 2;
    uint32 public constant CALENDAR_VERSION = SessionCalendar.CALENDAR_VERSION;
    uint64 public constant WINDOW = 300; // posting deadline: [O, O+WINDOW) for OPEN, [C-WINDOW, C+WINDOW) for CLOSE
    uint64 public constant RUNG = 30; // seconds between ladder rungs
    uint8 public constant RUNGS = 8; // rungs per fixing (targets span 210 s)
    uint64 public constant MAX_OBS_AGE = 30; // LIVE: observation age
    uint64 public constant MAX_MID_AGE = 60; // LIVE: mid freshness via lastSeenTimestampNs
    uint64 public constant MAX_CLOCK_SKEW = 2; // seconds
    uint64 internal constant NS = 1e9;
    uint32 internal constant STATUS_REGULAR = 2;

    IVerifierProxy public immutable PROXY;

    /// @notice Optional feedId -> stock token binding, set once at deployment (no admin afterwards).
    ///         When bound, every accepted report snapshots the token's uiMultiplier at acceptance and
    ///         admissibility checks honour the issuer's oraclePaused() flag.
    mapping(bytes32 feedId => address) public stockToken;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------
    struct ReportV11 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 mid;
        uint64 lastSeenTimestampNs;
        int192 bid;
        int192 bidVolume;
        int192 ask;
        int192 askVolume;
        int192 lastTradedPrice;
        uint32 marketStatus;
    }

    struct Latest {
        int192 mid;
        int192 bid;
        int192 ask;
        uint32 observationsTimestamp;
        uint32 expiresAt;
        uint32 marketStatus;
        uint64 lastSeenTimestampNs;
        uint64 acceptedAt;
        bytes32 receiptId;
    }

    struct Candidate {
        int192 mid;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint64 lastSeenTimestampNs;
        bytes32 receiptId;
        uint256 multiplier; // ERC-8056 uiMultiplier snapshot at acceptance (1e18 = 1.0); 0 if unbound
        uint8 rung; // ladder rung this candidate covers
        bool set;
        bool conflict; // two different DON statements cover this rung
    }

    struct Fixing {
        Candidate cand;
        uint8 provenMask; // bit i set: a DON report covering rung i was posted and is not eligible
    }

    struct SessionRef {
        Fixing open;
        Fixing close;
    }

    struct Receipt {
        bytes32 feedId;
        bytes32 configDigest;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint32 expiresAt;
        uint32 marketStatus;
        uint32 tradingDate;
        uint64 lastSeenTimestampNs;
        uint64 acceptedAt;
        uint64 blockNumber;
        int192 mid;
        uint256 multiplier; // uiMultiplier snapshot at acceptance; 0 if feed is not bound to a token
        uint8 phase; // 0 none, 1 evidence for the OPEN fixing, 2 evidence for the CLOSE fixing
    }

    enum Phase {
        NO_SESSION,
        NO_DATA,
        OPEN_PENDING,
        OPEN_FINAL,
        OPEN_UNRESOLVED,
        CLOSE_PENDING,
        CLOSE_FINAL,
        CLOSE_UNRESOLVED
    }

    enum Verdict {
        ALLOW,
        WAIT,
        REJECT
    }

    enum Reason {
        OK,
        NO_DATA,
        EXPIRED,
        OBS_STALE,
        MID_STALE,
        STATUS_UNKNOWN,
        NON_REGULAR,
        OUTSIDE_SESSION,
        REFERENCE_PENDING,
        REFERENCE_UNRESOLVED,
        NO_SESSION,
        CA_PAUSED
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    mapping(bytes32 feedId => Latest) public latest;
    mapping(bytes32 sessionId => SessionRef) internal _refs;
    mapping(bytes32 receiptId => Receipt) internal _receipts;

    /// @notice Receipt of an accepted report (zero struct if unknown).
    function receipt(bytes32 receiptId) external view returns (Receipt memory) {
        return _receipts[receiptId];
    }

    // ------------------------------------------------------------------
    // Events / errors
    // ------------------------------------------------------------------
    event ReportAccepted(
        bytes32 indexed receiptId,
        bytes32 indexed feedId,
        uint32 indexed tradingDate,
        uint32 observationsTimestamp,
        int192 mid,
        uint32 marketStatus,
        uint8 phase
    );
    event ReferenceCandidate(
        bytes32 indexed feedId,
        uint32 indexed tradingDate,
        bool isClose,
        uint8 rung,
        uint32 observationsTimestamp,
        int192 mid
    );
    event ReferenceConflict(bytes32 indexed feedId, uint32 indexed tradingDate, bool isClose, uint8 rung);
    event RungProven(bytes32 indexed feedId, uint32 indexed tradingDate, bool isClose, uint8 rung);

    error WrongSchema();
    error Expired();
    error BadTimestamps();
    error BadPrice();
    error ClockSkew();
    error NotYetValid();

    error LengthMismatch();

    /// @param feedIds v11 feed ids to bind; tokens the matching ERC-8056 stock tokens (same length).
    constructor(IVerifierProxy proxy, bytes32[] memory feedIds, address[] memory tokens) {
        PROXY = proxy;
        if (feedIds.length != tokens.length) revert LengthMismatch();
        for (uint256 i = 0; i < feedIds.length; i++) {
            stockToken[feedIds[i]] = tokens[i];
        }
    }

    // ------------------------------------------------------------------
    // Posting
    // ------------------------------------------------------------------

    /// @notice Verify a DON-signed v11 report and record it. Idempotent on replay.
    /// @return receiptId keccak256 of the signed payload.
    function post(bytes calldata payload) external returns (bytes32 receiptId) {
        receiptId = keccak256(payload);
        if (_receipts[receiptId].acceptedAt != 0) return receiptId; // replay: no state change

        // Verification is delegated to the official proxy: bad signature, unknown or
        // deactivated configDigest revert here. Fees are subscription-based on this chain.
        bytes memory verified = PROXY.verify(payload, "");
        ReportV11 memory r = abi.decode(verified, (ReportV11));
        if (bytes2(r.feedId) != 0x000b) revert WrongSchema();

        uint64 t = uint64(block.timestamp);
        if (r.expiresAt < t) revert Expired();
        if (r.validFromTimestamp > r.observationsTimestamp) revert BadTimestamps();
        if (r.mid <= 0) revert BadPrice();
        if (r.observationsTimestamp > t + MAX_CLOCK_SKEW) revert ClockSkew();
        if (r.lastSeenTimestampNs > (uint64(r.observationsTimestamp) + MAX_CLOCK_SKEW) * NS) revert ClockSkew();
        if (t < r.validFromTimestamp) revert NotYetValid();

        bytes32 digest = bytes32(payload[0:32]); // reportContext[0]
        uint256 multiplier = _multiplierNow(r.feedId);

        // Latest admissible observation: only a newer observation replaces the stored one.
        Latest storage L = latest[r.feedId];
        if (r.observationsTimestamp > L.observationsTimestamp) {
            L.mid = r.mid;
            L.bid = r.bid;
            L.ask = r.ask;
            L.observationsTimestamp = r.observationsTimestamp;
            L.expiresAt = r.expiresAt;
            L.marketStatus = r.marketStatus;
            L.lastSeenTimestampNs = r.lastSeenTimestampNs;
            L.acceptedAt = t;
            L.receiptId = receiptId;
        }

        // Session reference evidence.
        SessionCalendar.Session memory s = SessionCalendar.sessionAt(r.observationsTimestamp);
        uint8 phase = 0;
        if (s.exists) phase = _applyToFixings(r, s, t, receiptId, multiplier);

        _receipts[receiptId] = Receipt({
            feedId: r.feedId,
            configDigest: digest,
            validFromTimestamp: r.validFromTimestamp,
            observationsTimestamp: r.observationsTimestamp,
            expiresAt: r.expiresAt,
            marketStatus: r.marketStatus,
            tradingDate: s.tradingDate,
            lastSeenTimestampNs: r.lastSeenTimestampNs,
            acceptedAt: t,
            blockNumber: uint64(block.number),
            mid: r.mid,
            multiplier: multiplier,
            phase: phase
        });
        emit ReportAccepted(receiptId, r.feedId, s.tradingDate, r.observationsTimestamp, r.mid, r.marketStatus, phase);
    }

    /// @dev Regular-session freshness of a report (spec §2): status 2, mid seen, o - 60 <= l/1e9 <= o + 2.
    function _fresh(ReportV11 memory r) internal pure returns (bool) {
        if (r.marketStatus != STATUS_REGULAR) return false;
        if (r.lastSeenTimestampNs == 0) return false;
        uint64 obsNs = uint64(r.observationsTimestamp) * NS;
        if (r.lastSeenTimestampNs + MAX_MID_AGE * NS < obsNs) return false;
        if (r.lastSeenTimestampNs > obsNs + MAX_CLOCK_SKEW * NS) return false;
        return true;
    }

    /// @dev Routes a report to the OPEN or CLOSE fixing of its session if posted before that deadline.
    function _applyToFixings(
        ReportV11 memory r,
        SessionCalendar.Session memory s,
        uint64 t,
        bytes32 receiptId,
        uint256 multiplier
    ) internal returns (uint8) {
        SessionRef storage sr = _refs[sessionId(r.feedId, s.tradingDate)];
        if (t >= s.openUtc && t < s.openUtc + WINDOW) {
            if (_applyRungs(sr.open, r, receiptId, multiplier, s, false)) return 1;
        }
        if (t + WINDOW >= s.closeUtc && t < s.closeUtc + WINDOW) {
            if (_applyRungs(sr.close, r, receiptId, multiplier, s, true)) return 2;
        }
        return 0;
    }

    /// @dev Candidate eligibility: regular-session freshness plus, for OPEN, l >= O (mid updated at or
    ///      after the bell) and, for CLOSE, o < C and l < C (nothing observed after the close).
    function _eligible(ReportV11 memory r, SessionCalendar.Session memory s, bool isClose)
        internal
        pure
        returns (bool)
    {
        if (!_fresh(r)) return false;
        if (isClose) return r.observationsTimestamp < s.closeUtc && r.lastSeenTimestampNs < s.closeUtc * NS;
        return r.lastSeenTimestampNs >= s.openUtc * NS;
    }

    /// @dev Target second of rung i: OPEN O + 30 i, CLOSE C - 1 - 30 i.
    function _target(uint64 anchor, bool isClose, uint8 i) internal pure returns (uint64) {
        return isClose ? anchor - 1 - uint64(i) * RUNG : anchor + uint64(i) * RUNG;
    }

    /// @dev Applies one report as evidence to every rung its signed interval covers.
    ///      Eligible: candidate for the rung (lower rung replaces higher; same rung with a different
    ///      statement is a conflict; a rung already proven out is a conflict). Ineligible: proves the
    ///      rung out (a candidate at that rung becomes a conflict).
    /// @return touched true when the report covered at least one rung of this fixing.
    function _applyRungs(
        Fixing storage f,
        ReportV11 memory r,
        bytes32 receiptId,
        uint256 multiplier,
        SessionCalendar.Session memory s,
        bool isClose
    ) internal returns (bool touched) {
        bool eligible = _eligible(r, s, isClose);
        uint64 anchor = isClose ? s.closeUtc : s.openUtc;
        Candidate storage c = f.cand;
        for (uint8 i = 0; i < RUNGS; i++) {
            uint64 T = _target(anchor, isClose, i);
            if (r.validFromTimestamp > T || r.observationsTimestamp < T) continue;
            touched = true;
            bool proven = ((f.provenMask >> i) & 1) == 1;

            if (!eligible) {
                if (!proven) {
                    f.provenMask |= uint8(1 << i);
                    emit RungProven(r.feedId, s.tradingDate, isClose, i);
                }
                if (c.set && c.rung == i && !c.conflict) {
                    c.conflict = true;
                    emit ReferenceConflict(r.feedId, s.tradingDate, isClose, i);
                }
                continue;
            }

            if (c.set && i > c.rung) continue; // a lower rung already holds the candidate
            if (c.set && i == c.rung) {
                if (!_sameStatement(c, r) && !c.conflict) {
                    c.conflict = true;
                    emit ReferenceConflict(r.feedId, s.tradingDate, isClose, i);
                }
                continue;
            }
            // no candidate yet, or this rung is lower than the current candidate's
            _setCandidate(c, r, receiptId, multiplier, i);
            if (proven) {
                c.conflict = true;
                emit ReferenceConflict(r.feedId, s.tradingDate, isClose, i);
            } else {
                emit ReferenceCandidate(r.feedId, s.tradingDate, isClose, i, r.observationsTimestamp, r.mid);
            }
        }
    }

    function _sameStatement(Candidate storage c, ReportV11 memory r) internal view returns (bool) {
        return c.observationsTimestamp == r.observationsTimestamp && c.validFromTimestamp == r.validFromTimestamp
            && c.mid == r.mid && c.lastSeenTimestampNs == r.lastSeenTimestampNs;
    }

    function _setCandidate(Candidate storage c, ReportV11 memory r, bytes32 receiptId, uint256 multiplier, uint8 rung)
        internal
    {
        c.mid = r.mid;
        c.validFromTimestamp = r.validFromTimestamp;
        c.observationsTimestamp = r.observationsTimestamp;
        c.lastSeenTimestampNs = r.lastSeenTimestampNs;
        c.receiptId = receiptId;
        c.multiplier = multiplier;
        c.rung = rung;
        c.set = true;
        c.conflict = false;
    }

    /// @dev A fixing resolves when its candidate has no conflict and every lower rung is proven out.
    function _resolved(Fixing storage f) internal view returns (bool) {
        Candidate storage c = f.cand;
        if (!c.set || c.conflict) return false;
        uint8 need = uint8((uint16(1) << c.rung) - 1);
        return (f.provenMask & need) == need;
    }

    /// @dev uiMultiplier of the bound token right now; 0 when the feed is not bound. A token that reverts
    ///      on the call is treated as unbound for this report (never blocks posting).
    function _multiplierNow(bytes32 feedId) internal view returns (uint256) {
        address token = stockToken[feedId];
        if (token == address(0)) return 0;
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        return (ok && d.length >= 32) ? abi.decode(d, (uint256)) : 0;
    }

    /// @dev Issuer's corporate-action pause flag; false when unbound or the call fails.
    function _issuerPaused(bytes32 feedId) internal view returns (bool) {
        address token = stockToken[feedId];
        if (token == address(0)) return false;
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        return ok && d.length >= 32 && abi.decode(d, (bool));
    }

    // ------------------------------------------------------------------
    // Views: sessions and references (state is a pure function of time, no keeper)
    // ------------------------------------------------------------------

    function sessionId(bytes32 feedId, uint32 tradingDate) public pure returns (bytes32) {
        return keccak256(abi.encode(feedId, tradingDate, POLICY_VERSION, CALENDAR_VERSION));
    }

    function session(uint32 tradingDate) external pure returns (SessionCalendar.Session memory) {
        return SessionCalendar.sessionForDate(tradingDate);
    }

    /// @notice Target second of ladder rung `i` for a fixing; 0 when there is no session or i >= RUNGS.
    function rungTarget(uint32 tradingDate, bool isClose, uint8 i) external pure returns (uint64) {
        SessionCalendar.Session memory s = SessionCalendar.sessionForDate(tradingDate);
        if (!s.exists || i >= RUNGS) return 0;
        return _target(isClose ? s.closeUtc : s.openUtc, isClose, i);
    }

    /// @notice Phase of the OPEN fixing for (feedId, tradingDate) at the current block time.
    function openPhase(bytes32 feedId, uint32 tradingDate) public view returns (Phase) {
        SessionCalendar.Session memory s = SessionCalendar.sessionForDate(tradingDate);
        if (!s.exists) return Phase.NO_SESSION;
        uint64 t = uint64(block.timestamp);
        if (t < s.openUtc) return Phase.NO_DATA;
        if (t < s.openUtc + WINDOW) return Phase.OPEN_PENDING;
        return _resolved(_refs[sessionId(feedId, tradingDate)].open) ? Phase.OPEN_FINAL : Phase.OPEN_UNRESOLVED;
    }

    /// @notice Phase of the CLOSE fixing for (feedId, tradingDate) at the current block time.
    function closePhase(bytes32 feedId, uint32 tradingDate) public view returns (Phase) {
        SessionCalendar.Session memory s = SessionCalendar.sessionForDate(tradingDate);
        if (!s.exists) return Phase.NO_SESSION;
        uint64 t = uint64(block.timestamp);
        if (t + WINDOW < s.closeUtc) return Phase.NO_DATA;
        if (t < s.closeUtc + WINDOW) return Phase.CLOSE_PENDING;
        return _resolved(_refs[sessionId(feedId, tradingDate)].close) ? Phase.CLOSE_FINAL : Phase.CLOSE_UNRESOLVED;
    }

    /// @notice Session reference price at OPEN, under Bell policy v2. Valid only when openPhase == OPEN_FINAL.
    function openReference(bytes32 feedId, uint32 tradingDate) external view returns (Candidate memory) {
        return _refs[sessionId(feedId, tradingDate)].open.cand;
    }

    /// @notice Session reference price at CLOSE, under Bell policy v2. Valid only when closePhase == CLOSE_FINAL.
    function closeReference(bytes32 feedId, uint32 tradingDate) external view returns (Candidate memory) {
        return _refs[sessionId(feedId, tradingDate)].close.cand;
    }

    /// @notice Bitmask of rungs proven out by ineligible DON reports (bit i = rung i).
    function provenRungs(bytes32 feedId, uint32 tradingDate, bool isClose) external view returns (uint8) {
        SessionRef storage sr = _refs[sessionId(feedId, tradingDate)];
        return isClose ? sr.close.provenMask : sr.open.provenMask;
    }

    // ------------------------------------------------------------------
    // Admissibility checks (ALLOW / WAIT / REJECT + reason)
    // ------------------------------------------------------------------

    /// @notice Is the latest observation of `feedId` usable for a LIVE operation right now?
    function checkLive(bytes32 feedId) external view returns (Verdict, Reason) {
        Latest storage L = latest[feedId];
        uint64 t = uint64(block.timestamp);
        if (L.acceptedAt == 0) return (Verdict.WAIT, Reason.NO_DATA);
        if (t > L.expiresAt) return (Verdict.REJECT, Reason.EXPIRED);
        if (t > uint64(L.observationsTimestamp) + MAX_OBS_AGE) return (Verdict.WAIT, Reason.OBS_STALE);
        if (t * NS > L.lastSeenTimestampNs + MAX_MID_AGE * NS) return (Verdict.WAIT, Reason.MID_STALE);
        if (L.marketStatus == 0) return (Verdict.WAIT, Reason.STATUS_UNKNOWN);
        if (L.marketStatus != STATUS_REGULAR) return (Verdict.WAIT, Reason.NON_REGULAR);
        if (_issuerPaused(feedId)) return (Verdict.REJECT, Reason.CA_PAUSED);
        SessionCalendar.Session memory s = SessionCalendar.sessionAt(t);
        if (!s.exists) return (Verdict.WAIT, Reason.NO_SESSION);
        if (t < s.openUtc || t >= s.closeUtc) return (Verdict.WAIT, Reason.OUTSIDE_SESSION);
        return (Verdict.ALLOW, Reason.OK);
    }

    /// @notice May a consumer settle on the OPEN (isClose=false) or CLOSE reference of this trading day?
    /// @return verdict ALLOW only when the phase is FINAL; mid is the reference (18 decimals) when ALLOW.
    function checkSettle(bytes32 feedId, uint32 tradingDate, bool isClose)
        external
        view
        returns (Verdict verdict, Reason reason, int192 mid, bytes32 receiptId)
    {
        Phase p = isClose ? closePhase(feedId, tradingDate) : openPhase(feedId, tradingDate);
        if (p == Phase.NO_SESSION) return (Verdict.REJECT, Reason.NO_SESSION, 0, 0);
        if (p == Phase.NO_DATA || p == Phase.OPEN_PENDING || p == Phase.CLOSE_PENDING) {
            return (Verdict.WAIT, Reason.REFERENCE_PENDING, 0, 0);
        }
        if (p == Phase.OPEN_UNRESOLVED || p == Phase.CLOSE_UNRESOLVED) {
            return (Verdict.REJECT, Reason.REFERENCE_UNRESOLVED, 0, 0);
        }
        if (_issuerPaused(feedId)) return (Verdict.REJECT, Reason.CA_PAUSED, 0, 0);
        SessionRef storage sr = _refs[sessionId(feedId, tradingDate)];
        Candidate storage c = isClose ? sr.close.cand : sr.open.cand;
        return (Verdict.ALLOW, Reason.OK, c.mid, c.receiptId);
    }

    /// @notice Reference scaled by the ERC-8056 multiplier that was in force when the reference report was
    ///         accepted (18 decimals both sides). Using the multiplier of that moment, not the current one,
    ///         keeps a settlement from mixing two corporate-action epochs. 0 when unbound or not FINAL.
    function tokenizedReference(bytes32 feedId, uint32 tradingDate, bool isClose) external view returns (uint256) {
        Phase p = isClose ? closePhase(feedId, tradingDate) : openPhase(feedId, tradingDate);
        if (p != Phase.OPEN_FINAL && p != Phase.CLOSE_FINAL) return 0;
        SessionRef storage sr = _refs[sessionId(feedId, tradingDate)];
        Candidate storage c = isClose ? sr.close.cand : sr.open.cand;
        if (c.multiplier == 0) return 0;
        uint256 m = c.multiplier;
        // casting to 'uint192' is safe: post() rejects mid <= 0, so a set candidate always has mid > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint192(c.mid)) * m / 1e18;
    }

    /// @notice Whether the DON configuration a receipt was verified under is still routed by the proxy.
    function digestActive(bytes32 configDigest) external view returns (bool) {
        return PROXY.getVerifier(configDigest) != address(0);
    }
}
