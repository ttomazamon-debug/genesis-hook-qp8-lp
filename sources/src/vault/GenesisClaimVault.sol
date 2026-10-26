// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract GenesisClaimVault is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error GenesisVault_Unauthorized();
    error GenesisVault_ZeroAddress();
    error GenesisVault_InvalidToken();
    error GenesisVault_InsufficientBalance();

    address public immutable genesisHook;
    address public operator;

    mapping(uint256 => address) public tokenOfCurrencyId;

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event TokenMapped(uint256 indexed currencyId, address indexed token);
    event Funded(address indexed from, address indexed token, uint256 amount, uint256 indexed currencyId);
    event Payout(address indexed to, address indexed token, uint256 amount, uint256 indexed currencyId);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyHook() {
        if (msg.sender != genesisHook) revert GenesisVault_Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert GenesisVault_Unauthorized();
        _;
    }

    constructor(address _genesisHook, address _operator) {
        if (_genesisHook == address(0) || _operator == address(0)) {
            revert GenesisVault_ZeroAddress();
        }

        genesisHook = _genesisHook;
        operator = _operator;
    }

    function setOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert GenesisVault_ZeroAddress();

        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function setTokenForCurrency(uint256 currencyId, address token) external onlyOperator {
        if (token == address(0)) revert GenesisVault_ZeroAddress();

        tokenOfCurrencyId[currencyId] = token;

        emit TokenMapped(currencyId, token);
    }

    function pause() external onlyOperator {
        _pause();
    }

    function unpause() external onlyOperator {
        _unpause();
    }

    function fund(uint256 currencyId, uint256 amount) external onlyOperator nonReentrant whenNotPaused {
        address token = tokenOfCurrencyId[currencyId];
        if (token == address(0)) revert GenesisVault_InvalidToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Funded(msg.sender, token, amount, currencyId);
    }

    function payout(address to, uint256 amount, uint256 currencyId) external onlyHook nonReentrant whenNotPaused {
        if (to == address(0)) revert GenesisVault_ZeroAddress();

        address token = tokenOfCurrencyId[currencyId];
        if (token == address(0)) revert GenesisVault_InvalidToken();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) revert GenesisVault_InsufficientBalance();

        IERC20(token).safeTransfer(to, amount);

        emit Payout(to, token, amount, currencyId);
    }

    function tokenBalance(uint256 currencyId) external view returns (uint256) {
        address token = tokenOfCurrencyId[currencyId];
        if (token == address(0)) return 0;

        return IERC20(token).balanceOf(address(this));
    }

    function rescue(address token, address to, uint256 amount) external onlyOperator nonReentrant {
        if (token == address(0) || to == address(0)) revert GenesisVault_ZeroAddress();

        IERC20(token).safeTransfer(to, amount);

        emit Rescued(token, to, amount);
    }
}
