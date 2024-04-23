// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "./ShiftVault.sol";
import "./ShiftStoreUtils.sol";
import "./ShiftEventUtils.sol";

import "../nonce/NonceUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";
import "../utils/AccountUtils.sol";

import "../deposit/ExecuteDepositUtils.sol";
import "../withdrawal/ExecuteWithdrawalUtils.sol";

library ShiftUtils {
    using Deposit for Deposit.Props;
    using Withdrawal for Withdrawal.Props;
    using Shift for Shift.Props;

    struct CreateShiftParams {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address fromMarket;
        address toMarket;
        uint256 minMarketTokens;
        uint256 executionFee;
        uint256 callbackGasLimit;
    }

    struct ExecuteShiftParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        ShiftVault shiftVault;
        Oracle oracle;
        bytes32 key;
        address keeper;
        uint256 startingGas;
    }

    function createShift(
        DataStore dataStore,
        EventEmitter eventEmitter,
        ShiftVault shiftVault,
        address account,
        CreateShiftParams memory params
    ) external returns (bytes32) {
        AccountUtils.validateAccount(account);

        address wnt = TokenUtils.wnt(dataStore);
        uint256 wntAmount = shiftVault.recordTransferIn(wnt);

        if (wntAmount < params.executionFee) {
            revert Errors.InsufficientWntAmount(wntAmount, params.executionFee);
        }

        AccountUtils.validateReceiver(params.receiver);
        if (params.receiver == address(shiftVault)) {
            revert Errors.InvalidReceiver();
        }

        uint256 marketTokenAmount = shiftVault.recordTransferIn(params.fromMarket);

        if (marketTokenAmount == 0) {
            revert Errors.EmptyShiftAmount();
        }

        params.executionFee = wntAmount;

        MarketUtils.validateEnabledMarket(dataStore, params.fromMarket);
        MarketUtils.validateEnabledMarket(dataStore, params.toMarket);

        Shift.Props memory shift = Shift.Props(
            Shift.Addresses(
                account,
                params.receiver,
                params.callbackContract,
                params.uiFeeReceiver,
                params.fromMarket,
                params.toMarket
            ),
            Shift.Numbers(
                marketTokenAmount,
                params.minMarketTokens,
                Chain.currentTimestamp(),
                params.executionFee,
                params.callbackGasLimit
            )
        );

        CallbackUtils.validateCallbackGasLimit(dataStore, shift.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteShiftGasLimit(dataStore, shift);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, params.executionFee);

        bytes32 key = NonceUtils.getNextKey(dataStore);

        ShiftStoreUtils.set(dataStore, key, shift);

        ShiftEventUtils.emitShiftCreated(eventEmitter, key, shift);

        return key;
    }

    function executeShift(
        ExecuteShiftParams memory params,
        Shift.Props memory shift
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        params.startingGas -= gasleft() / 63;

        ShiftStoreUtils.remove(params.dataStore, params.key, shift.account());

        if (shift.account() == address(0)) {
            revert Errors.EmptyShift();
        }

        if (shift.marketTokenAmount() == 0) {
            revert Errors.EmptyShiftAmount();
        }

        Withdrawal.Props memory withdrawal = Withdrawal.Props(
            Withdrawal.Addresses(
                shift.account(),
                address(params.shiftVault), // receiver
                address(0), // callbackContract
                shift.uiFeeReceiver(), // uiFeeReceiver
                shift.fromMarket(), // market
                new address[](0), // longTokenSwapPath
                new address[](0) // shortTokenSwapPath
            ),
            Withdrawal.Numbers(
                shift.marketTokenAmount(),
                0, // minLongTokenAmount
                0, // minShortTokenAmount
                0, // updatedAtBlock
                shift.updatedAtTime(),
                0, // executionFee
                0 // callbackGasLimit
            ),
            Withdrawal.Flags(
                false
            )
        );

        bytes32 withdrawalKey = NonceUtils.getNextKey(params.dataStore);
        params.dataStore.addBytes32(
            Keys.WITHDRAWAL_LIST,
            withdrawalKey
        );

        ExecuteWithdrawalUtils.ExecuteWithdrawalParams memory executeWithdrawalParams = ExecuteWithdrawalUtils.ExecuteWithdrawalParams(
            params.dataStore,
            params.eventEmitter,
            WithdrawalVault(payable(params.shiftVault)),
            params.oracle,
            withdrawalKey,
            params.keeper,
            params.startingGas
        );

        ExecuteWithdrawalUtils.executeWithdrawal(
            executeWithdrawalParams,
            withdrawal
        );

        Market.Props memory depositMarket = MarketStoreUtils.get(params.dataStore, shift.toMarket());

        // if the initialLongToken and initialShortToken are the same, only the initialLongTokenAmount would
        // be non-zero, the initialShortTokenAmount would be zero
        uint256 initialLongTokenAmount = params.shiftVault.recordTransferIn(depositMarket.longToken);
        uint256 initialShortTokenAmount = params.shiftVault.recordTransferIn(depositMarket.shortToken);

        Deposit.Props memory deposit = Deposit.Props(
            Deposit.Addresses(
                shift.account(),
                shift.receiver(),
                address(0), // callbackContract
                shift.uiFeeReceiver(), // uiFeeReceiver
                shift.toMarket(), // market
                depositMarket.longToken, // initialLongToken
                depositMarket.shortToken, // initialShortToken
                new address[](0), // longTokenSwapPath
                new address[](0) // shortTokenSwapPath
            ),
            Deposit.Numbers(
                initialLongTokenAmount,
                initialShortTokenAmount,
                shift.minMarketTokens(),
                0, // updatedAtBlock
                shift.updatedAtTime(),
                0, // executionFee
                0 // callbackGasLimit
            ),
            Deposit.Flags(
                false // shouldUnwrapNativeToken
            )
        );

        bytes32 depositKey = NonceUtils.getNextKey(params.dataStore);
        params.dataStore.addBytes32(
            Keys.DEPOSIT_LIST,
            depositKey
        );

        ExecuteDepositUtils.ExecuteDepositParams memory executeDepositParams = ExecuteDepositUtils.ExecuteDepositParams(
            params.dataStore,
            params.eventEmitter,
            DepositVault(payable(params.shiftVault)),
            params.oracle,
            depositKey,
            params.keeper,
            params.startingGas
        );

        ExecuteDepositUtils.executeDeposit(executeDepositParams, deposit);

        GasUtils.payExecutionFee(
            params.dataStore,
            params.eventEmitter,
            params.shiftVault,
            params.key,
            deposit.callbackContract(),
            deposit.executionFee(),
            params.startingGas,
            params.keeper,
            shift.receiver()
        );
    }

    function cancelShift(
        DataStore dataStore,
        EventEmitter eventEmitter,
        ShiftVault shiftVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Shift.Props memory shift = ShiftStoreUtils.get(dataStore, key);

        if (shift.account() == address(0)) {
            revert Errors.EmptyShift();
        }

        if (shift.marketTokenAmount() == 0) {
            revert Errors.EmptyShiftAmount();
        }

        ShiftStoreUtils.remove(dataStore, key, shift.account());

        shiftVault.transferOut(
            shift.fromMarket(),
            shift.account(),
            shift.marketTokenAmount(),
            false // shouldUnwrapNativeToken
        );

        ShiftEventUtils.emitShiftCancelled(
            eventEmitter,
            key,
            shift.account(),
            reason,
            reasonBytes
        );

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterShiftCancellation(key, shift, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            shiftVault,
            key,
            shift.callbackContract(),
            shift.executionFee(),
            startingGas,
            keeper,
            shift.receiver()
        );
    }
}
