// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

//  ==========  External imports    ==========
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

//  ==========  Internal imports    ==========

import "../interfaces/IThirdwebContract.sol";
import "../feature/interface/IRoyalty.sol";
import "../feature/interface/IOwnable.sol";

import "../interfaces/IMultiwrap.sol";
import "../lib/CurrencyTransferLib.sol";
import "../openzeppelin-presets/metatx/ERC2771ContextUpgradeable.sol";

//  ==========  Features    ==========

import "../feature/ContractMetadata.sol";
import "../feature/Royalty.sol";
import "../feature/Ownable.sol";
import "../feature/PermissionsEnumerable.sol";
import "../feature/TokenStore.sol";

contract Multiwrap is
    Initializable,
    ContractMetadata,
    Royalty,
    Ownable,
    PermissionsEnumerable,
    TokenStore,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    MulticallUpgradeable,
    ERC721Upgradeable,
    IMultiwrap
{
    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant MODULE_TYPE = bytes32("Multiwrap");
    uint256 private constant VERSION = 1;

    /// @dev Only transfers to or from TRANSFER_ROLE holders are valid, when transfers are restricted.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can wrap tokens, when wrapping is restricted.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @dev Only UNWRAP_ROLE holders can unwrap tokens, when unwrapping is restricted.
    bytes32 private constant UNWRAP_ROLE = keccak256("UNWRAP_ROLE");

    /// @dev The next token ID of the NFT to mint.
    uint256 public nextTokenIdToMint;

    /*///////////////////////////////////////////////////////////////
                    Constructor + initializer logic
    //////////////////////////////////////////////////////////////*/

    constructor(address _nativeTokenWrapper) TokenStore(_nativeTokenWrapper) initializer {}

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _royaltyRecipient,
        uint256 _royaltyBps
    ) external initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ReentrancyGuard_init();
        __ERC2771Context_init(_trustedForwarders);
        __ERC721_init(_name, _symbol);

        // _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // // Initialize this contract's state.
        // royaltyRecipient = _royaltyRecipient;
        // royaltyBps = uint128(_royaltyBps);
        // contractURI = _contractURI;
        // _owner = _defaultAdmin;

        // _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        // _setupRole(MINTER_ROLE, _defaultAdmin);
        // _setupRole(TRANSFER_ROLE, _defaultAdmin);
        // _setupRole(TRANSFER_ROLE, address(0));
        // _setupRole(UNWRAP_ROLE, address(0));

        // _revokeRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*///////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyMinter() {
        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(MINTER_ROLE, address(0))) {
            require(hasRole(MINTER_ROLE, _msgSender()), "restricted to MINTER_ROLE holders.");
        }

        _;
    }

    /*///////////////////////////////////////////////////////////////
                        Generic contract logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 721 / 2981 logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the URI for a given tokenId.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        return getUriOfBundle(_tokenId);
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Receiver, ERC721Upgradeable)
        returns (bool)
    {
        return
            super.supportsInterface(interfaceId) ||
            interfaceId == type(IERC721Upgradeable).interfaceId ||
            interfaceId == type(IERC2981Upgradeable).interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                    Wrapping / Unwrapping logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Wrap multiple ERC1155, ERC721, ERC20 tokens into a single wrapped NFT.
    function wrap(
        Token[] calldata _wrappedContents,
        string calldata _uriForWrappedToken,
        address _recipient
    ) external payable nonReentrant onlyMinter returns (uint256 tokenId) {
        
        tokenId = nextTokenIdToMint;
        nextTokenIdToMint += 1;

        _storeTokens(_msgSender(), _wrappedContents, _uriForWrappedToken, tokenId);

        _safeMint(_recipient, tokenId);

        emit TokensWrapped(_msgSender(), _recipient, tokenId, _wrappedContents);
    }

    /// @dev Unwrap a wrapped NFT to retrieve underlying ERC1155, ERC721, ERC20 tokens.
    function unwrap(uint256 _tokenId, address _recipient) external nonReentrant {
        
        require(_tokenId < nextTokenIdToMint, "invalid tokenId");
        require(_isApprovedOrOwner(_msgSender(), _tokenId), "unapproved called");
        require(hasRole(UNWRAP_ROLE, address(0)) || hasRole(UNWRAP_ROLE, _msgSender()), "!UNWRAP_ROLE");

        _burn(_tokenId);
        _releaseTokens(_recipient, _tokenId);

        emit TokensUnwrapped(_msgSender(), _recipient, _tokenId);
    }

    /*///////////////////////////////////////////////////////////////
                        Getter functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the underlygin contents of a wrapped NFT.
    function getWrappedContents(uint256 _tokenId) external view returns (Token[] memory contents) {
        uint256 total = getTokenCountOfBundle(_tokenId);
        contents = new Token[](total);

        for (uint256 i = 0; i < total; i += 1) {
            contents[i] = getTokenOfBundle(_tokenId, i);
        }
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {ERC721-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            require(hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to), "restricted to TRANSFER_ROLE holders.");
        }
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}
