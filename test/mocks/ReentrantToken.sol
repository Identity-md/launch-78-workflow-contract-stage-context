// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockToken} from "./MockToken.sol";

/// @notice A token that calls back into whoever is transferring it.
/// @dev The vault's one external counterparty is its token, so a hostile token is the whole of its
/// attack surface. Two independent things are worth showing with it, and this mock does both:
///
/// - `arm` re-enters a state-changing function. With `bubbleRevert` the inner revert is propagated,
///   so the test sees exactly which guard stopped it instead of a swallowed failure.
/// - `armProbe` `staticcall`s a view instead. Views carry no reentrancy latch, so this reads the
///   vault's storage at the moment it is mid-transfer and shows the state was already final —
///   checks-effects-interactions holding on its own, independently of the latch.
///
/// The hook disarms itself before firing, so a reentrant transfer cannot recurse forever.
contract ReentrantToken is MockToken {
    address public target;
    bytes public reentryData;
    bool public bubbleRevert;

    address public probeTarget;
    bytes public probeData;

    uint256 public reentryCount;
    bool public lastReentrySucceeded;
    bytes public lastReturnData;
    bytes public lastProbeResult;

    error Reentered(bytes returnData);

    function arm(address target_, bytes calldata data, bool bubbleRevert_) external {
        target = target_;
        reentryData = data;
        bubbleRevert = bubbleRevert_;
    }

    function armProbe(address target_, bytes calldata data) external {
        probeTarget = target_;
        probeData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _hook();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _hook();
        return super.transferFrom(from, to, amount);
    }

    function _hook() private {
        if (probeTarget != address(0)) {
            address probed = probeTarget;
            bytes memory data = probeData;
            probeTarget = address(0);
            (bool probeOk, bytes memory result) = probed.staticcall(data);
            require(probeOk, "probe call failed");
            lastProbeResult = result;
        }

        if (target == address(0)) return;
        address reentered = target;
        bytes memory payload = reentryData;
        target = address(0);

        (bool ok, bytes memory returnData) = reentered.call(payload);
        reentryCount += 1;
        lastReentrySucceeded = ok;
        lastReturnData = returnData;

        if (!ok && bubbleRevert) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
