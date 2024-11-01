// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/IERC20Burnable.sol";
import "./lib/OracleLibrary.sol";
import "./lib/TickMath.sol";
import "./lib/constants.sol";

/// @title Jake's Piggy Bank contract
contract PiggyBank is ERC721Holder, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Burnable;

    // --------------------------- STATE VARIABLES --------------------------- //

    address public JakeNFT;
    bool public isBankActive;

    /// @notice Max number of NFTs per 1 withdrawal/deposit.
    uint64 public maxPerTransaction = 50;
    /// @notice Time used for TWAP calculation.
    uint32 public secondsAgo = 5 * 60;
    /// @notice Allowed deviation of the maxAmountIn from historical price.
    uint32 public deviation = 2000;

    // --------------------------- ERRORS & EVENTS --------------------------- //
    
    error BankInactive();
    error MaxAmountExceeded();
    error ZeroInput();
    error ZeroAddress();
    error Prohibited();
    error Unauthorized();
    error TWAP();

    event Deposit(address account, uint256[] tokenIds);
    event Withdrawal(address account, uint256[] tokenIds);

    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(address owner_) Ownable(owner_) {}

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    /// @notice Depoists JakeX Universe NFTs to the Piggy Bank and pays out JakeX tokens.
    /// @param tokenIds The list of token Ids to be deposited.
    /// @dev Can only be called by the owner of the NFTs.
    function deposit(uint256[] calldata tokenIds) external nonReentrant {
        if (!isBankActive) revert BankInactive();
        if (tokenIds.length > maxPerTransaction) revert MaxAmountExceeded();
        (uint256 totalPayout, uint256 totalBurnFee) = _addNFTsToBank(tokenIds);
        IERC20Burnable jakeX = IERC20Burnable(JAKEX);
        jakeX.burn(totalBurnFee);
        jakeX.safeTransfer(msg.sender, totalPayout);
        emit Deposit(msg.sender, tokenIds);
    }

    /// @notice Withdraws JakeX Universe NFTs from the Piggy Bank for a price paid in JakeX tokens.
    /// @param tokenIds The list of token Ids to be withdrawn.
    function withdrawWithJakeX(uint256[] calldata tokenIds) external nonReentrant {
        if (!isBankActive) revert BankInactive();
        if (tokenIds.length > maxPerTransaction) revert MaxAmountExceeded();
        (uint256 totalPrice, uint256 totalBurnFee) = _removeNFTsFromBank(tokenIds);
        IERC20Burnable jakeX = IERC20Burnable(JAKEX);
        jakeX.safeTransferFrom(msg.sender, address(this), totalPrice);
        jakeX.burn(totalBurnFee);
        emit Withdrawal(msg.sender, tokenIds);
    }

    /// @notice Withdraws JakeX Universe NFTs from the Piggy Bank for a price paid in TitanX tokens.
    /// @param tokenIds The list of token Ids to be withdrawn.
    /// @param titanXAmount Max TitanX amount to use for the swap.
    /// @param deadline Deadline for the transaction.
    function withdrawWithTitanX(uint256[] calldata tokenIds, uint256 titanXAmount, uint256 deadline) external nonReentrant {
        if (!isBankActive) revert BankInactive();
        if (tokenIds.length > maxPerTransaction) revert MaxAmountExceeded();
        IERC20(TITANX).safeTransferFrom(msg.sender, address(this), titanXAmount);
        (uint256 totalPrice, uint256 totalBurnFee) = _removeNFTsFromBank(tokenIds);
        _swapTitanXForJakeX(titanXAmount, totalPrice, deadline);
        IERC20Burnable(JAKEX).burn(totalBurnFee);
        emit Withdrawal(msg.sender, tokenIds);
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    /// @notice Sets a new max number of NFTs per withdrawal/deposit.
    /// @param limit The new max number of NFTs.
    function setMaxPerTransaction(uint64 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        maxPerTransaction = limit;
    }

    /// @notice Sets JakeX Universe NFT address and activated the Piggy Bank.
    /// @param nftAddress JakeX Universe NFT address.
    function activateBank(address nftAddress) external onlyOwner {
        if (JakeNFT != address(0)) revert Prohibited();
        if (nftAddress == address(0)) revert ZeroAddress();
        JakeNFT = nftAddress;
        isBankActive = true;
    }

    /// @notice Sets the number of seconds to look back for TWAP price calculations.
    /// @param limit The number of seconds to use for TWAP price lookback.
    function setSecondsAgo(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        secondsAgo = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        if (limit > 10000) revert Prohibited();
        deviation = limit;
    }


    // --------------------------- INTERNAL FUNCTIONS --------------------------- //

    function _addNFTsToBank(uint256[] memory tokenIds) private returns (uint256 totalPayout, uint256 totalBurnFee) {
        IERC721 jakeNFT = IERC721(JakeNFT);
        address originalOwner = jakeNFT.ownerOf(tokenIds[0]);
        if (originalOwner != msg.sender) revert Unauthorized();
        uint256 amount = tokenIds.length;
        totalBurnFee = amount * NFT_BURN_FEE;
        totalPayout = amount * NFT_PRICE - totalBurnFee;
        for (uint256 i; i < amount; i++) {
            uint256 tokenId = tokenIds[i];
            if (jakeNFT.ownerOf(tokenId) != originalOwner) revert Unauthorized();
            jakeNFT.safeTransferFrom(msg.sender, address(this), tokenId);
        }
    }


    function _removeNFTsFromBank(uint256[] memory tokenIds) private returns (uint256 totalPrice, uint256 totalBurnFee) {
        uint256 amount = tokenIds.length;
        totalBurnFee = amount * NFT_BURN_FEE;
        totalPrice = amount * NFT_PRICE + totalBurnFee;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            IERC721(JakeNFT).safeTransferFrom(address(this), msg.sender, tokenId);
        }
    }

    function _swapTitanXForJakeX(uint256 amountInMaximum, uint256 amountOut, uint256 deadline) internal {
        _twapCheckExactOutput(TITANX, JAKEX, amountInMaximum, amountOut);
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: TITANX,
            tokenOut: JAKEX,
            fee: 10000,
            recipient: address(this),
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        IERC20 titanX = IERC20(TITANX);
        titanX.safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountInMaximum);
        uint256 amountIn = ISwapRouter(UNISWAP_V3_ROUTER).exactOutputSingle(params);

        if (amountIn < amountInMaximum) {
            uint256 diff = amountInMaximum - amountIn;
            titanX.safeTransfer(msg.sender, diff);
            titanX.safeDecreaseAllowance(UNISWAP_V3_ROUTER, diff);
        }
    }

    function _twapCheckExactOutput(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        internal
        view
    {
        uint32 _secondsAgo = secondsAgo;

        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(TITANX_JAKEX_POOL);
        if (oldestObservation < _secondsAgo) {
            _secondsAgo = oldestObservation;
        }

        (int24 arithmeticMeanTick,) = OracleLibrary.consult(TITANX_JAKEX_POOL, _secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        uint256 twapAmountIn =
            OracleLibrary.getQuoteForSqrtRatioX96(sqrtPriceX96, uint128(amountOut), tokenOut, tokenIn);

        uint256 upperBound = (maxAmountIn * (10000 + deviation)) / 10000;

        if (upperBound < twapAmountIn) revert TWAP();
    }
}
