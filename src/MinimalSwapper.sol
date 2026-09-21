// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3PoolMin {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title MinimalSwapper
/// @notice The smallest thing that can buy USDG on this chain, because nothing else here can.
///
/// Robinhood Chain has Uniswap v3 pools but no public router: the canonical `SwapRouter` address holds a
/// contract that does not answer `factory()`, and every swap in the deepest WETH/USDG pool arrives from a
/// private bot with its own selector. A v3 pool cannot be called from an EOA, because `swap()` demands a
/// callback that pays the pool inside the same transaction. So this contract exists for one job: hold the
/// input token, call the pool, and pay it back when asked.
///
/// It is deliberately unowned and unprivileged. It holds nothing between transactions: whatever it buys
/// goes straight to the recipient named in the call, and anyone may use it. There is no admin key to lose.
///
/// Used once, to turn a few dollars of ETH into the USDG that funds a real settlement in `SettleOnMark`,
/// so the demo moves actual money rather than mock tokens.
contract MinimalSwapper {
    /// @dev Uniswap's own bounds. A swap must stay strictly inside them.
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    error NothingReceived();
    error WrongCaller();
    error TransferFailed();

    /// @notice Swap `amountIn` of `tokenIn` through `pool`, sending the output to `recipient`.
    /// @dev `tokenIn` must already sit on this contract. Pull it in first, or send it here, then call.
    function swap(address pool, bool zeroForOne, address tokenIn, uint256 amountIn, address recipient)
        public
        returns (int256 amount0, int256 amount1)
    {
        (amount0, amount1) = IUniswapV3PoolMin(pool).swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(pool, tokenIn)
        );
        int256 out = zeroForOne ? amount1 : amount0;
        if (out >= 0) revert NothingReceived();
    }

    /// @notice Pull `amountIn` from the caller and swap it in one transaction.
    function pullAndSwap(address pool, bool zeroForOne, address tokenIn, uint256 amountIn, address recipient)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (!IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        return swap(pool, zeroForOne, tokenIn, amountIn, recipient);
    }

    /// @notice The pool calls this to collect what it is owed.
    /// @dev The pool address is carried in `data` and checked against `msg.sender`, so a stranger cannot
    ///      call this to drain a stray balance: they would have to be the pool this contract just asked.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address pool, address tokenIn) = abi.decode(data, (address, address));
        if (msg.sender != pool) revert WrongCaller();
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (!IERC20Min(tokenIn).transfer(msg.sender, owed)) revert TransferFailed();
    }
}
