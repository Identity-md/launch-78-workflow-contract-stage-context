// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Streamline (STRM)
/// @notice The fixed-supply reward token of the Streamline protocol.
/// @dev The whole supply is minted to the deployer in a zero-argument constructor and can never
/// change afterwards: `totalSupply` is a compile-time constant, there is no mint, burn, owner,
/// minter, pause or upgrade path, and no function can create or destroy a balance. The only way
/// value moves is `transfer` / `transferFrom`, which conserve the sum of all balances exactly.
contract Streamline {
    string public constant name = "Streamline";
    string public constant symbol = "STRM";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 STRM in minor units (10^27). A constant, not a storage slot, so the
    /// supply is fixed by the bytecode rather than by the absence of a caller who can change it.
    uint256 public constant totalSupply = 1_000_000_000 * 10 ** 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error TransferToZeroAddress();
    error ApproveToZeroAddress();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);

    /// @dev Takes no arguments, so the creation code is identical for every deployment and the
    /// launch factory can predict the address without knowing anything about the token.
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    /// @notice Move `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Move `amount` from `from` to `to`, spending the caller's allowance.
    /// @dev The allowance is always decreased, including when it is `type(uint256).max`. An
    /// "infinite" approval is therefore infinite only in size, and there is no branch in which a
    /// spender's recorded allowance and what it can actually spend disagree.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(allowed, amount);
        allowance[from][msg.sender] = allowed - amount;
        emit Approval(from, msg.sender, allowed - amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Let `spender` move up to `amount` of the caller's balance.
    /// @dev Sets rather than increments, which is the ERC-20 behaviour every wallet and the
    /// Streamline site expect. Callers reducing a live allowance should set it to zero first.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ApproveToZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(balance, amount);
        // Cannot overflow: every balance is bounded by the constant `totalSupply`, which this
        // subtract-then-add pair conserves.
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
