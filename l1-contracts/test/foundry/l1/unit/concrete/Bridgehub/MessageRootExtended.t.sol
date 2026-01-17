// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {MessageRoot, CHAIN_TREE_EMPTY_ENTRY_HASH, SHARED_ROOT_TREE_EMPTY_HASH} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {ChainExists, MessageRootNotRegistered, OnlyBridgehubOrChainAssetHandler, OnlyChain, NotL2} from "contracts/bridgehub/L1BridgehubErrors.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";

/// @title Extended tests for MessageRoot to increase coverage
contract MessageRootExtendedTest is Test {
    address public bridgeHub;
    address public chainAssetHandler;
    address public proxyAdmin;
    uint256 public constant L1_CHAIN_ID = 1;
    MessageRoot public messageRoot;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        chainAssetHandler = makeAddr("chainAssetHandler");
        proxyAdmin = makeAddr("proxyAdmin");

        // Mock chainAssetHandler call
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );

        // Deploy MessageRoot implementation and proxy
        MessageRoot impl = new MessageRoot(IBridgehub(bridgeHub), L1_CHAIN_ID);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(MessageRoot.initialize.selector)
        );
        messageRoot = MessageRoot(address(proxy));
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(messageRoot.BRIDGE_HUB()), bridgeHub);
        assertEq(messageRoot.L1_CHAIN_ID(), L1_CHAIN_ID);
    }

    function test_Initialize_SetupSharedTree() public view {
        // After initialization, chainCount should be 1 (for current chain)
        assertEq(messageRoot.chainCount(), 1);
        assertTrue(messageRoot.chainRegistered(block.chainid));
    }

    function test_AddNewChain_ByChainAssetHandler() public {
        uint256 newChainId = 123;

        vm.prank(chainAssetHandler);
        messageRoot.addNewChain(newChainId);

        assertTrue(messageRoot.chainRegistered(newChainId));
        assertEq(messageRoot.chainCount(), 2);
        assertEq(messageRoot.chainIndex(newChainId), 1);
        assertEq(messageRoot.chainIndexToId(1), newChainId);
    }

    function test_AddNewChain_RevertWhen_ChainExists() public {
        uint256 newChainId = 123;

        vm.prank(bridgeHub);
        messageRoot.addNewChain(newChainId);

        vm.prank(bridgeHub);
        vm.expectRevert(ChainExists.selector);
        messageRoot.addNewChain(newChainId);
    }

    function test_GetChainRoot_RevertWhen_NotRegistered() public {
        uint256 unregisteredChainId = 999;

        vm.expectRevert(MessageRootNotRegistered.selector);
        messageRoot.getChainRoot(unregisteredChainId);
    }

    function test_GetChainRoot_Success() public {
        uint256 newChainId = 123;

        vm.prank(bridgeHub);
        messageRoot.addNewChain(newChainId);

        bytes32 root = messageRoot.getChainRoot(newChainId);
        // Initial root should be zero
        assertEq(root, bytes32(0));
    }

    function test_GetAggregatedRoot_NoChains() public {
        // Deploy a fresh instance without proxy to test initial state
        MessageRoot freshMessageRoot = new MessageRoot(IBridgehub(bridgeHub), L1_CHAIN_ID);

        // Note: The constructor already initializes the tree, so we can't test chainCount == 0
        // But we can verify the aggregated root exists
        bytes32 root = freshMessageRoot.getAggregatedRoot();
        assertTrue(root != bytes32(0));
    }

    function test_GetAggregatedRoot_WithChains() public {
        bytes32 root = messageRoot.getAggregatedRoot();
        assertTrue(root != bytes32(0));
    }

    function test_AddChainBatchRoot_RevertWhen_NotChain() public {
        uint256 chainId = 123;
        address notChainAddress = makeAddr("notChainAddress");
        address chainAddress = makeAddr("chainAddress");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, chainId),
            abi.encode(chainAddress)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId);

        vm.prank(notChainAddress);
        vm.expectRevert(abi.encodeWithSelector(OnlyChain.selector, notChainAddress, chainAddress));
        messageRoot.addChainBatchRoot(chainId, 1, bytes32(uint256(1)));
    }

    function test_ChainRegistered_CurrentChain() public view {
        assertTrue(messageRoot.chainRegistered(block.chainid));
    }

    function test_ChainRegistered_UnregisteredChain() public view {
        assertFalse(messageRoot.chainRegistered(12345));
    }

    function test_HistoricalRoot() public {
        // Initially should be bytes32(0)
        bytes32 root = messageRoot.historicalRoot(block.number);
        assertEq(root, bytes32(0));
    }

    function test_UpdateFullTree_EmitsEvent() public {
        uint256 newChainId = 123;
        address chainAddress = makeAddr("chainAddress");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, newChainId),
            abi.encode(chainAddress)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(newChainId);

        // Update full tree should emit NewInteropRoot
        vm.expectEmit(true, true, true, false);
        bytes32[] memory sides = new bytes32[](1);
        emit MessageRoot.NewInteropRoot(block.chainid, block.number, 0, sides);
        messageRoot.updateFullTree();
    }

    function test_UpdateFullTree_UpdatesHistoricalRoot() public {
        messageRoot.updateFullTree();

        bytes32 root = messageRoot.historicalRoot(block.number);
        assertTrue(root != bytes32(0));
    }

    function testFuzz_AddNewChain_MultipleChains(uint8 numChains) public {
        vm.assume(numChains > 0 && numChains < 50);

        for (uint256 i = 0; i < numChains; i++) {
            uint256 chainId = 1000 + i;
            vm.prank(bridgeHub);
            messageRoot.addNewChain(chainId);
            assertTrue(messageRoot.chainRegistered(chainId));
        }

        // +1 for the initial chain (block.chainid)
        assertEq(messageRoot.chainCount(), numChains + 1);
    }

    function testFuzz_ChainIndex(uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.assume(chainId != 0);

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId);

        uint256 index = messageRoot.chainIndex(chainId);
        assertEq(messageRoot.chainIndexToId(index), chainId);
    }
}
