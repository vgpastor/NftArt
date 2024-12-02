// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Counters.sol';

contract ArtNFT is ERC721URIStorage, Ownable, ReentrancyGuard, IERC721Receiver {
    using Counters for Counters.Counter;
    
    // State variables
    address payable public immutable developer;
    address payable public immutable charity;
    uint256 public constant ROYALTY_PERCENT = 5;
    uint256 public constant DEVELOPER_PERCENT = 10;
    uint256 public constant CHARITY_PERCENT = 5;
    
    Counters.Counter private _tokenIds;
    mapping(uint256 => uint256) private _prices;
    mapping(uint256 => bool) private _isFirstSale;
    mapping(uint256 => address payable) private _authors;

    // Events
    event Sale(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event RoyaltyPaid(uint256 indexed tokenId, address indexed recipient, uint256 amount);
    event PriceUpdated(uint256 indexed tokenId, uint256 newPrice);
    event NFTMinted(uint256 indexed tokenId, address indexed author, string tokenURI);
    
    // Custom errors
    error InvalidPrice();
    error InsufficientPayment();
    error NotForSale();
    error NotOwner();
    error TransferFailed();
    error InvalidAuthor();

    constructor(
        address payable _developer,
        address payable _charity
    ) ERC721('Rothschilds Le Art', 'RBt') Ownable(msg.sender) ReentrancyGuard() {
        require(_developer != address(0), "Invalid developer address");
        require(_charity != address(0), "Invalid charity address");
        
        developer = _developer;
        charity = _charity;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function mintNFT(
        address payable _author,
        string memory _tokenURI,
        uint256 _initialPrice
    ) external onlyOwner returns (uint256) {
        if (_author == address(0)) revert InvalidAuthor();
        if (_initialPrice == 0) revert InvalidPrice();

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        _safeMint(address(this), newTokenId);
        _setTokenURI(newTokenId, _tokenURI);
        _authors[newTokenId] = _author;
        _prices[newTokenId] = _initialPrice;
        _isFirstSale[newTokenId] = true;

        emit NFTMinted(newTokenId, _author, _tokenURI);
        emit PriceUpdated(newTokenId, _initialPrice);

        return newTokenId;
    }

    function getAuthor(uint256 tokenId) external view returns (address) {
        return _authors[tokenId];
    }

    function setPrice(uint256 tokenId, uint256 newPrice) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (newPrice == 0) revert InvalidPrice();
        
        _prices[tokenId] = newPrice;
        emit PriceUpdated(tokenId, newPrice);
    }

    function getPrice(uint256 tokenId) external view returns (uint256) {
        return _prices[tokenId];
    }

    function purchase(uint256 tokenId) external payable nonReentrant {
        uint256 price = _prices[tokenId];
        if (price == 0) revert NotForSale();
        if (msg.value < price) revert InsufficientPayment();

        address payable seller = payable(ownerOf(tokenId));
        
        if (_isFirstSale[tokenId]) {
            _handleFirstSale(tokenId, price);
            _isFirstSale[tokenId] = false;
        } else {
            _handleSecondarySale(tokenId, price, seller);
        }

        // Transfer NFT
        _transfer(seller, msg.sender, tokenId);
        
        // Clear price after sale
        delete _prices[tokenId];
        
        emit Sale(tokenId, seller, msg.sender, price);
    }

    function _handleFirstSale(uint256 tokenId, uint256 price) private {
        uint256 developerAmount = (price * DEVELOPER_PERCENT) / 100;
        uint256 charityAmount = (price * CHARITY_PERCENT) / 100;
        uint256 authorAmount = price - developerAmount - charityAmount;

        _safeTransfer(developer, developerAmount);
        _safeTransfer(charity, charityAmount);
        _safeTransfer(_authors[tokenId], authorAmount);
    }

    function _handleSecondarySale(uint256 tokenId, uint256 price, address payable seller) private {
        uint256 royalty = (price * ROYALTY_PERCENT) / 100;
        uint256 totalRoyalties = 3 * royalty; // For developer, charity, and author
        uint256 sellerAmount = price - totalRoyalties;

        // Transfer royalties
        _safeTransfer(developer, royalty);
        _safeTransfer(charity, royalty);
        _safeTransfer(_authors[tokenId], royalty);
        
        // Transfer remaining amount to seller
        _safeTransfer(seller, sellerAmount);

        emit RoyaltyPaid(tokenId, developer, royalty);
        emit RoyaltyPaid(tokenId, charity, royalty);
        emit RoyaltyPaid(tokenId, _authors[tokenId], royalty);
    }

    function _safeTransfer(address payable recipient, uint256 amount) private {
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // Allow contract to receive ETH
    receive() external payable {}
}