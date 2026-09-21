// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Streamline} from "../src/Streamline.sol";

contract StreamlineTest is Test {
    Streamline internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Streamline();
    }

    // ---------------------------------------------------------------------------------------------
    // Supply and metadata
    // ---------------------------------------------------------------------------------------------

    function test_metadataMatchesPolicy() public view {
        assertEq(token.name(), "Streamline");
        assertEq(token.symbol(), "STRM");
        assertEq(token.decimals(), 18, "policy requires 18 decimals");
        assertEq(token.totalSupply(), SUPPLY, "policy requires exactly 10^27 minor units");
        assertEq(token.totalSupply(), 1e27);
    }

    function test_constructorMintsWholeSupplyToItsDeployer() public view {
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// @dev The factory can only check the balance of the address that deployed the token, so the
    /// mint must be observable as a `Transfer` from zero to exactly that address.
    function test_constructorEmitsTheMintTransferFromZero() public {
        vm.recordLogs();
        Streamline fresh = new Streamline();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "the constructor should emit exactly one event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(this));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    /// @dev The property the launch floor cannot fully establish: not "no mint today" but "no mint
    /// path at all". Every one of these selectors is absent, so the call finds no function and no
    /// fallback.
    function test_noAdminSelectorExistsAtAll() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];

        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(alice);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    /// @dev Including from the deployer, which at launch is the factory — the one address a token
    /// might plausibly have been written to trust.
    function test_notEvenTheDeployerCanMint() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), uint256(1)));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_plainEtherAndUnknownCallsRevert() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token has no receive or fallback");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactlyWhatItWasAsked() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), alice, 1000e18);
        assertTrue(token.transfer(alice, 1000e18));

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1000e18);
        assertEq(token.totalSupply(), SUPPLY, "a transfer must not change the supply");
    }

    function test_transferOfZeroIsAllowedAndMovesNothing() public {
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferOfTheWholeBalanceLeavesTheSenderEmpty() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_selfTransferConservesTheBalance() public {
        assertTrue(token.transfer(address(this), 5e18));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(Streamline.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_transferMoreThanTheBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientBalance.selector, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transferOneMoreThanTheBalanceReverts() public {
        token.transfer(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientBalance.selector, 10e18, 10e18 + 1));
        vm.prank(alice);
        token.transfer(bob, 10e18 + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsTheAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(address(this), alice, 7e18);
        assertTrue(token.approve(alice, 7e18));
        assertEq(token.allowance(address(this), alice), 7e18);
    }

    function test_approveOverwritesRatherThanAdds() public {
        token.approve(alice, 7e18);
        token.approve(alice, 2e18);
        assertEq(token.allowance(address(this), alice), 2e18);
    }

    function test_approveToZeroAddressReverts() public {
        vm.expectRevert(Streamline.ApproveToZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsTheAllowance() public {
        token.approve(alice, 10e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 4e18));

        assertEq(token.allowance(address(this), alice), 6e18);
        assertEq(token.balanceOf(bob), 4e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 4e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev An "infinite" approval is infinite only in size. The allowance still decreases, so what
    /// a spender is recorded as being able to spend and what it can actually spend never diverge.
    function test_maxAllowanceStillDecreases() public {
        token.approve(alice, type(uint256).max);

        vm.prank(alice);
        token.transferFrom(address(this), bob, 3e18);

        assertEq(token.allowance(address(this), alice), type(uint256).max - 3e18);
    }

    function test_transferFromWithoutAnyAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientAllowance.selector, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
    }

    function test_transferFromOneMoreThanTheAllowanceReverts() public {
        token.approve(alice, 5e18);
        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientAllowance.selector, 5e18, 5e18 + 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 5e18 + 1);
    }

    /// @dev An allowance larger than the balance behind it is not a claim on tokens that do not
    /// exist.
    function test_transferFromMoreThanTheBalanceRevertsEvenWithAllowance() public {
        token.transfer(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientBalance.selector, 1e18, 2e18));
        vm.prank(bob);
        token.transferFrom(alice, bob, 2e18);
    }

    function test_transferFromCannotBeSpentTwiceOnOneApproval() public {
        token.approve(alice, 5e18);

        vm.prank(alice);
        token.transferFrom(address(this), bob, 5e18);

        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientAllowance.selector, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        token.approve(alice, 5e18);
        vm.expectRevert(Streamline.TransferToZeroAddress.selector);
        vm.prank(alice);
        token.transferFrom(address(this), address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transfersConserveTheSupply(uint256 toAlice, uint256 aliceToBob) public {
        toAlice = bound(toAlice, 0, SUPPLY);
        aliceToBob = bound(aliceToBob, 0, toAlice);

        token.transfer(alice, toAlice);
        vm.prank(alice);
        token.transfer(bob, aliceToBob);

        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob),
            SUPPLY,
            "balances must sum to the fixed supply"
        );
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A proxy passes every behavioural test above and then becomes a different token.
    /// `SELFDESTRUCT` is a token that can stop existing under a live pool. The scan steps over
    /// `PUSH` immediates so that a constant containing 0xF4 is not mistaken for an opcode.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170");

        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
