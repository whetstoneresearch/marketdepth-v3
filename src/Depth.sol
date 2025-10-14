// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
pragma abicoder v2;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {IDepth} from "./IDepth.sol";
import {PoolTickBitmap} from "./PoolTickBitmap.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {DepthLibrary} from "./DepthLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract Depth is IDepth {
    using PoolIdLibrary for PoolKey;
    using DepthLibrary for IDepth.DepthConfig;
    using PoolTickBitmap for IDepth.PoolVariables;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    
    IPoolManager immutable poolManager;

    constructor(address poolManager_) {
        poolManager = IPoolManager(poolManager_);
    } 

    function calculateDepths(PoolKey[] memory poolKeys, uint256[] memory sqrtDepthX96, DepthConfig[] memory configs)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        require(sqrtDepthX96.length == configs.length && poolKeys.length == sqrtDepthX96.length, "LengthMismatch");
        amounts = new uint256[](sqrtDepthX96.length);

        IDepth.PoolVariables memory poolVariables;
        for (uint256 i = 0; i < sqrtDepthX96.length; i++) {
            poolVariables = poolVariables.pool != poolKeys[i] ? _initializePoolVariables(pools[i]) : poolVariables;
            amounts[i] = _calculateDepth(poolVariables, configs[i], sqrtDepthX96[i]);
        }
        return amounts;
    }

    function _calculateDepth(PoolVariables memory poolVariables, DepthConfig memory config, uint256 sqrtDepthX96)
        internal
        view
        returns (uint256 returnAmt)
    {
        if (config.side == Side.Both) {
            config.side = Side.Upper;
            returnAmt += calculateOneSide(poolVariables, config, sqrtDepthX96);
            config.side = Side.Lower;
            returnAmt += calculateOneSide(poolVariables, config, sqrtDepthX96);
        } else {
            returnAmt += calculateOneSide(poolVariables, config, sqrtDepthX96);
        }

        return returnAmt;
    }

    function calculateOneSide(PoolVariables memory poolVariables, DepthConfig memory config, uint256 sqrtDepthX96)
        internal
        view
        returns (uint256 amount)
    {
        bool upper = config.side == Side.Upper;

        PoolId poolId = poolVariables.poolKey.toId();

        // Prep step variables.
        uint160 sqrtPriceX96Current = poolVariables.sqrtPriceX96;
        uint160 sqrtPriceX96Tgt = config.getSqrtPriceX96Tgt(poolVariables.sqrtPriceX96, sqrtDepthX96);

        uint128 liquidityCurrent = poolVariables.liquidity;
        int24 tickNext = poolVariables.findNextTick(poolVariables.tick, upper, sqrtPriceX96Tgt);
        uint160 sqrtPriceX96Next = TickMath.getSqrtRatioAtTick(tickNext);

        while (upper ? sqrtPriceX96Current < sqrtPriceX96Tgt : sqrtPriceX96Tgt < sqrtPriceX96Current) {
            // If we calculated a next price that is past the target we can calculate the amount directly to the target and break.
            if (upper ? sqrtPriceX96Next > sqrtPriceX96Tgt : sqrtPriceX96Next < sqrtPriceX96Tgt) {
                amount +=
                    _getAmountToNextPrice(config.amountInToken0, sqrtPriceX96Current, sqrtPriceX96Tgt, liquidityCurrent);
                break;
            }

            amount +=
                _getAmountToNextPrice(config.amountInToken0, sqrtPriceX96Current, sqrtPriceX96Next, liquidityCurrent);

            // Update the state variables.
            // First, we need liquidity net to calculate the liquidity spot.
            (, int128 liquidityNet) = IPoolManager(poolManager).getTickLiquidity(poolId, tickNext);

            if (!upper) {
                liquidityNet = -liquidityNet;
                // If not going upper, always push tickNext to the next word because we are on a word boundary.
                tickNext = tickNext - 1;
            }
            liquidityCurrent = LiquidityMath.addDelta(liquidityCurrent, liquidityNet);
            tickNext = poolVariables.findNextTick(tickNext, upper, sqrtPriceX96Tgt);

            // move the sqrtPriceCurrent to the end of the current bucket
            // then move the sqrtPriceX96Next to the end of the next bucket
            sqrtPriceX96Current = sqrtPriceX96Next;
            sqrtPriceX96Next = TickMath.getSqrtRatioAtTick(tickNext);
        }
    }

    function _initializePoolVariables(PoolKey poolKey) internal view returns (PoolVariables memory poolVariables) {
        PoolId poolId = poolKey.toId();
        
        (uint160 sqrtPriceX96, int24 tick,,,,,) = poolManager.getSlot0(poolId);
        
        poolVariables = IDepth.PoolVariables({
            tick: tick,
            tickSpacing: poolKey.tickSpacing(),
            liquidity: pool.liquidity(),
            sqrtPriceX96: sqrtPriceX96,
            poolKey: poolKey,
        });
    }

    function _getAmountToNextPrice(
        bool amountInToken0,
        uint160 sqrtPriceX96Current,
        uint160 sqrtPriceX96Next,
        uint128 liquidityCurrent
    ) internal pure returns (uint256 amount) {
        if (liquidityCurrent != 0) {
            if (amountInToken0) {
                amount = SqrtPriceMath.getAmount0Delta(sqrtPriceX96Current, sqrtPriceX96Next, liquidityCurrent, false);
            } else {
                amount = SqrtPriceMath.getAmount1Delta(sqrtPriceX96Current, sqrtPriceX96Next, liquidityCurrent, false);
            }
        }
    }
}
