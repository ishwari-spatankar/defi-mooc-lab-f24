//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Interfaces (as provided)
interface ILendingPool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

interface IUniswapV2Pair {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------
contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // Addresses and constants
    address constant AAVE_LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant TARGET_USER = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant UNISWAP_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant SUSHI_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;

    uint256 constant USDT_BORROW_AMOUNT = 2_916_359_000000; // USDT with 6 decimals

    // Helper function: Check if the target user is liquidatable
    function isLiquidatable(address user) public view returns (bool) {
        ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL);
        (, , , , , uint256 healthFactor) = lendingPool.getUserAccountData(user);
        return healthFactor < 10**health_factor_decimals; // Health Factor < 1
    }

    // Receive function for handling ETH withdrawals
    receive() external payable {}
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    // Main operate function
    function operate() external {
        console.log("Starting liquidation");
        require(isLiquidatable(TARGET_USER), "Target user is not liquidatable");
        console.log("Target user is liquidatable.");

        // Get Uniswap pair for USDT/WETH
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(UNISWAP_FACTORY);
        address pair = uniswapFactory.getPair(USDT, WETH);
        require(pair != address(0), "Uniswap pair not found for USDT/WETH");
        console.log("Uniswap pair for USDT/WETH found:", pair);

        // usdt flashloan
        bytes memory data = abi.encode(TARGET_USER, USDT_BORROW_AMOUNT);
        IUniswapV2Pair(pair).swap(0, USDT_BORROW_AMOUNT, address(this), data);
        console.log("Flash loan initiated: Borrowed USDT:", USDT_BORROW_AMOUNT);

        // convert profit and send back
        uint256 remainingWETH = IERC20(WETH).balanceOf(address(this));
        if (remainingWETH > 0) {
            console.log("Converting remaining WETH to ETH. WETH Balance:", remainingWETH);

            // Withdraw WETH to ETH
            IWETH(WETH).withdraw(remainingWETH);

            // Transfer ETH to the msg.sender? or sender?
            (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
            require(success, "Failed to send ETH to msg.sender");
            console.log("Profit converted to ETH and sent to sender.");
        } else {
            console.log("No remaining WETH to convert to ETH.");
        }
    }

    function uniswapV2Call(
        address sender,
        uint256,
        uint256 amount1,
        bytes calldata data
    ) external override {
        console.log("Flash swap triggered.");

        // Scope 1: Decode the data
        address targetUser;
        uint256 borrowAmount;
        {
            (targetUser, borrowAmount) = abi.decode(data, (address, uint256));
            console.log("Liquidating target user:", targetUser);
            console.log("USDT borrowed:", borrowAmount);
        }

        // Scope 2: approve lending pool
        {
            IERC20(USDT).approve(AAVE_LENDING_POOL, borrowAmount);
            console.log("Approved Aave lending pool to use USDT.");
        }

        // Scope 3: aave liquidatte
        uint256 wbtcBalance;
        uint256 usdtBalance;
        {
            ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL);
            lendingPool.liquidationCall(WBTC, USDT, targetUser, borrowAmount, false);
            console.log("Liquidation call executed on Aave.");

            // Get WBTC balance after liquidation
            wbtcBalance = IERC20(WBTC).balanceOf(address(this));
            console.log("Received WBTC from liquidation:", wbtcBalance);
            
            
        }
        usdtBalance = IERC20(USDT).balanceOf(address(this));
        console.log("Current USDT balance post liquidation:", usdtBalance);

        // Scope 4: Swap WBTC for WETH
        uint256 wethAmount;
        {
            address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(WBTC, WETH);
            require(pair != address(0), "Uniswap pair not found for WBTC/WETH");

            // APPROVE
            IERC20(WBTC).approve(pair, wbtcBalance);

            // RESERVES
            (uint112 reserveWBTC, uint112 reserveWETH, ) = IUniswapV2Pair(pair).getReserves();
            console.log("Before WBTC to WETH swap");
            console.log("Pair reserves - WBTC:", reserveWBTC, "WETH:", reserveWETH);

            uint256 initialK = uint256(reserveWBTC) * uint256(reserveWETH);
            console.log("Initial K:", initialK);

            // TRANSFER
            IERC20(WBTC).transfer(pair, wbtcBalance);
            // 9427338222
            // -1000000000
            console.log("Transferred WBTC to the Uniswap pair:", wbtcBalance);

            // Calculate the amount of WETH we will receive
            wethAmount = getAmountOut(wbtcBalance, reserveWBTC, reserveWETH);
            console.log("Calculated WETH amount:", wethAmount);

            // SWAP with WETH as output
            IUniswapV2Pair(pair).swap(0, wethAmount, address(this), "");
            console.log("Swapped WBTC for WETH:", wethAmount);
            // 1529087211375219375357
            // -10000000000000000000

            // Get reserves of WBTC/WETH pair AFTER the swap
            (uint112 newReserveWBTC, uint112 newReserveWETH, ) = IUniswapV2Pair(pair).getReserves();
            console.log("After WBTC to WETH swap");
            console.log("Pair reserves - WBTC:", newReserveWBTC, "WETH:", newReserveWETH);

            // final K after the swap
            uint256 finalK = uint256(newReserveWBTC) * uint256(newReserveWETH);
            console.log("Final K:", finalK);
            require(finalK >= initialK, "WBTC to WETH swap violated K");
        }

        // Scope 5: repay flash loan
        {
            usdtBalance = IERC20(USDT).balanceOf(address(this));
            console.log("Current USDT balance before repaying flash loan:", usdtBalance);
            // uint256 repaymentAmount = (amount1 * 1003) / 1000; // Add 0.3% fee to repayment
            uint256 repaymentAmount = amount1 + 20_000_000000;
            console.log("Flash loan repayment amount (including fee):", repaymentAmount);

            if (usdtBalance < repaymentAmount) {
                // console.log("Insufficient USDT, converting WETH to USDT using SushiSwap...");
                address pair = IUniswapV2Factory(SUSHI_FACTORY).getPair(WETH, USDT);
                require(pair != address(0), "SushiSwap pair not found for WETH/USDT");
                //APPROVE
                uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
                console.log("WETH balance before swap:", wethBalance);
                IERC20(WETH).approve(pair, wethBalance);

                // reserve sbefore swap
                (uint112 reserveWETH, uint112 reserveUSDT, ) = IUniswapV2Pair(pair).getReserves();
                console.log("SushiSwap pair reserves - WETH:", reserveWETH, "USDT:", reserveUSDT);
                uint256 initialK = uint256(reserveWETH) * uint256(reserveUSDT);
                console.log("Initial K:", initialK);
                uint256 usdtNeeded = repaymentAmount - usdtBalance;
                console.log("USDT needed to cover repayment:", usdtNeeded);

                uint256 wethToSwap = getAmountIn(usdtNeeded, reserveWETH, reserveUSDT);
                console.log("WETH required to swap for USDT:", wethToSwap);
                require(wethBalance >= wethToSwap, "Not enough WETH to perform swap");

                // tranfer
                IERC20(WETH).transfer(pair, wethToSwap);
                console.log("Transferred WETH to SushiSwap pair:", wethToSwap);

                // swap, recieving usdt for weth
                IUniswapV2Pair(pair).swap(0, usdtNeeded, address(this), "");
                console.log("Swapped WETH for USDT. Received USDT:", usdtNeeded);

                // post swap reserve ()
                (uint112 newReserveWETH, uint112 newReserveUSDT, ) = IUniswapV2Pair(pair).getReserves();
                console.log("Post-swap reserves - WETH:", newReserveWETH, "USDT:", newReserveUSDT);
                uint256 finalK = uint256(newReserveWETH) * uint256(newReserveUSDT);
                console.log("Final K:", finalK);

                require(finalK >= initialK, "WETH to USDT swap violated K");
            }

            // Update USDT balance post-swap
            usdtBalance = IERC20(USDT).balanceOf(address(this));
            console.log("Current USDT balance after swap:", usdtBalance);
            require(usdtBalance >= repaymentAmount, "Insufficient USDT for flash loan repayment");

            // approve?
            console.log("Approving Uniswap pair for USDT withdrawal...");
            IERC20(USDT).approve(msg.sender, repaymentAmount);
            console.log("Uniswap pair approved for repayment amount:", repaymentAmount);

            // sender or msg.sender. transfer no wrok
            console.log("Repaying flash loan to Uniswap pair:", msg.sender);
            (bool success, bytes memory d) = USDT.call(
                abi.encodeWithSelector(
                    IERC20.transfer.selector,
                    msg.sender,
                    repaymentAmount
                )
            );
            require(success, "USDT transfer failed");
            console.log("Flash loan repaid successfully. Repayment amount:", repaymentAmount);
        }
    }
}

