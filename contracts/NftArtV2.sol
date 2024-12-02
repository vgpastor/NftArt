// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/interfaces/IERC2981.sol';

contract RBt is ERC721URIStorage, Ownable, ReentrancyGuard, IERC2981 {
    using Counters for Counters.Counter;

    uint256 public constant MICROETHER = 1e12; // 1 microether = 1e12 wei
    uint256 public constant INITIAL_DEVELOPER_PERCENT = 10; // 10% for developer on first sale
    uint256 public constant INITIAL_CHARITY_PERCENT = 5;  // 5% for charity on first sale
    uint256 public constant CONTRACT_ROYALTY = 5; // 5% for developer and Charity on secondary sales

    Counters.Counter private _tokenIds;
    mapping(uint256 => uint256) private _prices; // Prices stored in microether
    mapping(uint256 => bool) private _isFirstSale;
    mapping(uint256 => address payable) private _authors;

    // Royalty information
    struct RoyaltyInfo {
        address receiver;
        uint96 royaltyFraction; // In basis points (1% = 100 basis points)
    }
    mapping(uint256 => RoyaltyInfo) private _royalties;

    // Developer and charity wallets
    address payable public immutable developer;
    address payable public immutable charity;

    // Events
    event Sale(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceInMicroether);
    event PriceUpdated(uint256 indexed tokenId, uint256 newPriceInMicroether);
    event NFTMinted(uint256 indexed tokenId, address indexed author, string tokenURI);
    event Received(address indexed sender, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Refunded(address indexed recipient, uint256 amount);

    constructor(
        address payable _developer,
        address payable _charity
        )
        ERC721('Rothschilds Le Art', 'RBt')
        Ownable(msg.sender)
        {
        require(_developer != address(0), "Invalid developer address");
        require(_charity != address(0), "Invalid charity address");

        developer = _developer;
        charity = _charity;
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");

        (bool success, ) = msg.sender.call{value: balance}("");
        require(success, "Withdrawal failed");

        emit Withdrawn(msg.sender, balance);
    }

    function refund(address payable recipient, uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= amount, "Insufficient balance in contract");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Refund failed");

        emit Refunded(recipient, amount);
    }

    function weiToMicroether(uint256 weiAmount) public pure returns (uint256) {
        return weiAmount / MICROETHER;
    }

    function microetherToWei(uint256 microetherAmount) public pure returns (uint256) {
        return microetherAmount * MICROETHER;
    }

    function mintNFT(
        address payable _author,
        string memory _tokenURI,
        uint256 _priceInMicroether,
        uint96 royaltyFraction
    ) external onlyOwner returns (uint256) {
        require(_author != address(0), "Invalid author address");
        require(_priceInMicroether > 0, "Price must be greater than zero");

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        _safeMint(address(this), newTokenId);
        _setTokenURI(newTokenId, _tokenURI);
        _authors[newTokenId] = _author;
        _prices[newTokenId] = _priceInMicroether;
        _isFirstSale[newTokenId] = true;

        // Set royalties for the token
        _setRoyaltyInfo(newTokenId, _author, royaltyFraction);

        emit NFTMinted(newTokenId, _author, _tokenURI);
        emit PriceUpdated(newTokenId, _priceInMicroether);

        return newTokenId;
    }

    function _setRoyaltyInfo(uint256 tokenId, address receiver, uint96 royaltyFraction) internal {
        require(receiver != address(0), "Invalid receiver address");
        require(royaltyFraction <= 10000, "Royalty too high"); // 10000 basis points = 100%
        _royalties[tokenId] = RoyaltyInfo(receiver, royaltyFraction);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view override returns (address, uint256) {
        require(_royalties[tokenId].receiver != address(0), "No royalties set for token");
        RoyaltyInfo memory royalty = _royalties[tokenId];
        uint256 royaltyAmount = (salePrice * royalty.royaltyFraction) / 10000;
        return (royalty.receiver, royaltyAmount);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    function setPrice(uint256 tokenId, uint256 newPriceInMicroether) external onlyOwner {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(newPriceInMicroether > 0, "Price must be greater than zero");

        _prices[tokenId] = newPriceInMicroether;
        emit PriceUpdated(tokenId, newPriceInMicroether);
    }

    function updateTokenURI(uint256 tokenId, string memory newURI) external onlyOwner {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        _setTokenURI(tokenId, newURI);
    }

    function purchase(uint256 tokenId) external payable nonReentrant {
        uint256 priceInMicroether = _prices[tokenId];
        require(priceInMicroether > 0, "Not for sale");

        uint256 priceInWei = microetherToWei(priceInMicroether);
        require(msg.value >= priceInWei, "Insufficient payment");

        require(msg.value == priceInWei, "Exact payment required");


        address payable seller = payable(ownerOf(tokenId));

        if (_isFirstSale[tokenId]) {
            _handleFirstSale(tokenId, priceInWei);
            _isFirstSale[tokenId] = false;
        } else {
            _handleSecondarySale(tokenId, priceInWei, seller);
        }

        _transfer(seller, msg.sender, tokenId);

        delete _prices[tokenId];

        emit Sale(tokenId, seller, msg.sender, priceInMicroether);
    }

    function _handleFirstSale(uint256 tokenId, uint256 priceInWei) private {
        uint256 developerAmount = (priceInWei * INITIAL_DEVELOPER_PERCENT) / 100;
        uint256 charityAmount = (priceInWei * INITIAL_CHARITY_PERCENT) / 100;
        uint256 authorAmount = priceInWei - developerAmount - charityAmount;

        payable(developer).transfer(developerAmount);
        payable(charity).transfer(charityAmount);
        payable(_authors[tokenId]).transfer(authorAmount);
    }

    function _handleSecondarySale(uint256 tokenId, uint256 priceInWei, address payable seller) private {
        // Calcula los montos de royalties
        RoyaltyInfo memory royalty = _royalties[tokenId];
        uint256 royaltyAmount = (priceInWei * royalty.royaltyFraction) / 10000;

        // Calcula los montos para el desarrollador y la caridad
        uint256 developerAmount = (priceInWei * CONTRACT_ROYALTY) / 100;
        uint256 charityAmount = (priceInWei * CONTRACT_ROYALTY) / 100;

        // Calcula el monto restante para el vendedor
        uint256 sellerAmount = priceInWei - developerAmount - charityAmount - royaltyAmount;

        // Transferencias
        if (developerAmount > 0) {
            (bool successDev, ) = developer.call{value: developerAmount}("");
            require(successDev, "Developer transfer failed");
        }

        if (charityAmount > 0) {
            (bool successCharity, ) = charity.call{value: charityAmount}("");
            require(successCharity, "Charity transfer failed");
        }

        if (royaltyAmount > 0 && royalty.receiver != address(0)) {
            (bool successRoyalty, ) = payable(royalty.receiver).call{value: royaltyAmount}("");
            require(successRoyalty, "Royalty transfer failed");
        }

        if (sellerAmount > 0) {
            (bool successSeller, ) = seller.call{value: sellerAmount}("");
            require(successSeller, "Seller transfer failed");
        }
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }
}
