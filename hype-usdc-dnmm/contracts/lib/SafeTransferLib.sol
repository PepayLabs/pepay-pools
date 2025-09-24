// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SafeTransferLib {
    error TransferFailed(address token, address to, uint256 amount);
    error TransferFromFailed(address token, address from, address to, uint256 amount);
    error ApproveFailed(address token, address spender, uint256 amount);

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success) revert TransferFailed(token, to, amount);
        if (data.length > 0 && !abi.decode(data, (bool))) revert TransferFailed(token, to, amount);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!success) revert TransferFromFailed(token, from, to, amount);
        if (data.length > 0 && !abi.decode(data, (bool))) revert TransferFromFailed(token, from, to, amount);
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!success) revert ApproveFailed(token, spender, amount);
        if (data.length > 0 && !abi.decode(data, (bool))) revert ApproveFailed(token, spender, amount);
    }
}
