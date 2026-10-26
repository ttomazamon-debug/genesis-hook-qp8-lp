// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface used by the vault. Kept local to avoid
///         repository-dependent OpenZeppelin import paths. Named to avoid a
///         source-unit symbol collision with the IERC20Minimal declared in
///         GenesisHookV5.sol.
interface IGenesisVaultERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal controller surface for on-chain surplus enforcement of rescue.
interface IGenesisReserveReporter {
    function reservedObligations(address token) external view returns (uint256);
}

/// @title GenesisVaultV2
/// @notice Physical custody for the Phase 3C/4 Model A non-trader economics.
///
/// During atomic hook realization the frozen GenesisHookV5 moves the full
/// distributable D out of itself: the trader share to the PoolManager, and the
/// non-trader share (LP + protocol + router + keeper + dust) to THIS vault, via a
/// plain ERC-20 transfer to this address — the hook never calls into the vault.
/// GenesisRewardsController ledgers obligations against the vault and later calls
/// pay() to release them; it reads available() for surplus checks.
///
/// The vault is a simple custody + payment contract. It holds NO economics, no
/// accounting mirror of controller obligations, no upgradeability, no delegatecall,
/// no ETH custody, no allowlists, no fees. Authority:
///   owner (Safe): binds the controller once, pauses payouts, transfers ownership,
///                 and rescues ONLY true surplus (never reserved obligations).
///   controller  : the sole caller of pay(); bound once, never replaced.
contract GenesisVaultV2 {
    address private _owner;
    address private _controller;
    bool private _paused;
    uint256 private _lock = 1;

    event ControllerBound(address indexed controller);
    event Paid(address indexed token, address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SurplusRescued(address indexed token, address indexed to, uint256 amount);

    error Unauthorized();
    error ZeroAddress();
    error InvalidToken();
    error InvalidController();
    error ControllerAlreadyBound();
    error ControllerNotBound();
    error Paused();
    error InsufficientBalance();
    error TransferFailed();
    error Reentrancy();
    error InsufficientSurplus();

    /// @dev Guard placed OUTERMOST on state-changing token paths so a malicious token
    ///      callback trips the reentrancy lock before any alternate check can mask it.
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert Unauthorized();
        _;
    }

    modifier onlyController() {
        if (msg.sender != _controller) revert Unauthorized();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function owner() external view returns (address) {
        return _owner;
    }

    function controller() external view returns (address) {
        return _controller;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice Physical balance of `token` held by the vault.
    function available(address token) external view returns (uint256) {
        _validToken(token);
        return IGenesisVaultERC20(token).balanceOf(address(this));
    }

    // ── controller binding (one-time) ─────────────────────────────────────

    /// @notice Bind the sole payer ONCE. Custody authority can never be repointed;
    ///         replacing the controller requires a new vault.
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        if (controller_.code.length == 0) revert InvalidController();
        if (_controller != address(0)) revert ControllerAlreadyBound();
        _controller = controller_;
        emit ControllerBound(controller_);
    }

    // ── custody payout (controller-only) ──────────────────────────────────

    /// @notice Release `amount` of `token` to `to`. Controller-only, non-reentrant,
    ///         blocked while paused. A zero amount is an explicit no-op (still emits).
    ///         Reverts on insufficient physical balance or a failed transfer, which
    ///         rolls back the controller's withdrawal or the hook's atomic unit.
    function pay(address token, address to, uint256 amount) external nonReentrant onlyController {
        if (_paused) revert Paused();
        _validToken(token);
        if (to == address(0)) revert ZeroAddress();

        if (amount == 0) {
            emit Paid(token, to, 0);
            return;
        }

        if (IGenesisVaultERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();
        _safeTransfer(token, to, amount);
        emit Paid(token, to, amount);
    }

    // ── owner controls ────────────────────────────────────────────────────

    /// @notice Pause/unpause outgoing payments. Never affects incoming transfers.
    function setPaused(bool paused_) external onlyOwner {
        _paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Rescue TRUE SURPLUS only: physical balance minus the controller's
    ///         on-chain reserved obligations for the token. Reserved custody backing
    ///         live obligations can never be withdrawn. Break-glass, owner-only.
    /// @dev Rescue intentionally remains available while paused: it is owner-only and
    ///      strictly limited to physical surplus above the controller-reported reserved
    ///      obligations, so it can never touch funds backing live obligations regardless
    ///      of pause state. Pausing gates controller payouts, not this bounded owner path.
    function rescueSurplus(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (_controller == address(0)) revert ControllerNotBound();
        _validToken(token);
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = IGenesisVaultERC20(token).balanceOf(address(this));
        uint256 reserved = IGenesisReserveReporter(_controller).reservedObligations(token);
        uint256 surplus = bal > reserved ? bal - reserved : 0;
        if (amount > surplus) revert InsufficientSurplus();

        if (amount == 0) {
            emit SurplusRescued(token, to, 0);
            return;
        }

        _safeTransfer(token, to, amount);
        emit SurplusRescued(token, to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    // ── internal ──────────────────────────────────────────────────────────

    /// @dev A low-level call to a codeless address returns success with empty data,
    ///      which would emit a false Paid event. Reject non-contract tokens.
    function _validToken(address token) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert InvalidToken();
    }

    /// @dev SafeERC20-style transfer with strict return-data handling:
    ///        failed / reverted call                 -> TransferFailed
    ///        empty return data                       -> success (non-standard ERC-20)
    ///        exactly 32 bytes, value == 1            -> success
    ///        exactly 32 bytes, value == 0            -> TransferFailed
    ///        exactly 32 bytes, any other value       -> TransferFailed
    ///        any other return length                 -> TransferFailed
    ///      The 32-byte word is read with assembly and required to equal exactly 1, so
    ///      malformed boolean return data produces TransferFailed rather than an opaque
    ///      abi.decode revert. Token is pre-validated as a contract, so empty returndata
    ///      reflects a real no-return ERC-20 rather than a codeless address.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IGenesisVaultERC20.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();

        uint256 len = ret.length;
        if (len == 0) return; // non-standard ERC-20 that returns nothing

        if (len != 32) revert TransferFailed();
        uint256 word;
        assembly {
            word := mload(add(ret, 0x20))
        }
        if (word != 1) revert TransferFailed();
    }
}
