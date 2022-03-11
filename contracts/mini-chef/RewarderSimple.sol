// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";

import "./IRewarder.sol";

contract RewarderSimple is IRewarder {
    using BoringMath for uint256;
    using BoringERC20 for IERC20;
    uint256 private immutable rewardMultiplier;
    IERC20 private immutable rewardToken;
    uint256 private immutable REWARD_TOKEN_DIVISOR;
    address private immutable MASTERCHEF_V2;

    constructor (uint256 _rewardMultiplier, address _rewardToken, uint256 _rewardDecimals, address _MASTERCHEF_V2) public {
        require(_rewardMultiplier > 0, "RewarderSimple::Invalid multiplier");
        require(_rewardDecimals <= 77, "RewarderSimple::Invalid decimals");
        require(
            _rewardToken != address(0)
            && _MASTERCHEF_V2 != address(0),
            "RewarderSimple::Cannot construct with zero address"
        );

        rewardMultiplier = _rewardMultiplier;
        rewardToken = IERC20(_rewardToken);
        REWARD_TOKEN_DIVISOR = 10 ** _rewardDecimals;
        MASTERCHEF_V2 = _MASTERCHEF_V2;
    }

    function onReward(uint256, address, address to, uint256 rewardAmount, uint256) onlyMCV2 override external {
        uint256 pendingReward = rewardAmount.mul(rewardMultiplier) / REWARD_TOKEN_DIVISOR;
        uint256 rewardBal = rewardToken.balanceOf(address(this));
        if (pendingReward > rewardBal) {
            rewardToken.safeTransfer(to, rewardBal);
        } else {
            rewardToken.safeTransfer(to, pendingReward);
        }
    }

    function pendingTokens(uint256, address, uint256 rewardAmount) override external view returns (IERC20[] memory rewardTokens, uint256[] memory rewardAmounts) {
        IERC20[] memory _rewardTokens = new IERC20[](1);
        _rewardTokens[0] = (rewardToken);
        uint256[] memory _rewardAmounts = new uint256[](1);
        _rewardAmounts[0] = rewardAmount.mul(rewardMultiplier) / REWARD_TOKEN_DIVISOR;
        return (_rewardTokens, _rewardAmounts);
    }

    modifier onlyMCV2 {
        require(
            msg.sender == MASTERCHEF_V2,
            "Only MCV2 can call this function."
        );
        _;
    }

}
