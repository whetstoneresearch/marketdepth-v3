// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IDepth} from "./IDepth.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
library PoolTickBitmap {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            // signed arithmetic shift right
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param poolVariables the pool variables for the pool we are searching
    /// @param tick The starting tick for the search
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @param poolManager The address of the pool manager contract
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function _nextInitializedTickWithinOneWord(IDepth.PoolVariables memory poolVariables, int24 tick, bool lte, address poolManager)
        internal
        view
        returns (int24 next, bool initialized)
    {
        int24 tickSpacing = poolVariables.tickSpacing;
        int24 compressed = tick / tickSpacing;
        
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        PoolId poolId = poolVariables.pool.toId();

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = IPoolManager(poolManager).getTickBitmap(poolId, wordPos) & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = IPoolManager(poolManager).getTickBitmap(poolId, wordPos) & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                            next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }

    /// @dev This may return a tick beyond the tick at the sqrtPriceX96Tgt.
    /// Instead of truncating the tickNext returned if it goes beyond the sqrtPriceTarget, we check the boundaries in `calculateOneSide` because we need to calculate amounts to a price that may be between two ticks.
    function findNextTick(IDepth.PoolVariables memory poolVariables, int24 tick, bool upper, uint160 sqrtPriceX96Tgt, address poolManager)
        internal
        view
        returns (int24 tickNext)
    {
        bool initialized;
        (tickNext, initialized) = _nextInitializedTickWithinOneWord(poolVariables, tick, !upper, poolManager);

        int24 tickMax =
            upper ? TickMath.getTickAtSqrtPrice(sqrtPriceX96Tgt) + 1 : TickMath.getTickAtSqrtPrice(sqrtPriceX96Tgt);

        // tick next at this point is either 
        // initialized (never enters this loop) or a word boundry and will search until it is found
        while (!initialized && (upper ? tickNext < tickMax : tickNext > tickMax)) {
            (tickNext, initialized) = _nextInitializedTickWithinOneWord(poolVariables, upper ? tickNext : tickNext - 1, !upper, poolManager);
        }
    }
}
