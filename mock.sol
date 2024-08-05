// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    
    // Updated to support multiple take-profit levels
    mapping(PoolId poolId => mapping(address user => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))) public takeProfitPositions;

    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
        address user;
    }
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    // New struct for conditional orders
    struct Condition {
        PoolKey conditionPool;
        int24 targetTick;
        bool above; // true if the condition is "above targetTick", false if "below targetTick"
    }
    mapping(uint256 tokenId => Condition) public orderConditions;

    // New mapping for cross-pool strategies
    mapping(uint256 sourceTokenId => uint256 destinationTokenId) public crossPoolStrategies;

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta) external override poolManagerOnly returns (bytes4) {
        bool attemptToFillMoreOrders = true;
        int24 currentTickLower;
        while (attemptToFillMoreOrders) {
            (attemptToFillMoreOrders, currentTickLower) = _tryFulfillingOrders(key, params);
            tickLowerLasts[key.toId()] = currentTickLower;
        }
        return TakeProfitsHook.afterSwap.selector;
    }

    // Updated to support multiple take-profit levels and conditional orders
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne,
        Condition memory condition
    ) external returns (uint256) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][msg.sender][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne, msg.sender);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne, msg.sender);
            orderConditions[tokenId] = condition;
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(tokenToBeSoldContract).transferFrom(msg.sender, address(this), amountIn);

        return tokenId;
    }

    // New function for setting up cross-pool strategies
    function setCrossPoolStrategy(uint256 sourceTokenId, uint256 destinationTokenId) external {
        require(tokenIdExists[sourceTokenId] && tokenIdExists[destinationTokenId], "Invalid token IDs");
        require(tokenIdData[sourceTokenId].user == msg.sender, "Not the owner of the source position");
        crossPoolStrategies[sourceTokenId] = destinationTokenId;
    }

    function cancelOrder(uint256 tokenId) external {
        TokenData memory data = tokenIdData[tokenId];
        require(data.user == msg.sender, "Not the owner of the position");

        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "No orders to cancel");

        takeProfitPositions[data.poolKey.toId()][msg.sender][data.tick][data.zeroForOne] -= int256(amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        address tokenToBeSoldContract = data.zeroForOne ? Currency.unwrap(data.poolKey.currency0) : Currency.unwrap(data.poolKey.currency1);
        IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
    }

    // Updated to check conditions before filling orders
    function _tryFulfillingOrders(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal returns (bool, int24) {
        (, int24 currentTick,,,,) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTickLower = tickLowerLasts[key.toId()];

        bool swapZeroForOne = !params.zeroForOne;

        if (lastTickLower < currentTickLower) {
            for (int24 tick = lastTickLower; tick < currentTickLower;) {
                uint256 tokenId = getTokenId(key, tick, swapZeroForOne, address(0));
                if (tokenIdExists[tokenId] && checkCondition(tokenId, currentTick)) {
                    int256 amountIn = takeProfitPositions[key.toId()][tokenIdData[tokenId].user][tick][swapZeroForOne];
                    if (amountIn > 0) {
                        fillOrder(key, tick, swapZeroForOne, amountIn, tokenId);
                        return (true, _getTickLower(currentTick, key.tickSpacing));
                    }
                }
                tick += key.tickSpacing;
            }
        } else {
            for (int24 tick = lastTickLower; currentTickLower < tick;) {
                uint256 tokenId = getTokenId(key, tick, swapZeroForOne, address(0));
                if (tokenIdExists[tokenId] && checkCondition(tokenId, currentTick)) {
                    int256 amountIn = takeProfitPositions[key.toId()][tokenIdData[tokenId].user][tick][swapZeroForOne];
                    if (amountIn > 0) {
                        fillOrder(key, tick, swapZeroForOne, amountIn, tokenId);
                        return (true, _getTickLower(currentTick, key.tickSpacing));
                    }
                }
                tick -= key.tickSpacing;
            }
        }

        return (false, currentTickLower);
    }

    // New function to check if the condition for an order is met
    function checkCondition(uint256 tokenId, int24 currentTick) internal view returns (bool) {
        Condition memory condition = orderConditions[tokenId];
        if (condition.conditionPool.toId() == bytes32(0)) {
            return true; // No condition set, always valid
        }
        
        (, int24 conditionPoolTick,,,,) = poolManager.getSlot0(condition.conditionPool.toId());
        return condition.above ? conditionPoolTick >= condition.targetTick : conditionPoolTick <= condition.targetTick;
    }

    // Updated to handle cross-pool strategies
    function fillOrder(PoolKey calldata key, int24 tick, bool zeroForOne, int256 amountIn, uint256 tokenId) internal {
        console.log("Filling order at tick = ");
        console.logInt(tick);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta = abi.decode(poolManager.lock(abi.encodeCall(this._handleSwap, (key, swapParams))), (BalanceDelta));

        takeProfitPositions[key.toId()][tokenIdData[tokenId].user][tick][zeroForOne] -= amountIn;

        uint256 amountOfTokensReceivedFromSwap = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));

        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;

        // Handle cross-pool strategy
        uint256 destinationTokenId = crossPoolStrategies[tokenId];
        if (destinationTokenId != 0 && tokenIdExists[destinationTokenId]) {
            TokenData memory destData = tokenIdData[destinationTokenId];
            address tokenToSwapContract = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
            IERC20(tokenToSwapContract).approve(address(this), amountOfTokensReceivedFromSwap / 2);
            placeOrder(destData.poolKey, destData.tick, amountOfTokensReceivedFromSwap / 2, destData.zeroForOne, orderConditions[destinationTokenId]);
        }
    }

    // ... (other functions remain the same)

    function getTokenId(PoolKey calldata key, int24 tickLower, bool zeroForOne, address user) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne, user)));
    }

    // ... (utility functions remain the same)
}
