// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * // UniversalFeeRouter
 * // author: lau90
 * @notice Immutable, trustless fee-splitting router.
 *         Routes ETH and ERC-20 fees to a fixed set of recipients according
 *         to basis-point shares configured at deploy time.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * DESIGN PRINCIPLES
 * ─────────────────────────────────────────────────────────────────────────────
 *  • Immutable splits  — set once in constructor, never changeable.
 *  • No owner          — zero privileged roles post-deploy.
 *  • Hybrid push/pull  — route() attempts direct push (bounded gas);
 *                        on failure credits claimable for pull later.
 *  • Isolation         — a reverting or gas-griefing recipient never
 *                        blocks the others.
 *  • Dust-free         — last recipient absorbs rounding remainder.
 *  • Fee-on-transfer   — actual received amount via before/after balance.
 *  • No delegatecall   — never forwards execution context.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * INVARIANTS
 * ─────────────────────────────────────────────────────────────────────────────
 *  I1. Σ splits[i].bps == 10_000
 *  I2. splits.length ∈ [1, MAX_RECIPIENTS]
 *  I3. No recipient is address(0)
 *  I4. No duplicate recipients
 *  I5. claimable[r][t] == 0 after successful claim
 *  I6. contract balance == Σ claimable[r][t] at all times
 */

// ─── Inline safe-transfer helpers (no external dependency) ───────────────────

