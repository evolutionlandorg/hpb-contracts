pragma solidity ^0.4.24;

import "../common/ERC721.sol";
import "../common/SafeMath.sol";
import "../common/interfaces/ISettingsRegistry.sol";
import "../common/PausableDSAuth.sol";
import "./ApostleSettingIds.sol";
import "./interfaces/IApostleBase.sol";

contract ApostleClockAuction is PausableDSAuth, ApostleSettingIds {
    using SafeMath for *;
    event AuctionCreated(
        uint256 tokenId, address seller, uint256 startingPriceInToken, uint256 endingPriceInToken, uint256 duration, address token, uint256 startedAt
    );

    event AuctionSuccessful(uint256 tokenId, uint256 totalPrice, address winner);
    event AuctionCancelled(uint256 tokenId);

    // claimedToken event
    event ClaimedTokens(address indexed token, address indexed owner, uint amount);

    // new bid event
    event NewBid(
        uint256 indexed tokenId, address lastBidder, address lastReferer, uint256 lastRecord, address tokenAddress, uint256 bidStartAt, uint256 returnToLastBidder
    );

    // Represents an auction on an NFT
    struct Auction {
        // Current owner of NFT
        address seller;
        // Time when auction started
        // NOTE: 0 if this auction has been concluded
        uint48 startedAt;
        // Duration (in seconds) of auction
        uint48 duration;
        // Price (in token) at beginning of auction
        uint128 startingPriceInToken;
        // Price (in token) at end of auction
        uint128 endingPriceInToken;
        // bid the auction through which token
        address token;

        // it saves gas in this order
        // highest offered price (in RING)
        uint128 lastRecord;
        // bidder who offer the highest price
        address lastBidder;
        // latestBidder's bidTime in timestamp
        uint48 lastBidStartAt;
        // lastBidder's referer
        address lastReferer;
    }

    bool private singletonLock = false;

    ISettingsRegistry public registry;

    // Map from token ID to their corresponding auction.
    mapping(uint256 => Auction) public tokenIdToAuction;

    /*
    *  Modifiers
    */
    modifier singletonLockCall() {
        require(!singletonLock, "Only can call once");
        _;
        singletonLock = true;
    }

    modifier isHuman() {
        require(msg.sender == tx.origin, "robot is not permitted");
        _;
    }

    // Modifiers to check that inputs can be safely stored with a certain
    // number of bits. We use constants and multiple modifiers to save gas.
    modifier canBeStoredWith48Bits(uint256 _value) {
        require(_value <= 281474976710656);
        _;
    }

    modifier canBeStoredWith128Bits(uint256 _value) {
        require(_value < 340282366920938463463374607431768211455);
        _;
    }

    modifier isOnAuction(uint256 _tokenId) {
        require(tokenIdToAuction[_tokenId].startedAt > 0);
        _;
    }

    ///////////////////////
    // Constructor
    ///////////////////////
    constructor() public {
        // initializeContract
    }

    /// @dev Constructor creates a reference to the NFT ownership contract
    ///  and verifies the owner cut is in the valid range.
    ///  bidWaitingMinutes - biggest waiting time from a bid's starting to ending(in minutes)
    function initializeContract(
        ISettingsRegistry _registry) public singletonLockCall {

        owner = msg.sender;
        emit LogSetOwner(msg.sender);

        registry = _registry;
    }

    /// @dev DON'T give me your money.
    function() external {}

    ///////////////////////
    // Auction Create and Cancel
    ///////////////////////

    function createAuction(
        uint256 _tokenId,
        uint256 _startingPriceInToken,
        uint256 _endingPriceInToken,
        uint256 _duration,
        uint256 _startAt,
        address _token) // with any token
    public auth {
        _createAuction(msg.sender, _tokenId, _startingPriceInToken, _endingPriceInToken, _duration, _startAt, msg.sender, _token);
    }

    /// @dev Cancels an auction that hasn't been won yet.
    ///  Returns the NFT to original owner.
    /// @notice This is a state-modifying function that can
    ///  be called while the contract is paused.
    /// @param _tokenId - ID of token on auction
    function cancelAuction(uint256 _tokenId) public isOnAuction(_tokenId)
    {
        Auction storage auction = tokenIdToAuction[_tokenId];

        address seller = auction.seller;
        require((msg.sender == seller && !paused) || msg.sender == owner);

        // once someone has bidden for this auction, no one has the right to cancel it.
        require(auction.lastBidder == 0x0);

        delete tokenIdToAuction[_tokenId];

        ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)).safeTransferFrom(this, seller, _tokenId);
        emit AuctionCancelled(_tokenId);
    }

    //@dev only NFT contract can invoke this
    //@param _from - owner of _tokenId
    function receiveApproval(
        address _from,
        uint256 _tokenId,
        bytes //_extraData
    )
    public
    whenNotPaused
    {
        if (msg.sender == registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)) {
            uint256 startingPriceInRING;
            uint256 endingPriceInRING;
            uint256 duration;
            address seller;

            assembly {
                let ptr := mload(0x40)
                calldatacopy(ptr, 0, calldatasize)
                startingPriceInRING := mload(add(ptr, 132))
                endingPriceInRING := mload(add(ptr, 164))
                duration := mload(add(ptr, 196))
                seller := mload(add(ptr, 228))
            }

            // TODO: add parameter _token
            _createAuction(_from, _tokenId, startingPriceInRING, endingPriceInRING, duration, now, seller, 0);
        }

    }

    ///////////////////////
    // Bid With Auction
    ///////////////////////

    // @dev bid with RING. Computes the price and transfers winnings.
    function _bidWithToken(address _from, uint256 _tokenId, uint256 _valueInToken, address _referer) internal returns (uint256){
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        // Check that the incoming bid is higher than the current price
        uint priceInToken = getCurrentPriceInToken(_tokenId);
        require(_valueInToken >= priceInToken,
            "your offer is lower than the current price, try again with a higher one.");
        uint refund = _valueInToken - priceInToken;

        if (refund > 0) {
            _from.transfer(refund);
        }

        uint bidMoment;
        uint returnToLastBidder;
        (bidMoment, returnToLastBidder) = _bidProcess(_from, auction, priceInToken, _referer);

        // Tell the world!
        emit NewBid(_tokenId, _from, _referer, priceInToken, auction.token, bidMoment, returnToLastBidder);

        return priceInToken;
    }

    // here to handle bid for LAND(NFT) using RING
    // @dev bidder must use RING.transfer(address(this), _valueInRING, bytes32(_tokenId)
    // to invoke this function
    // @param _data - need to be generated from (tokenId + referer)

    function bid(uint tokenId, address referer) payable public whenNotPaused {
        // safer for users
        require(tokenIdToAuction[tokenId].startedAt > 0);

        _bidWithToken(msg.sender, tokenId, msg.value, referer);
    }

    // TODO: advice: offer some reward for the person who claimed
    // @dev claim _tokenId for auction's lastBidder
    function claimApostleAsset(uint _tokenId) public isHuman isOnAuction(_tokenId) {
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        // at least bidWaitingTime after last bidder's bid moment,
        // and no one else has bidden during this bidWaitingTime,
        // then any one can claim this token(land) for lastBidder.
        require(auction.lastBidder != 0x0 && now >= auction.lastBidStartAt + registry.uintOf(ApostleSettingIds.UINT_APOSTLE_BID_WAITING_TIME),
            "this auction has not finished yet, try again later");

        address lastBidder = auction.lastBidder;
        uint lastRecord = auction.lastRecord;

        delete tokenIdToAuction[_tokenId];

        ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)).safeTransferFrom(this, lastBidder, _tokenId);

        emit AuctionSuccessful(_tokenId, lastRecord, lastBidder);
    }

    function _firstPartBid(uint _auctionCut, uint _refererCut, address _pool, address _buyer, Auction storage _auction, uint _priceInToken, address _referer) internal returns (uint, uint){
        require(now >= uint256(_auction.startedAt));
        //  Calculate the auctioneer's cut.
        // (NOTE: computeCut() is guaranteed to return a
        //  value <= price, so this subtraction can't go negative.)
        // TODO: token to the seller
        uint256 ownerCutAmount = computeCut(_priceInToken, _auctionCut);

        // transfer to the seller
        _auction.seller.transfer(_priceInToken - ownerCutAmount);

        if (_referer != 0x0) {
            uint refererBounty = computeCut(ownerCutAmount, _refererCut);
            _referer.transfer(refererBounty);
            _pool.transfer(ownerCutAmount - refererBounty);
        } else {
            _pool.transfer(ownerCutAmount);
        }

        // modify bid-related member variables
        _auction.lastBidder = _buyer;
        _auction.lastRecord = uint128(_priceInToken);
        _auction.lastBidStartAt = uint48(now);
        _auction.lastReferer = _referer;

        return (_auction.lastBidStartAt, 0);
    }


    function _secondPartBid(uint _auctionCut, uint _refererCut, address _pool, address _buyer, Auction storage _auction, uint _priceInToken, address _referer) internal returns (uint, uint){
        // TODO: repair bug of first bid's time limitation
        // if this the first bid, there is no time limitation
        require(now <= _auction.lastBidStartAt + registry.uintOf(ApostleSettingIds.UINT_APOSTLE_BID_WAITING_TIME), "It's too late.");

        // _priceInToken that is larger than lastRecord
        // was assured in _currentPriceInRING(_auction)
        // here double check
        // 1.1*price + bounty - (price + bounty) = 0.1 * price
        uint surplus = _priceInToken.sub(uint256(_auction.lastRecord));
        uint poolCutAmount = computeCut(surplus, _auctionCut);
        uint extractFromGap = surplus - poolCutAmount;
        uint realReturnForEach = extractFromGap / 2;

        // here use transfer(address,uint256) for safety
        _auction.seller.transfer(realReturnForEach);
        _auction.lastBidder.transfer(realReturnForEach + uint256(_auction.lastRecord));

        if (_referer != 0x0) {
            uint refererBounty = computeCut(poolCutAmount, _refererCut);
            _referer.transfer(refererBounty);
            _pool.transfer(poolCutAmount - refererBounty);
        } else {
            _pool.transfer(poolCutAmount);
        }

        // modify bid-related member variables
        _auction.lastBidder = _buyer;
        _auction.lastRecord = uint128(_priceInToken);
        _auction.lastBidStartAt = uint48(now);
        _auction.lastReferer = _referer;

        return (_auction.lastBidStartAt, (realReturnForEach + uint256(_auction.lastRecord)));
    }

    // TODO: add _token to compatible backwards with ring and eth
    function _bidProcess(address _buyer, Auction storage _auction, uint _priceInToken, address _referer)
    internal
    canBeStoredWith128Bits(_priceInToken)
    returns (uint256, uint256){

        uint auctionCut = registry.uintOf(UINT_AUCTION_CUT);
        uint256 refererCut = registry.uintOf(UINT_REFERER_CUT);
        address revenuePool = registry.addressOf(CONTRACT_REVENUE_POOL);

        // uint256 refererBounty;

        // the first bid
        if (_auction.lastBidder == 0x0 && _priceInToken > 0) {

            return _firstPartBid(auctionCut, refererCut, revenuePool, _buyer, _auction, _priceInToken, _referer);
        }

        // TODO: the math calculation needs further check
        //  not the first bid
        if (_auction.lastRecord > 0 && _auction.lastBidder != 0x0) {

            return _secondPartBid(auctionCut, refererCut, revenuePool, _buyer, _auction, _priceInToken, _referer);
        }

    }


    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) public onlyOwner {
        if (_token == 0x0) {
            owner.transfer(address(this).balance);
            return;
        }
    }

    /// @dev Computes owner's cut of a sale.
    /// @param _price - Sale price of NFT.
    function computeCut(uint256 _price, uint256 _cut) public pure returns (uint256) {
        // NOTE: We don't use SafeMath (or similar) in this function because
        //  all of our entry functions carefully cap the maximum values for
        //  currency (at 128-bits), and ownerCut <= 10000 (see the require()
        //  statement in the ClockAuction constructor). The result of this
        //  function is always guaranteed to be <= _price.
        return _price * _cut / 10000;
    }

    /// @dev Returns auction info for an NFT on auction.
    /// @param _tokenId - ID of NFT on auction.
    function getAuction(uint256 _tokenId)
    public
    view
    returns
    (
        address seller,
        uint256 startedAt,
        uint256 duration,
        uint256 startingPrice,
        uint256 endingPrice,
        address token,
        uint128 lastRecord,
        address lastBidder,
        uint256 lastBidStartAt,
        address lastReferer
    ) {
        Auction storage auction = tokenIdToAuction[_tokenId];
        return (
        auction.seller,
        auction.startingPriceInToken,
        auction.endingPriceInToken,
        auction.duration,
        auction.startedAt,
        auction.token,
        auction.lastRecord,
        auction.lastBidder,
        auction.lastBidStartAt,
        auction.lastReferer
        );
    }

    /// @dev Returns the current price of an auction.
    /// Returns current price of an NFT on auction. Broken into two
    ///  functions (this one, that computes the duration from the auction
    ///  structure, and the other that does the price computation) so we
    ///  can easily test that the price computation works correctly.
    /// @param _tokenId - ID of the token price we are checking.
    function getCurrentPriceInToken(uint256 _tokenId)
    public
    view
    returns (uint256)
    {
        uint256 secondsPassed = 0;

        // A bit of insurance against negative values (or wraparound).
        // Probably not necessary (since Ethereum guarnatees that the
        // now variable doesn't ever go backwards).
        if (now > tokenIdToAuction[_tokenId].startedAt) {
            secondsPassed = now - tokenIdToAuction[_tokenId].startedAt;
        }
        // if no one has bidden for _auction, compute the price as below.
        if (tokenIdToAuction[_tokenId].lastRecord == 0) {
            return _computeCurrentPriceInToken(
                tokenIdToAuction[_tokenId].startingPriceInToken,
                tokenIdToAuction[_tokenId].endingPriceInToken,
                tokenIdToAuction[_tokenId].duration,
                secondsPassed
            );
        } else {
            // compatible with first bid
            // as long as price_offered_by_buyer >= 1.1 * currentPice,
            // this buyer will be the lastBidder
            // 1.1 * (lastRecord)
            return (11 * (uint256(tokenIdToAuction[_tokenId].lastRecord)) / 10);
        }
    }

    // to apply for the safeTransferFrom
    function onERC721Received(
        address, //_operator,
        address, //_from,
        uint256 _tokenId,
        bytes //_data
    )
    public
    returns (bytes4) {
        // owner can put apostle on market
        // after coolDownEndTime
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    // get auction's price of last bidder offered
    // @dev return price of _auction (in RING)
    function getLastRecord(uint _tokenId) public view returns (uint256) {
        return tokenIdToAuction[_tokenId].lastRecord;
    }

    function getLastBidder(uint _tokenId) public view returns (address) {
        return tokenIdToAuction[_tokenId].lastBidder;
    }

    function getLastBidStartAt(uint _tokenId) public view returns (uint256) {
        return tokenIdToAuction[_tokenId].lastBidStartAt;
    }

    // @dev if someone new wants to bid, the lowest price he/she need to afford
    function computeNextBidRecord(uint _tokenId) public view returns (uint256) {
        return getCurrentPriceInToken(_tokenId);
    }

    /// @dev Creates and begins a new auction.
    /// @param _tokenId - ID of token to auction, sender must be owner.
    //  NOTE: change _startingPrice and _endingPrice in from wei to ring for user-friendly reason
    /// @param _startingPriceInToken - Price of item (in token) at beginning of auction.
    /// @param _endingPriceInToken - Price of item (in token) at end of auction.
    /// @param _duration - Length of time to move between starting
    ///  price and ending price (in seconds).
    /// @param _seller - Seller, if not the message sender
    function _createAuction(
        address _from,
        uint256 _tokenId,
        uint256 _startingPriceInToken,
        uint256 _endingPriceInToken,
        uint256 _duration,
        uint256 _startAt,
        address _seller,
        address _token
    )
    internal
    canBeStoredWith128Bits(_startingPriceInToken)
    canBeStoredWith128Bits(_endingPriceInToken)
    canBeStoredWith48Bits(_duration)
    canBeStoredWith48Bits(_startAt)
    whenNotPaused
    {
        // Require that all auctions have a duration of
        // at least one minute. (Keeps our math from getting hairy!)
        require(_duration >= 1 minutes, "duration must be at least 1 minutes");
        require(_duration <= 1000 days);
        require(IApostleBase(registry.addressOf(ApostleSettingIds.CONTRACT_APOSTLE_BASE)).isReadyToBreed(_tokenId), "it is still in use or have a baby to give birth.");
        // escrow
        ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)).safeTransferFrom(_from, this, _tokenId);

        tokenIdToAuction[_tokenId] = Auction({
            seller : _seller,
            startedAt : uint48(_startAt),
            duration : uint48(_duration),
            startingPriceInToken : uint128(_startingPriceInToken),
            endingPriceInToken : uint128(_endingPriceInToken),
            lastRecord : 0,
            token : _token,
            // which refer to lastRecord, lastBidder, lastBidStartAt,lastReferer
            // all set to zero when initialized
            lastBidder : address(0),
            lastBidStartAt : 0,
            lastReferer : address(0)
            });

        emit AuctionCreated(_tokenId, _seller, _startingPriceInToken, _endingPriceInToken, _duration, _token, _startAt);
    }

    /// @dev Computes the current price of an auction. Factored out
    ///  from _currentPrice so we can run extensive unit tests.
    ///  When testing, make this function public and turn on
    ///  `Current price computation` test suite.
    function _computeCurrentPriceInToken(
        uint256 _startingPriceInToken,
        uint256 _endingPriceInToken,
        uint256 _duration,
        uint256 _secondsPassed
    )
    internal
    pure
    returns (uint256)
    {
        // NOTE: We don't use SafeMath (or similar) in this function because
        //  all of our public functions carefully cap the maximum values for
        //  time (at 64-bits) and currency (at 128-bits). _duration is
        //  also known to be non-zero (see the require() statement in
        //  _addAuction())
        if (_secondsPassed >= _duration) {
            // We've reached the end of the dynamic pricing portion
            // of the auction, just return the end price.
            return _endingPriceInToken;
        } else {
            // Starting price can be higher than ending price (and often is!), so
            // this delta can be negative.
            int256 totalPriceInTokenChange = int256(_endingPriceInToken) - int256(_startingPriceInToken);

            // This multiplication can't overflow, _secondsPassed will easily fit within
            // 64-bits, and totalPriceChange will easily fit within 128-bits, their product
            // will always fit within 256-bits.
            int256 currentPriceInTokenChange = totalPriceInTokenChange * int256(_secondsPassed) / int256(_duration);

            // currentPriceChange can be negative, but if so, will have a magnitude
            // less that _startingPrice. Thus, this result will always end up positive.
            int256 currentPriceInToken = int256(_startingPriceInToken) + currentPriceInTokenChange;

            return uint256(currentPriceInToken);
        }
    }


    function toBytes(address x) public pure returns (bytes b) {
        b = new bytes(32);
        assembly {mstore(add(b, 32), x)}
    }
}