//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router02.sol";
import "./ReentrantGuard.sol";

/** 
 * Contract: PUMP
 * 
 *  This Contract Awards xUSD to holders
 *  weighed by how many PUMP is held. 
 *  PUMP is the first token mainly backed by XUSD
 * 
 *  Transfer Fee:   10%
 *  Buy Fee:        10%
 *  Sell Fee:       10%
 * 
 *  Buys/Transfers Directly Deletes Tokens From Fees
 * 
 *  Sell Fees Go Toward:
 *  70% XUSD Distribution
 *  20% XUSD Buy and Burn
 *  15% Marketing
 *  5%  Development
 */
contract PUMP is IERC20, ReentrancyGuard {
    
    using SafeMath for uint256;
    using SafeMath for uint8;
    using Address for address;

    // token data
    string constant _name = "PUMP";
    string constant _symbol = "PUMP";
    uint8 constant _decimals = 18;
    
    // 100 Million Max Supply
    uint256 _totalSupply = 1 * 10**8 * (10 ** _decimals);
    uint256 public _maxTxAmount = _totalSupply.div(50); // 2% or 2 Million
    
    // balances
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;
    
    // backing asset
    address public XUSD = 0x254246331cacbC0b2ea12bEF6632E4C6075f60e2;

    // permissions
    struct Permissions {
        bool isFeeExempt;
        bool isTxLimitExempt;
        bool isDividendExempt;
        bool isLiquidityPool;
    }
    // user -> permissions
    mapping (address => Permissions) permissions;
    
    // per tx fees
    uint256 public localBurnFee = 10;      // 10% of tax taken is burned per transaction

    // on sale fees
    uint256 public burnFee = 20;           // 20% of tax burns backing asset
    uint256 public reflectionFee = 75;     // 75% of tax is reflected to holders
    uint256 public marketingFee = 15;      // 15% of tax is given to marketing
    // total fees
    uint256 totalFeeSells = 1000;
    uint256 totalFeeBuys = 1000;
    uint256 totalFeeTransfers = 1000;
    uint256 constant feeDenominator = 10000;
    
    // Marketing Funds Receiver
    address public marketingFeeReceiver = 0x3CbA1A2e38dCd4E3917FaF5512025a6C0A66956b;

    // Pancakeswap V2 Router
    IUniswapV2Router02 router;
    address private pair;

    // gas for distributor
    IDistributor public distributor;
    uint256 distributorGas = 800000;
    
    // in charge of swapping
    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply.div(5000);

    // prevents infinite swap loop
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }
    
    // Uniswap Router V2
    address private _dexRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    
    // ownership
    address public _owner;
    modifier onlyOwner(){require(msg.sender == _owner, 'OnlyOwner'); _;}
    
    // Token -> BNB
    address[] path;
    // BNB -> Token
    address[] buyPath;

    // initialize some stuff
    constructor ( address payable _distributor
    ) {
        // Pancakeswap V2 Router
        router = IUniswapV2Router02(_dexRouter);

        // Liquidity Pool Address for BNB -> HYPE
        pair = IUniswapV2Factory(router.factory()).createPair(XUSD, address(this));
        
        // our dividend Distributor
        distributor = IDistributor(_distributor);

        // exempt deployer and contract from fees
        permissions[msg.sender].isFeeExempt = true;
        permissions[address(this)].isFeeExempt = true;

        // exempt important addresses from TX limit
        permissions[msg.sender].isTxLimitExempt = true;
        permissions[marketingFeeReceiver].isTxLimitExempt = true;
        permissions[address(this)].isTxLimitExempt = true;

        // exempt important addresses from receiving Rewards
        permissions[pair].isDividendExempt = true;
        permissions[address(router)].isDividendExempt = true;
        permissions[address(this)].isDividendExempt = true;

        // declare LP as Liquidity Pool
        permissions[pair].isLiquidityPool = true;
        permissions[address(router)].isLiquidityPool = true;

        // approve router of total supply
        _balances[msg.sender] = _totalSupply;

        // token sell path
        path = new address[](2);
        path[0] = address(this);
        path[1] = XUSD;

        // token buy path
        buyPath = new address[](2);
        buyPath[0] = XUSD;
        buyPath[1] = address(this);

        // ownership
        _owner = msg.sender;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable {
        require(msg.value > 0, 'Zero Value');
        // buy xUSD
        (bool s,) = payable(XUSD).call{value: address(this).balance}("");
        require(s, 'Failure on XUSD Purchase');
        // approve router
        IERC20(XUSD).approve(_dexRouter, IERC20(XUSD).balanceOf(address(this)));
        // swap for PUMP
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(XUSD).balanceOf(address(this)),
            0,
            buyPath,
            msg.sender,
            block.timestamp + 30
        );
    }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }
    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    /** Approve Total Supply */
    function approveMax(address spender) external returns (bool) {
        return approve(spender, _totalSupply);
    }
    
    /** Transfer Function */
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }
    
    /** Transfer Function */
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        return _transferFrom(sender, recipient, amount);
    }
    
    ////////////////////////////////////
    /////    INTERNAL FUNCTIONS    /////
    ////////////////////////////////////
    
    /** Internal Transfer */
    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        // make standard checks
        require(recipient != address(0), "BEP20: Invalid Transfer");
        require(amount > 0, "Zero Amount");
        require(amount <= balanceOf(sender), 'Insufficient balance');
        // check if we have reached the transaction limit
        require(amount <= _maxTxAmount || permissions[sender].isTxLimitExempt, "TX Limit");

        // whether transfer succeeded
        bool success;
        // if we're in swap perform a basic transfer
        if(inSwap){
            (success) = handleTransferBody(sender, recipient, amount);
            return success;
        }
        
        // limit gas consumption by splitting up operations
        if(shouldSwapBack()) {
            swapBack();
            (success) = handleTransferBody(sender, recipient, amount);
        } else {
            (success) = handleTransferBody(sender, recipient, amount);
            try distributor.process(distributorGas) {} catch {}
        }
        return success;
    }
    
    /** Takes Associated Fees and sets holders' new Share for the HYPE Distributor */
    function handleTransferBody(address sender, address recipient, uint256 amount) internal returns (bool) {
        // subtract balance from sender
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        // amount receiver should receive
        uint256 amountReceived = (permissions[sender].isFeeExempt || permissions[recipient].isFeeExempt) ? amount : takeFee(sender, recipient, amount);
        // add amount to recipient
        _balances[recipient] = _balances[recipient].add(amountReceived);
        // set shares for distributors
        if(!permissions[sender].isDividendExempt){ 
            distributor.setShare(sender, _balances[sender]);
        }
        if(!permissions[recipient].isDividendExempt){ 
            distributor.setShare(recipient, _balances[recipient]);
        }

        // emit transfer
        emit Transfer(sender, recipient, amountReceived);
        // return the amount received by receiver
        return true;
    }
    
    /** Takes Fee and Stores in contract Or Deletes From Circulation */
    function takeFee(address sender, address receiver, uint256 amount) internal returns (uint256) {
        uint256 tFee = permissions[receiver].isLiquidityPool ? totalFeeSells : permissions[sender].isLiquidityPool ? totalFeeBuys : totalFeeTransfers;
        uint256 feeAmount = amount.mul(tFee).div(feeDenominator);

        // separate amount into burn and reflect
        uint256 burnAmount = (feeAmount * localBurnFee) / 100;
        uint256 takeAmount = feeAmount - burnAmount;

        // take fee for rewards
        if (takeAmount > 0) {
            _balances[address(this)] = _balances[address(this)].add(takeAmount);
            emit Transfer(sender, address(this), feeAmount);
        }

        // burn portion from supply
        if (burnAmount > 0) {
            _totalSupply = _totalSupply.sub(burnAmount);
            emit Transfer(sender, address(0), burnAmount);
        }
        
        return amount.sub(feeAmount);
    }
    
    /** True if we should swap from HYPE => BNB */
    function shouldSwapBack() internal view returns (bool) {
        return !permissions[msg.sender].isLiquidityPool
        && !inSwap
        && swapEnabled
        && _balances[address(this)] > swapThreshold;
    }
    
    /**
     *  Swaps HYPE for BNB if threshold is reached and the swap is enabled
     *  Burns percent of HYPE in Contract, delivers percent to marketing
     *  Swaps The Rest For BNB
     */
    function swapBack() private swapping {

        // set allowance to be max
        _allowances[address(this)][_dexRouter] = swapThreshold;

        // swap tokens for XUSD
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            swapThreshold,
            0,
            path,
            address(this),
            block.timestamp + 300
        );
        
        // fuel distributor
        fuelDistributorAndBurner();
        // Tell The Blockchain
        emit SwappedBack(swapAmount, burnAmount, marketingTokens);
    }
    
    /** Deposits BNB To Distributor And Burner*/
    function fuelDistributorAndBurner() private {

        // allocate percentages
        uint256 bal = IERC20(xUSD).balanceOf(address(this));
        uint256 forBurning = (bal * burnFee) / 100;
        uint256 forMarketing = (bal * marketingFee) / 100;

        if (forBurning > 0) {
            IERC20(xUSD).transfer(xUSD, forBurning);
        }
        if (forMarketing > 0) {
            IERC20(xUSD).transfer(marketingAddress, forMarketing);
        }
        if (IERC20(xUSD).balanceOf(address(this)) > 0) {
            IERC20(xUSD).transfer(address(distributor), IERC20(xUSD).balanceOf(address(this)));
        }
        
        emit FueledContracts(forBurning, forDistribution);
    }
    
    ////////////////////////////////////
    /////    EXTERNAL FUNCTIONS    /////
    ////////////////////////////////////
    
    
    /** Deletes the portion of holdings from sender */
    function burnTokens(uint256 nTokens) external nonReentrant returns(bool){
        // make sure you are burning enough tokens
        require(nTokens > 0 && _balances[msg.sender] >= nTokens, 'Insufficient Balance');
        // remove tokens from sender
        _balances[msg.sender] = _balances[msg.sender].sub(nTokens);
        // remove tokens from total supply
        _totalSupply = _totalSupply.sub(nTokens);
        // set share to be new balance
        if (!permissions[msg.sender].isDividendExempt) {
            distributor.setShare(msg.sender, _balances[msg.sender]);
        }
        // tell blockchain
        emit Transfer(msg.sender, address(0), nTokens);
        return true;
    }
    
    
    ////////////////////////////////////
    /////      READ FUNCTIONS      /////
    ////////////////////////////////////
    
    
    /** Is Holder Exempt From Fees */
    function getIsFeeExempt(address holder) public view returns (bool) {
        return permissions[holder].isFeeExempt;
    }
    
    /** Is Holder Exempt From Dividends */
    function getIsDividendExempt(address holder) public view returns (bool) {
        return permissions[holder].isDividendExempt;
    }
    
    /** Is Holder Exempt From Transaction Limit */
    function getIsTxLimitExempt(address holder) public view returns (bool) {
        return permissions[holder].isTxLimitExempt;
    }

    
    ////////////////////////////////////
    /////     OWNER FUNCTIONS      /////
    ////////////////////////////////////
    
    function setXUSD(address _xusd) external onlyOwner {
        require(_xusd != address(0));
        XUSD = _xusd;
        path[1] = _xusd;
        buyPath[0] = _xusd;
    }

    function setTaxPercentages(uint256 localBurnPercentPerTx, uint256 burnPercent, uint256 devFee, uint256 marketingPercent) external onlyOwner {
        require(localBurnPercentPerTx <= 100);
        require(burnPercent + devFee + marketingPercent < 100);
        localBurnFee = localBurnPercentPerTx;
        burnFee = burnPercent;
        developmentFee = devFee;
        marketingFee = marketingPercent;
    }

    /** Sets Various Fees */
    function setFees(uint256 _buyFee, uint256 _sellFee, uint256 _transferFee) external onlyOwner {
        totalFeeBuys = _buyFee;
        totalFeeTransfers = _transferFee;
        totalFeeSells = _sellFee;
        require(_buyFee <= feeDenominator/2);
        require(_sellFee <= feeDenominator/2);
        require(_transferFee <= feeDenominator/2);
        emit UpdateFees(_buyFee, _sellFee, _transferFee);
    }
    
    /** Set Exemption For Holder */
    function setExemptions(address holder, bool feeExempt, bool txLimitExempt, bool _isLiquidityPool) external onlyOwner {
        require(holder != address(0));
        permissions[holder].isFeeExempt = feeExempt;
        permissions[holder].isTxLimitExempt = txLimitExempt;
        permissions[holder].isLiquidityPool = _isLiquidityPool;
        emit SetExemptions(holder, feeExempt, txLimitExempt, _isLiquidityPool);
    }
    
    /** Set Holder To Be Exempt From Dividends */
    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        permissions[holder].isDividendExempt = exempt;
        if(exempt) {
            distributor.setShare(holder, 0);
        } else {
            distributor.setShare(holder, _balances[holder]);
        }
    }
    
    /** Set Settings related to Swaps */
    function setSwapBackSettings(bool _swapEnabled, uint256 _swapThreshold, bool _canChangeSwapThreshold, uint256 _percentOfCirculatingSupply, bool _burnEnabled) external onlyOwner {
        swapEnabled = _swapEnabled;
        swapThreshold = _swapThreshold;
        canChangeSwapThreshold = _canChangeSwapThreshold;
        swapThresholdPercentOfCirculatingSupply = _percentOfCirculatingSupply;
        burnEnabled = _burnEnabled;
        emit UpdateSwapBackSettings(_swapEnabled, _swapThreshold, _canChangeSwapThreshold, _burnEnabled);
    }

    /** Should We Transfer To Marketing */
    function setMarketingFundReceiver(address _marketingFeeReceiver) external onlyOwner {
        require(_marketingFeeReceiver != address(0), 'Invalid Address');
        marketingFeeReceiver = _marketingFeeReceiver;
        emit UpdateMarketingAddress(_marketingFeeReceiver);
    }
    
    /** Updates Gas Required For distribution */
    function setDistributorGas(uint256 newGas) external onlyOwner {
        require(newGas >= 10**5 && newGas <= 10**7, 'Out Of Range');
        distributorGas = newGas;
        emit UpdatedDistributorGas(newGas);
    }
    
    function setRouterAddress(address router) external onlyOwner {
        require(router != address(0));
        _dexRouter = router;
        _router = IUniswapV2Router02(router);
        emit UpdatedRouterAddress(router);
    }
    
    function setPairAddress(address newPair) external onlyOwner {
        require(newPair != address(0));
        _pair = newPair;
        permissions[newPair].isLiquidityPool = true;
        permissions[newPair].isDividendExempt = true;
        _distributor.setShare(newPair, 0);
        emit UpdatedPairAddress(newPair);
    }
    /** Set Address For Surge Distributor */
    function setDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(distributor) && newDistributor != address(0), 'Invalid Address');
        distributor = IDistributor(payable(newDistributor));
        emit SwappedDistributor(newDistributor);
    }

    /** Transfers Ownership of HYPE Contract */
    function transferOwnership(address newOwner) external onlyOwner {
        require(_owner != newOwner);
        _owner = newOwner;
        emit TransferOwnership(newOwner);
    }

    
    ////////////////////////////////////
    //////        EVENTS          //////
    ////////////////////////////////////
    
    
    event TransferOwnership(address newOwner);
    event UpdateMarketingAddress(address _marketingFeeReceiver);
    event UpdatedDistributorGas(uint256 newGas);
    event SwappedDistributor(address newDistributor);
    event UpdatedManualSwapperDisabled(bool disabled);
    event FueledContracts(uint256 bnbForBurning, uint256 bnbForReflections);
    event SetExemptions(address holder, bool feeExempt, bool txLimitExempt, bool isLiquidityPool);
    event SwappedBack(uint256 tokensSwapped, uint256 amountBurned, uint256 marketingTokens);
    event UpdateTransferToMarketing(address fundReceiver);
    event UpdateSwapBackSettings(bool swapEnabled, uint256 swapThreshold, bool canChangeSwapThreshold, bool burnEnabled);
    event UpdatePancakeswapRouter(address newRouter);
    event TokensLockedForWallet(address wallet, uint256 duration, uint256 allowanceToSpend);
    event UpdateFees(uint256 buyFee, uint256 sellFee, uint256 transferFee, uint256 burnFee, uint256 reflectionFee);
    
}
