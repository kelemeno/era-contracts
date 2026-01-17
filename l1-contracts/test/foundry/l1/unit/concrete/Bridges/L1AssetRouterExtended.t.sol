// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Extended tests for L1AssetRouter to increase coverage
contract L1AssetRouterExtendedTest is Test {
    using stdStorage for StdStorage;

    L1AssetRouter public l1AssetRouter;

    address public owner;
    address public proxyAdmin;
    address public wethToken;
    address public bridgehub;
    address public l1Nullifier;
    address public nativeTokenVault;

    MockERC20 public token;

    uint256 public constant ERA_CHAIN_ID = 270;
    uint256 public constant CHAIN_ID = 123;
    address public eraDiamondProxy;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        wethToken = makeAddr("wethToken");
        bridgehub = makeAddr("bridgehub");
        l1Nullifier = makeAddr("l1Nullifier");
        nativeTokenVault = makeAddr("nativeTokenVault");
        eraDiamondProxy = makeAddr("eraDiamondProxy");

        token = new MockERC20();

        // Deploy L1AssetRouter
        l1AssetRouter = new L1AssetRouter({
            _l1WethToken: wethToken,
            _bridgehub: bridgehub,
            _l1Nullifier: l1Nullifier,
            _eraChainId: ERA_CHAIN_ID,
            _eraDiamondProxy: eraDiamondProxy
        });
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(l1AssetRouter.L1_WETH_TOKEN(), wethToken);
        assertEq(address(l1AssetRouter.BRIDGE_HUB()), bridgehub);
        assertEq(address(l1AssetRouter.L1_NULLIFIER()), l1Nullifier);
        assertEq(l1AssetRouter.ERA_CHAIN_ID(), ERA_CHAIN_ID);
        assertEq(l1AssetRouter.ERA_DIAMOND_PROXY(), eraDiamondProxy);
    }

    function test_SetNativeTokenVault_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1AssetRouter.setNativeTokenVault(INativeTokenVaultForRouter(nativeTokenVault));
    }

    function test_SetAssetHandlerAddressThisChain_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        bytes32 assetId = keccak256("assetId");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1AssetRouter.setAssetHandlerAddressThisChain(assetId, makeAddr("handler"));
    }

    function test_DepositLegacyErc20Bridge_RevertWhen_NotNullifier() public {
        address notNullifier = makeAddr("notNullifier");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        vm.prank(notNullifier);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNullifier));
        l1AssetRouter.depositLegacyErc20Bridge({
            _originalCaller: makeAddr("caller"),
            _l2Receiver: makeAddr("receiver"),
            _l1Token: address(token),
            _amount: 100,
            _l2TxGasLimit: 100000,
            _l2TxGasPerPubdataByte: 800,
            _refundRecipient: makeAddr("refund")
        });
    }

    function test_FinalizeDeposit_RevertWhen_NotNullifier() public {
        address notNullifier = makeAddr("notNullifier");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        vm.prank(notNullifier);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNullifier));
        l1AssetRouter.finalizeDeposit(CHAIN_ID, assetId, bytes(""));
    }

    function test_BridgeRecoverFailedTransfer_RevertWhen_NotNullifier() public {
        address notNullifier = makeAddr("notNullifier");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        vm.prank(notNullifier);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNullifier));
        l1AssetRouter.bridgeRecoverFailedTransfer(
            CHAIN_ID,
            makeAddr("sender"),
            assetId,
            bytes("")
        );
    }

    function test_TransferFundsToNTV_RevertWhen_NotNTV() public {
        address notNTV = makeAddr("notNTV");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        vm.prank(notNTV);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNTV));
        l1AssetRouter.transferFundsToNTV(assetId, 100, makeAddr("from"));
    }

    function test_BridgehubDeposit_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        l1AssetRouter.bridgehubDeposit(CHAIN_ID, makeAddr("caller"), 0, bytes(""));
    }

    function test_BridgehubConfirmL2Transaction_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        l1AssetRouter.bridgehubConfirmL2Transaction(CHAIN_ID, bytes32(0), bytes32(0));
    }

    function test_BridgehubDepositBaseToken_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        l1AssetRouter.bridgehubDepositBaseToken(CHAIN_ID, assetId, makeAddr("sender"), 0);
    }

    function testFuzz_GetAssetRouter(uint256 chainId) public view {
        address router = l1AssetRouter.assetRouterAddress(chainId);
        // Should return zero address for unset chains
        assertEq(router, address(0));
    }
}

interface INativeTokenVaultForRouter {
    function tokenAddress(bytes32 assetId) external view returns (address);
}
