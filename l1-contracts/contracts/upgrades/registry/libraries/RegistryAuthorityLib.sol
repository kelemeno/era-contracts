// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";
import {
    BootstrapExecutorOwnerMismatch,
    BootstrapNominationPending,
    BootstrapServerNotifierNotBound
} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The part of a registry-era ecosystem's authority shape the bootstrap reads at execution,
///         because someone other than governance can change it after review: the executors answer
///         to one governance, and the CTM and its ServerNotifier are bound to each other. The rest
///         of the shape is a review-time fact or a post-condition — see
///         {protocol-docs/ecosystem-upgrade.md#where-each-check-lives} and "Authority" in
///         {docs/registry-driven-upgrades.md}.
library RegistryAuthorityLib {
    /// @notice Every address the authority shape names.
    /// @param ctm The ChainTypeManager proxy.
    /// @param serverNotifier The CTM's ServerNotifier proxy.
    /// @param ctmExecutor The `CTMUpgradeExecutor` bound to `ctm`.
    /// @param coreExecutor The `CoreUpgradeExecutor` bound to the ecosystem `ProxyAdmin`.
    /// @param governance The owner of both executors.
    // solhint-disable-next-line gas-struct-packing
    struct Authority {
        address ctm;
        address serverNotifier;
        address ctmExecutor;
        address coreExecutor;
        address governance;
    }

    /// @notice Reverts unless both executors are owned by `governance` with no nomination
    ///         outstanding: an executor whose ownership moved would act for its new owner, and a
    ///         nominee could claim it.
    /// @param _a The authority shape to check.
    function requireExecutorsGoverned(Authority memory _a) internal view {
        _requireGovernedBy(_a.ctmExecutor, _a.governance);
        _requireGovernedBy(_a.coreExecutor, _a.governance);
    }

    /// @notice Reverts unless the CTM names the ServerNotifier and the ServerNotifier serves the CTM.
    /// @param _a The authority shape to check.
    function requireNotifierBound(Authority memory _a) internal view {
        address ctmNotifier = IChainTypeManager(_a.ctm).serverNotifierAddress();
        if (ctmNotifier != _a.serverNotifier) {
            revert BootstrapServerNotifierNotBound(_a.serverNotifier, ctmNotifier);
        }
        address notifierCtm = address(ServerNotifier(_a.serverNotifier).chainTypeManager());
        if (notifierCtm != _a.ctm) {
            revert BootstrapServerNotifierNotBound(_a.ctm, notifierCtm);
        }
    }

    /// @param _target An `Ownable2Step` authority of the shape.
    function _requireNoNomination(address _target) private view {
        address pendingOwner = Ownable2Step(_target).pendingOwner();
        if (pendingOwner != address(0)) {
            revert BootstrapNominationPending(_target, pendingOwner);
        }
    }

    /// @param _executor An executor of the shape.
    /// @param _governance The owner it must answer to.
    function _requireGovernedBy(address _executor, address _governance) private view {
        address owner = Ownable2Step(_executor).owner();
        if (owner != _governance) {
            revert BootstrapExecutorOwnerMismatch(_executor, _governance, owner);
        }
        _requireNoNomination(_executor);
    }
}
