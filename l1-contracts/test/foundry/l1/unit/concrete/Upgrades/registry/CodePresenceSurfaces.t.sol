// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {RegistryTargetHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {ProxyUpgradeRow, ReleaseManifest, TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev The check surface of the write-once objects that keep one: a release and a transition.
interface IValidatable {
    function validate() external view;
}

/// @dev Two distinct implementations so a proxy row is a real `expectedOldImpl -> implNew` edge.
contract ValidateTargetOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract ValidateTargetNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Where "the named contract is deployed code" is enforced, member by member — the MANIFEST
///         is the spec, not the objects' code. A release's `validate()` (run once, when the CTM
///         installs it) covers its own members; a transition's covers only the code it names itself
///         (engine, composer); a proxy upgrade transition has no check of its own, and applying a
///         row to a codeless implementation is refused by OZ's ERC1967 upgrade. See
///         {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}.
/// @dev The transition under test names its optional delegate composer, so the full list is
///      exercised.
contract CodePresenceSurfacesTest is CTMUpgradeExecutorFixture {
    /// @dev `diamondInit`, `genesisUpgrade`, `verifier` — the release members that are not facets.
    uint256 internal constant RELEASE_FIXED_MEMBERS = 3;

    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal ecosystemProxy;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    ProxyUpgradeTransition internal coreTransition;
    ProxyUpgradeTransition internal infrastructure;
    CTMTransition internal fullTransition;

    function setUp() public override {
        super.setUp();
        implOld = address(new ValidateTargetOld());
        implNew = address(new ValidateTargetNew());

        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        coreTransition = _deployCoreTransition(_row(address(ecosystemProxy)));

        fullTransition = _deployTransition(777);
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        infrastructure = _deployCTMInfrastructureTransition(_row(address(ctmDomainProxy)));
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_freshObjectsValidate() public view {
        IValidatable(address(release)).validate();
        IValidatable(address(fullTransition)).validate();
    }

    /// @dev The optional-zero member stays legal: a transition with no composer still validates,
    ///      so the code check is not silently turned into "every slot must be filled".
    function test_transitionWithoutComposerValidates() public {
        TransitionManifest memory manifest = _transitionManifest(
            778,
            chainContractAddress.currentRelease(),
            L2_DELEGATE_CODE
        );
        manifest.l2Plan.delegateComposer = address(0);
        CTMTransition uncomposed = new CTMTransition(manifest);
        uncomposed.validate();
    }

    // ─────────────────────────────── every named member ───────────────────────────────

    /// @dev The fixed members carry their own diagnostic. A facet is READ (`selectors()`), and a
    ///      codeless one fails that read without data — covered where the facets are real
    ///      contracts (`ReleaseFacetRows.t.sol`, `StorageRegistries.t.sol`); this fixture's facets
    ///      answer through mocks.
    function test_everyReleaseMemberIsRequiredToHaveCode() public {
        ReleaseManifest memory m = release.getManifest();
        address[RELEASE_FIXED_MEMBERS] memory fixedMembers = [m.diamondInit, m.genesisUpgrade, m.verifier];
        for (uint256 i = 0; i < RELEASE_FIXED_MEMBERS; ++i) {
            _assertCodelessMemberIsRefused(
                IValidatable(address(release)),
                fixedMembers[i],
                abi.encodeWithSelector(RegistryTargetHasNoCode.selector, fixedMembers[i])
            );
        }
    }

    /// @dev A transition names the engine and the composer; each must be code.
    function test_everyTransitionMemberIsRequiredToHaveCode() public {
        TransitionManifest memory m = fullTransition.getManifest();
        assertTrue(m.l2Plan.delegateComposer != address(0), "the fixture transition names a composer");
        address[2] memory members = [m.upgradeEngine, m.l2Plan.delegateComposer];
        for (uint256 i = 0; i < members.length; ++i) {
            _assertCodelessMemberIsRefused(
                IValidatable(address(fullTransition)),
                members[i],
                abi.encodeWithSelector(RegistryTargetHasNoCode.selector, members[i])
            );
        }
    }

    /// @dev The releases are checked where they are installed, not again by every transition naming
    ///      them: a transition still validates with a codeless member in either release.
    function test_aTransitionDoesNotRecheckItsReleases() public {
        address releaseMember = release.getManifest().genesisUpgrade;
        vm.etch(releaseMember, "");
        fullTransition.validate();
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, releaseMember));
        release.validate();
    }

    /// @dev A proxy upgrade transition of either domain has no check surface of its own: a row whose
    ///      implementation has no code is refused when the executor applies it, by OZ's
    ///      `ERC1967Upgrade._setImplementation`, and nothing of the leg stands.
    function test_aRowWithACodelessImplementationIsRefusedWhenApplied() public {
        assertEq(coreTransition.rows()[0].implNew, implNew);
        assertEq(infrastructure.rows()[0].implNew, implNew);
        vm.etch(implNew, "");

        vm.prank(governor);
        vm.expectRevert("ERC1967: new implementation is not a contract");
        coreExecutor.applyL1Upgrade(coreTransition);
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implOld,
            "the core row did not land"
        );

        vm.prank(governor);
        vm.expectRevert("ERC1967: new implementation is not a contract");
        ctmExecutor.applyInfrastructureUpgrade(infrastructure);
        assertEq(
            ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ctmDomainProxy))),
            implOld,
            "the CTM row did not land"
        );
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _row(address _proxy) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({proxy: _proxy, expectedOldImpl: implOld, implNew: implNew, callInitializeUpgrade: false});
    }

    /// @dev Empties `_member`'s code and checks `validate()` refuses it with `_error`, then restores
    ///      the state and checks the object validates again.
    function _assertCodelessMemberIsRefused(IValidatable _object, address _member, bytes memory _error) internal {
        assertTrue(_member.code.length != 0, "the fixture member must have code before it is emptied");

        uint256 snapshot = vm.snapshotState();
        vm.etch(_member, "");
        vm.expectRevert(_error);
        _object.validate();
        assertTrue(vm.revertToState(snapshot), "restore the emptied member");

        _object.validate();
    }
}
