// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice ERC-1155 где каждый marketId*2 = YES token, marketId*2+1 = NO token
contract OutcomeToken is ERC1155, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // marketId => resolved
    mapping(uint256 => bool) public marketResolved;

    event OutcomeMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event OutcomeBurned(address indexed from, uint256 indexed tokenId, uint256 amount);

    constructor(address admin) ERC1155("https://predict.xyz/metadata/{id}.json") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @notice tokenId = marketId * 2 (YES) or marketId * 2 + 1 (NO)
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        _mint(to, tokenId, amount, data);
        emit OutcomeMinted(to, tokenId, amount);
    }

    function burn(
        address from,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _burn(from, tokenId, amount);
        emit OutcomeBurned(from, tokenId, amount);
    }

    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        _mintBatch(to, ids, amounts, data);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC1155, AccessControl) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}