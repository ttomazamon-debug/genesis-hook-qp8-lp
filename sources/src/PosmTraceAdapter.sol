// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RealPoolTraceAdapter} from "src/RealPoolTraceAdapter.sol";
import {GenesisLpClaimsPrototype} from "src/GenesisLpClaimsPrototype.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId,PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IReviewPosm {
    function ownerOf(uint256 tokenId) external view returns(address);
    function subscriber(uint256 tokenId) external view returns(address);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns(PoolKey memory,uint256);
}
contract ReviewLedgerFactory {
    function create(address authority,address nft) external returns(GenesisLpClaimsPrototype){
        require(msg.sender==authority);return new GenesisLpClaimsPrototype(authority,nft);
    }
}

/// @notice LP trace and ownership adapter for the pinned Uniswap PositionManager.
/// Positive-liquidity native burn requires subscription to this adapter.
/// No owner is accepted from hookData, msgSender, or an untrusted backend.
contract PosmTraceAdapter is RealPoolTraceAdapter {
    using PoolIdLibrary for PoolKey;using StateLibrary for IPoolManager;
    ReviewLedgerFactory public immutable factory;
    uint256 transient private closingId;
    uint128 transient private closingLiquidity;
    mapping(uint256=>bool) public autoClaim;
    event ClaimDeferred(uint256 indexed tokenId,address indexed owner);
    error BurnSubscriptionRequired();error InvalidBurnNotification();
    constructor(IPoolManager pm,address posm,ReviewLedgerFactory f,address hook_,address ctl_) RealPoolTraceAdapter(pm,posm,hook_,ctl_){factory=f;}
    function _createLedger() internal override returns(GenesisLpClaimsPrototype){return factory.create(address(this),nft);}
    function setAutoClaim(uint256 tokenId,bool enabled) external {
        if(IReviewPosm(nft).ownerOf(tokenId)!=msg.sender)revert Unauthorized();
        if(enabled&&IReviewPosm(nft).subscriber(tokenId)!=address(this))revert BurnSubscriptionRequired();
        autoClaim[tokenId]=enabled;
    }
    function _change(address sender,PoolKey memory key,IPoolManager.ModifyLiquidityParams calldata p) internal override {
        _key(key);if(sender!=nft)revert Unauthorized();
        uint256 id=uint256(p.salt);(uint128 old,,)=manager.getPositionInfo(key.toId(),sender,p.tickLower,p.tickUpper,p.salt);
        address owner;try IReviewPosm(nft).ownerOf(id) returns(address got){owner=got;}catch{}
        if(owner==address(0)){
            if(old==0||p.liquidityDelta!=-int256(uint256(old))||closingId!=0||IReviewPosm(nft).subscriber(id)!=address(this))revert BurnSubscriptionRequired();
            closingId=id;closingLiquidity=old;ledger.beginVerifiedBurn(pid,id,p.tickLower,p.tickUpper);
        }else{
            int256 next=int256(uint256(old))+p.liquidityDelta;
            if(next<0||uint256(next)>uint256(uint128(type(int128).max)))revert InvalidTrace();
            ledger.change(pid,id,p.tickLower,p.tickUpper,uint128(uint256(next)));
        }
    }
    modifier onlyPosm(){if(msg.sender!=nft)revert Unauthorized();_;}
    function notifySubscribe(uint256 tokenId,bytes calldata) external onlyPosm {
        (PoolKey memory key,)=IReviewPosm(nft).getPoolAndPositionInfo(tokenId);
        if(PoolId.unwrap(key.toId())!=pid||IReviewPosm(nft).ownerOf(tokenId)==address(0))revert InvalidTrace();
    }
    function notifyUnsubscribe(uint256 tokenId) external onlyPosm {delete autoClaim[tokenId];}
    function _payOptional(uint256 tokenId,address owner,bool live) internal {
        if(!autoClaim[tokenId])return;
        if(live){try ledger.claimFor(pid,tokenId){}catch{emit ClaimDeferred(tokenId,owner);}}
        try ledger.claimClosedFor(pid,owner){}catch{emit ClaimDeferred(tokenId,owner);}
    }
    function notifyModifyLiquidity(uint256 tokenId,int256,BalanceDelta) external onlyPosm {
        _payOptional(tokenId,IReviewPosm(nft).ownerOf(tokenId),true);
    }
    // uint256 is the ABI underlying type of PositionInfo in the pinned PosM.
    function notifyBurn(uint256 tokenId,address owner,uint256,uint256 liquidity,BalanceDelta) external onlyPosm {
        if(owner==address(0))revert InvalidBurnNotification();
        if(liquidity!=0){
            if(closingId!=tokenId||closingLiquidity!=liquidity)revert InvalidBurnNotification();
            closingId=0;closingLiquidity=0;ledger.finalizeVerifiedBurn(pid,tokenId,owner);
        }else if(closingId!=0)revert InvalidBurnNotification();
        _payOptional(tokenId,owner,false);delete autoClaim[tokenId];
    }
}
