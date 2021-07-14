//SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.6;

import "./interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PresaleWithSwapping is Ownable {
	using SafeERC20 for IERC20;
	IUniswapV2Router02 public router;
	IERC20 public tokenForSale; //token for sale
	IERC20 public tokenToPay; //token to be used for payment
    address public safeAddress; //safe to receive proceeds
	uint256 public exchangeRateWholeToken; //amount of tokenToPay that buys an entire tokenForSale
	uint256 public immutable exchangeRateDivisor; //divisor for exchange rate. set in constructor equal to 10**decimcals of tokenForSale
	uint256 public saleStart; //UTC timestamp of sale start
	uint256 public saleEnd; //UTC timestamp of sale end
    uint256 public amountLeftToSell; //amount of tokens remaining to sell
    uint256 public totalTokensSold; //tracks sum of all tokens sold
    uint256 public totalProceeds; //tracks sum of proceeds from all token sales
    uint256 public whitelistBonusBIPS; //bonus to whitelisted addresses in BIPS
	bool public adjustableExchangeRate; //determines if exchange rate is adjustable or fixed
    bool public adjustableTiming; //determines if start/end times can be adjusted, or if they are fixed
	mapping(address => uint256) public tokensPurchased; //amount of tokens purchased by each address
    mapping(address => bool) public whitelist; //whether each address is whitelisted or not
    mapping(address => bool) public hasPurchased; //whether each address has purchased tokens or not
    address[] public purchasers; //array of all purchasers for ease of querying

	event TokensPurchased(address indexed buyer, uint256 amountPurchased);
	event ExchangeRateSet(uint256 newExchangeRate);

	modifier checkPurchase(address buyer, uint256 amountToBuy) {
		require(saleOngoing(),"sale not ongoing");
        uint256 amountToSend = amountToBuy;
        if (whitelist[buyer]) {
            amountToSend = amountToBuy * (10000 + whitelistBonusBIPS) / 10000;
        }
		require(amountToSend <= amountLeftToSell, "amountToSend exceeds amountLeftToSell");
        _;
	}

	constructor(
            IUniswapV2Router02 router_,
			IERC20 tokenForSale_,
			IERC20 tokenToPay_,
            address safeAddress_,
			uint256 saleStart_,
			uint256 saleEnd_,
            uint256 amountTokensToSell_,
			uint256 exchangeRateWholeToken_,
            uint256 whitelistBonusBIPS_,
			bool adjustableExchangeRate_,
            bool adjustableTiming_
            ) {
        require(whitelistBonusBIPS_ <= 5000, "bonus too high");
		require(saleStart_ > block.timestamp, "sale must start in future");
		require(saleStart_ < saleEnd_, "sale must start before it ends");
        router = router_;
		tokenForSale = tokenForSale_;
		tokenToPay = tokenToPay_;
        safeAddress = safeAddress_;
		saleStart = saleStart_;
		saleEnd = saleEnd_;
        amountLeftToSell = amountTokensToSell_;
		exchangeRateWholeToken = exchangeRateWholeToken_;
		emit ExchangeRateSet(exchangeRateWholeToken_);
        whitelistBonusBIPS = whitelistBonusBIPS_;
		adjustableExchangeRate = adjustableExchangeRate_;
        adjustableTiming = adjustableTiming_;
        exchangeRateDivisor = 10**(IERC20Metadata(address(tokenForSale)).decimals());
	}

       receive() external payable {}

	//PUBLIC FUNCTIONS
	function saleStarted() public view returns(bool) {
		return(block.timestamp >= saleStart);
	}

	function saleEnded() public view returns(bool) {
		return(block.timestamp > saleEnd);
	}

	function saleOngoing() public view returns(bool) {
		return(saleStarted() && !saleEnded());
	}

    //find amount of tokenToPay needed to buy amountToBuy of tokenForSale
    function findAmountToPay(uint256 amountToBuy) public view returns(uint256) {
        uint256 amountToPay = (amountToBuy * exchangeRateWholeToken) / exchangeRateDivisor;
        return amountToPay;
    }

    //find amount of ETH to send in a call to purchaseTokensWithETH( amountToBuy )
    //to be conservative, we overestimate the amount of ETH  by 2%. the router will ultimately refund any extra ETH that is sent
    function findAmountETHToPay(uint256 amountToBuy) public view returns(uint256) {
        uint256 amountToPay = findAmountToPay(amountToBuy);
        address[] memory swapPath; //WETH, tokenToPay
        swapPath[0] = router.WETH();
        swapPath[1] = address(tokenToPay);
        uint256[] memory amountsIn = router.getAmountsIn(amountToPay, swapPath);
        uint256 ETHToPay = amountsIn[amountsIn.length - 1];
        return ((ETHToPay * 102) / 100);
    }

    function numberOfPurchasers() public view returns(uint256) {
        return purchasers.length;
    }

	//EXTERNAL FUNCTIONS
	function purchaseTokens(uint256 amountToBuy) external checkPurchase(msg.sender, amountToBuy) {
		_processPurchase(msg.sender, amountToBuy);
	}

	function purchaseTokensWithETH(uint256 amountToBuy) external payable checkPurchase(msg.sender, amountToBuy) {
		_swapToPurchaseTokens(msg.sender, msg.value, amountToBuy);
		_processPurchase(msg.sender, amountToBuy);
	}

	//OWNER-ONLY FUNCTIONS
	function adjustStart(uint256 newStartTime) external onlyOwner {
        require(adjustableTiming, "timing is not adjustable");
		require(!saleOngoing(), "cannot adjust start while sale ongoing");
		require(newStartTime < saleEnd, "sale must start before it ends");
		require(newStartTime > block.timestamp, "sale must start in future");
		saleStart = newStartTime;
	}

	function adjustEnd(uint256 newEndTime) external onlyOwner {
        require(adjustableTiming, "timing is not adjustable");
		require(saleStart < newEndTime, "sale must start before it ends");
		saleEnd = newEndTime;
	}

	function adjustExchangeRate(uint256 newExchangeRate) external onlyOwner {
		require(adjustableExchangeRate, "exchange rate is not adjustable");
		exchangeRateWholeToken = newExchangeRate;
		emit ExchangeRateSet(newExchangeRate);
	}

    function addToWhitelist(address[] calldata users) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata users) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = false;
        }
    }

    function setwhitelistBonusBIPS(uint256 value) external onlyOwner {
        require(value <= 5000, "bonus too high");
        whitelistBonusBIPS = value;
    }

	//INTERNAL FUNCTIONS
	function _processPurchase(address buyer, uint256 amountToBuy) internal {
		uint256 amountToPay = findAmountToPay(amountToBuy);
        totalProceeds += amountToPay;
        uint256 amountToSend = amountToBuy;
        if (whitelist[buyer]) {
            amountToSend = amountToBuy * (10000 + whitelistBonusBIPS) / 10000;
        }
        totalTokensSold += amountToSend;
        tokensPurchased[buyer] += amountToSend;
		emit TokensPurchased(buyer, amountToSend);
        amountLeftToSell -= amountToSend;
        if (!hasPurchased[buyer] && amountToBuy > 0) {
            hasPurchased[buyer] = true;
            purchasers.push(buyer);
        }
        tokenToPay.safeTransferFrom(buyer, safeAddress, amountToPay);
	}

	function _swapToPurchaseTokens(address buyer, uint256 amountETH, uint256 amountToBuy) internal {
        uint256 amountToPay = findAmountToPay(amountToBuy);
        require(tokenToPay.allowance(buyer, address(this)) >= amountToPay, "must approve the contract first");
		address[] memory swapPath; //WETH, tokenToPay. assumes good liquidity for this pair
        swapPath[0] = router.WETH();
        swapPath[1] = address(tokenToPay);
        //swap tokens for buyer, ensuring that they get the amount out needed to buy the tokens
		router.swapETHForExactTokens{value:amountETH}(amountToPay, swapPath, buyer, block.timestamp);
        //send any extra ETH back to buyer
        payable(buyer).transfer(address(this).balance);
	}
}











