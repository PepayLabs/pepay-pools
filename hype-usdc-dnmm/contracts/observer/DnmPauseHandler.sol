// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../interfaces/IDnmPool.sol";

/// @notice Mediates OracleWatcher auto-pause signals with governance supervision and cooldowns.
contract DnmPauseHandler {
    IDnmPool private immutable POOL;

    address public governance;
    address public watcher;
    uint32 public cooldownSec;
    uint64 public lastPauseAt;

    error InvalidAddress();
    error NotGovernance();
    error NotWatcher();
    error CooldownActive(uint64 nextAvailable);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event WatcherUpdated(address indexed watcher);
    event CooldownUpdated(uint32 oldCooldown, uint32 newCooldown);
    event AutoPaused(address indexed watcher, bytes32 reason, uint64 timestamp);

    constructor(IDnmPool pool_, address governance_, uint32 cooldownSec_) {
        if (address(pool_) == address(0) || governance_ == address(0)) revert InvalidAddress();
        POOL = pool_;
        governance = governance_;
        cooldownSec = cooldownSec_;
    }

    function pool() public view returns (IDnmPool) {
        return POOL;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyWatcher() {
        if (msg.sender != watcher) revert NotWatcher();
        _;
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        address old = governance;
        governance = newGovernance;
        emit GovernanceTransferred(old, newGovernance);
    }

    function setWatcher(address newWatcher) external onlyGovernance {
        if (newWatcher == address(0)) revert InvalidAddress();
        watcher = newWatcher;
        emit WatcherUpdated(newWatcher);
    }

    function setCooldown(uint32 newCooldownSec) external onlyGovernance {
        uint32 old = cooldownSec;
        cooldownSec = newCooldownSec;
        emit CooldownUpdated(old, newCooldownSec);
    }

    function onOracleCritical(bytes32 reason) external onlyWatcher {
        uint32 delay = cooldownSec;
        if (delay > 0 && lastPauseAt != 0) {
            uint64 nextAllowed = lastPauseAt + delay;
            if (block.timestamp < nextAllowed) revert CooldownActive(nextAllowed);
        }

        POOL.pause();
        lastPauseAt = uint64(block.timestamp);
        emit AutoPaused(msg.sender, reason, lastPauseAt);
    }
}
