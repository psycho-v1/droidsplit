// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PullVault
/// @notice Pull-payment book. Credits never send ETH. Recipients pull.
///         Checks-effects-interactions on every withdraw so a reentrant
///         receiver cannot drain another user's pending balance.
contract PullVault {
    mapping(address => uint256) public pending;

    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, address indexed dest, uint256 amount);

    error ZeroAddress();
    error NoBalance();
    error TransferFailed();

    function credit(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        pending[to] += amount;
        emit Credited(to, amount);
    }

    function withdraw() external {
        _withdraw(payable(msg.sender));
    }

    function withdrawTo(address payable dest) external {
        if (dest == address(0)) revert ZeroAddress();
        _withdraw(dest);
    }

    function _withdraw(address payable dest) private {
        uint256 amount = pending[msg.sender];
        if (amount == 0) revert NoBalance();
        pending[msg.sender] = 0;
        (bool ok, ) = dest.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, dest, amount);
    }
}
