pragma solidity ^0.4.24;
import "./ApostleSettingIds.sol";
import "../common/interfaces/ISettingsRegistry.sol";
import "./interfaces/IApostleAuction.sol";
import "./interfaces/IApostleBase.sol";
import "../common/ERC721.sol";
import "../common/PausableDSAuth.sol";

contract Gen0Apostle is PausableDSAuth, ApostleSettingIds {
    // claimedToken event
    event ClaimedTokens(address indexed token, address indexed owner, uint amount);
    event ClaimedERC721Token(address indexed owner, uint256 tokenId);
    event TakeOut(uint256 tokenId);

    bool private singletonLock = false;

    uint256 public gen0CreationLimit;

    ISettingsRegistry public registry;

    address public operator;

    uint256 public gen0Count;
    /*
     * Modifiers
     */
    modifier singletonLockCall() {
        require(!singletonLock, "Only can call once");
        _;
        singletonLock = true;
    }

    function initializeContract(ISettingsRegistry _registry, uint _gen0Limit) public singletonLockCall {
        owner = msg.sender;
        emit LogSetOwner(msg.sender);

        registry = _registry;
        gen0CreationLimit = _gen0Limit;
    }


    function createGen0Apostle(uint256 _genes, uint256 _talents, address _owner) public {
        require(operator == msg.sender, "you have no rights");
        require(gen0Count + 1 <= gen0CreationLimit, "Exceed Generation Limit");
        IApostleBase apostleBase = IApostleBase(registry.addressOf(CONTRACT_APOSTLE_BASE));
        apostleBase.createApostle(0, 0, 0, _genes, _talents, _owner);
        gen0Count++;
    }

    function createGen0Auction(
        uint256 _tokenId,
        uint256 _startingPriceInToken,
        uint256 _endingPriceInToken,
        uint256 _duration,
        uint256 _startAt,
        address _token)
    public {
        require(operator == msg.sender, "you have no rights");
        IApostleAuction auction = IApostleAuction(registry.addressOf(ApostleSettingIds.CONTRACT_APOSTLE_AUCTION));

        // aprove land to auction contract
        ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)).approve(address(auction), _tokenId);
        // create an auciton
        // have to set _seller to this
        auction.createAuction(_tokenId,_startingPriceInToken, _endingPriceInToken, _duration,_startAt, _token);

    }

    function cancelAuction(uint256 _tokenId) public onlyOwner {
        IApostleAuction auction = IApostleAuction(registry.addressOf(ApostleSettingIds.CONTRACT_APOSTLE_AUCTION));
        auction.cancelAuction(_tokenId);
    }

    function setOperator(address _operator) public onlyOwner {
        operator = _operator;
    }

    function () payable public {
        //address revenuePool = registry.addressOf(CONTRACT_REVENUE_POOL);
        //revenuePool.transfer(msg.value);
    }

    // to apply for the safeTransferFrom
    function onERC721Received(
        address, //_operator,
        address, //_from,
        uint256, // _tokenId,
        bytes //_data
    )
    public
    returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
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

    function claimERC721Tokens(uint256 _tokenId) public onlyOwner {
        ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP)).transferFrom(address(this), owner, _tokenId);

        emit ClaimedERC721Token(owner, _tokenId);
    }

    function setApproval(address _operator, bool _isApproved) public onlyOwner {
        ERC721 nft = ERC721(registry.addressOf(SettingIds.CONTRACT_OBJECT_OWNERSHIP));
        nft.setApprovalForAll(_operator, _isApproved);
    }

}