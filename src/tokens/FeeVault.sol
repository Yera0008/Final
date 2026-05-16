// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeeVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    address public market; 

    error OnlyMarket();

    event FeeDeposited(uint256 amount);

    constructor(
        IERC20 asset_,
        address owner_
    )
        ERC4626(asset_)
        ERC20("PredictVaultShares", "pvSHARE")
        Ownable(owner_)
    {}

    function setMarket(address market_) external onlyOwner {
        market = market_;
    }

    function depositFee(uint256 amount) external {
        if (msg.sender != market) revert OnlyMarket();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit FeeDeposited(amount);
    }


    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}