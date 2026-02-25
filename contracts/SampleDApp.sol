// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SampleDApp
 * @author Web3Assam Gas Optimizer Team
 * @notice A sample decentralized application to demonstrate batch transactions
 * @dev This contract simulates a typical DApp with multiple user actions
 * 
 * USE CASE: NFT Marketplace
 * - Users can list items, place bids, update profiles, etc.
 * - Without batching: Each action = 1 transaction = 1 gas payment
 * - With batching: Multiple actions = 1 transaction = 1 gas payment
 */
contract SampleDApp {
    
    // ============ STRUCTS ============
    
    struct UserProfile {
        string username;
        string bio;
        uint256 reputation;
        uint256 totalTransactions;
        bool isVerified;
    }

    struct Listing {
        address seller;
        string itemName;
        uint256 price;
        bool isActive;
        uint256 createdAt;
    }

    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }

    // ============ STATE VARIABLES ============
    
    mapping(address => UserProfile) public profiles;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid[]) public listingBids;
    mapping(address => uint256[]) public userListings;
    mapping(address => uint256) public userBalances;
    
    uint256 public nextListingId;
    uint256 public totalListings;
    uint256 public totalBids;

    // ============ EVENTS ============
    
    event ProfileUpdated(address indexed user, string username);
    event ListingCreated(uint256 indexed listingId, address indexed seller, string itemName, uint256 price);
    event ListingUpdated(uint256 indexed listingId, uint256 newPrice);
    event ListingCancelled(uint256 indexed listingId);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 amount);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    // ============ PROFILE FUNCTIONS ============

    /**
     * @notice Create or update user profile
     * @param username User's display name
     * @param bio User's biography
     */
    function updateProfile(string calldata username, string calldata bio) external {
        profiles[msg.sender].username = username;
        profiles[msg.sender].bio = bio;
        emit ProfileUpdated(msg.sender, username);
    }

    /**
     * @notice Set user verification status (admin function in real app)
     * @param user User to verify
     * @param verified Verification status
     */
    function setVerified(address user, bool verified) external {
        profiles[user].isVerified = verified;
    }

    // ============ LISTING FUNCTIONS ============

    /**
     * @notice Create a new listing
     * @param itemName Name of the item
     * @param price Price in wei
     * @return listingId The ID of the created listing
     */
    function createListing(string calldata itemName, uint256 price) 
        external 
        returns (uint256 listingId) 
    {
        listingId = nextListingId++;
        
        listings[listingId] = Listing({
            seller: msg.sender,
            itemName: itemName,
            price: price,
            isActive: true,
            createdAt: block.timestamp
        });

        userListings[msg.sender].push(listingId);
        totalListings++;

        profiles[msg.sender].totalTransactions++;

        emit ListingCreated(listingId, msg.sender, itemName, price);
    }

    /**
     * @notice Update listing price
     * @param listingId ID of the listing
     * @param newPrice New price
     */
    function updateListing(uint256 listingId, uint256 newPrice) external {
        require(listings[listingId].seller == msg.sender, "Not seller");
        require(listings[listingId].isActive, "Listing not active");
        
        listings[listingId].price = newPrice;
        emit ListingUpdated(listingId, newPrice);
    }

    /**
     * @notice Cancel a listing
     * @param listingId ID of the listing
     */
    function cancelListing(uint256 listingId) external {
        require(listings[listingId].seller == msg.sender, "Not seller");
        listings[listingId].isActive = false;
        emit ListingCancelled(listingId);
    }

    /**
     * @notice Create multiple listings in one call
     * @param itemNames Array of item names
     * @param prices Array of prices
     * @return listingIds Array of created listing IDs
     */
    function createMultipleListings(
        string[] calldata itemNames, 
        uint256[] calldata prices
    ) 
        external 
        returns (uint256[] memory listingIds) 
    {
        require(itemNames.length == prices.length, "Array length mismatch");
        
        listingIds = new uint256[](itemNames.length);
        
        for (uint256 i = 0; i < itemNames.length; i++) {
            uint256 listingId = nextListingId++;
            
            listings[listingId] = Listing({
                seller: msg.sender,
                itemName: itemNames[i],
                price: prices[i],
                isActive: true,
                createdAt: block.timestamp
            });

            userListings[msg.sender].push(listingId);
            listingIds[i] = listingId;
            
            emit ListingCreated(listingId, msg.sender, itemNames[i], prices[i]);
        }

        totalListings += itemNames.length;
        profiles[msg.sender].totalTransactions += itemNames.length;
    }

    // ============ BIDDING FUNCTIONS ============

    /**
     * @notice Place a bid on a listing
     * @param listingId ID of the listing
     */
    function placeBid(uint256 listingId) external payable {
        require(listings[listingId].isActive, "Listing not active");
        require(msg.value > 0, "Bid must be positive");

        listingBids[listingId].push(Bid({
            bidder: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp
        }));

        totalBids++;
        profiles[msg.sender].totalTransactions++;

        emit BidPlaced(listingId, msg.sender, msg.value);
    }

    /**
     * @notice Get bids for a listing
     * @param listingId ID of the listing
     * @return Array of bids
     */
    function getBids(uint256 listingId) external view returns (Bid[] memory) {
        return listingBids[listingId];
    }

    // ============ BALANCE FUNCTIONS ============

    /**
     * @notice Deposit ETH to user balance
     */
    function deposit() external payable {
        userBalances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from user balance
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external {
        require(userBalances[msg.sender] >= amount, "Insufficient balance");
        userBalances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get user's profile
     * @param user User address
     */
    function getProfile(address user) external view returns (UserProfile memory) {
        return profiles[user];
    }

    /**
     * @notice Get user's listings
     * @param user User address
     */
    function getUserListings(address user) external view returns (uint256[] memory) {
        return userListings[user];
    }

    /**
     * @notice Get listing details
     * @param listingId Listing ID
     */
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /**
     * @notice Get contract statistics
     */
    function getStats() external view returns (
        uint256 _totalListings,
        uint256 _totalBids,
        uint256 _contractBalance
    ) {
        return (totalListings, totalBids, address(this).balance);
    }
}
