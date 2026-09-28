// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LoopPosition} from "./LoopPosition.sol";
import {LoopAccountDeployer} from "./LoopAccountDeployer.sol";

/// @notice Transferable title to an isolated position, not fungible shares or a capital guarantee.
contract LoopReceipt is ERC721 {
    address public immutable config;
    LoopAccountDeployer public immutable accountDeployer;
    uint256 public nextId = 1;
    mapping(uint256 => address) public accountOf;
    error InvalidConfiguration();
    error Unauthorized();
    error PositionBusy();
    event PositionCreated(address indexed owner, uint256 indexed id, address indexed account);

    constructor(address deployer_) ERC721("Bitcoin Cooler Position", "BCP") {
        if (deployer_.code.length == 0) revert InvalidConfiguration();
        accountDeployer = LoopAccountDeployer(deployer_);
        config = accountDeployer.config();
    }

    function createPosition() external returns (uint256 id, address account) {
        id = nextId++;
        account = accountDeployer.deploy(id);
        accountOf[id] = account;
        _mint(msg.sender, id);
        emit PositionCreated(msg.sender, id, account);
    }

    function burn(uint256 id) external {
        if (msg.sender != accountOf[id] || !LoopPosition(msg.sender).closed()) revert Unauthorized();
        _burn(id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat(
            'data:application/json;utf8,{"name":"Bitcoin Cooler #',
            Strings.toString(id),
            '","description":"Ownership of an isolated leveraged position; not a capital guarantee.","account":"',
            Strings.toHexString(accountOf[id]),
            '"}'
        );
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(id) != address(0) && LoopPosition(accountOf[id]).busy()) {
            revert PositionBusy();
        }
        return super._update(to, id, auth);
    }
}
