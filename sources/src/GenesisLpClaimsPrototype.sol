// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface ILpToken {
    function balanceOf(address) external view returns(uint256);
}
interface ILpNft {
    function ownerOf(uint256) external view returns(address);
}

/// @notice Path-indexed LP reward escrow for a bound, authenticated adapter.
/// The native PosmTraceAdapter supplies complete position changes and swap traces;
/// this ledger alone does not prove trace authenticity or completeness.
/// Supports only standard exact-transfer ERC20s. No admin withdrawal function.
/// Historical Prototype naming is retained for source and ABI continuity.
contract GenesisLpClaimsPrototype {
    uint256 constant Q=1<<128;
    address public immutable authority;
    address public immutable nft;
    bool private entered;
    struct Boundary {uint128 gross;int128 net;uint256[2] outside;}
    struct Pool {bool exists;int24 tick;uint128 liquidity;uint256 nonce;address[2] tokens;uint256[2] growth;}
    struct Position {bool exists;int24 lower;int24 upper;uint128 liquidity;uint256[2] last;uint256[2] owed;uint256[2] remainder;}
    mapping(bytes32=>Pool) private pools;
    mapping(bytes32=>mapping(int24=>Boundary)) private boundaries;
    mapping(bytes32=>mapping(uint256=>Position)) private positions;
    mapping(bytes32=>mapping(address=>uint256[2])) private walletOwed;
    mapping(address=>uint256) public reserved;
    mapping(bytes32=>mapping(uint256=>bool)) public awaitingBurnOwner;
    mapping(bytes32=>mapping(uint256=>uint256[2])) private burnPending;
    mapping(bytes32=>uint256[2]) public funded;
    mapping(bytes32=>uint256[2]) public paid;
    error Unauthorized(); error Invalid(); error Replay(); error OwnerUnavailable();
    error TransferFailed(); error Reentered(); error Unfunded();
    modifier locked(){if(entered)revert Reentered();entered=true;_;entered=false;}
    modifier onlyAuthority(){if(msg.sender!=authority)revert Unauthorized();_;}
    event Funded(bytes32 indexed pid,uint8 indexed token,uint256 amount);
    event Claimed(bytes32 indexed pid,address indexed owner,uint256 amount0,uint256 amount1);
    event Closed(bytes32 indexed pid,uint256 indexed tokenId,address indexed owner);
    constructor(address authority_,address nft_){
        if(authority_==address(0)||nft_==address(0))revert Invalid();
        authority=authority_;nft=nft_;
    }
    function register(bytes32 pid,address token0,address token1,int24 tick) external onlyAuthority locked {
        if(pools[pid].exists||token0==address(0)||token0==token1||token1==address(0)||tick<-887272||tick>887272)revert Invalid();
        Pool storage p=pools[pid];p.exists=true;p.tokens=[token0,token1];p.tick=tick;
    }
    function poolState(bytes32 pid) external view returns(int24,uint128,uint256,uint256[2] memory){
        Pool storage p=pools[pid];return(p.tick,p.liquidity,p.nonce,p.growth);
    }
    function _owner(uint256 tokenId) internal view returns(address who){
        try ILpNft(nft).ownerOf(tokenId) returns(address got){who=got;}catch{revert OwnerUnavailable();}
        if(who==address(0))revert OwnerUnavailable();
    }
    function _inside(bytes32 pid,Position storage pos,uint8 t) internal view returns(uint256 result){
        Pool storage p=pools[pid];uint256 g=p.growth[t];
        uint256 lo=boundaries[pid][pos.lower].outside[t];uint256 hi=boundaries[pid][pos.upper].outside[t];
        unchecked{
            uint256 below=p.tick>=pos.lower?lo:g-lo;
            uint256 above=p.tick<pos.upper?hi:g-hi;
            result=g-below-above;
        }
    }
    function _checkpoint(bytes32 pid,Position storage pos) internal {
        if(pos.liquidity==0)return;
        for(uint8 t;t<2;++t){
            uint256 nowGrowth=_inside(pid,pos,t);uint256 delta;
            unchecked{delta=nowGrowth-pos.last[t];}
            uint256 amount=FullMath.mulDiv(pos.liquidity,delta,Q);
            uint256 rem=mulmod(pos.liquidity,delta,Q)+pos.remainder[t];
            pos.owed[t]+=amount+rem/Q;pos.remainder[t]=rem%Q;pos.last[t]=nowGrowth;
        }
    }
    function _boundary(bytes32 pid,int24 tick,int128 delta,bool upper) internal {
        Pool storage p=pools[pid];Boundary storage b=boundaries[pid][tick];
        uint128 magnitude=uint128(delta<0?-delta:delta);
        if(b.gross==0){
            if(delta<=0)revert Invalid();
            if(tick<=p.tick)b.outside=p.growth;
        }
        if(delta>0)b.gross+=magnitude;else b.gross-=magnitude;
        b.net+=upper?-delta:delta;
        if(b.gross==0)delete boundaries[pid][tick];
    }
    function change(bytes32 pid,uint256 tokenId,int24 lower,int24 upper,uint128 newLiquidity) external onlyAuthority locked {
        Pool storage p=pools[pid];Position storage pos=positions[pid][tokenId];
        if(!p.exists||lower<-887272||upper>887272||lower>=upper||newLiquidity>uint128(type(int128).max))revert Invalid();
        address owner=_owner(tokenId); // Authenticated NFT registry, never hookData.
        if(!pos.exists){
            if(newLiquidity==0)revert Invalid();
            pos.exists=true;pos.lower=lower;pos.upper=upper;
        }
        if(pos.lower!=lower||pos.upper!=upper)revert Invalid();
        _checkpoint(pid,pos);
        int128 delta=int128(newLiquidity)-int128(pos.liquidity);
        if(delta!=0){
            _boundary(pid,lower,delta,false);_boundary(pid,upper,delta,true);
            if(p.tick>=lower&&p.tick<upper){
                if(delta>0)p.liquidity+=uint128(delta);else p.liquidity-=uint128(-delta);
            }
        }
        if(pos.liquidity==0&&newLiquidity>0){
            for(uint8 t;t<2;++t)pos.last[t]=_inside(pid,pos,t);
        }
        pos.liquidity=newLiquidity;
        if(newLiquidity==0){
            // Detach earned whole units from the NFT before it can be burned.
            // Sub-raw-unit position fractions become unallocated reserve dust;
            // a later owner/re-entry must not inherit an old exit's fraction.
            for(uint8 t;t<2;++t){walletOwed[pid][owner][t]+=pos.owed[t];pos.owed[t]=0;pos.remainder[t]=0;}
            emit Closed(pid,tokenId,owner);
        }
    }
    function _crossLiquidity(uint128 liquidity,int128 net,bool upward) internal pure returns(uint128){
        int256 result=int256(uint256(liquidity))+(upward?int256(net):-int256(net));
        if(result<0||uint256(result)>type(uint128).max)revert Invalid();return uint128(uint256(result));
    }
    /// @dev Only a verified PositionManager subscriber adapter may use this:
    /// core burn callback runs after ownerOf disappears, but before notifyBurn
    /// supplies its authenticated owner. Both calls must complete atomically.
    function beginVerifiedBurn(bytes32 pid,uint256 tokenId,int24 lower,int24 upper) external onlyAuthority locked {
        Position storage pos=positions[pid][tokenId];Pool storage p=pools[pid];
        if(!pos.exists||pos.liquidity==0||pos.lower!=lower||pos.upper!=upper||awaitingBurnOwner[pid][tokenId])revert Invalid();
        address stillOwner;try ILpNft(nft).ownerOf(tokenId) returns(address owner){stillOwner=owner;}catch{}
        if(stillOwner!=address(0))revert Invalid();
        _checkpoint(pid,pos);int128 delta=-int128(pos.liquidity);
        _boundary(pid,lower,delta,false);_boundary(pid,upper,delta,true);
        if(p.tick>=lower&&p.tick<upper)p.liquidity-=pos.liquidity;
        pos.liquidity=0;awaitingBurnOwner[pid][tokenId]=true;
        for(uint8 t;t<2;++t){burnPending[pid][tokenId][t]=pos.owed[t];pos.owed[t]=0;pos.remainder[t]=0;}
    }
    function finalizeVerifiedBurn(bytes32 pid,uint256 tokenId,address owner) external onlyAuthority locked {
        if(!awaitingBurnOwner[pid][tokenId]||owner==address(0))revert Invalid();
        delete awaitingBurnOwner[pid][tokenId];
        for(uint8 t;t<2;++t){walletOwed[pid][owner][t]+=burnPending[pid][tokenId][t];}
        delete burnPending[pid][tokenId];emit Closed(pid,tokenId,owner);
    }
    function _transfer(address token,bytes memory data) internal {
        (bool ok,bytes memory out)=token.call(data);
        if(!ok||(out.length!=0&&(out.length!=32||!abi.decode(out,(bool)))))revert TransferFailed();
    }
    /// @dev crosses lists ALL initialized boundaries crossed, strictly ordered.
    /// feeGrowth length = crosses+1, aligned to segments BEFORE each crossing.
    /// Authenticity/completeness is authority's responsibility, NOT proved here.
    function record(bytes32 pid,uint256 nonce,uint8 token,uint256 amount,int24 endTick,int24[] calldata crosses,uint256[] calldata feeGrowth) external onlyAuthority locked {
        Pool storage p=pools[pid];
        if(!p.exists||token>1||endTick<-887272||endTick>887272||feeGrowth.length!=crosses.length+1)revert Invalid();
        if(nonce<=p.nonce)revert Replay();
        bool upward=endTick>=p.tick;int24 cursor=p.tick;uint128 liq=p.liquidity;uint256 weight;
        for(uint256 i;i<feeGrowth.length;++i){
            weight+=uint256(liq)*feeGrowth[i];
            if(i<crosses.length){
                int24 tick=crosses[i];Boundary storage b=boundaries[pid][tick];
                if(b.gross==0)revert Invalid();
                if(upward){if(tick<=cursor||tick>endTick)revert Invalid();cursor=tick;}
                else{if(tick>cursor||tick<=endTick)revert Invalid();cursor=tick-1;}
                liq=_crossLiquidity(liq,b.net,upward);
            }
        }
        uint256 denominator=weight/Q+(weight%Q==0?0:1);
        if(amount>0&&denominator==0)revert Invalid();
        if(amount>0){
            address asset=p.tokens[token];uint256 beforeBalance=ILpToken(asset).balanceOf(address(this));
            _transfer(asset,abi.encodeWithSignature("transferFrom(address,address,uint256)",msg.sender,address(this),amount));
            if(ILpToken(asset).balanceOf(address(this))!=beforeBalance+amount)revert TransferFailed();
            reserved[asset]+=amount;funded[pid][token]+=amount;emit Funded(pid,token,amount);
        }
        for(uint256 i;i<feeGrowth.length;++i){
            if(amount>0)p.growth[token]+=FullMath.mulDiv(amount,feeGrowth[i],denominator);
            if(i<crosses.length){
                Boundary storage b=boundaries[pid][crosses[i]];
                for(uint8 t;t<2;++t){unchecked{b.outside[t]=p.growth[t]-b.outside[t];}}
            }
        }
        p.tick=endTick;p.liquidity=liq;p.nonce=nonce;
    }
    function pending(bytes32 pid,uint256 tokenId) external view returns(uint256[2] memory result){
        Position storage pos=positions[pid][tokenId];result=pos.owed;
        if(pos.liquidity>0)for(uint8 t;t<2;++t){
            uint256 d;unchecked{d=_inside(pid,pos,t)-pos.last[t];}
            uint256 rem=mulmod(pos.liquidity,d,Q)+pos.remainder[t];
            result[t]+=FullMath.mulDiv(pos.liquidity,d,Q)+rem/Q;
        }
    }
    function closedPending(bytes32 pid,address owner) external view returns(uint256[2] memory){return walletOwed[pid][owner];}
    function _pay(bytes32 pid,address owner,uint256[2] memory amounts) internal {
        Pool storage p=pools[pid];
        for(uint8 t;t<2;++t){
            uint256 a=amounts[t];if(a==0)continue;address asset=p.tokens[t];
            if(a>reserved[asset])revert Unfunded();
            reserved[asset]-=a;paid[pid][t]+=a;
            uint256 beforeBalance=ILpToken(asset).balanceOf(address(this));
            _transfer(asset,abi.encodeWithSignature("transfer(address,uint256)",owner,a));
            if(ILpToken(asset).balanceOf(address(this))+a!=beforeBalance)revert TransferFailed();
        }
        emit Claimed(pid,owner,amounts[0],amounts[1]);
    }
    function claim(bytes32 pid,uint256 tokenId) external locked {
        Position storage pos=positions[pid][tokenId];
        if(!pos.exists||_owner(tokenId)!=msg.sender)revert Unauthorized();
        _checkpoint(pid,pos);uint256[2] memory amounts=pos.owed;delete pos.owed;_pay(pid,msg.sender,amounts);
    }
    // The authenticated LP-operation adapter may trigger payment, but
    // NEVER choose a different recipient for someone else's position.
    function claimFor(bytes32 pid,uint256 tokenId) external onlyAuthority locked {
        Position storage pos=positions[pid][tokenId];if(!pos.exists)revert Invalid();
        address owner=_owner(tokenId);_checkpoint(pid,pos);
        uint256[2] memory amounts=pos.owed;delete pos.owed;_pay(pid,owner,amounts);
    }
    function claimClosed(bytes32 pid) external locked {
        uint256[2] memory amounts=walletOwed[pid][msg.sender];delete walletOwed[pid][msg.sender];_pay(pid,msg.sender,amounts);
    }
    function claimClosedFor(bytes32 pid,address owner) external onlyAuthority locked {
        uint256[2] memory amounts=walletOwed[pid][owner];delete walletOwed[pid][owner];_pay(pid,owner,amounts);
    }
}