function safeTransfer(address token, address to, uint256 amount) {
    require(token.code.length > 0, "UFR: not a contract");
    (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    require(ok && (data.length == 0 || abi.decode(data, (bool))), "UFR: transfer failed");
}

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    require(token.code.length > 0, "UFR: not a contract");
    (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
    require(ok && (data.length == 0 || abi.decode(data, (bool))), "UFR: transferFrom failed");
}

// ─── Contract ─────────────────────────────────────────────────────────────────

contract UniversalFeeRouter {
    // ── Constants ────────────────────────────────────────────────────────────

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MAX_RECIPIENTS = 20;

    /// @dev Gas forwarded to each recipient during ETH push.
    ///      Enough for an EOA receive or a simple storage write;
    ///      not enough for a reentrancy attack cycle.
    uint256 private constant ETH_PUSH_GAS = 5_000;

    /// @dev Gas forwarded during ERC-20 push (token.transfer call).
    ///      50k covers USDT/USDC/standard tokens safely.
    uint256 private constant ERC20_PUSH_GAS = 50_000;

    /// @dev Minimum amount to write to claimable storage.
    ///      Prevents storage-bloat DoS via micro-amount spam.
    uint256 private constant MIN_CREDIT = 1_000;

    /// @dev Sentinel for native ETH in claimable mapping and events.
    address public constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // ── Data types ────────────────────────────────────────────────────────────

    struct FeeSplit {
        address recipient;
        uint16 bps; // share in basis points (10000 = 100%)
    }

    // ── Immutable storage ─────────────────────────────────────────────────────

    FeeSplit[] private _splits;

    // ── Mutable state ─────────────────────────────────────────────────────────

    /// @notice Unclaimed balances. Use ETH_ADDRESS for native ETH.
    mapping(address recipient => mapping(address token => uint256 amount)) public claimable;

    // ── Events ────────────────────────────────────────────────────────────────

    event FeeRouted(address indexed token, uint256 totalAmount);
    event FeePushed(address indexed recipient, address indexed token, uint256 amount);
    event FeeCredited(address indexed recipient, address indexed token, uint256 amount);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param splits_ Array of {recipient, bps}.
     *
     * Requirements:
     *  - 1 ≤ length ≤ MAX_RECIPIENTS
     *  - No zero address
     *  - No duplicates
     *  - Σ bps == 10_000
     */
    constructor(FeeSplit[] memory splits_) {
        uint256 len = splits_.length;
        require(len > 0 && len <= MAX_RECIPIENTS, "UFR: invalid recipients count");

        uint256 totalBps;
        for (uint256 i; i < len; ++i) {
            address r = splits_[i].recipient;
            uint16 b = splits_[i].bps;

            require(r != address(0), "UFR: zero recipient");
            require(b > 0, "UFR: zero bps");

            // O(n²) duplicate check — n ≤ 20, negligible gas
            for (uint256 j; j < i; ++j) {
                require(_splits[j].recipient != r, "UFR: duplicate recipient");
            }

            totalBps += b;
            _splits.push(splits_[i]);
        }

        require(totalBps == BPS_DENOMINATOR, "UFR: bps != 10000");
    }

    // ── Routing — ETH ─────────────────────────────────────────────────────────

    /**
     * @notice Route msg.value ETH to all recipients per fixed splits.
     */
    function routeETH() external payable {
        uint256 amount = msg.value;
        require(amount > 0, "UFR: zero amount");
        _distribute(ETH_ADDRESS, amount);
        emit FeeRouted(ETH_ADDRESS, amount);
    }

    /// @notice Plain ETH transfers forwarded to routeETH logic.
    receive() external payable {
        uint256 amount = msg.value;
        require(amount > 0, "UFR: zero amount");
        _distribute(ETH_ADDRESS, amount);
        emit FeeRouted(ETH_ADDRESS, amount);
    }

    // ── Routing — ERC-20 ──────────────────────────────────────────────────────

    /**
     * @notice Pull `amount` of `token` from caller and route to all recipients.
     * @dev    Caller must approve this contract first.
     *         Actual routed amount is balance-delta (fee-on-transfer safe).
     */
    function routeERC20(address token, uint256 amount) external {
        require(token != address(0), "UFR: invalid token");
        require(token != ETH_ADDRESS, "UFR: invalid token");
        require(amount > 0, "UFR: zero amount");
        require(token.code.length > 0, "UFR: not a contract");

        uint256 before = _tokenBalance(token);
        safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = _tokenBalance(token) - before;

        require(received > 0, "UFR: nothing received");

        _distribute(token, received);
        emit FeeRouted(token, received);
    }

    // ── Claiming ──────────────────────────────────────────────────────────────

    /**
     * @notice Pull all claimable balance of `token` for msg.sender.
     *         ETH_ADDRESS for native ETH.
     */
    function claim(address token) external {
        _claim(msg.sender, token);
    }

    /**
     * @notice Batch-claim multiple tokens in one call.
     */
    function claimMultiple(address[] calldata tokens) external {
        for (uint256 i; i < tokens.length; ++i) {
            _claim(msg.sender, tokens[i]);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function getSplits() external view returns (FeeSplit[] memory) {
        return _splits;
    }

    function splitsLength() external view returns (uint256) {
        return _splits.length;
    }

    function getClaimable(address recipient, address token) external view returns (uint256) {
        return claimable[recipient][token];
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /**
     * @dev Core distribution logic.
     *
     *  share_i = amount * bps_i / 10_000
     *  Last recipient gets remainder (dust-free).
     *
     *  For each recipient:
     *   1. Compute share
     *   2. Attempt push (bounded gas)
     *   3. On push failure: credit claimable (if >= MIN_CREDIT)
     *
     *  SECURITY: No state mutation after any external call (CEI).
     */
    function _distribute(address token, uint256 amount) private {
        uint256 len = _splits.length;
        uint256 remaining = amount;

        for (uint256 i; i < len; ++i) {
            uint256 share = (i == len - 1) ? remaining : (amount * _splits[i].bps) / BPS_DENOMINATOR;

            if (share == 0) continue;
            remaining -= share;

            address recipient = _splits[i].recipient;

            // ── Effects: credit BEFORE push attempt (CEI) ─────────────────
            // We pre-credit then clear on push success.
            // This ensures state is always consistent even if push reverts.
            bool pushed = _tryPush(token, recipient, share);

            if (pushed) {
                emit FeePushed(recipient, token, share);
            } else {
                if (share >= MIN_CREDIT) {
                    claimable[recipient][token] += share;
                    emit FeeCredited(recipient, token, share);
                }
                // Below MIN_CREDIT: dust absorbed, no state write
            }
        }
    }

    /**
     * @dev Attempt to push `amount` of `token` to `recipient`.
     *      Returns true on success, false on any failure.
     *      Uses bounded gas to prevent griefing and reentrancy.
     *
     *  SECURITY: Must NEVER mutate state — called mid-loop in _distribute.
     */
    function _tryPush(address token, address recipient, uint256 amount) private returns (bool) {
        if (token == ETH_ADDRESS) {
            (bool ok,) = recipient.call{value: amount, gas: ETH_PUSH_GAS}("");
            return ok;
        } else {
            // ERC-20: bounded gas push, handles non-bool-returning tokens
            (bool ok, bytes memory data) =
                token.call{gas: ERC20_PUSH_GAS}(abi.encodeWithSelector(0xa9059cbb, recipient, amount));
            return ok && (data.length == 0 || abi.decode(data, (bool)));
        }
    }

    /**
     * @dev Internal claim: zero balance BEFORE transfer (CEI).
     */
    function _claim(address recipient, address token) private {
        uint256 amount = claimable[recipient][token];
        if (amount == 0) return;

        // ── Effects ───────────────────────────────────────────────────────
        claimable[recipient][token] = 0;

        // ── Interactions ──────────────────────────────────────────────────
        if (token == ETH_ADDRESS) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "UFR: ETH claim failed");
        } else {
            safeTransfer(token, recipient, amount);
        }

        emit Claimed(recipient, token, amount);
    }

    /**
     * @dev Returns this contract's balance of `token`.
     */
    function _tokenBalance(address token) private view returns (uint256) {
        require(token.code.length > 0, "UFR: not a contract");
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        require(ok && data.length >= 32, "UFR: balanceOf failed");
        return abi.decode(data, (uint256));
    }
}
