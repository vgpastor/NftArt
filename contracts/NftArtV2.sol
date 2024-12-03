// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract RBt is ERC721URIStorage, Ownable, ReentrancyGuard, IERC2981, Pausable {
    using Counters for Counters.Counter;

    // Constants
    uint256 private immutable GWEI = 1e9; // 1 gwei = 1e9 wei
    uint256 private immutable INITIAL_DEVELOPER_PERCENT = 10;
    uint256 private immutable INITIAL_CHARITY_PERCENT = 10;
    uint256 private immutable CONTRACT_ROYALTY = 5;

    // State variables
    Counters.Counter private _tokenIds;
    mapping(uint256 => uint256) private _pricesInGwei;
    mapping(uint256 => bool) private _isFirstSale;
    mapping(uint256 => address payable) private _authors;

    // Royalty info struct
    struct RoyaltyInfo {
        address receiver;
        uint96 royaltyFraction;
    }
    mapping(uint256 => RoyaltyInfo) private _royalties;

    // Immutable addresses
    address payable public immutable developer;
    address payable public immutable charity;

    // Regular events
    event Sale(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceInGwei);
    event PriceUpdated(uint256 indexed tokenId, uint256 newPriceInGwei);
    event NFTMinted(uint256 indexed tokenId, address indexed author, string tokenURI);
    event Received(address indexed sender, uint256 amountInGwei);
    event Withdrawn(address indexed recipient, uint256 amountInGwei);
    event Refunded(address indexed recipient, uint256 amountInGwei);

    // Custom errors
    error InvalidAddress();
    error InsufficientPayment();
    error NotForSale();
    error NotOwner();
    error NoFunds();
    error TransferFailed();
    error InvalidPrice();
    error RoyaltyTooHigh();
    error NoRoyaltiesSet();
    error NotAuthor();
    error EmergencyStop();

    constructor(
        address payable _developer,
        address payable _charity
    ) ERC721("Rothschilds Le Art", "RBt") Ownable(msg.sender) {
        if (_developer == address(0) || _charity == address(0)) revert InvalidAddress();
        developer = _developer;
        charity = _charity;
    }

    // Función de emergencia para pause
    function togglePause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }

    function mintNFT(
        address payable _author,
        string calldata _tokenURI,
        uint256 _initialPriceInGwei
    ) external onlyOwner nonReentrant whenNotPaused returns (uint256) {        
        if (_author == address(0)) revert InvalidAddress();
        
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        _safeMint(_author, newTokenId);
        _setTokenURI(newTokenId, _tokenURI);
        
        _authors[newTokenId] = _author;
        _isFirstSale[newTokenId] = true;
        
        if (_initialPriceInGwei > 0) {
            _pricesInGwei[newTokenId] = _initialPriceInGwei;
            emit PriceUpdated(newTokenId, _initialPriceInGwei);
        }

        emit NFTMinted(newTokenId, _author, _tokenURI);
        
        return newTokenId;
    }

    function withdraw() external onlyOwner {
        uint256 balanceInWei = address(this).balance;
        if (balanceInWei == 0) revert NoFunds();

        (bool success, ) = msg.sender.call{value: balanceInWei}("");
        if (!success) revert TransferFailed();

        emit Withdrawn(msg.sender, balanceInWei / GWEI);
    }

    function refund(address payable recipient, uint256 amountInGwei) external onlyOwner {
        uint256 amountInWei = amountInGwei * GWEI;
        if (amountInWei == 0 || address(this).balance < amountInWei) revert InvalidPrice();
        
        (bool success, ) = recipient.call{value: amountInWei}("");
        if (!success) revert TransferFailed();

        emit Refunded(recipient, amountInGwei);
    }

    function weiToGwei(uint256 weiAmount) public pure returns (uint256) {
        return weiAmount / GWEI;
    }

    function gweiToWei(uint256 gweiAmount) public pure returns (uint256) {
        return gweiAmount * GWEI;
    }

    function setRoyaltyInfo(uint256 tokenId, address receiver, uint96 royaltyFraction) external {
        if (_authors[tokenId] != msg.sender) revert NotAuthor();
        if (receiver == address(0)) revert InvalidAddress();
        if (royaltyFraction > 10000) revert RoyaltyTooHigh();
        
        _royalties[tokenId] = RoyaltyInfo(receiver, royaltyFraction);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view override returns (address, uint256) {
        RoyaltyInfo memory royalty = _royalties[tokenId];
        if (royalty.receiver == address(0)) revert NoRoyaltiesSet();
        
        uint256 royaltyAmount = (salePrice * royalty.royaltyFraction) / 10000;
        return (royalty.receiver, royaltyAmount);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    function setPrice(uint256 tokenId, uint256 newPriceInGwei) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (newPriceInGwei == 0) revert InvalidPrice();

        _pricesInGwei[tokenId] = newPriceInGwei;
        emit PriceUpdated(tokenId, newPriceInGwei);
    }

    function updateTokenURI(uint256 tokenId, string calldata newURI) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        _setTokenURI(tokenId, newURI);
    }

    // Función de emergencia para recuperar ETH
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(owner()).call{value: balance}("");
            if (!success) revert TransferFailed();
            emit Withdrawn(owner(), balance);
        }
    }

    function purchase(uint256 tokenId) external payable nonReentrant whenNotPaused {
        if (paused()) revert EmergencyStop();
        uint256 priceInGwei = _pricesInGwei[tokenId];
        if (priceInGwei == 0) revert NotForSale();

        uint256 priceInWei = gweiToWei(priceInGwei);
        if (msg.value < priceInWei) revert InsufficientPayment();

        address payable seller = payable(ownerOf(tokenId));

        if (_isFirstSale[tokenId]) {
            _handleFirstSale(tokenId, priceInWei);
            _isFirstSale[tokenId] = false;
        } else {
            _handleSecondarySale(tokenId, priceInWei, seller);
        }

        // Procesar exceso de pago si existe
        uint256 excess = msg.value - priceInWei;
        if (excess > 0) {
            (bool success, ) = payable(msg.sender).call{value: excess}("");
            if (!success) revert TransferFailed();
            emit Refunded(msg.sender, weiToGwei(excess));
        }


        _transfer(seller, msg.sender, tokenId);
        delete _pricesInGwei[tokenId];

        emit Sale(tokenId, seller, msg.sender, priceInGwei);
    }

    function _handleFirstSale(uint256 tokenId, uint256 priceInWei) private {
        uint256 developerAmount = (priceInWei * INITIAL_DEVELOPER_PERCENT) / 100;
        uint256 charityAmount = (priceInWei * INITIAL_CHARITY_PERCENT) / 100;
        uint256 authorAmount = priceInWei - developerAmount - charityAmount;

        _safeTransfer(developer, developerAmount);
        _safeTransfer(charity, charityAmount);
        _safeTransfer(_authors[tokenId], authorAmount);
    }

    function _handleSecondarySale(uint256 tokenId, uint256 priceInWei, address payable seller) private {
        RoyaltyInfo memory royalty = _royalties[tokenId];
        uint256 royaltyAmount = (priceInWei * royalty.royaltyFraction) / 10000;
        uint256 developerAmount = (priceInWei * CONTRACT_ROYALTY) / 100;
        uint256 charityAmount = (priceInWei * CONTRACT_ROYALTY) / 100;
        uint256 sellerAmount = priceInWei - developerAmount - charityAmount - royaltyAmount;

        if (developerAmount > 0) _safeTransfer(developer, developerAmount);
        if (charityAmount > 0) _safeTransfer(charity, charityAmount);
        if (royaltyAmount > 0 && royalty.receiver != address(0)) {
            _safeTransfer(payable(royalty.receiver), royaltyAmount);
        }
        if (sellerAmount > 0) _safeTransfer(seller, sellerAmount);
    }

    function _safeTransfer(address payable recipient, uint256 amountInWei) private {
        (bool success, ) = recipient.call{value: amountInWei}("");
        if (!success) revert TransferFailed();
    }

    function getTokenInfo(uint256 tokenId) external view returns (
        address owner,
        address author,
        uint256 priceInGwei,
        bool isFirstSale
    ) {
        owner = ownerOf(tokenId);
        author = _authors[tokenId];
        priceInGwei = _pricesInGwei[tokenId];
        isFirstSale = _isFirstSale[tokenId];
    }

    function getRoyaltyDetails(uint256 tokenId) external view returns (address receiver, uint96 fraction) {
        RoyaltyInfo memory royalty = _royalties[tokenId];
        return (royalty.receiver, royalty.royaltyFraction);
    }

    function removeFromSale(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        delete _pricesInGwei[tokenId];
        emit PriceUpdated(tokenId, 0);
    }

    // Implementar onERC721Received para manejar transferencias seguras
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value / GWEI);
    }

    fallback() external payable {
        emit Received(msg.sender, msg.value / GWEI);
    }
}