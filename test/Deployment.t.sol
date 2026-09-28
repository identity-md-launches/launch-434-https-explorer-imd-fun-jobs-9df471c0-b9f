// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LoopConfig} from "../src/LoopConfig.sol";
import {LoopAccountDeployer} from "../src/LoopAccountDeployer.sol";
import {LoopReceipt} from "../src/LoopReceipt.sol";
import {LoopPosition} from "../src/LoopPosition.sol";
import {FxSwapRouter} from "../src/FxSwapRouter.sol";
import {WbtcUsdFeed} from "../src/WbtcUsdFeed.sol";

contract LocalDeploymentProbe {
    function deploy(bytes memory code, uint256 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0) && deployed.code.length != 0, "constructor failed");
    }
}

/// @notice Mirrors the protected factory sequence with no RPC, environment or preinstalled protocols.
contract DeploymentTest is Test {
    function testLaunchSequenceOnEmptyChain() public {
        LocalDeploymentProbe factory = new LocalDeploymentProbe();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, 1));
        WbtcUsdFeed feed = WbtcUsdFeed(
            factory.deploy(
                abi.encodePacked(
                    type(WbtcUsdFeed).creationCode,
                    abi.encode(address(101), address(102), uint256(90000), uint256(7200))
                ),
                2
            )
        );
        FxSwapRouter router = FxSwapRouter(
            factory.deploy(
                abi.encodePacked(
                    type(FxSwapRouter).creationCode,
                    abi.encode(address(103), address(104), address(105), address(2), address(106))
                ),
                3
            )
        );
        LoopConfig config = LoopConfig(
            factory.deploy(
                abi.encodePacked(
                    type(LoopConfig).creationCode,
                    abi.encode(
                        address(1),
                        address(2),
                        address(3),
                        address(4),
                        address(5),
                        address(6),
                        address(7),
                        address(8),
                        address(9),
                        address(router),
                        address(10),
                        address(feed),
                        uint256(90000)
                    )
                ),
                4
            )
        );
        LoopAccountDeployer deployer = LoopAccountDeployer(
            factory.deploy(abi.encodePacked(type(LoopAccountDeployer).creationCode, abi.encode(address(config))), 5)
        );
        LoopReceipt receipt = LoopReceipt(
            factory.deploy(abi.encodePacked(type(LoopReceipt).creationCode, abi.encode(address(deployer))), 6)
        );
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(receipt.config(), address(config));
        _runtime(address(token));
        _runtime(address(feed));
        _runtime(address(router));
        _runtime(address(config));
        _runtime(address(deployer));
        _runtime(address(receipt));
        // Deployment success does not silently authorize use of absent dependencies.
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        config.validate();
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        feed.latestRoundData();
        vm.expectRevert("missing dependency");
        router.validate();
        (uint256 id, address account) = receipt.createPosition();
        assertEq(receipt.ownerOf(id), address(this));
        assertEq(LoopPosition(account).receiptId(), id);
        _runtime(account);
        LoopPosition.DepositParams memory params;
        params.deadline = block.timestamp;
        vm.expectRevert();
        LoopPosition(account).deposit(params);
        assertEq(token.balanceOf(address(factory)), 1e27);
    }

    function testConstructorRejectsZeroAndDuplicateDependencies() public {
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        _config(address(0), address(2), 1 hours);
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        _config(address(1), address(1), 1 hours);
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        _config(address(1), address(2), 0);
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        _config(address(1), address(2), 8 days);
        vm.expectRevert("invalid feed");
        new WbtcUsdFeed(address(0), address(1), 1, 1);
        vm.expectRevert("invalid feed");
        new WbtcUsdFeed(address(1), address(1), 1, 1);
        vm.expectRevert("feed age");
        new WbtcUsdFeed(address(1), address(2), 0, 1);
        vm.expectRevert("missing dependency");
        new FxSwapRouter(address(0), address(1), address(2), address(3), address(4));
        vm.expectRevert("wrong Curve pool");
        new FxSwapRouter(address(1), address(2), address(3), address(4), address(4));
    }

    function _config(address wbtc, address fx, uint256 age) private returns (LoopConfig) {
        return new LoopConfig(
            wbtc,
            fx,
            address(3),
            address(4),
            address(5),
            address(6),
            address(7),
            address(8),
            address(9),
            address(10),
            address(11),
            address(12),
            age
        );
    }

    function _runtime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
