// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {GenesisLpClaimsPrototype} from "src/GenesisLpClaimsPrototype.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId,PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ITraceNft {function ownerOf(uint256) external view returns(address);}
interface ITraceRouter {function currentOwner() external view returns(address);}
interface ITraceToken {function approve(address,uint256) external returns(bool);}
interface ITraceHookController {function rewardsController() external view returns(address);}

/// @notice Single-pool native pre/post swap trace and LP index synchronization.
/// PosmTraceAdapter supplies the pinned native PositionManager ownership integration.
/// The base implementation uses a liquidity-router/NFT-registry interface for tests.
/// Reward finalization is authorized by the bound hook current rewardsController.
/// Uses a revert-only native swap probe to discover the exact path endpoint.
/// No artificial tick/word cap; work/gas grow with actual path complexity.
/// Historical transient namespace encodings are intentionally unchanged.
contract RealPoolTraceAdapter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address public immutable boundHook;
    /// @notice Deployment provenance only; authorization follows the bound hook.
    address public immutable initialController;
    PoolKey private configuredKey;
    IPoolManager public immutable manager;
    address public immutable admin;
    address public immutable nft;
    GenesisLpClaimsPrototype public ledger;
    bytes32 public pid;
    address public liquidityRouter;
    uint256 public nextReward;
    uint256 public nonce;
    uint256 public lastWeight;
    uint256 public lastDenominator;
    int24[] public lastCrosses;
    uint256[] public lastFeeGrowth;
    int24 public lastStart;
    int24 public lastEnd;
    uint256 public lastCandidateCount;
    bool public diagnostics;
    uint256 constant TAG=uint256(keccak256("GENESIS_RESEARCH_TRACE_V1"));
    error Unauthorized();error InvalidTrace();error ProbeEndTick(int24 tick);
    modifier onlyManager(){if(msg.sender!=boundHook)revert Unauthorized();_;}
    constructor(IPoolManager manager_,address nft_,address hook_,address controller_){manager=manager_;nft=nft_;admin=msg.sender;boundHook=hook_;initialController=controller_;}
    /// @notice The hook's existing governor controls replacement and unbinding.
    /// No separate adapter admin can authorize a funding controller.
    function controller() public view returns(address){return ITraceHookController(boundHook).rewardsController();}
    function configure(PoolKey memory key,address router) external {
        if(msg.sender!=admin||address(ledger)!=address(0)||address(key.hooks)!=boundHook)revert Unauthorized();
        (uint160 sqrt,int24 tick,,)=manager.getSlot0(key.toId());require(sqrt!=0&&manager.getLiquidity(key.toId())==0);
        pid=PoolId.unwrap(key.toId());liquidityRouter=router;configuredKey=key;
        ledger=_createLedger();
        ledger.register(pid,Currency.unwrap(key.currency0),Currency.unwrap(key.currency1),tick);
        diagnostics=true;
        require(ITraceToken(Currency.unwrap(key.currency0)).approve(address(ledger),type(uint256).max));
        require(ITraceToken(Currency.unwrap(key.currency1)).approve(address(ledger),type(uint256).max));
    }
    function _createLedger() internal virtual returns(GenesisLpClaimsPrototype){return new GenesisLpClaimsPrototype(address(this),nft);}

    function setDiagnostics(bool enabled) external {if(msg.sender!=admin)revert Unauthorized();diagnostics=enabled;}
    function probe(PoolKey memory key,IPoolManager.SwapParams calldata params) external {
        if(msg.sender!=address(this))revert Unauthorized();
        // Core skips callbacks for calls originating from the pool's own hook.
        // Reverting this frame rolls back swap state, deltas and logs.
        (bool ok,bytes memory reason)=boundHook.call(abi.encodeWithSignature(
            "researchLpProbe((address,address,uint24,int24,address),(bool,int256,uint160),uint24)",key,params,uint24(_get(9))));
        if(ok)revert InvalidTrace();
        if(reason.length==36&&bytes4(reason)==bytes4(keccak256("ResearchLpEndTick(int24)"))){
            int256 end;assembly("memory-safe"){end:=mload(add(reason,36))}revert ProbeEndTick(int24(end));
        }
        assembly("memory-safe"){revert(add(reason,32),mload(reason))}
    }
    function _project(PoolKey memory key,IPoolManager.SwapParams calldata params) internal returns(int24 tick){
        try this.probe(key,params){revert InvalidTrace();}
        catch(bytes memory reason){
            if(reason.length!=36||bytes4(reason)!=ProbeEndTick.selector){assembly("memory-safe"){revert(add(reason,32),mload(reason))}}
            int256 value;assembly("memory-safe"){value:=mload(add(reason,36))}
            tick=int24(value);if(value!=int256(tick))revert InvalidTrace();
        }
    }
    function _put(uint256 off,uint256 value) internal {uint256 slot=TAG+off;assembly("memory-safe"){tstore(slot,value)}}
    function _get(uint256 off) internal view returns(uint256 value){uint256 slot=TAG+off;assembly("memory-safe"){value:=tload(slot)}}
    function _int(int256 value) internal pure returns(uint256){return uint256(value);}
    function _key(PoolKey memory key) internal view {if(PoolId.unwrap(key.toId())!=pid)revert InvalidTrace();}
    function _change(address sender,PoolKey memory key,IPoolManager.ModifyLiquidityParams calldata p) internal virtual {
        _key(key);uint256 id=uint256(p.salt);
        if(sender!=liquidityRouter||ITraceRouter(sender).currentOwner()!=ITraceNft(nft).ownerOf(id))revert Unauthorized();
        (uint128 old,,)=manager.getPositionInfo(key.toId(),sender,p.tickLower,p.tickUpper,p.salt);
        int256 afterL=int256(uint256(old))+p.liquidityDelta;
        if(afterL<0||uint256(afterL)>uint256(uint128(type(int128).max)))revert InvalidTrace();
        ledger.change(pid,id,p.tickLower,p.tickUpper,uint128(uint256(afterL)));
    }
    function beforeAddLiquidity(address sender,PoolKey memory key,IPoolManager.ModifyLiquidityParams calldata p,bytes calldata) external onlyManager returns(bytes4){
        _change(sender,key,p);return IHooks.beforeAddLiquidity.selector;
    }
    function beforeRemoveLiquidity(address sender,PoolKey memory key,IPoolManager.ModifyLiquidityParams calldata p,bytes calldata) external onlyManager returns(bytes4){
        _change(sender,key,p);return IHooks.beforeRemoveLiquidity.selector;
    }
    function captureBefore(PoolKey memory key,IPoolManager.SwapParams calldata params,uint24 selectedFee,bool mayReward) external onlyManager {
        _key(key);if(_get(0)!=0)revert InvalidTrace();
        (,int24 start,,)=manager.getSlot0(key.toId());uint128 startL=manager.getLiquidity(key.toId());
        (int24 known,uint128 knownL,,)=ledger.poolState(pid);
        if(start!=known||startL!=knownL)revert InvalidTrace();
        _put(0,1);_put(1,_int(start));_put(2,startL);
        // Bound hook derives this necessary condition from the exact cached
        // external snapshot used by ROFR. False NEVER skips historical crossings.
        _put(8,mayReward?1:0);_put(10,params.zeroForOne?1:0);
        if(!mayReward)return;
        _put(9,selectedFee);
        (uint256 g0,uint256 g1)=manager.getFeeGrowthGlobals(key.toId());_put(3,g0);_put(4,g1);
        int24 projected=_project(key,params);
        if(params.zeroForOne?projected>start:projected<start)revert InvalidTrace();_put(6,_int(projected));
        _scan(key,params.zeroForOne,start,projected,true);

    }
    function _scan(PoolKey memory key,bool zeroForOne,int24 start,int24 projected,bool fees) internal {
        int24 compressed=start/key.tickSpacing;if(start<0&&start%key.tickSpacing!=0)--compressed;
        if(!zeroForOne)++compressed;
        int24 last=projected/key.tickSpacing;if(projected<0&&projected%key.tickSpacing!=0)--last;
        if(zeroForOne)++last;
        int16 first=int16(compressed>>8);int16 finalWord=int16(last>>8);
        uint8 bit=uint8(uint24(compressed));uint8 lastBit=uint8(uint24(last));uint256 count;
        bool search=zeroForOne?compressed>=last:compressed<=last;
        uint256 words=search?uint256(zeroForOne?int256(first)-int256(finalWord)+1:int256(finalWord)-int256(first)+1):0;
        for(uint256 w;w<words;++w){
            int16 wordPos=zeroForOne?first-int16(uint16(w)):first+int16(uint16(w));
            uint256 bitmap=manager.getTickBitmap(key.toId(),wordPos);
            if(w==0){
                if(zeroForOne)bitmap&=type(uint256).max>>(255-bit);
                else bitmap&=type(uint256).max<<bit;
            }
            if(wordPos==finalWord){
                if(zeroForOne)bitmap&=type(uint256).max<<lastBit;
                else bitmap&=type(uint256).max>>(255-lastBit);
            }
            while(bitmap!=0){
                uint8 index=zeroForOne?BitMath.mostSignificantBit(bitmap):BitMath.leastSignificantBit(bitmap);
                bitmap^=uint256(1)<<index;
                int24 tick=int24((int256(wordPos)*256+int256(uint256(index)))*key.tickSpacing);
                uint128 gross;int128 net;uint256 o0;uint256 o1;
                if(fees)(gross,net,o0,o1)=manager.getTickInfo(key.toId(),tick);
                else(gross,net)=manager.getTickLiquidity(key.toId(),tick);
                if(gross==0)revert InvalidTrace();
                uint256 off=16+count*4;_put(off,_int(tick));_put(off+1,_int(net));
                if(fees){_put(off+2,o0);_put(off+3,o1);}++count;
            }
        }
        _put(5,count);
    }
    function finalizeReward(address token,uint256 amount) external {
        if(_get(0)!=1||amount==0)revert Unauthorized();
        address activeController=controller();
        if(activeController==address(0)||msg.sender!=activeController)revert Unauthorized();
        bool direction=_get(10)!=0;
        if(token!=Currency.unwrap(direction?configuredKey.currency1:configuredKey.currency0))revert InvalidTrace();
        _finish(configuredKey,direction,amount);
    }
    function finishEmpty(PoolKey memory key,bool direction) external onlyManager {
        if(_get(0)==0)return;
        if(direction!=(_get(10)!=0))revert InvalidTrace();
        _finish(key,direction,0);
    }
    function _finish(PoolKey memory key,bool zeroForOne,uint256 amount) internal {
        _key(key);if(_get(0)!=1)revert InvalidTrace();
        int24 start=int24(int256(_get(1)));uint128 startL=uint128(_get(2));
        (,int24 end,,)=manager.getSlot0(key.toId());
        if(zeroForOne?end>start:end<start)revert InvalidTrace();
        bool rewardPath=_get(8)!=0;uint256 g0;uint256 g1;uint256 previous;uint8 input=zeroForOne?0:1;
        if(rewardPath){
            if(end!=int24(int256(_get(6))))revert InvalidTrace();
            (g0,g1)=manager.getFeeGrowthGlobals(key.toId());previous=input==0?_get(3):_get(4);
            if(input==0?g1!=_get(4):g0!=_get(3))revert InvalidTrace();
        }else{
            if(amount!=0)revert InvalidTrace();_scan(key,zeroForOne,start,end,false);
        }
        uint256 count=_get(5);uint256 n;
        for(uint256 i;i<count;++i){int24 tick=int24(int256(_get(16+i*4)));if(zeroForOne?tick>end:tick<=end)++n;}
        if(n!=count)revert InvalidTrace();
        int24[] memory crossed=new int24[](n);uint256[] memory growth=new uint256[](n+1);
        uint128 liq=startL;uint256 weight;
        for(uint256 i;i<n;++i){
            uint256 off=16+i*4;int24 tick=int24(int256(_get(off)));crossed[i]=tick;
            if(rewardPath){
                (uint256 o0,uint256 o1)=manager.getTickFeeGrowthOutside(key.toId(),tick);
                uint256 atCross;unchecked{atCross=(input==0?o0:o1)+_get(off+2+input);growth[i]=atCross-previous;}
                weight+=uint256(liq)*growth[i];previous=atCross;
            }
            int128 net=int128(int256(_get(off+1)));
            int256 next=int256(uint256(liq))+(zeroForOne?-int256(net):int256(net));
            if(next<0||uint256(next)>type(uint128).max)revert InvalidTrace();liq=uint128(uint256(next));
        }
        if(rewardPath){unchecked{growth[n]=(input==0?g0:g1)-previous;}}
        weight+=uint256(liq)*growth[n];
        if(liq!=manager.getLiquidity(key.toId()))revert InvalidTrace();
        _put(0,0);
        ledger.record(pid,++nonce,1-input,amount,end,crossed,growth);
        (int24 nowTick,uint128 nowL,,)=ledger.poolState(pid);
        if(nowTick!=end||nowL!=liq)revert InvalidTrace();
        // Persistent diagnostics ONLY, deliberately included in test gas.
        // Not a gas-optimized production event/trace interface.
        if(diagnostics){
            lastCrosses=crossed;lastFeeGrowth=growth;lastStart=start;lastEnd=end;lastWeight=weight;
            lastDenominator=weight/(1<<128)+(weight%(1<<128)==0?0:1);lastCandidateCount=count;
        }

    }
    function trace() external view returns(int24[] memory,uint256[] memory){return(lastCrosses,lastFeeGrowth);}
}
