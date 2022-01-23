//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Router02.sol";
import "./IERC20.sol";
import "./ReentrantGuard.sol";

/** Distributes XUSD To Holders Varied on Weight */
contract Distributor is IDistributor, ReentrancyGuard {
    
    using SafeMath for uint256;
    using Address for address;
    
    // Token Contract
    address public _token;
    
    // Share 
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
    }
    
    // shareholder fields
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    mapping (address => Share) public shares;
    
    // shares math and fields
    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public dividendsPerShare;
    uint256 constant dividendsPerShareAccuracyFactor = 10 ** 18;
    
    // blocks until next distribution
    uint256 public minPeriod = 3600;
    // auto claim every 10 minutes if able
    uint256 public constant minAutoPeriod = 200;
    // 0.50 XUSD minimum distribution
    uint256 public minDistribution = 5 * 10**17;

    // current index in shareholder array 
    uint256 currentIndex;
    
    // owner of token contract - used to pair with Vault Token
    address _master;

    // reward token
    address public XUSD = 0x254246331cacbC0b2ea12bEF6632E4C6075f60e2;
    
    modifier onlyToken() {
        require(msg.sender == _token); _;
    }
    
    modifier onlyMaster() {
        require(msg.sender == _master, 'Invalid Entry'); _;
    }

    constructor () {
        _master = msg.sender;
    }
    
    ///////////////////////////////////////////////
    //////////      Only Token Owner    ///////////
    ///////////////////////////////////////////////

    function pairToken(address token) external onlyMaster {
        require(token != address(0) && _token == address(0), 'Already Paired');
        _token = token;
    }

    function transferOwnership(address newOwner) external onlyMaster {
        _master = newOwner;
        emit TransferedOwnership(newOwner);
    }

    function setXUSD(address XUSD_) external onlyMaster {
        XUSD = XUSD_;
    }
    
    /** Withdraw Assets Mistakingly Sent To Distributor, And For Upgrading If Necessary */
    function withdraw(bool bnb, address token, uint256 amount) external onlyMaster {
        if (bnb) {
            (bool s,) = payable(_master).call{value: amount}("");
            require(s);
        } else {
            IERC20(token).transfer(_master, amount);
        }
    }
    
    /** Sets Distibution Criteria */
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyMaster {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        emit UpdateDistributorCriteria(_minPeriod, _minDistribution);
    }
    
    ///////////////////////////////////////////////
    //////////    Only Token Contract   ///////////
    ///////////////////////////////////////////////
    
    /** Sets Share For User */
    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }
    
    ///////////////////////////////////////////////
    //////////      Public Functions    ///////////
    ///////////////////////////////////////////////
    
    function claimDividendForUser(address shareholder) external nonReentrant {
        _claimDividend(shareholder);
    }

    function reinvestRewards() external nonReentrant {
        _reinvestRewards();
    }
    
    function claimDividend() external nonReentrant {
        _claimDividend(msg.sender);
    }
    
    function process(uint256 gas) external override {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        
        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }
            
            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }
            
            gasUsed += (gasLeft - gasleft());
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
        emit AddedShareholder(shareholder);
    }

    function removeShareholder(address shareholder) internal { 
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder]; 
        shareholders.pop();
        delete shareholderIndexes[shareholder];
        emit RemovedShareholder(shareholder);
    }
    

    function distributeDividend(address shareholder) internal nonReentrant {
        if(shares[shareholder].amount == 0){ return; }
        
        uint256 amount = getUnpaidMainEarnings(shareholder);
        if(amount > 0){
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
            shareholderClaims[shareholder] = block.number;
            bool s = IERC20(XUSD).transfer(shareholder, amount);
            require(s, 'Failure on XUSD Transfer');
        }
    }
    
    function _claimDividend(address shareholder) private {
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidMainEarnings(shareholder);
        require(amount > 0, 'Zero To Claim');

        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        shareholderClaims[shareholder] = block.number;
        
        bool s = IERC20(XUSD).transfer(shareholder, amount);
        require(s, 'Failure on XUSD Transfer');
    }
    
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.number
        && getUnpaidMainEarnings(shareholder) >= minDistribution
        && !Address.isContract(shareholder);
    }
    
    function getShareholders() external view override returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) external view override returns(uint256) {
        return shares[holder].amount;
    }

    function getUnpaidMainEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }
    
    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function getNumShareholdersForDistributor(address distributor) external view returns(uint256) {
        return IDistributor(distributor).getShareholders().length;
    }
    
    function getNumShareholders() external view returns(uint256) {
        return shareholders.length;
    }

    // EVENTS 
    event TokenPaired(address pairedToken);
    event UpgradeDistributor(address newDistributor);
    event AddedShareholder(address shareholder);
    event RemovedShareholder(address shareholder);
    event TransferedOwnership(address newOwner);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minDistribution);

    receive() external payable {
        require(msg.value > 0, 'Zero Value');
        uint256 before = IERC20(XUSD).balanceOf(address(this));
        (bool s,) = payable(XUSD).call{value: address(this).balance}("");
        uint256 received = IERC20(XUSD).balanceOf(address(this)) - before;
        require(received > 0 && s, 'Failure');

        totalDividends = totalDividends.add(received);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(received).div(totalShares));
    }

}
