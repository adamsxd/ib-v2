// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./IronBankStorage.sol";
import "../../interfaces/DeferLiquidityCheckInterface.sol";
import "../../interfaces/IBTokenInterface.sol";
import "../../interfaces/InterestRateModelInterface.sol";
import "../../interfaces/IronBankInterface.sol";
import "../../interfaces/PriceOracleInterface.sol";
import "../../interfaces/UserHelperRegistryInterface.sol";
import "../../libraries/Arrays.sol";

contract IronBank is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuard,
    IronBankStorage,
    IronBankInterface
{
    using SafeERC20 for IERC20;
    using Arrays for address[];

    /**
     * @notice Initialize the contract
     */
    function initialize(address _admin) public initializer {
        __Ownable_init();

        transferOwnership(_admin);
    }

    modifier onlyMarketConfigurator() {
        require(msg.sender == marketConfigurator, "!configurator");
        _;
    }

    modifier onlyCreditLimitManager() {
        require(msg.sender == creditLimitManager, "!manager");
        _;
    }

    modifier isAuthorized(address user) {
        _checkAuthorized(user);
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getAllMarkets() public view returns (address[] memory) {
        return allMarkets;
    }

    function getExchangeRate(address market) public view returns (uint256) {
        Market storage m = markets[market];
        return _getExchangeRate(m);
    }

    function getMaxBorrowAmount(address market) public view returns (uint256) {
        Market storage m = markets[market];
        uint256 maxBorrowAmount = m.totalCash;
        if (m.config.borrowCap > m.totalBorrow) {
            uint256 gap = m.config.borrowCap - m.totalBorrow;
            if (gap < m.totalCash) {
                maxBorrowAmount = gap;
            }
        }
        return maxBorrowAmount;
    }

    function getBorrowBalance(address user, address market) public view returns (uint256) {
        Market storage m = markets[market];
        UserBorrow memory b = m.userBorrows[user];

        return _getBorrowBalance(b.borrowBalance, b.borrowIndex, m.borrowIndex);
    }

    function getSupplyBalance(address user, address market) public view returns (uint256, uint256) {
        Market storage m = markets[market];
        return (m.userSupplies[user], m.userCollaterals[user]);
    }

    function getAccountLiquidity(address user) public view returns (uint256, uint256) {
        return _getAccountLiquidity(user);
    }

    function getUserEnteredMarkets(address user) public view returns (address[] memory) {
        return allEnteredMarkets[user];
    }

    function isEnteredMarket(address user, address market) public view returns (bool) {
        return enteredMarkets[user][market];
    }

    function getCreditLimit(address user, address market) public view returns (uint256) {
        return creditLimits[user][market];
    }

    function getUserCreditMarkets(address user) public view returns (address[] memory) {
        return allCreditMarkets[user];
    }

    function isCreditAccount(address user) public view returns (bool) {
        return allCreditMarkets[user].length > 0;
    }

    function getMarketConfiguration(address market) public view returns (MarketConfig memory) {
        return markets[market].config;
    }

    function calculateLiquidationOpportunity(address marketBorrow, address marketCollateral, uint256 repayAmount)
        public
        view
        returns (uint256)
    {
        Market storage mCollateral = markets[marketCollateral];

        return _getLiquidationAmount(marketBorrow, marketCollateral, mCollateral, repayAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function enterMarket(address user, address market) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");

        _enterMarket(market, user);
    }

    function exitMarket(address user, address market) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        UserBorrow storage b = m.userBorrows[user];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(b.borrowBalance == 0, "borrow balance not zero");

        if (!isEnteredMarket(user, market)) {
            // Skip if the market is not entered.
            return;
        }

        delete enteredMarkets[user][market];
        allEnteredMarkets[user].deleteElement(market);

        if (m.userCollaterals[user] > 0) {
            _decreaseCollateral(market, m, user, m.userCollaterals[user]);
        }

        if (m.userSupplies[user] != 0 && m.config.collateralFactor != 0) {
            _checkAccountLiquidity(user);
        }

        emit MarketExited(market, user);
    }

    function registerCollateral(address user, address market) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(isEnteredMarket(user, market), "market not entered");

        uint256 gap = m.userSupplies[user] - m.userCollaterals[user];
        if (gap > 0) {
            _increaseCollateral(market, m, user, gap);
        }
    }

    function accrueInterest(address market) external nonReentrant {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");

        _accrueInterest(market, m);
    }

    function checkAccountLiquidity(address user) public {
        _checkAccountLiquidity(user);
    }

    function supply(address user, address market, uint256 amount) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(!m.config.supplyPaused, "supply paused");
        require(!isCreditAccount(user), "credit account cannot supply");

        if (m.config.supplyCap != 0) {
            require(m.totalSupply + amount <= m.config.supplyCap, "supply cap reached");
        }

        _accrueInterest(market, m);

        // Update internal cash in pool.
        m.totalCash += amount;

        uint256 ibTokenAmount = (amount * 1e18) / _getExchangeRate(m);

        // Update user supply status.
        m.userSupplies[user] += ibTokenAmount;
        m.totalSupply += ibTokenAmount;

        if (isEnteredMarket(user, market)) {
            // Increase user and total collateral.
            _increaseCollateral(market, m, user, ibTokenAmount);
        }

        IBTokenInterface(m.config.ibTokenAddress).mint(user, ibTokenAmount);
        IERC20(market).safeTransferFrom(user, address(this), amount);

        emit Supply(market, user, amount, ibTokenAmount);
    }

    function borrow(address user, address market, uint256 amount) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(!m.config.borrowPaused, "borrow paused");
        require(m.totalCash >= amount, "insufficient cash");

        if (m.config.borrowCap != 0) {
            require(m.totalBorrow + amount <= m.config.borrowCap, "borrow cap reached");
        }

        _accrueInterest(market, m);
        _enterMarket(market, user);

        // Update internal cash and total borrow in pool.
        m.totalCash -= amount;
        m.totalBorrow += amount;

        // Update user borrow status.
        uint256 borrowBalance = _updateUserBorrowBalance(m, user, amount, 0);

        IERC20(market).safeTransfer(user, amount);

        if (isCreditAccount(user)) {
            require(creditLimits[user][market] >= borrowBalance, "insufficient credit limit");
        } else {
            _checkAccountLiquidity(user);
        }

        emit Borrow(market, user, amount, borrowBalance, m.totalBorrow);
    }

    function redeem(address user, address market, uint256 amount) external nonReentrant isAuthorized(user) {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(!isCreditAccount(user), "credit account cannot redeem");

        _accrueInterest(market, m);

        uint256 ibTokenAmount;
        if (amount == type(uint256).max) {
            ibTokenAmount = m.userSupplies[user];
            amount = (ibTokenAmount * _getExchangeRate(m)) / 1e18;
        } else {
            ibTokenAmount = (amount * 1e18) / _getExchangeRate(m);
        }

        require(m.totalCash >= amount, "insufficient cash");

        // Update internal cash in pool.
        m.totalCash -= amount;

        // Update user supply status.
        m.userSupplies[user] -= ibTokenAmount;
        m.totalSupply -= ibTokenAmount;

        if (isEnteredMarket(user, market)) {
            // Decrease user and total collateral.
            uint256 collateralAmount = _getCollateralToken(m, user, ibTokenAmount);
            _decreaseCollateral(market, m, user, collateralAmount);
        }

        IBTokenInterface(m.config.ibTokenAddress).burn(user, ibTokenAmount);
        IERC20(market).safeTransfer(user, amount);

        _checkAccountLiquidity(user);

        emit Redeem(market, user, amount, ibTokenAmount);
    }

    function repay(address user, address market, uint256 amount) external nonReentrant {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        if (msg.sender != user) {
            require(!isCreditAccount(user), "cannot repay for credit account");
        }

        _accrueInterest(market, m);

        if (amount == type(uint256).max) {
            UserBorrow memory b = m.userBorrows[user];
            amount = _getBorrowBalance(b.borrowBalance, b.borrowIndex, m.borrowIndex);
        }

        // Update internal cash and total borrow in pool.
        m.totalCash += amount;
        m.totalBorrow -= amount;

        // Update user borrow status.
        uint256 borrowBalance = _updateUserBorrowBalance(m, user, 0, amount);

        IERC20(market).safeTransferFrom(msg.sender, address(this), amount);

        emit Repay(market, user, amount, borrowBalance, m.totalBorrow);
    }

    function liquidate(
        address liquidator,
        address violator,
        address marketBorrow,
        address marketCollateral,
        uint256 repayAmount
    ) external nonReentrant {
        Market storage mBorrow = markets[marketBorrow];
        Market storage mCollateral = markets[marketCollateral];
        require(mBorrow.config.isListed, "borrow market not listed");
        require(mCollateral.config.isListed, "collateral market not listed");
        require(!mBorrow.config.isFrozen, "borrow market frozen");
        require(!mCollateral.config.isFrozen, "collateral market frozen");
        require(!isCreditAccount(violator), "cannot liquidate credit account");
        require(liquidator != violator, "cannot self liquidate");
        require(isEnteredMarket(violator, marketBorrow), "borrow market not entered");
        require(isEnteredMarket(violator, marketCollateral), "collateral market not entered");

        _accrueInterest(marketBorrow, mBorrow);
        _accrueInterest(marketCollateral, mCollateral);

        // Check if the liquidator is actually liquidatable.
        (uint256 collateralValue, uint256 debtValue) = _getAccountLiquidity(violator);
        require(collateralValue < debtValue, "not liquidatable");

        // Transfer debt.
        _transferDebt(marketBorrow, mBorrow, violator, liquidator, repayAmount);

        // Transfer collateral.
        uint256 ibTokenAmount = _getLiquidationAmount(marketBorrow, marketCollateral, mCollateral, repayAmount);
        _transferIBToken(mCollateral, violator, liquidator, ibTokenAmount);
        IBTokenInterface(mCollateral.config.ibTokenAddress).seize(violator, liquidator, ibTokenAmount);

        _checkAccountLiquidity(liquidator);

        emit Liquidate(liquidator, violator, marketBorrow, marketCollateral, repayAmount);
    }

    function deferLiquidityCheck(address user, bytes memory data) external {
        require(!isCreditAccount(user), "credit account cannot defer liquidity check");
        require(liquidityCheckStatus[user] == LIQUIDITY_CHECK_NORMAL, "reentry defer liquidity check");
        liquidityCheckStatus[user] = LIQUIDITY_CHECK_DEFERRED;

        DeferLiquidityCheckInterface(msg.sender).onDeferredLiquidityCheck(data);

        uint8 status = liquidityCheckStatus[user];
        liquidityCheckStatus[user] = LIQUIDITY_CHECK_NORMAL;

        if (status == LIQUIDITY_CHECK_DIRTY) {
            _checkAccountLiquidity(user);
        }
    }

    /* ========== TOKEN HOOKS ========== */

    function transferDebt(address market, address from, address to, uint256 amount) external nonReentrant {
        Market storage m = markets[market];
        require(msg.sender == m.config.debtTokenAddress, "!authorized");
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(from != to, "cannot self transfer");
        require(!isCreditAccount(from), "cannot transfer from credit account");
        require(!isCreditAccount(to), "cannot transfer to credit account");

        _accrueInterest(market, m);
        if (amount == type(uint256).max) {
            UserBorrow memory b = m.userBorrows[from];
            amount = _getBorrowBalance(b.borrowBalance, b.borrowIndex, m.borrowIndex);
        }
        _transferDebt(market, m, from, to, amount);

        _checkAccountLiquidity(to);
    }

    function transferIBToken(address market, address from, address to, uint256 amount) external nonReentrant {
        Market storage m = markets[market];
        require(msg.sender == m.config.ibTokenAddress, "!authorized");
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");
        require(from != to, "cannot self transfer");
        require(!isCreditAccount(to), "cannot transfer to credit account");

        _accrueInterest(market, m);
        _transferIBToken(m, from, to, amount);

        _checkAccountLiquidity(from);
    }

    function addToReserves(address market) external nonReentrant {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(!m.config.isFrozen, "frozen");

        _accrueInterest(market, m);

        uint256 amount = IERC20(market).balanceOf(address(this)) - m.totalCash;

        if (amount > 0) {
            uint256 ibTokenAmount = (amount * 1e18) / _getExchangeRate(m);

            // Update total reserves and internal cash.
            m.totalReserves += ibTokenAmount;
            m.totalCash += amount;

            emit ReservesIncreased(market, ibTokenAmount, amount);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function listMarket(
        address market,
        address ibTokenAddress,
        address debtTokenAddress,
        address interestRateModelAddress,
        uint16 reserveFactor,
        uint256 initialExchangeRate
    ) external onlyOwner {
        Market storage m = markets[market];
        require(!m.config.isListed, "already listed");
        require(IBTokenInterface(ibTokenAddress).getUnderlying() == market, "mismatch underlying");
        require(IBTokenInterface(debtTokenAddress).getUnderlying() == market, "mismatch underlying");
        require(reserveFactor <= MAX_RESERVE_FACTOR, "invalid reserve factor");

        m.config.isListed = true;
        m.config.ibTokenAddress = ibTokenAddress;
        m.config.debtTokenAddress = debtTokenAddress;
        m.config.interestRateModelAddress = interestRateModelAddress;
        m.config.reserveFactor = reserveFactor;
        m.config.initialExchangeRate = initialExchangeRate;

        allMarkets.push(market);

        emit MarketListed(market);
    }

    function delistMarket(address market) external onlyOwner {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");
        require(m.config.supplyPaused && m.config.borrowPaused, "not paused");
        require(m.config.collateralFactor == 0, "collateral not zero");

        delete markets[market];
        allMarkets.deleteElement(market);

        emit MarketDelisted(market);
    }

    function setMarketConfiguration(address market, MarketConfig calldata config) external onlyMarketConfigurator {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");

        m.config = config;

        emit MarketConfigurationSet(market, config);
    }

    function setCreditLimit(address user, address market, uint256 credit) external onlyCreditLimitManager {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");

        if (credit == 0 && creditLimits[user][market] != 0) {
            allCreditMarkets[user].deleteElement(market);
        } else if (credit != 0 && creditLimits[user][market] == 0) {
            allCreditMarkets[user].push(market);
        }

        creditLimits[user][market] = credit;
        emit CreditLimitChanged(user, market, credit);
    }

    function setPriceOracle(address oracle) external onlyOwner {
        priceOracle = oracle;

        emit PriceOracleSet(oracle);
    }

    function setMarketConfigurator(address configurator) external onlyOwner {
        marketConfigurator = configurator;

        emit MarketConfiguratorSet(configurator);
    }

    function setCreditLimitManager(address manager) external onlyOwner {
        creditLimitManager = manager;

        emit CreditLimitManagerSet(manager);
    }

    function setUserHelperRegistry(address registry) external onlyOwner {
        userHelperRegistry = registry;

        emit UserHelperRegistrySet(registry);
    }

    function seize(address token, address recipient) external onlyOwner {
        require(!markets[token].config.isListed, "market is listed");

        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, balance);

        emit TokenSeized(token, recipient, balance);
    }

    function reduceReserves(address market, uint256 ibTokenAmount, address recipient) external onlyOwner {
        Market storage m = markets[market];
        require(m.config.isListed, "not listed");

        _accrueInterest(market, m);

        uint256 amount = (ibTokenAmount * _getExchangeRate(m)) / 1e18;

        require(m.totalCash >= amount, "insufficient cash");

        // Update total reserves.
        m.totalReserves -= ibTokenAmount;

        IERC20(market).safeTransfer(recipient, amount);

        emit ReservesDecreased(market, ibTokenAmount, amount, recipient);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev _authorizeUpgrade is used by UUPSUpgradeable to determine if it's allowed to upgrade a proxy implementation.
     * @param newImplementation The new implementation
     *
     * Ref: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/proxy/utils/UUPSUpgradeable.sol
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _getNow() internal view virtual returns (uint40) {
        require(block.timestamp < 2 ** 40, "timestamp too large");
        return uint40(block.timestamp);
    }

    function _checkAuthorized(address user) internal view {
        require(
            msg.sender == user
                || (
                    !isCreditAccount(user) && userHelperRegistry != address(0)
                        && UserHelperRegistryInterface(userHelperRegistry).isHelperAuthorized(user, msg.sender)
                ),
            "!authorized"
        );
    }

    function _getExchangeRate(Market storage m) internal view returns (uint256) {
        if (m.totalSupply == 0) {
            return m.config.initialExchangeRate;
        }
        return ((m.totalCash + m.totalBorrow) * 1e18) / m.totalSupply;
    }

    function _getLiquidationAmount(
        address marketBorrow,
        address marketCollateral,
        Market storage mCollateral,
        uint256 repayAmount
    ) internal view returns (uint256) {
        uint256 borrowMarketPrice = PriceOracleInterface(priceOracle).getPrice(marketBorrow);
        uint256 collateralMarketPrice = PriceOracleInterface(priceOracle).getPrice(marketCollateral);
        require(borrowMarketPrice > 0 && collateralMarketPrice > 0, "invalid price");

        // collateral amount = repayAmount * liquidationBonus * borrowMarketPrice / collateralMarketPrice
        // IBToken amount = collateral amount / exchangeRate
        //   = repayAmount * (liquidationBonus * borrowMarketPrice) / (collateralMarketPrice * exchangeRate)
        uint256 numerator = (mCollateral.config.liquidationBonus * borrowMarketPrice) / FACTOR_SCALE;
        uint256 denominator = (_getExchangeRate(mCollateral) * collateralMarketPrice) / 1e18;
        return (repayAmount * numerator) / denominator;
    }

    function _getBorrowBalance(uint256 borrowBalance, uint256 userBorrowIndex, uint256 marketBorrowindex)
        internal
        pure
        returns (uint256)
    {
        if (borrowBalance == 0) {
            return 0;
        }

        // borrowBalanceWithInterests = borrowBalance * marketBorrowindex / userBorrowIndex
        return (borrowBalance * marketBorrowindex) / userBorrowIndex;
    }

    function _updateUserBorrowBalance(Market storage m, address user, uint256 increaseAmount, uint256 decreaseAmount)
        internal
        returns (uint256)
    {
        require(increaseAmount == 0 || decreaseAmount == 0, "invalid argument");
        UserBorrow storage b = m.userBorrows[user];
        uint256 borrowBalance = _getBorrowBalance(b.borrowBalance, b.borrowIndex, m.borrowIndex);
        b.borrowBalance = borrowBalance + increaseAmount - decreaseAmount;
        b.borrowIndex = m.borrowIndex;
        return b.borrowBalance;
    }

    function _increaseCollateral(address market, Market storage m, address user, uint256 amount) internal {
        if (
            m.config.collateralCap == 0
                || (m.config.collateralCap != 0 && m.totalCollateral + amount <= m.config.collateralCap)
        ) {
            m.totalCollateral += amount;
            m.userCollaterals[user] += amount;

            emit UserCollateralChanged(market, user, amount);
        } else if (m.totalCollateral < m.config.collateralCap) {
            uint256 gap = m.config.collateralCap - m.totalCollateral;
            m.totalCollateral += gap;
            m.userCollaterals[user] += gap;

            emit UserCollateralChanged(market, user, gap);
        }
    }

    function _decreaseCollateral(address market, Market storage m, address user, uint256 amount) internal {
        if (amount > 0) {
            m.totalCollateral -= amount;
            m.userCollaterals[user] -= amount;

            emit UserCollateralChanged(market, user, amount);
        }
    }

    function _getCollateralToken(Market storage m, address user, uint256 amount) internal view returns (uint256) {
        if (amount <= m.userCollaterals[user]) {
            return amount;
        }
        return m.userCollaterals[user];
    }

    function _transferDebt(address market, Market storage m, address from, address to, uint256 amount) internal {
        _enterMarket(market, to);

        _updateUserBorrowBalance(m, from, 0, amount);
        _updateUserBorrowBalance(m, to, amount, 0);
    }

    function _transferIBToken(Market storage m, address from, address to, uint256 amount) internal {
        m.userSupplies[from] -= amount;
        m.userSupplies[to] += amount;

        if (m.userCollaterals[from] > 0) {
            uint256 collateralAmount = _getCollateralToken(m, from, amount);
            m.userCollaterals[from] -= collateralAmount;
            m.userCollaterals[to] += collateralAmount;
        }
    }

    function _accrueInterest(address market, Market storage m) internal {
        uint40 timestamp = _getNow();
        uint256 timeElapsed = uint256(timestamp - m.lastUpdateTimestamp);
        if (timeElapsed > 0) {
            uint256 borrowRate =
                InterestRateModelInterface(m.config.interestRateModelAddress).getBorrowRate(m.totalCash, m.totalBorrow);
            uint256 interestFactor = (borrowRate * timeElapsed);
            uint256 interestIncreased = (interestFactor * m.totalBorrow) / 1e18;
            uint256 newTotalBorrow = m.totalBorrow + interestIncreased;
            uint256 feeIncreased = (interestIncreased * m.config.reserveFactor) / FACTOR_SCALE;
            uint256 poolSize = m.totalCash + newTotalBorrow;
            uint256 newTotalSupply = (m.totalSupply * poolSize) / (poolSize - feeIncreased);
            uint256 reservesIncreased = newTotalSupply - m.totalSupply;

            m.totalBorrow = newTotalBorrow;
            m.borrowIndex += (interestFactor * m.borrowIndex) / 1e18;
            m.lastUpdateTimestamp = timestamp;
            m.totalSupply = newTotalSupply;
            m.totalReserves += reservesIncreased;

            emit InterestAccrued(market, interestIncreased, m.borrowIndex, m.totalBorrow);
        }
    }

    function _enterMarket(address market, address user) internal {
        if (enteredMarkets[user][market]) {
            // Skip if user has entered the market.
            return;
        }

        enteredMarkets[user][market] = true;
        allEnteredMarkets[user].push(market);

        emit MarketEntered(market, user);
    }

    function _checkAccountLiquidity(address user) internal {
        uint8 status = liquidityCheckStatus[user];

        if (status == LIQUIDITY_CHECK_NORMAL) {
            (uint256 collateralValue, uint256 debtValue) = _getAccountLiquidity(user);
            require(collateralValue >= debtValue, "insufficient collateral");
        } else if (status == LIQUIDITY_CHECK_DEFERRED) {
            liquidityCheckStatus[user] = LIQUIDITY_CHECK_DIRTY;
        }
    }

    function _getAccountLiquidity(address user) internal view returns (uint256, uint256) {
        uint256 collateralValue;
        uint256 debtValue;

        address[] memory userEnteredMarkets = allEnteredMarkets[user];
        for (uint256 i = 0; i < userEnteredMarkets.length;) {
            Market storage m = markets[userEnteredMarkets[i]];
            if (!m.config.isListed) {
                continue;
            }
            UserBorrow storage b = m.userBorrows[user];

            uint256 collateralBalance = m.userCollaterals[user];
            uint256 borrowBalance = _getBorrowBalance(b.borrowBalance, b.borrowIndex, m.borrowIndex);
            if (collateralBalance == 0 && borrowBalance == 0) {
                // Skip if user has no supply or borrow balance on this asset.
                continue;
            }

            uint256 assetPrice = PriceOracleInterface(priceOracle).getPrice(userEnteredMarkets[i]);
            uint256 collateralFactor = uint256(m.config.collateralFactor);
            if (collateralBalance > 0 && collateralFactor > 0) {
                uint256 exchangeRate = _getExchangeRate(m);
                collateralValue +=
                    (collateralBalance * exchangeRate * assetPrice * collateralFactor) / 1e36 / FACTOR_SCALE;
            }
            if (borrowBalance > 0) {
                debtValue += (borrowBalance * assetPrice) / 1e18;
            }

            unchecked {
                i++;
            }
        }
        return (collateralValue, debtValue);
    }
}