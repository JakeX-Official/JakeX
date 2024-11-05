// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "erc721a/contracts/ERC721A.sol";
import "./interfaces/IERC20Burnable.sol";
import "./lib/OracleLibrary.sol";
import "./lib/TickMath.sol";
import "./lib/constants.sol";

/// @title JakeX Universe NFT contract
contract JakeXUniverse is ERC2981, ERC721A, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Burnable;
    using Strings for uint256;

    // --------------------------- STATE VARIABLES --------------------------- //

    address immutable JakeBank;
    bool public isSaleActive;
    string private baseURI;
    string public contractURI;
    uint64 public maxSupply = 2888;

    /// @notice Time used for TWAP calculation.
    uint32 public secondsAgo = 5 * 60;
    /// @notice Allowed deviation of the maxAmountIn from historical price.
    uint32 public deviation = 2000;

    // --------------------------- ERRORS & EVENTS --------------------------- //

    error SaleInactive();
    error MaxSupplyExceeded();
    error ZeroInput();
    error ZeroAddress();
    error TWAP();
    error Prohibited();
    error Unauthorized();

    event SaleUpdated(bool active);
    event Mint(uint256 amount);
    event SupplyCut(uint256 newMaxSupply);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event ContractURIUpdated();

    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(address owner_, string memory contractURI_, string memory baseURI_, address jakeBank_)
        ERC721A("JakeX Universe", "JKXU")
        Ownable(owner_)
    {
        if (jakeBank_ == address(0)) revert ZeroAddress();
        if (bytes(contractURI_).length == 0) revert ZeroInput();
        if (bytes(baseURI_).length == 0) revert ZeroInput();
        contractURI = contractURI_;
        baseURI = baseURI_;
        JakeBank = jakeBank_;
        _setDefaultRoyalty(0x410e10C33a49279f78CB99c8d816F18D5e7D5404, 800);
    }

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    /// @notice Mints a specified amount of NFTs to the sender using JakeX.
    /// @param amount The number of tokens to mint.
    function mintWithJakeX(uint256 amount) external {
        if (!isSaleActive) revert SaleInactive();
        if (amount == 0) revert ZeroInput();
        if (_totalMinted() + amount > maxSupply) revert MaxSupplyExceeded();
        uint256 burnSum = amount * NFT_BURN_FEE;
        uint256 bankSum = amount * NFT_PRICE;
        IERC20Burnable jakeX = IERC20Burnable(JAKEX);
        jakeX.safeTransferFrom(msg.sender, JakeBank, bankSum);
        jakeX.burnFrom(msg.sender, burnSum);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    /// @notice Mints a specified amount of NFTs to the sender using TitanX.
    /// @param amount The number of tokens to mint.
    /// @param titanXAmount Max TitanX amount to use for the swap.
    /// @param deadline Deadline for the transaction.
    function mintWithTitanX(uint256 amount, uint256 titanXAmount, uint256 deadline) external {
        if (!isSaleActive) revert SaleInactive();
        if (amount == 0) revert ZeroInput();
        if (_totalMinted() + amount > maxSupply) revert MaxSupplyExceeded();
        uint256 burnSum = amount * NFT_BURN_FEE;
        uint256 bankSum = amount * NFT_PRICE;
        uint256 totalSum = bankSum + burnSum;
        IERC20(TITANX).safeTransferFrom(msg.sender, address(this), titanXAmount);
        _swapTitanXForJakeX(titanXAmount, totalSum, deadline);
        IERC20Burnable jakeX = IERC20Burnable(JAKEX);
        jakeX.safeTransfer(JakeBank, bankSum);
        jakeX.burn(burnSum);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    /// @notice Sets the base URI for the token metadata.
    /// @param uri The new base URI to set.
    function setBaseURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        baseURI = uri;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    /// @notice Sets the contract-level metadata URI.
    /// @param uri The new contract URI to set.
    function setContractURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice Toggles the sale state (active/inactive).
    function flipSaleState() external onlyOwner {
        isSaleActive = !isSaleActive;
        emit SaleUpdated(isSaleActive);
    }

    /// @notice Reduces the maximum supply of NFTs.
    /// @param newMaxSupply The new maximum supply to set.
    function cutSupply(uint64 newMaxSupply) external onlyOwner {
        if (newMaxSupply >= maxSupply) revert Prohibited();
        if (newMaxSupply < _totalMinted()) revert Prohibited();
        maxSupply = newMaxSupply;
        emit SupplyCut(newMaxSupply);
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

    // --------------------------- VIEW FUNCTIONS --------------------------- //

    /// @notice Returns all token IDs owned by a specific account.
    /// @param account The address of the token owner.
    /// @return tokenIds An array of token IDs owned by the account.
    /// @dev Should not be called by contracts.
    function tokenIdsOf(address account) external view returns (uint256[] memory tokenIds) {
        uint256 totalTokenIds = _nextTokenId();
        uint256 userBalance = balanceOf(account);
        tokenIds = new uint256[](userBalance);
        if (userBalance == 0) return tokenIds;
        uint256 counter;
        for (uint256 tokenId = 1; tokenId < totalTokenIds; tokenId++) {
            if (_exists(tokenId) && ownerOf(tokenId) == account) {
                tokenIds[counter] = tokenId;
                counter++;
                if (counter == userBalance) return tokenIds;
            }
        }
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        return string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721A, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // --------------------------- INTERNAL FUNCTIONS --------------------------- //

    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }

    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity)
        internal
        virtual
        override
    {
        if (to == JakeBank) {
            if (from != tx.origin) revert Unauthorized();
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
