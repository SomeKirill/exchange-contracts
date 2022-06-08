pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../pangolin-lib/libraries/TransferHelper.sol";

interface IPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function approve(address spender, uint256 amount) external;
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IStakingRewardsLocked {
    function stake(uint256 amount, address user) external;
    function stakingToken() external returns (address stakingToken);
}

// SPDX-License-Identifier: MIT

/// @author bmino for Pangolin
/// @notice This contract migrates pool2 compliant liquidity to Pangolin

contract Vampire is Ownable {

    mapping(address => bool) private approvedStakingContracts;
    address[] public stakingContracts;

    event Migrate(address indexed pairFrom, address indexed pairTo, uint256 amount, address userFrom, address userTo);
    event DustSweep(address indexed dust, uint256 amount);

    constructor(address firstOwner) {
        transferOwnership(firstOwner);
    }

    /// @notice Migrate liquidity
    /// @dev Requires that `pairFrom` is approved for spending via this contract
    function migrate(
        address pairFrom,
        uint256 liquidity,
        address pairTo,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 dustThreshold0,
        uint256 dustThreshold1,
        address liquidityTo
    ) external {
        _migrate(
            pairFrom,
            liquidity,
            pairTo,
            amount0Min,
            amount1Min,
            dustThreshold0,
            dustThreshold1,
            liquidityTo
        );
    }

    /// @notice Migrate liquidity
    /// @dev Not all 3rd party pairs will support `permit` but some will
    /// @dev The `liquidityTo` param is excluded and the EOA caller is used
    function migrateWithPermit(
        address pairFrom,
        uint256 liquidity,
        address pairTo,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 dustThreshold0,
        uint256 dustThreshold1,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        IPair(pairFrom).permit(msg.sender, address(this), liquidity, deadline, v, r, s);
        _migrate(
            pairFrom,
            liquidity,
            pairTo,
            amount0Min,
            amount1Min,
            dustThreshold0,
            dustThreshold1,
            msg.sender
        );
    }

    /// @notice Migrate liquidity and stake resulting liquidity
    /// @dev Not all 3rd party pairs will support `permit` but some will
    /// @dev Requires that an owner has approved the staking contract for use
    /// @dev The `liquidityTo` param is excluded and the EOA caller is used
    function migrateWithPermitAndStake(
        address pairFrom,
        uint256 liquidity,
        address pairTo,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 dustThreshold0,
        uint256 dustThreshold1,
        address stakingContract,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(approvedStakingContracts[stakingContract], "Invalid staking contract");
        IPair(pairFrom).permit(msg.sender, address(this), liquidity, deadline, v, r, s);
        uint256 deposited = _migrate(
            pairFrom,
            liquidity,
            pairTo,
            amount0Min,
            amount1Min,
            dustThreshold0,
            dustThreshold1,
            address(this)
        );
        IStakingRewardsLocked(stakingContract).stake(deposited, msg.sender);
    }

    /// @notice Migrate liquidity and stake resulting liquidity
    /// @dev Requires that `pairFrom` is approved for spending via this contract
    /// @dev Requires that an owner has approved the staking contract for use
    function migrateAndStake(
        address pairFrom,
        uint256 liquidity,
        address pairTo,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 dustThreshold0,
        uint256 dustThreshold1,
        address liquidityTo,
        address stakingContract
    ) external {
        require(approvedStakingContracts[stakingContract], "Invalid staking contract");
        uint256 deposited = _migrate(
            pairFrom,
            liquidity,
            pairTo,
            amount0Min,
            amount1Min,
            dustThreshold0,
            dustThreshold1,
            address(this)
        );
        IStakingRewardsLocked(stakingContract).stake(deposited, liquidityTo);
    }

    /// @notice Moves liquidity from a UniswapV2-based pool2 implementation to Pangolin
    /// @param pairFrom - Pair address to migrate out of
    /// @param liquidity - Amount of the pair to migrate
    /// @param pairTo - Pair address to migrate into
    /// @param amount0Min - Minimum amount to LP of the destination pair's token0
    /// @param amount1Min - Minimum amount to LP of the destination pair's token1
    /// @param dustThreshold0 - Minimum amount of token0 dust required to transfer
    /// @param dustThreshold1 - Minimum amount of token1 dust required to transfer
    /// @param liquidityTo - Recipient of the Pangolin LP
    /// @dev amount0Min and amount1Min are used in tandem as a slippage check of the pool reserve ratio
    /// @dev dustThreshold0 and dustThreshold1 are used to avoid spending more on gas to recover dust than it is worth
    /// @dev Dust (when above the threshold) will always be sent to msg.sender
    /// @dev Does not support pools which contain a token which incurs fees on transfer
    function _migrate(
        address pairFrom,
        uint256 liquidity,
        address pairTo,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 dustThreshold0,
        uint256 dustThreshold1,
        address liquidityTo
    ) private returns (uint256 deposited) {
        require(liquidityTo != address(0), "Invalid recipient");

        (uint256 amount0, uint256 amount1) = _removeLiquidity(
            pairFrom,
            liquidity
        );

        address token0 = IPair(pairTo).token0();
        address token1 = IPair(pairTo).token1();

        // Scope to avoid stack too deep error
        {
            address tokenFrom0 = IPair(pairFrom).token0();
            address tokenFrom1 = IPair(pairFrom).token1();
            if (tokenFrom0 < tokenFrom1) {
                // Standard sorting
                require(token0 == tokenFrom0 && token1 == tokenFrom1, "Incompatible pairs");
            } else {
                // Non standard sorting
                require(token0 == tokenFrom1 && token1 == tokenFrom0, "Incompatible pairs");
                (amount0, amount1) = (amount1, amount0);
            }
        }

        (uint256 pooledAmount0, uint256 pooledAmount1) = _calculateAddLiquidity(
            pairTo,
            amount0,
            amount1,
            amount0Min,
            amount1Min
        );

        // pooledAmountX will always be less than received amountX
        unchecked {
            amount0 -= pooledAmount0;
            amount1 -= pooledAmount1;
        }

        TransferHelper.safeTransfer(token0, pairTo, pooledAmount0);
        TransferHelper.safeTransfer(token1, pairTo, pooledAmount1);
        deposited = IPair(pairTo).mint(liquidityTo);

        // Send back dust
        if (amount0 > dustThreshold0) {
            TransferHelper.safeTransfer(token0, msg.sender, amount0);
        }
        if (amount1 > dustThreshold1) {
            TransferHelper.safeTransfer(token1, msg.sender, amount1);
        }

        emit Migrate(pairFrom, pairTo, deposited, msg.sender, liquidityTo);
    }

    function _removeLiquidity(
        address pair,
        uint256 amount
    ) private returns (uint256 amount0, uint256 amount1) {
        TransferHelper.safeTransferFrom(pair, msg.sender, pair, amount);
        (amount0, amount1) = IPair(pair).burn(address(this));
    }

    function _calculateAddLiquidity(
        address pair,
        uint256 amount0Available,
        uint256 amount1Available,
        uint256 amount0Min,
        uint256 amount1Min
    ) private view returns (uint256 amount0, uint256 amount1) {
        (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();

        if (reserve0 == 0 && reserve1 == 0) {
            (amount0, amount1) = (amount0Available, amount1Available);
        } else {
            uint256 amount1Optimal = quote(amount0Available, reserve0, reserve1);
            if (amount1Optimal <= amount1Available) {
                // Will result in exactly the available0 and less than available1
                (amount0, amount1) = (amount0Available, amount1Optimal);
            } else {
                uint256 amount0Optimal = quote(amount1Available, reserve1, reserve0);
                require(amount0Optimal <= amount0Available, "Insufficient amount");
                // Will result in exactly the available1 and less than available0
                (amount0, amount1) = (amount0Optimal, amount1Available);
            }
        }

        require(amount0 >= amount0Min, "Slippage check via token 0");
        require(amount1 >= amount1Min, "Slippage check via token 1");
    }

    /// @notice Approve a staking contract
    /// @param stakingContract - Address of a staking contract to migrate into
    /// @dev Allows the owner to whitelist a staking contract and the required approvals
    /// @dev Note via shung from Pangolin that callers can provide a malicious `stakingContract` address
    ///      which returns a `stakingToken` of a dust token residing in this contract and proceed
    ///      to use the transferFrom method to extract dust bypassing the `sweepDust` onlyOwner
    ///      check. Since only owners can call this method, semantically no additional risk is presented
    ///      beyond a previously removed malicious owner potentially having a lingering ability to withdraw dust.
    function approveStakingContract(
        address stakingContract
    ) external onlyOwner {
        require(!approvedStakingContracts[stakingContract], "Already approved");
        address principle = IStakingRewardsLocked(stakingContract).stakingToken();
        require(principle != address(0), "Invalid staking token");
        IPair(principle).approve(stakingContract, type(uint256).max);
        stakingContracts.push(stakingContract);
        approvedStakingContracts[stakingContract] = true;
    }

    /// @notice Allows the owner to remove accumulated dust forfeited by migrators
    /// @param dust - Address of a dusty token
    /// @param amount - Quantity of the dusty token to recover
    function sweepDust(
        address dust,
        uint256 amount,
        address to
    ) external onlyOwner {
        TransferHelper.safeTransfer(dust, to, amount);
        emit DustSweep(dust, amount);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) private pure returns (uint256 amountB) {
        require(amountA > 0, 'INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'INSUFFICIENT_LIQUIDITY');
        amountB = (amountA * reserveB) / reserveA;
    }

}
