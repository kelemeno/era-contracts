// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ManifestStorage} from "./ManifestStorage.sol";
import {IProxyUpgradeTransition} from "./IProxyUpgradeTransition.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeDomain, ProxyUpgradeRow, ProxyUpgradeTransitionManifest} from "../RegistryTypes.sol";

/// @title Proxy upgrade transition — one instance per domain per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Write-once object pinning one domain's proxy implementation swaps (see `CTMRelease` for
///         the model): the manifest is written at construction and there is no state-mutating
///         function, so a per-instance review is a pure DATA check (read the getters or compare
///         {manifestHash} against the audited manifest).
/// @dev Rows are source-checked edges (`expectedOldImpl -> implNew`). What each `implNew` RUNS, and
///      the inventory's shape, are what governance reviewed before approving this object; the
///      object checks nothing of its own — see
///      {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}.
contract ProxyUpgradeTransition is IProxyUpgradeTransition, ManifestStorage {
    /// @notice Pins the full manifest.
    /// @param _manifest The manifest to pin: an inventory indexed by `_manifest.domain`'s contract
    ///        enum.
    constructor(ProxyUpgradeTransitionManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {}

    /// @inheritdoc IProxyUpgradeTransition
    function getManifest() public view returns (ProxyUpgradeTransitionManifest memory) {
        return abi.decode(encodedManifest, (ProxyUpgradeTransitionManifest));
    }

    /// @inheritdoc IProxyUpgradeTransition
    function domain() external view returns (ProxyUpgradeDomain) {
        return getManifest().domain;
    }

    /// @inheritdoc IProxyUpgradeTransition
    function rows() external view returns (ProxyUpgradeRow[] memory) {
        return _rows();
    }

    function _rows() private view returns (ProxyUpgradeRow[] memory) {
        return ProxyUpgradeRowLib.toRows(getManifest().proxyUpgrades);
    }
}
