// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardsControllerSettable {
    function setRewardsController(address next) external;
}

/// @title GenesisControllerGovernor
/// @notice The 48-hour timelock for rewards-controller replacement, moved OUT of
///         GenesisHookV5 (Phase 3B size optimization, Option A).
///
/// The hook holds `immutable controllerGovernor == address(this)` and accepts
/// setRewardsController() from this contract ONLY. The delay therefore lives
/// here rather than being duplicated in the hook's bytecode.
///
/// ── SECURITY PROPERTIES PRESERVED FROM THE HOOK-NATIVE TIMELOCK ───────────
///  • no instant operator replacement — every change waits DELAY
///  • anti-V6: the controller remains replaceable, so a controller bug never
///    forces a hook redeploy
///  • zero-address unbind is explicit and still timelocked
///  • no generic arbitrary-call logic: this contract can call exactly one
///    function on exactly one target, both fixed at construction
///
/// Owner should be the Safe (0xF84D2025cE5fBe87Ff78951383befE5693169e23).
contract GenesisControllerGovernor {
    uint256 public constant DELAY = 48 hours;

    address public immutable hook;
    address public owner;

    address public pendingController;
    uint256 public eta;
    bool public scheduled; // distinguishes "scheduled to address(0)" from "nothing scheduled"

    event ControllerChangeScheduled(address indexed controller, uint256 eta);
    event ControllerChangeExecuted(address indexed controller);
    event ControllerChangeCancelled(address indexed controller);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    error Unauthorized();
    error NothingScheduled();
    error AlreadyScheduled();
    error NotReady();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _hook, address _owner) {
        if (_hook == address(0) || _owner == address(0)) revert ZeroAddress();
        hook = _hook;
        owner = _owner;
    }

    /// @notice Schedule a controller change. `next == address(0)` is the explicit
    ///         unbind path (rewards permanently off until re-bound via a new schedule).
    function schedule(address next) external onlyOwner {
        if (scheduled) revert AlreadyScheduled();
        pendingController = next;
        eta = block.timestamp + DELAY;
        scheduled = true;
        emit ControllerChangeScheduled(next, eta);
    }

    function cancel() external onlyOwner {
        if (!scheduled) revert NothingScheduled();
        address cancelled = pendingController;
        pendingController = address(0);
        eta = 0;
        scheduled = false;
        emit ControllerChangeCancelled(cancelled);
    }

    function execute() external onlyOwner {
        if (!scheduled) revert NothingScheduled();
        if (block.timestamp < eta) revert NotReady();

        address next = pendingController;
        pendingController = address(0);
        eta = 0;
        scheduled = false;

        IRewardsControllerSettable(hook).setRewardsController(next);
        emit ControllerChangeExecuted(next);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }
}
