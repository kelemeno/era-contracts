// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @title Extended tests for ZKChainBase to increase coverage on modifiers
contract ZKChainBaseExtendedTest is Test {
    IAdmin internal adminFacet;
    IExecutor internal executorFacet;
    IMailbox internal mailboxFacet;
    IGetters internal gettersFacet;
    UtilsFacet internal utilsFacet;

    address internal admin;
    address internal validator;
    address internal chainTypeManager;
    address internal bridgehub;
    address internal settlementLayer;
    address internal chainAssetHandler;

    uint256 constant eraChainId = 9;
    address internal testnetVerifier = address(new TestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));

    function setUp() public {
        admin = makeAddr("admin");
        validator = makeAddr("validator");
        chainTypeManager = makeAddr("chainTypeManager");
        bridgehub = makeAddr("bridgehub");
        settlementLayer = makeAddr("settlementLayer");
        chainAssetHandler = makeAddr("chainAssetHandler");

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](5);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet(block.chainid, makeAddr("rollupDAManager"))),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new ExecutorFacet(block.chainid)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getExecutorSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(new MailboxFacet(eraChainId, block.chainid)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: address(new GettersFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier);

        adminFacet = IAdmin(diamondProxy);
        executorFacet = IExecutor(diamondProxy);
        mailboxFacet = IMailbox(diamondProxy);
        gettersFacet = IGetters(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);

        // Set up state
        utilsFacet.util_setAdmin(admin);
        utilsFacet.util_setValidator(validator, true);
        utilsFacet.util_setChainTypeManager(chainTypeManager);
        utilsFacet.util_setBridgehub(bridgehub);
    }

    function test_OnlyAdmin_RevertWhen_NotAdmin() public {
        address notAdmin = makeAddr("notAdmin");

        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAdmin));
        adminFacet.setPendingAdmin(makeAddr("newAdmin"));
    }

    function test_OnlyAdmin_Success() public {
        address newPendingAdmin = makeAddr("newPendingAdmin");

        vm.prank(admin);
        adminFacet.setPendingAdmin(newPendingAdmin);

        assertEq(gettersFacet.getPendingAdmin(), newPendingAdmin);
    }

    function test_OnlyValidator_RevertWhen_NotValidator() public {
        address notValidator = makeAddr("notValidator");

        // Executor functions use onlyValidator or onlyValidatorOrChainTypeManager
        // We need to test through actual facet calls
        vm.prank(notValidator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notValidator));
        executorFacet.revertBatches(0);
    }

    function test_OnlyChainTypeManager_RevertWhen_NotCTM() public {
        address notCTM = makeAddr("notCTM");

        // executeUpgrade requires onlyChainTypeManager
        Diamond.FacetCut[] memory emptyFacets = new Diamond.FacetCut[](0);
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: emptyFacets,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.prank(notCTM);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notCTM));
        adminFacet.executeUpgrade(diamondCut);
    }

    function test_OnlyChainTypeManager_Success() public {
        Diamond.FacetCut[] memory emptyFacets = new Diamond.FacetCut[](0);
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: emptyFacets,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.prank(chainTypeManager);
        // This might revert for other reasons, but not Unauthorized
        try adminFacet.executeUpgrade(diamondCut) {} catch (bytes memory reason) {
            // Check it's not Unauthorized
            assertTrue(keccak256(reason) != keccak256(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager)));
        }
    }

    function test_OnlyBridgehub_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        // Use bridgehubRequestL2Transaction which has onlyBridgehub modifier
        mailboxFacet.bridgehubRequestL2Transaction(
            _createDummyBridgehubRequest()
        );
    }

    function test_OnlyAdminOrChainTypeManager_ByAdmin() public {
        vm.prank(admin);
        // setValidator uses onlyAdminOrChainTypeManager
        adminFacet.setValidator(makeAddr("newValidator"), true);
    }

    function test_OnlyAdminOrChainTypeManager_ByCTM() public {
        vm.prank(chainTypeManager);
        adminFacet.setValidator(makeAddr("newValidator"), true);
    }

    function test_OnlyAdminOrChainTypeManager_RevertWhen_Neither() public {
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomUser));
        adminFacet.setValidator(makeAddr("newValidator"), true);
    }

    function test_OnlyValidatorOrChainTypeManager_ByValidator() public {
        // revertBatches uses onlyValidatorOrChainTypeManager
        vm.prank(validator);
        // This will likely fail for other reasons but not Unauthorized
        try executorFacet.revertBatches(0) {} catch (bytes memory reason) {
            assertTrue(keccak256(reason) != keccak256(abi.encodeWithSelector(Unauthorized.selector, validator)));
        }
    }

    function test_OnlyValidatorOrChainTypeManager_ByCTM() public {
        vm.prank(chainTypeManager);
        try executorFacet.revertBatches(0) {} catch (bytes memory reason) {
            assertTrue(keccak256(reason) != keccak256(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager)));
        }
    }

    function test_OnlySettlementLayer_RevertWhen_SettlementLayerSet() public {
        // Set a settlement layer
        utilsFacet.util_setSettlementLayer(settlementLayer);

        // Now trying to commit batches should fail with NotSettlementLayer
        IExecutor.StoredBatchInfo memory lastCommittedBatch = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(0),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: bytes32(0),
            l2LogsTreeRoot: bytes32(0),
            timestamp: 0,
            commitment: bytes32(0)
        });
        IExecutor.CommitBatchInfo[] memory newBatches = new IExecutor.CommitBatchInfo[](1);
        newBatches[0] = IExecutor.CommitBatchInfo({
            batchNumber: 1,
            timestamp: uint64(block.timestamp),
            indexRepeatedStorageChanges: 1,
            newStateRoot: bytes32(uint256(1)),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: bytes32(0),
            bootloaderHeapInitialContentsHash: bytes32(0),
            eventsQueueStateHash: bytes32(0),
            systemLogs: bytes(""),
            operatorDAInput: bytes("")
        });

        vm.prank(validator);
        vm.expectRevert(NotSettlementLayer.selector);
        executorFacet.commitBatchesSharedBridge(0, lastCommittedBatch, newBatches);
    }

    function _createDummyBridgehubRequest() internal pure returns (BridgehubL2TransactionRequest memory) {
        return BridgehubL2TransactionRequest({
            sender: address(0),
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2GasLimit: 0,
            l2Calldata: bytes(""),
            l2GasPerPubdataByteLimit: 0,
            factoryDeps: new bytes[](0),
            refundRecipient: address(0)
        });
    }
}

struct BridgehubL2TransactionRequest {
    address sender;
    address contractL2;
    uint256 mintValue;
    uint256 l2Value;
    uint256 l2GasLimit;
    bytes l2Calldata;
    uint256 l2GasPerPubdataByteLimit;
    bytes[] factoryDeps;
    address refundRecipient;
}
