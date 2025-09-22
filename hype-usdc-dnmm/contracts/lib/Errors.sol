// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    string internal constant PAUSED = "POOL_PAUSED";
    string internal constant NOT_GOVERNANCE = "NOT_GOVERNANCE";
    string internal constant NOT_PAUSER = "NOT_PAUSER";
    string internal constant DEADLINE_EXPIRED = "DEADLINE_EXPIRED";
    string internal constant ORACLE_STALE = "ORACLE_STALE";
    string internal constant ORACLE_SPREAD = "ORACLE_SPREAD";
    string internal constant ORACLE_DIVERGENCE = "ORACLE_DIVERGENCE";
    string internal constant INVALID_OB = "INVALID_OB";
    string internal constant INVALID_TS = "INVALID_TS";
    string internal constant TOKEN_FEE_UNSUPPORTED = "TOKEN_FEE_UNSUPPORTED";
    string internal constant FLOOR_BREACH = "FLOOR_BREACH";
    string internal constant ZERO_AMOUNT = "ZERO_AMOUNT";
    string internal constant INVALID_CONFIG = "INVALID_CONFIG";
}
