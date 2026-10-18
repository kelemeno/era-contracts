// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {ManifestStorage} from "../objects/ManifestStorage.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {CTMContract} from "../libraries/ContractIdentifiers.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {RegistryAuthorityLib} from "../libraries/RegistryAuthorityLib.sol";
import {CTMUpgradeExecutor} from "../executors/CTMUpgradeExecutor.sol";
import {ICommittedUpgrade} from "../objects/ICommittedUpgrade.sol";
import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {VersionEdgeLib} from "../libraries/VersionEdgeLib.sol";
import {IRegistryBootstrapMigration} from "./IRegistryBootstrapMigration.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {BootstrapServerNotifierRowMissing, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {BootstrapManifest, L2UpgradePlan} from "../RegistryTypes.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {CTMUpgradeComposer} from "../libraries/CTMUpgradeComposer.sol";
import {TransitionDerivationLib} from "../libraries/TransitionDerivationLib.sol";

/// @title RegistryBootstrapMigration
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The single, source-checked edge from a pre-registry ecosystem to the registry-driven
///         one: it swaps the named implementations, installs the genesis release, commits the
///         version edge, and hands CTM + ProxyAdmin authority to the bound executors — after
///         which every later upgrade is a `CTMTransition`, and this object is inert. See the
///         Bootstrap section of {docs/registry-driven-upgrades.md}.
/// @dev Deliberately NOT a general-purpose executor: there is no arbitrary-call surface. The
///      manifest names every address it touches, and `migrate()` reverts unless the live ecosystem
///      is the starting state the manifest names (each row's source implementation, the departing
///      version) — so the reviewable question is "is this the edge we intend?" rather than "are
///      these calls right against a state I must verify separately".
/// @dev Authority is never parked: `migrate()` acquires nothing it does not hand onward in the same
///      transaction. Governance transfers ownership in, the migration executes, and ownership
///      leaves to the executors before the call returns.
contract RegistryBootstrapMigration is IRegistryBootstrapMigration, ManifestStorage {
    /// @notice Set once `migrate` has run. A replay reverts anyway: the migration no longer owns
    ///         the CTM it would commit on.
    bool public executed;

    /// @dev The FINAL L2 plan, constructed at construction and stored as its ABI encoding (see
    ///      {CTMTransition} for why).
    bytes internal encodedL2Plan;

    /// @dev The genesis release's version, read at construction (see {newProtocolVersion}).
    uint256 internal derivedNewProtocolVersion;

    /// @notice Stores the audited manifest at construction; it is immutable afterwards.
    constructor(BootstrapManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {
        // A zero governance would accept executors whose ownership was renounced; a zero engine
        // commits a cut every chain rejects. Every other zero address fails the first read of it.
        if (_manifest.governance == address(0) || _manifest.upgradeEngine == address(0)) {
            revert ZeroAddress();
        }
        // The notifier's slot is mandatory: its proxy is what `validate()` holds the one-time
        // notifier handover against.
        if (_manifest.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].implNew == address(0)) {
            revert BootstrapServerNotifierRowMissing();
        }
        // The L2 leg, exactly as a transition constructs it: the genesis release's table (the target
        // state, installed in full — there is no departing release to diff against) plus the
        // authored delegate and extras, with the same shape rules ({L2PlanLib.build}).
        ICTMRelease release = ICTMRelease(_manifest.currentRelease);
        uint256 newVersion = release.protocolVersion();
        derivedNewProtocolVersion = newVersion;
        L2UpgradePlan memory plan = L2PlanLib.build(
            TransitionDerivationLib.deriveL2DeploymentsFromTable(
                release.l2BytecodeInfos(),
                release.l2SystemProxyBytecodeInfo()
            ),
            _manifest.l2Plan
        );
        // Held to the edge rules of a `CTMTransition`: chains cross this edge through the same
        // per-chain version checks, so an edge they would refuse must not be committable.
        VersionEdgeLib.requireValidEdge({
            _oldVersion: _manifest.expectedProtocolVersion,
            _newVersion: newVersion,
            _oldVersionDeadline: _manifest.oldProtocolVersionDeadline,
            _upgradeTimestamp: _manifest.upgradeTimestamp,
            _hasL2Side: plan.deployments.length != 0
        });
        encodedL2Plan = abi.encode(plan);
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function getManifest() public view returns (BootstrapManifest memory) {
        return abi.decode(encodedManifest, (BootstrapManifest));
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function newProtocolVersion() external view returns (uint256) {
        return derivedNewProtocolVersion;
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev The genesis release is the edge's target: a chain crossing this edge after the CTM has
    ///      moved on still installs the release ITS OWN committed migration names.
    function upgradeTarget() external view returns (uint256, uint256, address) {
        BootstrapManifest memory m = getManifest();
        return (derivedNewProtocolVersion, m.upgradeTimestamp, m.currentRelease);
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev The stored derived-plus-extra deployments with the authored delegate leg and factory
    ///      dependencies.
    function l2Plan() public view returns (L2UpgradePlan memory) {
        return abi.decode(encodedL2Plan, (L2UpgradePlan));
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function l2UpgradeTx(uint256 _chainId) public view returns (L2CanonicalTransaction memory) {
        BootstrapManifest memory m = getManifest();
        return
            CTMUpgradeComposer.buildL2UpgradeTxFromPlan({
                _plan: l2Plan(),
                _newRelease: ICTMRelease(m.currentRelease),
                _newProtocolVersion: derivedNewProtocolVersion,
                _bridgehub: IChainTypeManager(m.ctm).BRIDGE_HUB(),
                _chainId: _chainId
            });
    }

    /// @inheritdoc IRegistryBootstrapMigration
    /// @dev The engine reads the version edge, schedule and L2 plan from this object at execution,
    ///      so the cut carries nothing but the reference back to it.
    function upgradeCut() public view returns (Diamond.DiamondCutData memory) {
        return CTMUpgradeComposer.buildBootstrapUpgradeCutData(this);
    }

    /// @notice Reverts unless the edge is executable now against the state it lands on: both
    ///         domains' executors answer to the manifest's governance with no nomination pending,
    ///         the CTM and the ServerNotifier the manifest names are bound to each other, the code
    ///         the edge names exists, and every L2 bytecode its plan depends on is published.
    /// @dev Only what can change between review and execution, by someone other than governance,
    ///      and is not refused by a later step of `migrate` anyway; see
    ///      {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}.
    function validate() public view {
        BootstrapManifest memory m = getManifest();
        RegistryAuthorityLib.Authority memory authority = _authority(m);
        RegistryAuthorityLib.requireExecutorsGoverned(authority);
        RegistryAuthorityLib.requireNotifierBound(authority);

        ObjectAnchorLib.requireCode(m.upgradeEngine);
        if (m.l2Plan.delegateComposer != address(0)) {
            ObjectAnchorLib.requireCode(m.l2Plan.delegateComposer);
        }
        // The composed L2 transaction must find every bytecode it depends on already published
        // on the CTM's supplier, or the edge fails on every chain's L2 leg.
        L2PlanLib.requirePublished(
            BytecodesSupplier(IChainTypeManager(m.ctm).L1_BYTECODES_SUPPLIER()),
            l2Plan().factoryDepHashes
        );
    }

    /// @param _m The manifest.
    /// @return The authority shape the manifest names.
    function _authority(BootstrapManifest memory _m) private pure returns (RegistryAuthorityLib.Authority memory) {
        return
            RegistryAuthorityLib.Authority({
                ctm: _m.ctm,
                serverNotifier: _m.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].proxy,
                ctmExecutor: _m.ctmExecutor,
                coreExecutor: _m.coreExecutor,
                governance: _m.governance
            });
    }

    /// @notice Performs the whole edge, then hands authority to the bound executors.
    /// @dev Ordering is load-bearing: the CTM implementation is swapped BEFORE the registry setters
    ///      are called, because those setters only exist on the new implementation.
    /// @dev Deliberately PERMISSIONLESS. The gate is not the caller but the state: nothing here can
    ///      run until governance has handed this object both ownerships, which IS the approval, and
    ///      every value it then writes is pinned by the manifest. Leaving the trigger open means the
    ///      edge cannot be left half-applied because one privileged account failed to send the final
    ///      transaction.
    function migrate() external {
        executed = true;
        BootstrapManifest memory m = getManifest();
        // The CTM is `Ownable2Step`: governance's `transferOwnership` only nominated this contract,
        // so claim it here. Doing it inside `migrate` keeps the whole edge — claim, mutate, hand on
        // — in ONE transaction, which is what stops authority resting here between operations.
        if (Ownable2Step(m.ctm).pendingOwner() == address(this)) {
            Ownable2Step(m.ctm).acceptOwnership();
        }
        validate();

        ProxyUpgradeRowLib.applyRows(m.ctmProxyAdmin, ProxyUpgradeRowLib.toRows(m.ctmProxyUpgrades));

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        // The cut-taking form, not `setNewVersionUpgradeFromTransition`: there is no transition for
        // this edge to derive from. Chains crossing it therefore use the cut-taking chain-side
        // entrypoint too — `upgradeTransition` stays zero for the departing version, and only
        // registry-driven hops after this one populate it. It installs the genesis release in the
        // same call, at the release's own version.
        ctm.setNewVersionUpgrade({
            _cutData: upgradeCut(),
            _oldProtocolVersion: m.expectedProtocolVersion,
            _oldProtocolVersionDeadline: m.oldProtocolVersionDeadline,
            _newRelease: m.currentRelease
        });

        // Authority leaves in the same transaction it arrived. The ProxyAdmin is plain `Ownable`,
        // so its transfer lands immediately. The CTM is `Ownable2Step`: nominate the executor and
        // complete the handover through its `acceptCTMOwnership()` in the SAME transaction — the
        // accept is permissionless-safe (see its docs), so the CTM never sits owned by this
        // spent one-shot object waiting for a separate governance call.
        Ownable2Step(m.ctm).transferOwnership(m.ctmExecutor);
        m.ctmProxyAdmin.transferOwnership(m.ctmExecutor);
        CTMUpgradeExecutor(payable(m.ctmExecutor)).acceptCTMOwnership();

        emit EcosystemBootstrapped(m.ctm, m.currentRelease, derivedNewProtocolVersion);
    }
}
