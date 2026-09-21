// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A mintable ERC-20 whose transfers can be made to fail on demand.
/// @dev Used to drive the vault's settlement-failure paths. `StreamingVault` checks return values
/// strictly, and a token that answers `false` instead of reverting is the case a strict check exists
/// for, so it is the one worth simulating.
contract MockToken {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public failTransfers;
    bool public failTransferFrom;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function setFailTransferFrom(bool value) external {
        failTransferFrom = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        if (failTransfers) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        if (failTransferFrom) return false;
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
