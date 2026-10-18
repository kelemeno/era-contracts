// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RegistryTargetHasNoCode} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The one code check the registry model runs against live addresses: "there is a
///         contract here at all".
/// @dev Deliberately the only one: a runtime codehash cannot show that the audited constructor
///      produced an object, so object trust is governance's approval of the exact deployed
///      objects, verified off-chain — see "Provenance and validation" in
///      {docs/registry-driven-upgrades.md}.
library ObjectAnchorLib {
    /// @notice Reverts unless `_target` is a deployed contract.
    /// @dev Used where an address is BOUND into a release or transition (install, commit): code
    ///      placed at an empty address later (an EIP-7702 delegation, a later CREATE2) would run
    ///      on every chain, so only code that already exists may be bound.
    function requireCode(address _target) internal view {
        if (_target.code.length == 0) {
            revert RegistryTargetHasNoCode(_target);
        }
    }
}
