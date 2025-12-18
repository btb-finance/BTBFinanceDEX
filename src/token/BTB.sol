// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title BTB Finance Token
/// @author BTB Finance
/// @notice ERC20 governance token with vote delegation, permit, and controlled minting
/// @dev Uses UUPS upgradeable pattern. Minter role for emission control.
contract BTB is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMinter();
    error ZeroAddress();
    error MaxSupplyExceeded();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterSet(address indexed oldMinter, address indexed newMinter);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address authorized to mint new tokens (typically the Minter contract)
    address public minter;

    /// @notice Maximum supply cap (1 billion tokens)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the BTB token
    /// @param initialOwner The initial owner address (receives initial supply)
    /// @param initialMinter The initial minter address
    function initialize(address initialOwner, address initialMinter) public initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        __ERC20_init("BTB Finance", "BTB");
        __ERC20Burnable_init();
        __ERC20Permit_init("BTB Finance");
        __ERC20Votes_init();
        __Ownable_init(initialOwner);

        minter = initialMinter;
        emit MinterSet(address(0), initialMinter);
    }

    /*//////////////////////////////////////////////////////////////
                            MINTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint new tokens (only callable by minter)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    /// @notice Set the minter address
    /// @param newMinter New minter address
    function setMinter(address newMinter) external onlyOwner {
        address oldMinter = minter;
        minter = newMinter;
        emit MinterSet(oldMinter, newMinter);
    }

    /*//////////////////////////////////////////////////////////////
                           REQUIRED OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                              CLOCK MODE
    //////////////////////////////////////////////////////////////*/

    /// @dev Use block.timestamp for voting snapshots
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev Clock mode is timestamp-based
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
