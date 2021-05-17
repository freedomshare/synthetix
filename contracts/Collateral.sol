pragma solidity ^0.5.16;

pragma experimental ABIEncoderV2;

// Inheritance
import "./Owned.sol";
import "./MixinSystemSettings.sol";
import "./interfaces/ICollateralLoan.sol";

// Libraries
import "./SafeDecimalMath.sol";

// Internal references
import "./CollateralUtil.sol";
import "./interfaces/ICollateralManager.sol";
import "./interfaces/ISystemStatus.sol";
import "./interfaces/IFeePool.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IShortingRewards.sol";
import "./interfaces/ICollateralUtil.sol";

contract Collateral is ICollateralLoan, Owned, MixinSystemSettings {
    /* ========== LIBRARIES ========== */
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ========== */

    bytes32 private constant sUSD = "sUSD";

    // ========== STATE VARIABLES ==========

    // The synth corresponding to the collateral.
    bytes32 public collateralKey;

    // Stores loans open
    mapping(uint => Loan) public loans;

    address public manager;

    // The synths that this contract can issue.
    bytes32[] public synths;

    // Map from currency key to synth contract name.
    mapping(bytes32 => bytes32) public synthsByKey;

    // Map from currency key to the shorting rewards contract
    mapping(bytes32 => address) public shortingRewards;

    // ========== SETTER STATE VARIABLES ==========

    // The minimum collateral ratio required to avoid liquidation.
    uint public minCratio;

    // The minimum amount of collateral to create a loan.
    uint public minCollateral;

    // The fee charged for issuing a loan.
    uint public issueFeeRate;

    // The maximum number of loans that an account can create with this collateral.
    uint public maxLoansPerAccount = 50;

    bool public canOpenLoans = true;

    bool internal initialized = false;

    uint public interactionDelay = 0;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";
    bytes32 private constant CONTRACT_SYNTHSUSD = "SynthsUSD";
    bytes32 private constant CONTRACT_COLLATERALUTIL = "CollateralUtil";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _manager,
        address _resolver,
        bytes32 _collateralKey,
        uint _minCratio,
        uint _minCollateral
    ) public Owned(_owner) MixinSystemSettings(_resolver) {
        manager = _manager;
        collateralKey = _collateralKey;
        minCratio = _minCratio;
        minCollateral = _minCollateral;
    }

    /* ========== VIEWS ========== */

    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory existingAddresses = MixinSystemSettings.resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](4);
        newAddresses[0] = CONTRACT_FEEPOOL;
        newAddresses[1] = CONTRACT_EXRATES;
        newAddresses[2] = CONTRACT_SYSTEMSTATUS;
        newAddresses[3] = CONTRACT_SYNTHSUSD;
        newAddresses[4] = CONTRACT_COLLATERALUTIL;

        bytes32[] memory combined = combineArrays(existingAddresses, newAddresses);

        addresses = combineArrays(combined, synths);
    }

    /* ---------- Related Contracts ---------- */

    function _systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS));
    }

    function _synth(bytes32 synthName) internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(synthName));
    }

    function _synthsUSD() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSUSD));
    }

    function _exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function _feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function _manager() internal view returns (ICollateralManager) {
        return ICollateralManager(manager);
    }

    function _collateralUtil() internal view returns (ICollateralUtil) {
        return ICollateralUtil(requireAndGetAddress(CONTRACT_COLLATERALUTIL));
    }

    /* ---------- Public Views ---------- */

    function collateralRatio(uint id) public view returns (uint cratio) {
        Loan memory loan = loans[id];
        return _collateralUtil().getCollateralRatio(loan, collateralKey);
    }

    // The maximum number of synths issuable for this amount of collateral
    function maxLoan(uint amount, bytes32 currency) public view returns (uint max) {
        return _collateralUtil().maxLoan(amount, currency, minCratio, collateralKey);
    }

    function liquidationAmount(Loan memory loan) public view returns (uint amount) {
        return _collateralUtil().liquidationAmount(loan, minCratio, collateralKey);
    }

    function collateralRedeemed(bytes32 currency, uint amount) public view returns (uint collateral) {
        return _collateralUtil().collateralRedeemed(currency, amount, collateralKey);
    }

    function areSynthsAndCurrenciesSet(bytes32[] calldata _synthNamesInResolver, bytes32[] calldata _synthKeys)
        external
        view
        returns (bool)
    {
        if (synths.length != _synthNamesInResolver.length) {
            return false;
        }

        for (uint i = 0; i < _synthNamesInResolver.length; i++) {
            bytes32 synthName = _synthNamesInResolver[i];
            if (synths[i] != synthName) {
                return false;
            }
            if (synthsByKey[_synthKeys[i]] != synths[i]) {
                return false;
            }
        }

        return true;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /* ---------- Synths ---------- */

    function addSynths(bytes32[] calldata _synthNamesInResolver, bytes32[] calldata _synthKeys) external onlyOwner {
        require(_synthNamesInResolver.length == _synthKeys.length);

        for (uint i = 0; i < _synthNamesInResolver.length; i++) {
            bytes32 synthName = _synthNamesInResolver[i];
            synths.push(synthName);
            synthsByKey[_synthKeys[i]] = synthName;
        }

        // ensure cache has the latest
        rebuildCache();
    }

    /* ---------- Rewards Contracts ---------- */

    function addRewardsContracts(address rewardsContract, bytes32 synth) external onlyOwner {
        shortingRewards[synth] = rewardsContract;
    }

    /* ---------- SETTERS ---------- */

    function setMinCratio(uint _minCratio) external onlyOwner {
        require(_minCratio > SafeDecimalMath.unit());
        minCratio = _minCratio;
        emit MinCratioRatioUpdated(minCratio);
    }

    function setIssueFeeRate(uint _issueFeeRate) external onlyOwner {
        issueFeeRate = _issueFeeRate;
        emit IssueFeeRateUpdated(issueFeeRate);
    }

    function setInteractionDelay(uint _interactionDelay) external onlyOwner {
        require(_interactionDelay <= SafeDecimalMath.unit() * 3600, "Max 1 hour");
        interactionDelay = _interactionDelay;
        emit InteractionDelayUpdated(interactionDelay);
    }

    function setManager(address _newManager) external onlyOwner {
        manager = _newManager;
        emit ManagerUpdated(manager);
    }

    function setCanOpenLoans(bool _canOpenLoans) external onlyOwner {
        canOpenLoans = _canOpenLoans;
        emit CanOpenLoansUpdated(canOpenLoans);
    }

    /* ---------- LOAN INTERACTIONS ---------- */

    function openInternal(
        uint collateral,
        uint amount,
        bytes32 currency,
        bool short
    ) internal rateIsValid returns (uint id) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        require(canOpenLoans);

        // 1. We can only issue certain synths.
        require(synthsByKey[currency] > 0);

        // 2. Make sure the synth rate is not invalid.
        require(!_exchangeRates().rateIsInvalid(currency));

        // 3. Collateral >= minimum collateral size.
        require(collateral >= minCollateral);

        // 5. Check we haven't hit the debt cap for non snx collateral.
        (bool canIssue, bool anyRateIsInvalid) = _manager().exceedsDebtLimit(amount, currency);

        require(canIssue && !anyRateIsInvalid);

        // 6. Require requested loan < max loan
        require(amount <= maxLoan(collateral, currency));

        // 7. This fee is denominated in the currency of the loan
        uint issueFee = amount.multiplyDecimalRound(issueFeeRate);

        // 8. Calculate the minting fee and subtract it from the loan amount
        uint loanAmountMinusFee = amount.sub(issueFee);

        // 9. Get a Loan ID
        id = _manager().getNewLoanId();

        // 10. Create the loan.
        loans[id] = Loan({
            id: id,
            account: msg.sender,
            collateral: collateral,
            currency: currency,
            amount: amount,
            short: short,
            accruedInterest: 0,
            interestIndex: 0,
            lastInteraction: block.timestamp
        });

        // 11. Accrue interest on the loan.
        accrueInterest(loans[id]);

        // 12. Pay the minting fees to the fee pool
        _payFees(issueFee, currency);

        // 13. If its short, convert back to sUSD, otherwise issue the loan.
        if (short) {
            _synthsUSD().issue(msg.sender, _exchangeRates().effectiveValue(currency, loanAmountMinusFee, sUSD));
            _manager().incrementShorts(currency, amount);

            if (shortingRewards[currency] != address(0)) {
                IShortingRewards(shortingRewards[currency]).enrol(msg.sender, amount);
            }
        } else {
            _synth(synthsByKey[currency]).issue(msg.sender, loanAmountMinusFee);
            _manager().incrementLongs(currency, amount);
        }

        // 14. Emit event
        emit LoanCreated(msg.sender, id, amount, collateral, currency, issueFee);
    }

    function closeInternal(address borrower, uint id) internal rateIsValid returns (uint collateral) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 1. Get the loan.
        Loan storage loan = loans[id];

        require(loan.account == borrower, "Not loan creator");

        // 3. Accrue interest on the loan.
        accrueInterest(loan);

        // 4. Work out the total amount owing on the loan.
        uint total = loan.amount.add(loan.accruedInterest);

        // 5. Check they have enough balance to close the loan + interest.
        require(IERC20(address(_synth(synthsByKey[loan.currency]))).balanceOf(loan.account) >= total);

        // 6. Burn the synths.
        _synth(synthsByKey[loan.currency]).burn(borrower, total);

        // 7. Tell the manager.
        if (loan.short) {
            _manager().decrementShorts(loan.currency, loan.amount);

            if (shortingRewards[loan.currency] != address(0)) {
                IShortingRewards(shortingRewards[loan.currency]).withdraw(borrower, loan.amount);
            }
        } else {
            _manager().decrementLongs(loan.currency, loan.amount);
        }

        // 8. Assign the collateral to be returned.
        collateral = loan.collateral;

        // 9. Pay fees
        _payFees(loan.accruedInterest, loan.currency);

        // 10. Record loan as closed.
        loan.interestIndex = 0;

        // 11. Emit the event
        emit LoanClosed(borrower, id);
    }

    function closeByLiquidationInternal(
        address borrower,
        address liquidator,
        Loan storage loan
    ) internal returns (uint collateral) {
        // 1. Work out the total amount owing on the loan.
        uint total = loan.amount.add(loan.accruedInterest);

        // 2. Store this for the event.
        uint amount = loan.amount;

        // 3. Return collateral to the child class so it knows how much to transfer.
        collateral = loan.collateral;

        // 4. Burn the synths
        _synth(synthsByKey[loan.currency]).burn(liquidator, total);

        // 5. Tell the manager.
        if (loan.short) {
            _manager().decrementShorts(loan.currency, loan.amount);

            if (shortingRewards[loan.currency] != address(0)) {
                IShortingRewards(shortingRewards[loan.currency]).withdraw(borrower, loan.amount);
            }
        } else {
            _manager().decrementLongs(loan.currency, loan.amount);
        }

        // 6. Pay fees
        _payFees(loan.accruedInterest, loan.currency);

        // 7. Record loan as closed
        // loan.interestIndex = 0;

        // 8. Emit the event.
        emit LoanClosedByLiquidation(borrower, loan.id, liquidator, amount, collateral);
    }

    function depositInternal(
        address account,
        uint id,
        uint amount
    ) internal rateIsValid returns (uint, uint) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 2. Get the loan
        Loan storage loan = loans[id];

        // 3. Check loan is open still.
        require(loan.interestIndex != 0);

        // 4. Accrue interest
        accrueInterest(loan);

        // 5. Add the collateral
        loan.collateral = loan.collateral.add(amount);

        // 6. Emit the event
        emit CollateralDeposited(account, id, amount, loan.collateral);

        return (loan.amount, loan.collateral);
    }

    function withdrawInternal(uint id, uint amount) internal rateIsValid returns (uint, uint) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 1. Get the loan.
        Loan storage loan = loans[id];

        // 3. Check loan is open still and owner is calling.
        require(loan.interestIndex != 0 && loan.account == msg.sender);

        // 3. Accrue interest.
        accrueInterest(loan);

        // 4. Subtract the collateral.
        loan.collateral = loan.collateral.sub(amount);

        // 6. Check that the new amount does not put them under the minimum c ratio.
        require(collateralRatio(loan.id) > minCratio, "Cratio too low");

        // 9. Emit the event.
        emit CollateralWithdrawn(msg.sender, id, amount, loan.collateral);

        return (loan.amount, loan.collateral);
    }

    function liquidateInternal(
        address borrower,
        uint id,
        uint payment
    ) internal rateIsValid returns (uint collateralLiquidated) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 1. Check the payment amount.
        require(payment > 0);

        // 2. Get the loan.
        Loan storage loan = loans[id];

        // 4. Accrue interest.
        accrueInterest(loan);

        // 5. Check they have enough balance to make the payment.
        require(IERC20(address(_synth(synthsByKey[loan.currency]))).balanceOf(msg.sender) >= payment);

        // 6. Check they are eligible for liquidation.
        require(_collateralUtil().getCollateralRatio(loan, collateralKey) < minCratio);

        // 7. Determine how much needs to be liquidated to fix their c ratio.
        uint liqAmount = liquidationAmount(loan);

        // 8. Only allow them to liquidate enough to fix the c ratio.
        uint amountToLiquidate = liqAmount < payment ? liqAmount : payment;

        // 9. Work out the total amount owing on the loan.
        uint amountOwing = loan.amount.add(loan.accruedInterest);

        // 10. If its greater than the amount owing, we need to close the loan.
        if (amountToLiquidate >= amountOwing) {
            return closeByLiquidationInternal(borrower, msg.sender, loan);
        }

        // 11. Process the payment to workout interest/principal split.
        _processPayment(loan, amountToLiquidate);

        // 12. Work out how much collateral to redeem.
        collateralLiquidated = collateralRedeemed(loan.currency, amountToLiquidate);
        loan.collateral = loan.collateral.sub(collateralLiquidated);

        // 14. Burn the synths from the liquidator.
        _synth(synthsByKey[loan.currency]).burn(msg.sender, amountToLiquidate);

        // 16. Emit the event
        emit LoanPartiallyLiquidated(borrower, id, msg.sender, amountToLiquidate, collateralLiquidated);
    }

    function repayInternal(
        address borrower,
        address repayer,
        uint id,
        uint payment
    ) internal rateIsValid returns (uint, uint) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 1. Check the payment amount.
        require(payment > 0, "Payment must be greater than 0");

        // 2. Get loan
        Loan storage loan = loans[id];

        // 3. Check loan is open and last interaction time.
        require(loan.interestIndex != 0 && loan.lastInteraction.add(interactionDelay) <= block.timestamp);

        // 4. Accrue interest.
        accrueInterest(loan);

        // 6. Process the payment.
        _processPayment(loan, payment);

        // 7. Update the last interaction time.
        loan.lastInteraction = block.timestamp;

        // 8. Burn synths from the payer
        _synth(synthsByKey[loan.currency]).burn(repayer, payment);

        // 10. Emit the event.
        emit LoanRepaymentMade(borrower, repayer, id, payment, loan.amount);

        return (loan.amount, loan.collateral);
    }

    function drawInternal(uint id, uint amount) internal rateIsValid returns (uint, uint) {
        // 0. Check the system is active.
        _systemStatus().requireIssuanceActive();

        // 1. Get loan.
        Loan storage loan = loans[id];

        // 2. Check loan is open and last interaction time.
        require(loan.interestIndex != 0 && loan.lastInteraction.add(interactionDelay) <= block.timestamp);

        // 3. Accrue interest.
        accrueInterest(loan);

        // 4. Add the requested amount.
        loan.amount = loan.amount.add(amount);

        // 5. If it is below the minimum, don't allow this draw.
        require(collateralRatio(loan.id) > minCratio, "Cannot draw this much");

        // 6. This fee is denominated in the currency of the loan
        uint issueFee = amount.multiplyDecimalRound(issueFeeRate);

        // 7. Calculate the minting fee and subtract it from the draw amount
        uint amountMinusFee = amount.sub(issueFee);

        // 8. If its short, let the child handle it, otherwise issue the synths.
        if (loan.short) {
            _manager().incrementShorts(loan.currency, amount);
            _synthsUSD().issue(msg.sender, _exchangeRates().effectiveValue(loan.currency, amountMinusFee, sUSD));

            if (shortingRewards[loan.currency] != address(0)) {
                IShortingRewards(shortingRewards[loan.currency]).enrol(msg.sender, amount);
            }
        } else {
            _manager().incrementLongs(loan.currency, amount);
            _synth(synthsByKey[loan.currency]).issue(msg.sender, amountMinusFee);
        }

        // 9. Pay the minting fees to the fee pool
        _payFees(issueFee, loan.currency);

        // 10. Update the last interaction time.
        loan.lastInteraction = block.timestamp;

        // 12. Emit the event.
        emit LoanDrawnDown(msg.sender, id, amount);

        return (loan.amount, loan.collateral);
    }

    // Update the cumulative interest rate for the currency that was interacted with.
    function accrueInterest(Loan storage loan) internal {
        (uint differential, uint newIndex) = _manager().accrueInterest(loan.interestIndex, loan.currency, loan.short);

        // 5. If the loan was just opened, don't record any interest. Otherwise multiple by the amount outstanding.
        uint interest = loan.interestIndex == 0 ? 0 : loan.amount.multiplyDecimal(differential);

        // 8. Update loan
        loan.accruedInterest = loan.accruedInterest.add(interest);
        loan.interestIndex = newIndex;
    }

    // Works out the amount of interest and principal after a repayment is made.
    function _processPayment(Loan storage loan, uint payment) internal {
        if (payment > 0 && loan.accruedInterest > 0) {
            uint interestPaid = payment > loan.accruedInterest ? loan.accruedInterest : payment;
            loan.accruedInterest = loan.accruedInterest.sub(interestPaid);
            payment = payment.sub(interestPaid);

            _payFees(interestPaid, loan.currency);
        }

        // If there is more payment left after the interest, pay down the pr incipal.
        if (payment > 0) {
            loan.amount = loan.amount.sub(payment);

            // And get the manager to reduce the total long/short balance.
            if (loan.short) {
                _manager().decrementShorts(loan.currency, payment);

                if (shortingRewards[loan.currency] != address(0)) {
                    IShortingRewards(shortingRewards[loan.currency]).withdraw(loan.account, payment);
                }
            } else {
                _manager().decrementLongs(loan.currency, payment);
            }
        }
    }

    // Take an amount of fees in a certain synth and convert it to sUSD before paying the fee pool.
    function _payFees(uint amount, bytes32 synth) internal {
        if (amount > 0) {
            if (synth != sUSD) {
                amount = _exchangeRates().effectiveValue(synth, amount, sUSD);
            }
            _synthsUSD().issue(_feePool().FEE_ADDRESS(), amount);
            _feePool().recordFeePaid(amount);
        }
    }

    // ========== MODIFIERS ==========

    modifier rateIsValid() {
        _requireRateIsValid();
        _;
    }

    function _requireRateIsValid() private view {
        require(!_exchangeRates().rateIsInvalid(collateralKey));
    }

    // ========== EVENTS ==========
    // Setters
    event MinCratioRatioUpdated(uint minCratio);
    event MinCollateralUpdated(uint minCollateral);
    event IssueFeeRateUpdated(uint issueFeeRate);
    event MaxLoansPerAccountUpdated(uint maxLoansPerAccount);
    event InteractionDelayUpdated(uint interactionDelay);
    event ManagerUpdated(address manager);
    event CanOpenLoansUpdated(bool canOpenLoans);

    // Loans
    event LoanCreated(address indexed account, uint id, uint amount, uint collateral, bytes32 currency, uint issuanceFee);
    event LoanClosed(address indexed account, uint id);
    event CollateralDeposited(address indexed account, uint id, uint amountDeposited, uint collateralAfter);
    event CollateralWithdrawn(address indexed account, uint id, uint amountWithdrawn, uint collateralAfter);
    event LoanRepaymentMade(address indexed account, address indexed repayer, uint id, uint amountRepaid, uint amountAfter);
    event LoanDrawnDown(address indexed account, uint id, uint amount);
    event LoanPartiallyLiquidated(
        address indexed account,
        uint id,
        address liquidator,
        uint amountLiquidated,
        uint collateralLiquidated
    );
    event LoanClosedByLiquidation(
        address indexed account,
        uint id,
        address indexed liquidator,
        uint amountLiquidated,
        uint collateralLiquidated
    );
}
