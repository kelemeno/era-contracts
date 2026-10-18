// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {TransitionNotCommitted, UpgradeNotPermissionlessYet} from "../../../common/L1ContractErrors.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeDomain} from "../RegistryTypes.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to one immutable ChainTypeManager: it owns that CTM and its
///         `ProxyAdmin`, applies CTM-domain `ProxyUpgradeTransition` objects, commits write-once
///         `CTMTransition` objects on the CTM, and runs the per-chain `upgradeChain`. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The transition it commits is the exact deployed
///      object governance approved, never a proxy. Every other owner operation of the CTM (freezing
///      a chain, moving a deadline, replacing a committed transition, ...) goes through the
///      owner-gated, event-logged `forward`.
contract CTMUpgradeExecutor is UpgradeExecutorBase, ICTMUpgradeExecutor {
    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM
    ///         through this executor.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies under the CTM's own administration. Owned by this executor.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    /// @dev The bindings are review-time facts, checked off-chain against the reviewed CTM and
    ///      ProxyAdmin; see {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}.
    constructor(
        address _initialOwner,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin
    ) UpgradeExecutorBase(_initialOwner) {
        CHAIN_TYPE_MANAGER = _ctm;
        CTM_PROXY_ADMIN = _ctmProxyAdmin;
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function acceptCTMOwnership() external {
        Ownable2Step(address(CHAIN_TYPE_MANAGER)).acceptOwnership();
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function applyInfrastructureUpgrade(IProxyUpgradeTransition _infrastructureTransition) external onlyOwner {
        ProxyUpgradeRowLib.applyTransition(CTM_PROXY_ADMIN, _infrastructureTransition, ProxyUpgradeDomain.CTM);
        emit CTMInfrastructureUpgradeApplied(address(_infrastructureTransition));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev Every check lives in the CTM, so a commit sent through `forward` gets the same ones.
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        // One argument, not four plus a cut: the CTM reads the version edge, the schedule, the cut
        // and the release it installs from the same pinned object, so they cannot be passed
        // inconsistently.
        CHAIN_TYPE_MANAGER.setNewVersionUpgradeFromTransition(_transition);
        emit CTMUpgradeApplied(
            address(_transition),
            _transition.oldProtocolVersion(),
            _transition.newProtocolVersion()
        );
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            uint256 deadline = CHAIN_TYPE_MANAGER.protocolVersionDeadline(oldProtocolVersion);
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        // The chain executes the cut its own CTM committed, so `_transition` must BE that
        // transition — otherwise the argument would name one edge while a different one ran.
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        // Deliberately NOT re-validated here: the CTM checked the code the transition names when
        // it committed it, and that code cannot have gone since.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);
        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }
}
