// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Streamline} from "../src/Streamline.sol";
import {StreamingVault} from "../src/StreamingVault.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract StreamingVaultTest is Test {
    Streamline internal token;
    StreamingVault internal vault;

    address internal alice;
    address internal bob;
    address internal carol;

    uint256 internal constant FUNDING = 1_000_000e18;
    uint256 internal constant DEPOSIT = 1000e18;
    uint64 internal constant DURATION = 30 days;

    /// @dev Mirrors of the vault's events, for `vm.expectEmit`.
    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 deposit,
        uint64 startTime,
        uint64 stopTime
    );
    event Withdrawn(uint256 indexed streamId, address indexed recipient, uint256 amount, uint256 totalWithdrawn);
    event StreamCompleted(uint256 indexed streamId, address indexed recipient, uint256 totalWithdrawn);
    event StreamCancelled(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 recipientAmount,
        uint256 senderAmount
    );

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        token = new Streamline();
        vault = new StreamingVault(address(token));

        token.transfer(alice, FUNDING);
        token.transfer(carol, FUNDING);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        token.approve(address(vault), type(uint256).max);

        // Away from timestamp 1 so `startTime` boundaries are not degenerate.
        vm.warp(1_700_000_000);
    }

    function _open() internal returns (uint256 streamId) {
        vm.prank(alice);
        streamId = vault.createStream(bob, DEPOSIT, DURATION);
    }

    // ---------------------------------------------------------------------------------------------
    // Construction and the absence of privilege
    // ---------------------------------------------------------------------------------------------

    function test_constructorStoresTheTokenAndNothingElse() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.streamCount(), 0);
        assertEq(token.balanceOf(address(vault)), 0, "the constructor must move no tokens");
    }

    function test_constructorRejectsTheZeroToken() public {
        vm.expectRevert(StreamingVault.TokenIsZeroAddress.selector);
        new StreamingVault(address(0));
    }

    /// @dev The vault's defence against a privileged argument in the manifest is that there is no
    /// role for one to fill. Nothing responds to any of these, from any caller, including the
    /// deployer.
    function test_noPrivilegedFunctionExists() public {
        string[10] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "setOwner(address)",
            "pause()",
            "unpause()",
            "setFee(uint256)",
            "sweep(address)",
            "rescue(address,uint256)",
            "upgradeTo(address)",
            "initialize(address)"
        ];

        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(1));
            (bool okDeployer,) = address(vault).call(data);
            assertFalse(okDeployer, signatures[i]);
            vm.prank(alice);
            (bool okStranger,) = address(vault).call(data);
            assertFalse(okStranger, signatures[i]);
        }
    }

    function test_vaultRejectsEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "the vault has no payable entry point");
        assertEq(address(vault).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // createStream
    // ---------------------------------------------------------------------------------------------

    function test_createStreamRecordsTheStreamAndPullsTheDeposit() public {
        uint64 start = uint64(block.timestamp);

        vm.expectEmit(true, true, true, true, address(vault));
        emit StreamCreated(1, alice, bob, DEPOSIT, start, start + DURATION);

        uint256 id = _open();
        assertEq(id, 1, "stream ids are 1-based");
        assertEq(vault.streamCount(), 1);

        StreamingVault.Stream memory stream = vault.getStream(id);
        assertEq(stream.sender, alice);
        assertEq(stream.recipient, bob);
        assertEq(stream.deposit, DEPOSIT);
        assertEq(stream.withdrawn, 0);
        assertEq(stream.startTime, start);
        assertEq(stream.stopTime, start + DURATION);
        assertEq(stream.settledAt, 0);
        assertTrue(stream.status == StreamingVault.Status.Active);

        assertEq(token.balanceOf(address(vault)), DEPOSIT, "the vault holds the deposit");
        assertEq(token.balanceOf(alice), FUNDING - DEPOSIT);
    }

    function test_createStreamIndexesBothParticipants() public {
        uint256 first = _open();
        vm.prank(alice);
        uint256 second = vault.createStream(carol, 5e18, 1 days);
        vm.prank(carol);
        uint256 third = vault.createStream(bob, 7e18, 1 days);

        uint256[] memory aliceSent = vault.sentStreamIds(alice);
        assertEq(aliceSent.length, 2);
        assertEq(aliceSent[0], first);
        assertEq(aliceSent[1], second);

        uint256[] memory bobReceived = vault.receivedStreamIds(bob);
        assertEq(bobReceived.length, 2);
        assertEq(bobReceived[0], first);
        assertEq(bobReceived[1], third);

        assertEq(vault.sentStreamIds(bob).length, 0);
        assertEq(vault.receivedStreamIds(alice).length, 0);
    }

    function test_createStreamRevertsOnZeroRecipient() public {
        vm.expectRevert(StreamingVault.RecipientIsZeroAddress.selector);
        vm.prank(alice);
        vault.createStream(address(0), DEPOSIT, DURATION);
    }

    function test_createStreamRevertsOnSelfStream() public {
        vm.expectRevert(StreamingVault.RecipientIsSender.selector);
        vm.prank(alice);
        vault.createStream(alice, DEPOSIT, DURATION);
    }

    /// @dev A stream to the vault itself would mix a recipient's balance with the pooled deposits.
    function test_createStreamRevertsWhenTheRecipientIsTheVault() public {
        vm.expectRevert(StreamingVault.RecipientIsVault.selector);
        vm.prank(alice);
        vault.createStream(address(vault), DEPOSIT, DURATION);
    }

    function test_createStreamRevertsOnZeroDeposit() public {
        vm.expectRevert(StreamingVault.DepositIsZero.selector);
        vm.prank(alice);
        vault.createStream(bob, 0, DURATION);
    }

    function test_createStreamRevertsOnZeroDuration() public {
        vm.expectRevert(StreamingVault.DurationIsZero.selector);
        vm.prank(alice);
        vault.createStream(bob, DEPOSIT, 0);
    }

    function test_createStreamRevertsAboveMaxDuration() public {
        uint64 tooLong = vault.MAX_DURATION() + 1;
        vm.expectRevert(abi.encodeWithSelector(StreamingVault.DurationTooLong.selector, tooLong, vault.MAX_DURATION()));
        vm.prank(alice);
        vault.createStream(bob, DEPOSIT, tooLong);
    }

    function test_createStreamAcceptsExactlyMaxDuration() public {
        // Read out of the vault before pranking: an external call in the argument list would
        // consume the prank and leave `createStream` called by this contract.
        uint64 maxDuration = vault.MAX_DURATION();

        vm.prank(alice);
        uint256 id = vault.createStream(bob, DEPOSIT, maxDuration);
        assertEq(vault.getStream(id).stopTime, uint64(block.timestamp) + maxDuration);
    }

    function test_createStreamAcceptsTheSmallestViableStream() public {
        vm.prank(alice);
        uint256 id = vault.createStream(bob, 1, 1);
        vm.warp(block.timestamp + 1);
        assertEq(vault.withdrawableAmount(id), 1);
    }

    function test_createStreamRevertsWithoutApproval() public {
        token.transfer(address(0xD00D), 1);
        address noApproval = makeAddr("noApproval");
        token.transfer(noApproval, DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientAllowance.selector, 0, DEPOSIT));
        vm.prank(noApproval);
        vault.createStream(bob, DEPOSIT, DURATION);
    }

    function test_createStreamRevertsWhenTheSenderCannotCoverTheDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientBalance.selector, FUNDING, FUNDING + 1));
        vm.prank(alice);
        vault.createStream(bob, FUNDING + 1, DURATION);
    }

    /// @dev One approval funds one deposit. A second stream against a spent approval must fail
    /// rather than quietly create an unfunded stream.
    function test_createStreamCannotReuseAFiniteApproval() public {
        address dave = makeAddr("dave");
        token.transfer(dave, 2 * DEPOSIT);
        vm.prank(dave);
        token.approve(address(vault), DEPOSIT);

        vm.prank(dave);
        vault.createStream(bob, DEPOSIT, DURATION);

        vm.expectRevert(abi.encodeWithSelector(Streamline.InsufficientAllowance.selector, 0, DEPOSIT));
        vm.prank(dave);
        vault.createStream(bob, DEPOSIT, DURATION);

        assertEq(token.balanceOf(address(vault)), DEPOSIT);
    }

    function test_createStreamRevertsWhenTransferFromReturnsFalse() public {
        (MockToken hostile, StreamingVault hostileVault) = _hostileVault();
        hostile.setFailTransferFrom(true);

        vm.expectRevert(StreamingVault.TokenTransferFailed.selector);
        vm.prank(alice);
        hostileVault.createStream(bob, DEPOSIT, DURATION);

        assertEq(hostileVault.streamCount(), 0, "a failed pull must leave no stream behind");
    }

    // ---------------------------------------------------------------------------------------------
    // Accrual
    // ---------------------------------------------------------------------------------------------

    function test_nothingHasAccruedInTheCreationBlock() public {
        uint256 id = _open();
        assertEq(vault.accruedAmount(id), 0);
        assertEq(vault.withdrawableAmount(id), 0);
        assertEq(vault.refundableAmount(id), DEPOSIT);
    }

    function test_accruesLinearlyAcrossTheStream() public {
        uint256 id = _open();
        uint64 start = vault.getStream(id).startTime;

        vm.warp(start + DURATION / 4);
        assertEq(vault.accruedAmount(id), DEPOSIT / 4);

        vm.warp(start + DURATION / 2);
        assertEq(vault.accruedAmount(id), DEPOSIT / 2);
        assertEq(vault.refundableAmount(id), DEPOSIT - DEPOSIT / 2);

        vm.warp(start + (DURATION * 3) / 4);
        assertEq(vault.accruedAmount(id), (DEPOSIT * 3) / 4);
    }

    function test_oneSecondBeforeStopTimeIsNotYetTheWholeDeposit() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime - 1);
        assertLt(vault.accruedAmount(id), DEPOSIT);
    }

    /// @dev Exactly at `stopTime` the whole deposit is accrued, with no division and so no dust
    /// stranded by rounding.
    function test_theWholeDepositIsAccruedExactlyAtStopTime() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime);
        assertEq(vault.accruedAmount(id), DEPOSIT);
        assertEq(vault.withdrawableAmount(id), DEPOSIT);
        assertEq(vault.refundableAmount(id), 0);
    }

    function test_accrualClampsLongAfterStopTime() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime + 5000 days);
        assertEq(vault.accruedAmount(id), DEPOSIT);
    }

    /// @dev Rounding is down, never up: the recipient can never be credited more than has accrued,
    /// which is what keeps the vault solvent when many streams share it.
    function testFuzz_accrualIsMonotonicAndNeverExceedsTheDeposit(uint256 deposit, uint64 duration, uint64 elapsed)
        public
    {
        deposit = bound(deposit, 1, FUNDING);
        duration = uint64(bound(duration, 1, vault.MAX_DURATION()));
        elapsed = uint64(bound(elapsed, 0, uint256(duration) * 2));

        vm.prank(alice);
        uint256 id = vault.createStream(bob, deposit, duration);
        uint64 start = vault.getStream(id).startTime;

        vm.warp(start + elapsed);
        uint256 accrued = vault.accruedAmount(id);
        assertLe(accrued, deposit, "accrual must never exceed the deposit");
        assertEq(accrued + vault.refundableAmount(id), deposit, "accrued plus refundable is the deposit");

        vm.warp(start + elapsed + 1);
        assertGe(vault.accruedAmount(id), accrued, "accrual must never go backwards");

        vm.warp(uint256(start) + duration);
        assertEq(vault.accruedAmount(id), deposit, "the full deposit must accrue by stopTime");
    }

    // ---------------------------------------------------------------------------------------------
    // withdraw
    // ---------------------------------------------------------------------------------------------

    function test_withdrawPaysTheRecipientAndRecordsIt() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);
        uint256 half = DEPOSIT / 2;

        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdrawn(id, bob, half, half);

        vm.prank(bob);
        vault.withdraw(id, half);

        assertEq(token.balanceOf(bob), half);
        assertEq(token.balanceOf(address(vault)), DEPOSIT - half);
        assertEq(vault.getStream(id).withdrawn, half);
        assertEq(vault.withdrawableAmount(id), 0);
    }

    function test_withdrawInSeveralPartsNeverExceedsWhatHasAccrued() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(bob);
        vault.withdraw(id, DEPOSIT / 4);
        vm.prank(bob);
        vault.withdraw(id, DEPOSIT / 4);

        assertEq(token.balanceOf(bob), DEPOSIT / 2);
        assertEq(vault.withdrawableAmount(id), 0);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.AmountExceedsWithdrawable.selector, 1, 0));
        vm.prank(bob);
        vault.withdraw(id, 1);
    }

    function test_withdrawMaxTakesEverythingAccrued() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 3);
        uint256 expected = vault.withdrawableAmount(id);

        vm.prank(bob);
        uint256 taken = vault.withdrawMax(id);

        assertEq(taken, expected);
        assertEq(token.balanceOf(bob), expected);
        assertEq(vault.withdrawableAmount(id), 0);
    }

    function test_withdrawMaxAtStopTimeCompletesTheStream() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdrawn(id, bob, DEPOSIT, DEPOSIT);
        vm.expectEmit(true, true, true, true, address(vault));
        emit StreamCompleted(id, bob, DEPOSIT);

        vm.prank(bob);
        vault.withdrawMax(id);

        StreamingVault.Stream memory stream = vault.getStream(id);
        assertTrue(stream.status == StreamingVault.Status.Completed);
        assertEq(stream.settledAt, uint64(block.timestamp));
        assertEq(token.balanceOf(bob), DEPOSIT);
        assertEq(token.balanceOf(address(vault)), 0, "a completed stream leaves nothing behind");
    }

    function test_withdrawAfterCompletionReverts() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime);
        vm.prank(bob);
        vault.withdrawMax(id);

        vm.expectRevert(
            abi.encodeWithSelector(StreamingVault.StreamNotActive.selector, id, StreamingVault.Status.Completed)
        );
        vm.prank(bob);
        vault.withdraw(id, 1);
    }

    function test_withdrawRevertsForTheSender() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.CallerIsNotTheRecipient.selector, id, bob));
        vm.prank(alice);
        vault.withdraw(id, 1);
    }

    function test_withdrawRevertsForAStranger() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.CallerIsNotTheRecipient.selector, id, bob));
        vm.prank(carol);
        vault.withdrawMax(id);
    }

    function test_withdrawOfZeroReverts() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);

        vm.expectRevert(StreamingVault.WithdrawAmountIsZero.selector);
        vm.prank(bob);
        vault.withdraw(id, 0);
    }

    function test_withdrawMoreThanAccruedReverts() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);
        uint256 accrued = vault.accruedAmount(id);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.AmountExceedsWithdrawable.selector, accrued + 1, accrued));
        vm.prank(bob);
        vault.withdraw(id, accrued + 1);
    }

    function test_withdrawBeforeAnythingAccruedReverts() public {
        uint256 id = _open();

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.AmountExceedsWithdrawable.selector, 1, 0));
        vm.prank(bob);
        vault.withdraw(id, 1);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.NothingToWithdraw.selector, id));
        vm.prank(bob);
        vault.withdrawMax(id);
    }

    function test_withdrawFromAnUnknownStreamReverts() public {
        _open();

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 0));
        vm.prank(bob);
        vault.withdraw(0, 1);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 99));
        vm.prank(bob);
        vault.withdrawMax(99);
    }

    function test_withdrawRevertsWhenTheTokenTransferReturnsFalse() public {
        (MockToken hostile, StreamingVault hostileVault) = _hostileVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        hostile.setFailTransfers(true);

        vm.expectRevert(StreamingVault.TokenTransferFailed.selector);
        vm.prank(bob);
        hostileVault.withdrawMax(id);

        assertEq(hostileVault.getStream(id).withdrawn, 0, "a failed payout must not be recorded");
    }

    // ---------------------------------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------------------------------

    function test_cancelSplitsTheDepositAtTheCancellationInstant() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 4);

        uint256 accrued = vault.accruedAmount(id);
        uint256 refund = DEPOSIT - accrued;

        vm.expectEmit(true, true, true, true, address(vault));
        emit StreamCancelled(id, alice, bob, accrued, refund);

        vm.prank(alice);
        vault.cancel(id);

        assertEq(token.balanceOf(bob), accrued, "the recipient keeps what accrued");
        assertEq(token.balanceOf(alice), FUNDING - accrued, "the sender is refunded the rest");
        assertEq(token.balanceOf(address(vault)), 0, "cancellation settles in full");

        StreamingVault.Stream memory stream = vault.getStream(id);
        assertTrue(stream.status == StreamingVault.Status.Cancelled);
        assertEq(stream.settledAt, uint64(block.timestamp));
        assertEq(stream.withdrawn, accrued);
    }

    function test_cancelImmediatelyRefundsTheWholeDeposit() public {
        uint256 id = _open();

        vm.prank(alice);
        vault.cancel(id);

        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), FUNDING);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_cancelAfterFullAccrualPaysTheRecipientEverything() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime + 1 days);

        vm.prank(alice);
        vault.cancel(id);

        assertEq(token.balanceOf(bob), DEPOSIT, "the sender cannot reclaim what has accrued");
        assertEq(token.balanceOf(alice), FUNDING - DEPOSIT);
    }

    /// @dev The case where both halves of the accounting are live at once: part already paid out,
    /// part accrued but unpaid, part unaccrued.
    function test_cancelAfterAPartialWithdrawalAccountsForBoth() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);

        uint256 firstTake = DEPOSIT / 8;
        vm.prank(bob);
        vault.withdraw(id, firstTake);

        vm.warp(block.timestamp + DURATION / 4);
        uint256 accrued = vault.accruedAmount(id);

        vm.prank(alice);
        vault.cancel(id);

        assertEq(token.balanceOf(bob), accrued, "the recipient ends with exactly what accrued");
        assertEq(token.balanceOf(alice), FUNDING - accrued);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_cancelRevertsForTheRecipient() public {
        uint256 id = _open();
        vm.expectRevert(abi.encodeWithSelector(StreamingVault.CallerIsNotTheSender.selector, id, alice));
        vm.prank(bob);
        vault.cancel(id);
    }

    function test_cancelRevertsForAStranger() public {
        uint256 id = _open();
        vm.expectRevert(abi.encodeWithSelector(StreamingVault.CallerIsNotTheSender.selector, id, alice));
        vm.prank(carol);
        vault.cancel(id);
    }

    function test_cancelTwiceReverts() public {
        uint256 id = _open();
        vm.prank(alice);
        vault.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(StreamingVault.StreamNotActive.selector, id, StreamingVault.Status.Cancelled)
        );
        vm.prank(alice);
        vault.cancel(id);
    }

    function test_cancelACompletedStreamReverts() public {
        uint256 id = _open();
        vm.warp(vault.getStream(id).stopTime);
        vm.prank(bob);
        vault.withdrawMax(id);

        vm.expectRevert(
            abi.encodeWithSelector(StreamingVault.StreamNotActive.selector, id, StreamingVault.Status.Completed)
        );
        vm.prank(alice);
        vault.cancel(id);
    }

    function test_cancelAnUnknownStreamReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 7));
        vm.prank(alice);
        vault.cancel(7);
    }

    /// @dev Accrual freezes at the cancellation instant. Without that, a cancelled stream would
    /// keep "accruing" on paper and the recorded history would drift away from what was paid.
    function test_cancelFreezesAccrual() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 4);

        vm.prank(alice);
        vault.cancel(id);
        uint256 accruedAtCancel = vault.accruedAmount(id);

        vm.warp(block.timestamp + 10 * uint256(DURATION));
        assertEq(vault.accruedAmount(id), accruedAtCancel, "a cancelled stream must not keep accruing");
        assertEq(vault.withdrawableAmount(id), 0);
        assertEq(vault.refundableAmount(id), DEPOSIT - accruedAtCancel);
    }

    function test_withdrawAfterCancelReverts() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        vault.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(StreamingVault.StreamNotActive.selector, id, StreamingVault.Status.Cancelled)
        );
        vm.prank(bob);
        vault.withdrawMax(id);
    }

    /// @dev Cancellation pays two parties in one transaction. If either leg cannot land, the whole
    /// cancellation must revert rather than pay one and drop the other.
    function test_cancelRevertsWhenEitherLegOfSettlementFails() public {
        (MockToken hostile, StreamingVault hostileVault) = _hostileVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        hostile.setFailTransfers(true);

        vm.expectRevert(StreamingVault.TokenTransferFailed.selector);
        vm.prank(alice);
        hostileVault.cancel(id);

        assertTrue(hostileVault.getStream(id).status == StreamingVault.Status.Active, "the stream survives intact");
        assertEq(hostile.balanceOf(bob), 0);
        assertEq(hostile.balanceOf(address(hostileVault)), DEPOSIT);
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation of funds
    // ---------------------------------------------------------------------------------------------

    function test_vaultHoldsExactlyTheSumOfWhatItsStreamsStillOwe() public {
        vm.prank(alice);
        uint256 a = vault.createStream(bob, 300e18, DURATION);
        vm.prank(carol);
        uint256 b = vault.createStream(bob, 700e18, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(bob);
        vault.withdraw(a, 100e18);

        uint256 owed = (vault.getStream(a).deposit - vault.getStream(a).withdrawn)
            + (vault.getStream(b).deposit - vault.getStream(b).withdrawn);
        assertEq(token.balanceOf(address(vault)), owed);

        // One stream settling must not disturb the other's funds.
        vm.prank(carol);
        vault.cancel(b);
        assertEq(token.balanceOf(address(vault)), vault.getStream(a).deposit - vault.getStream(a).withdrawn);
    }

    function testFuzz_fundsAreConservedThroughWithdrawAndCancel(uint256 deposit, uint64 duration, uint64 elapsed)
        public
    {
        deposit = bound(deposit, 1, FUNDING);
        duration = uint64(bound(duration, 1, vault.MAX_DURATION()));
        elapsed = uint64(bound(elapsed, 0, duration));

        uint256 total = token.balanceOf(alice) + token.balanceOf(bob);

        vm.prank(alice);
        uint256 id = vault.createStream(bob, deposit, duration);
        uint64 start = vault.getStream(id).startTime;

        vm.warp(uint256(start) + elapsed);
        if (vault.withdrawableAmount(id) > 0) {
            vm.prank(bob);
            vault.withdrawMax(id);
        }

        if (vault.getStream(id).status == StreamingVault.Status.Active) {
            vm.prank(alice);
            vault.cancel(id);
        }

        assertEq(token.balanceOf(address(vault)), 0, "the vault keeps nothing once a stream settles");
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), total, "no tokens created or destroyed");
        assertEq(token.balanceOf(bob), vault.getStream(id).withdrawn, "the recipient got exactly what accrued");
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy through a hostile token
    // ---------------------------------------------------------------------------------------------

    function test_reentrantCreateStreamIsRejected() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        hostile.arm(
            address(hostileVault), abi.encodeCall(StreamingVault.createStream, (carol, DEPOSIT, DURATION)), true
        );

        vm.expectRevert(StreamingVault.ReentrantCall.selector);
        vm.prank(alice);
        hostileVault.createStream(bob, DEPOSIT, DURATION);
    }

    function test_reentrantWithdrawIsRejected() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);
        vm.warp(block.timestamp + DURATION / 2);

        hostile.arm(address(hostileVault), abi.encodeCall(StreamingVault.withdraw, (id, 1)), true);

        vm.expectRevert(StreamingVault.ReentrantCall.selector);
        vm.prank(bob);
        hostileVault.withdraw(id, DEPOSIT / 4);
    }

    function test_reentrantWithdrawMaxIsRejected() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);
        vm.warp(block.timestamp + DURATION / 2);

        hostile.arm(address(hostileVault), abi.encodeCall(StreamingVault.withdrawMax, (id)), true);

        vm.expectRevert(StreamingVault.ReentrantCall.selector);
        vm.prank(bob);
        hostileVault.withdrawMax(id);
    }

    /// @dev The most valuable one to block: cancellation makes two transfers, so a hostile token
    /// gets a callback while the second is still outstanding.
    function test_reentrantCancelIsRejected() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);
        vm.warp(block.timestamp + DURATION / 2);

        hostile.arm(address(hostileVault), abi.encodeCall(StreamingVault.cancel, (id)), true);

        vm.expectRevert(StreamingVault.ReentrantCall.selector);
        vm.prank(alice);
        hostileVault.cancel(id);
    }

    /// @dev Checks-effects-interactions, shown independently of the latch. Views carry no latch, so
    /// the hostile token reads the vault's storage while the payout transfer is still in flight and
    /// sees the post-withdrawal state, not the pre-withdrawal one. Even with the latch removed
    /// there would be nothing to re-enter for.
    function test_stateIsAlreadyFinalWhenTheTokenIsCalled() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);
        vm.warp(block.timestamp + DURATION / 2);

        uint256 accrued = hostileVault.accruedAmount(id);
        hostile.armProbe(address(hostileVault), abi.encodeCall(StreamingVault.withdrawableAmount, (id)));

        vm.prank(bob);
        hostileVault.withdrawMax(id);

        assertEq(
            abi.decode(hostile.lastProbeResult(), (uint256)),
            0,
            "the withdrawal was already recorded before the token was called"
        );
        assertEq(hostileVault.getStream(id).withdrawn, accrued);
    }

    /// @dev A hostile token cannot be used to fabricate a stream either: the reentrant creation is
    /// rejected and the record stays at the one legitimate stream.
    function test_reentrancyCannotFabricateAStream() public {
        (ReentrantToken hostile, StreamingVault hostileVault) = _reentrantVault();
        vm.prank(alice);
        uint256 id = hostileVault.createStream(bob, DEPOSIT, DURATION);
        vm.warp(block.timestamp + DURATION / 2);

        // Not bubbled: the outer withdrawal is allowed to finish so the aftermath can be inspected.
        hostile.arm(
            address(hostileVault), abi.encodeCall(StreamingVault.createStream, (carol, DEPOSIT, DURATION)), false
        );

        vm.prank(bob);
        hostileVault.withdrawMax(id);

        assertEq(hostile.reentryCount(), 1, "the token did try to re-enter");
        assertFalse(hostile.lastReentrySucceeded(), "and was refused");
        assertEq(bytes4(hostile.lastReturnData()), StreamingVault.ReentrantCall.selector);
        assertEq(hostileVault.streamCount(), 1, "no stream was fabricated");
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function test_viewsRevertForAnUnknownStream() public {
        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 1));
        vault.getStream(1);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 1));
        vault.accruedAmount(1);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 1));
        vault.withdrawableAmount(1);

        vm.expectRevert(abi.encodeWithSelector(StreamingVault.StreamNotFound.selector, 1));
        vault.refundableAmount(1);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(vault).code;
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

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _hostileVault() internal returns (MockToken hostile, StreamingVault hostileVault) {
        hostile = new MockToken();
        hostileVault = new StreamingVault(address(hostile));
        hostile.mint(alice, FUNDING);
        vm.prank(alice);
        hostile.approve(address(hostileVault), type(uint256).max);
    }

    function _reentrantVault() internal returns (ReentrantToken hostile, StreamingVault hostileVault) {
        hostile = new ReentrantToken();
        hostileVault = new StreamingVault(address(hostile));
        hostile.mint(alice, FUNDING);
        vm.prank(alice);
        hostile.approve(address(hostileVault), type(uint256).max);
    }
}
