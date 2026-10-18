// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IProxyUpgradeInitializable} from "../IUpgradeInit.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {ProxyUpgradeDomain, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {ProxyUpgradeDomainMismatch, ProxyUpgradeRowMismatch} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice THE `ProxyUpgradeRow` semantics, shared by everything that carries rows (the proxy
///         upgrade transitions of both domains and the bootstrap migration) and everything that
///         applies them: rows are SOURCE-CHECKED edges — a proxy already at
///         `implNew` is skipped (idempotence); a proxy at `expectedOldImpl` is upgraded; a proxy
///         at anything else reverts, so replaying a stale object can never downgrade a proxy that
///         a later upgrade has already moved on.
/// @dev Manifests carry rows as inventories indexed by the canonical contract enums
///      (`L1EcosystemContract` for the ecosystem domain, `CTMContract` for the CTM domain — one
///      enum per domain for deployment and upgrades alike). `toRows` is the single point where
///      those become the row arrays everything below consumes, dropping the slots marked "not
///      upgraded" (zero `implNew`). Appliers therefore never see the inventory shape and survive
///      it growing.
library ProxyUpgradeRowLib {
    /// @notice Emitted (from the applying contract) for every proxy pointed at its new
    ///         implementation. The proxy ADDRESS is the row identity (human labels live in the
    ///         off-chain manifest).
    event ProxyImplementationUpgraded(address indexed proxy, address newImpl);

    /// @notice The participating rows of an enum-indexed inventory: the slots with a nonzero
    ///         `implNew` ("not upgraded" slots are dropped). Shape — one slot per enum member, no
    ///         zero field, no self-edge, one row per proxy — is a review-time fact protocol-ops
    ///         checks; on chain a malformed row is skipped or reverts in {applyRows}.
    function toRows(ProxyUpgradeRow[] memory _slots) internal pure returns (ProxyUpgradeRow[] memory rows) {
        uint256 slotsLength = _slots.length;
        uint256 count = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew != address(0)) {
                ++count;
            }
        }
        rows = new ProxyUpgradeRow[](count);
        uint256 next = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew != address(0)) {
                rows[next] = _slots[i];
                ++next;
            }
        }
    }

    /// @notice Applies a proxy upgrade transition of `_domain` through `_admin`: the object must be
    ///         of that domain, then {applyRows} runs its rows.
    /// @param _admin The applying executor's bound `ProxyAdmin`.
    /// @param _transition The write-once transition governance approved.
    /// @param _domain The domain the applying executor administers.
    function applyTransition(
        ProxyAdmin _admin,
        IProxyUpgradeTransition _transition,
        ProxyUpgradeDomain _domain
    ) internal {
        ProxyUpgradeDomain transitionDomain = _transition.domain();
        if (transitionDomain != _domain) {
            revert ProxyUpgradeDomainMismatch(uint8(_domain), uint8(transitionDomain));
        }
        applyRows(_admin, _transition.rows());
    }

    /// @notice Applies every row with the source-checked semantics above through `_admin`, the
    ///         applying contract's bound `ProxyAdmin`, which administers every proxy of its domain,
    ///         then verifies every row's proxy runs its `implNew` before returning.
    /// @dev The verification is a separate pass after every swap, so a reinitializer that moves
    ///      any proxy of the row set is caught too.
    function applyRows(ProxyAdmin _admin, ProxyUpgradeRow[] memory _rows) internal {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(_rows[i].proxy);
            address newImpl = _rows[i].implNew;
            address liveImpl = _admin.getProxyImplementation(proxy);
            if (liveImpl == newImpl) {
                continue;
            }
            if (liveImpl != _rows[i].expectedOldImpl) {
                revert ProxyUpgradeRowMismatch(_rows[i].proxy, _rows[i].expectedOldImpl, liveImpl);
            }
            if (_rows[i].callInitializeUpgrade) {
                // The reinitializer carries no arguments and no data — see {IUpgradeInit.sol}.
                _admin.upgradeAndCall(proxy, newImpl, abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ()));
            } else {
                _admin.upgrade(proxy, newImpl);
            }
            emit ProxyImplementationUpgraded(address(proxy), newImpl);
        }
        for (uint256 i = 0; i < length; ++i) {
            address liveImpl = _admin.getProxyImplementation(ITransparentUpgradeableProxy(_rows[i].proxy));
            if (liveImpl != _rows[i].implNew) {
                revert ProxyUpgradeRowMismatch(_rows[i].proxy, _rows[i].implNew, liveImpl);
            }
        }
    }
}
