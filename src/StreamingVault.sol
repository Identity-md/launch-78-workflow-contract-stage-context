// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of ERC-20 the vault uses.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StreamingVault
/// @notice Linear token streams: a sender funds a stream to a recipient over a duration, the
/// recipient withdraws whatever has accrued so far at any time, and the sender may cancel, which
/// pays the recipient the accrued part and returns the unaccrued part to the sender.
///
/// @dev Deliberately absent: fees, an owner, an admin, a pause, upgradeability, and any external
/// call other than to the single immutable token set at construction. Nobody — including the
/// deployer and the launch factory — holds a privileged role over a stream; the only addresses a
/// stream ever answers to are its own sender and recipient.
///
/// Accounting invariant: for every live stream, `deposit - withdrawn` tokens are owed to its
/// participants, and the vault only ever moves tokens that some stream owes. It never holds a
/// balance of its own and has no way to sweep one.
contract StreamingVault {
    enum Status {
        None,
        Active,
        Cancelled,
        Completed
    }

    struct Stream {
        address sender;
        uint64 startTime;
        Status status;
        address recipient;
        uint64 stopTime;
        /// @dev Zero while the stream is active. Once it is cancelled or fully withdrawn, accrual
        /// is frozen at this instant, so the historical record stays readable for the UI instead of
        /// being rewritten or deleted on settlement.
        uint64 settledAt;
        uint256 deposit;
        uint256 withdrawn;
    }

    /// @notice The streamed token. Immutable and the vault's only external counterparty.
    IERC20 public immutable token;

    /// @notice Upper bound on a stream's duration.
    /// @dev Bounds the `deposit * elapsed` product in `_accruedAt`, and a stream longer than a
    /// decade is far likelier to be a units mistake than an intent.
    uint64 public constant MAX_DURATION = 3650 days;

    /// @notice Number of streams ever created. Stream ids are 1-based, so 0 is never a stream.
    uint256 public streamCount;

    mapping(uint256 streamId => Stream) private _streams;
    mapping(address sender => uint256[] streamIds) private _sentStreamIds;
    mapping(address recipient => uint256[] streamIds) private _receivedStreamIds;

    /// @dev Reentrancy latch. The vault follows checks-effects-interactions unconditionally, so
    /// this is a second line and not the first: it holds even if a future token gains a callback.
    bool private _entered;

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

    error TokenIsZeroAddress();
    error RecipientIsZeroAddress();
    error RecipientIsSender();
    error RecipientIsVault();
    error DepositIsZero();
    error DurationIsZero();
    error DurationTooLong(uint64 duration, uint64 maxDuration);
    error StreamNotFound(uint256 streamId);
    error StreamNotActive(uint256 streamId, Status status);
    error CallerIsNotTheRecipient(uint256 streamId, address recipient);
    error CallerIsNotTheSender(uint256 streamId, address sender);
    error WithdrawAmountIsZero();
    error NothingToWithdraw(uint256 streamId);
    error AmountExceedsWithdrawable(uint256 requested, uint256 withdrawable);
    error TokenTransferFailed();
    error ReentrantCall();

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param token_ The streamed ERC-20. Supplied as `$token` by the launch manifest.
    /// @dev Nonpayable, makes no calls, and moves no tokens, so it cannot disturb the launch supply
    /// the factory holds while it runs.
    constructor(address token_) {
        if (token_ == address(0)) revert TokenIsZeroAddress();
        token = IERC20(token_);
    }

    // --------------------------------------------------------------------------------------------
    // Streams
    // --------------------------------------------------------------------------------------------

    /// @notice Open a stream of `deposit` tokens to `recipient`, accruing linearly over `duration`
    /// seconds starting now.
    /// @dev The caller must have approved the vault for at least `deposit` beforehand. The stream is
    /// recorded before the tokens are pulled, so a token that re-enters finds the final state, and
    /// the latch rejects it regardless.
    /// @return streamId The new stream's id.
    function createStream(address recipient, uint256 deposit, uint64 duration)
        external
        nonReentrant
        returns (uint256 streamId)
    {
        if (recipient == address(0)) revert RecipientIsZeroAddress();
        if (recipient == msg.sender) revert RecipientIsSender();
        if (recipient == address(this)) revert RecipientIsVault();
        if (deposit == 0) revert DepositIsZero();
        if (duration == 0) revert DurationIsZero();
        if (duration > MAX_DURATION) revert DurationTooLong(duration, MAX_DURATION);

        uint64 startTime = uint64(block.timestamp);
        uint64 stopTime = startTime + duration;

        streamId = ++streamCount;
        _streams[streamId] = Stream({
            sender: msg.sender,
            startTime: startTime,
            status: Status.Active,
            recipient: recipient,
            stopTime: stopTime,
            settledAt: 0,
            deposit: deposit,
            withdrawn: 0
        });
        _sentStreamIds[msg.sender].push(streamId);
        _receivedStreamIds[recipient].push(streamId);

        emit StreamCreated(streamId, msg.sender, recipient, deposit, startTime, stopTime);

        _pull(msg.sender, deposit);
    }

    /// @notice Withdraw `amount` of the tokens that have accrued to the caller's stream.
    /// @dev Only the recipient may call. `amount` is explicit so a recipient can take part of what
    /// has accrued; `withdrawMax` covers the usual case.
    function withdraw(uint256 streamId, uint256 amount) external nonReentrant {
        if (amount == 0) revert WithdrawAmountIsZero();
        _withdraw(streamId, amount);
    }

    /// @notice Withdraw everything that has accrued to the caller's stream and is still unpaid.
    /// @return amount The tokens transferred.
    function withdrawMax(uint256 streamId) external nonReentrant returns (uint256 amount) {
        Stream storage stream = _activeStream(streamId);
        if (msg.sender != stream.recipient) revert CallerIsNotTheRecipient(streamId, stream.recipient);

        amount = _accrued(stream) - stream.withdrawn;
        if (amount == 0) revert NothingToWithdraw(streamId);
        _withdraw(streamId, amount);
    }

    /// @notice Cancel a stream: the recipient is paid what has accrued and is still unpaid, and the
    /// sender gets the rest back.
    /// @dev Only the sender may cancel, which is what makes a stream worth receiving: the recipient
    /// cannot lose what has already accrued, and the sender cannot reclaim it. Cancellation is
    /// settled in full immediately, so no balance is left parked in the vault for anyone to claim
    /// later.
    function cancel(uint256 streamId) external nonReentrant {
        Stream storage stream = _activeStream(streamId);
        address sender = stream.sender;
        address recipient = stream.recipient;
        if (msg.sender != sender) revert CallerIsNotTheSender(streamId, sender);

        uint256 deposit = stream.deposit;
        uint256 accrued = _accrued(stream);
        uint256 recipientAmount = accrued - stream.withdrawn;
        uint256 senderAmount = deposit - accrued;

        stream.status = Status.Cancelled;
        stream.settledAt = uint64(block.timestamp);
        stream.withdrawn = accrued;

        emit StreamCancelled(streamId, sender, recipient, recipientAmount, senderAmount);

        // Both legs must land or the cancellation reverts as a whole: a settlement that pays one
        // party and silently drops the other is the one outcome worse than not cancelling.
        if (recipientAmount > 0) _push(recipient, recipientAmount);
        if (senderAmount > 0) _push(sender, senderAmount);
    }

    // --------------------------------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------------------------------

    /// @notice The full record of a stream, including settled ones.
    function getStream(uint256 streamId) external view returns (Stream memory) {
        Stream storage stream = _streams[streamId];
        if (stream.status == Status.None) revert StreamNotFound(streamId);
        return stream;
    }

    /// @notice Total tokens accrued to the recipient so far, paid or not. Frozen once settled.
    function accruedAmount(uint256 streamId) external view returns (uint256) {
        return _accrued(_existingStream(streamId));
    }

    /// @notice Tokens the recipient can withdraw right now.
    function withdrawableAmount(uint256 streamId) external view returns (uint256) {
        Stream storage stream = _existingStream(streamId);
        return _accrued(stream) - stream.withdrawn;
    }

    /// @notice Tokens the sender would get back if the stream were cancelled right now.
    function refundableAmount(uint256 streamId) external view returns (uint256) {
        Stream storage stream = _existingStream(streamId);
        return stream.deposit - _accrued(stream);
    }

    /// @notice Ids of the streams `sender` has opened, oldest first.
    function sentStreamIds(address sender) external view returns (uint256[] memory) {
        return _sentStreamIds[sender];
    }

    /// @notice Ids of the streams paying `recipient`, oldest first.
    function receivedStreamIds(address recipient) external view returns (uint256[] memory) {
        return _receivedStreamIds[recipient];
    }

    // --------------------------------------------------------------------------------------------
    // Internals
    // --------------------------------------------------------------------------------------------

    function _withdraw(uint256 streamId, uint256 amount) private {
        Stream storage stream = _activeStream(streamId);
        address recipient = stream.recipient;
        if (msg.sender != recipient) revert CallerIsNotTheRecipient(streamId, recipient);

        uint256 withdrawable = _accrued(stream) - stream.withdrawn;
        if (amount > withdrawable) revert AmountExceedsWithdrawable(amount, withdrawable);

        uint256 totalWithdrawn = stream.withdrawn + amount;
        stream.withdrawn = totalWithdrawn;

        bool completed = totalWithdrawn == stream.deposit;
        if (completed) {
            stream.status = Status.Completed;
            stream.settledAt = uint64(block.timestamp);
        }

        emit Withdrawn(streamId, recipient, amount, totalWithdrawn);
        if (completed) emit StreamCompleted(streamId, recipient, totalWithdrawn);

        _push(recipient, amount);
    }

    function _existingStream(uint256 streamId) private view returns (Stream storage stream) {
        stream = _streams[streamId];
        if (stream.status == Status.None) revert StreamNotFound(streamId);
    }

    function _activeStream(uint256 streamId) private view returns (Stream storage stream) {
        stream = _streams[streamId];
        if (stream.status == Status.None) revert StreamNotFound(streamId);
        if (stream.status != Status.Active) revert StreamNotActive(streamId, stream.status);
    }

    /// @dev Accrual is read at `block.timestamp` while a stream is active and at its settlement
    /// instant afterwards.
    function _accrued(Stream storage stream) private view returns (uint256) {
        uint256 at = stream.status == Status.Active ? block.timestamp : stream.settledAt;
        return _accruedAt(stream, at);
    }

    function _accruedAt(Stream storage stream, uint256 at) private view returns (uint256) {
        uint64 startTime = stream.startTime;
        uint64 stopTime = stream.stopTime;
        if (at <= startTime) return 0;
        if (at >= stopTime) return stream.deposit;
        // Multiply first: dividing first would truncate the elapsed fraction to zero. The product
        // is bounded by `deposit * MAX_DURATION`, which cannot overflow for any plausible supply,
        // and would revert rather than wrap if it ever did. The remaining truncation rounds down,
        // in the sender's favour by at most one minor unit, and the recipient recovers it at
        // `stopTime`, where the exact `deposit` is returned without any division at all.
        return (stream.deposit * (at - startTime)) / (stopTime - startTime);
    }

    function _pull(address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TokenTransferFailed();
    }

    function _push(address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TokenTransferFailed();
    }
}
