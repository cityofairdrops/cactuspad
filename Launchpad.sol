// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "./LaunchToken.sol";

interface IUniswapV2Factory {
    function createPair(address a, address b) external returns (address);
}

interface IUniswapV2Pair {
    function mint(address to) external returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title Launchpad
/// @notice Pump.fun-style launchpad. Anyone can create a token, trade it on a
/// constant-product bonding curve, and when 800M tokens are sold it graduates to a
/// Uniswap V2-style pool with the LP tokens burned.
/// Unique features: creator fee share, referral rewards, creator lock/vesting,
/// decaying anti-sniper fee, early per-wallet cap.
/// The contract has NO admin power over tokens or curves. Owner can only change
/// the treasury address and the creation fee (capped).
contract Launchpad is Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------- config
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_TOKENS = 800_000_000 ether; // sold on the curve
    uint256 public constant LP_TOKENS = TOTAL_SUPPLY - CURVE_TOKENS; // seeded to DEX
    uint256 public constant VIRTUAL_ETH = 1 ether;
    uint256 public constant VIRTUAL_TOKENS = 1_000_000_000 ether;
    uint256 public constant K = VIRTUAL_ETH * VIRTUAL_TOKENS; // ~4 ETH raised at graduation

    uint256 public constant BASE_FEE_BPS = 50; // 0.5% trade fee
    uint256 public constant SNIPER_EXTRA_BPS = 1000; // +10% at launch, decays to 0
    uint256 public constant SNIPER_DECAY = 300; // seconds
    uint256 public constant CREATOR_SHARE_BPS = 5000; // 50% of each fee to creator
    uint256 public constant REFERRAL_SHARE_BPS = 1500; // 15% of buy fee to referrer
    uint256 public constant GRADUATION_FEE_BPS = 100; // 1% of raised ETH

    uint256 public constant EARLY_WINDOW = 120; // seconds
    uint256 public constant EARLY_WALLET_MAX = 20_000_000 ether; // 2% of supply
    uint256 public constant CREATOR_MAX = 50_000_000 ether; // 5% of supply, locked
    uint256 public constant VEST_DURATION = 30 days;
    uint256 public constant MAX_CREATION_FEE = 0.01 ether;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable weth;
    address public immutable uniFactory;
    address public treasury;
    uint256 public creationFee;

    struct Curve {
        address creator;
        uint64 createdAt;
        bool exists;
        bool graduated;
        uint256 vEth;
        uint256 vTokens;
        uint256 realEth;
        uint256 sold;
        uint256 locked; // creator tokens held in vesting
        uint256 claimed; // vested tokens already claimed
    }

    mapping(address => Curve) public curves;
    mapping(address => mapping(address => uint256)) public earlyBought;
    mapping(address => uint256) public pending; // claimable ETH (fees)

    // ---------------------------------------------------------------- events
    event TokenCreated(
        address indexed token, address indexed creator, address pair, string name, string symbol, string metadataURI
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 vEth,
        uint256 vTokens,
        uint256 timestamp
    );
    event Graduated(address indexed token, address pair, uint256 ethLiquidity, uint256 tokenLiquidity);
    event VestedClaimed(address indexed token, address indexed creator, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    // ---------------------------------------------------------------- errors
    error UnknownToken();
    error AlreadyGraduated();
    error Slippage();
    error ZeroAmount();
    error EarlyWalletCap();
    error CreatorCap();
    error FeeTooLow();
    error FeeTooHigh();
    error NotCreator();
    error SendFailed();

    constructor(address weth_, address uniFactory_, address treasury_, uint256 creationFee_) Ownable(msg.sender) {
        if (creationFee_ > MAX_CREATION_FEE) revert FeeTooHigh();
        weth = weth_;
        uniFactory = uniFactory_;
        treasury = treasury_;
        creationFee = creationFee_;
    }

    // ---------------------------------------------------------------- admin
    function setTreasury(address t) external onlyOwner {
        treasury = t;
    }

    function setCreationFee(uint256 f) external onlyOwner {
        if (f > MAX_CREATION_FEE) revert FeeTooHigh();
        creationFee = f;
    }

    // ---------------------------------------------------------------- create
    /// @notice Create a token. Any ETH above the creation fee is used as the
    /// creator's first buy (capped at 5% of supply and locked/vested).
    function createToken(string calldata name, string calldata symbol, string calldata metadataURI, address referrer)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value < creationFee) revert FeeTooLow();

        token = address(new LaunchToken(name, symbol, TOTAL_SUPPLY, address(this)));
        address pair = IUniswapV2Factory(uniFactory).createPair(token, weth);
        LaunchToken(token).setPair(pair);

        curves[token] = Curve({
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            exists: true,
            graduated: false,
            vEth: VIRTUAL_ETH,
            vTokens: VIRTUAL_TOKENS,
            realEth: 0,
            sold: 0,
            locked: 0,
            claimed: 0
        });

        pending[treasury] += creationFee;
        emit TokenCreated(token, msg.sender, pair, name, symbol, metadataURI);

        uint256 buyValue = msg.value - creationFee;
        if (buyValue > 0) {
            (, uint256 refund) = _buy(token, msg.sender, buyValue, 0, referrer);
            if (refund > 0) _send(msg.sender, refund);
        }
    }

    // ---------------------------------------------------------------- trade
    function buy(address token, uint256 minTokensOut, address referrer) external payable nonReentrant {
        (, uint256 refund) = _buy(token, msg.sender, msg.value, minTokensOut, referrer);
        if (refund > 0) _send(msg.sender, refund);
    }

    function sell(address token, uint256 amount, uint256 minEthOut) external nonReentrant {
        Curve storage c = curves[token];
        if (!c.exists) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
        if (amount == 0 || amount > c.sold) revert ZeroAmount();

        uint256 newVT = c.vTokens + amount;
        uint256 newVE = _ceilDiv(K, newVT);
        uint256 gross = c.vEth - newVE;
        if (gross > c.realEth) revert ZeroAmount();

        uint256 fee = gross * currentFeeBps(token) / 10_000;
        uint256 net = gross - fee;
        if (net < minEthOut) revert Slippage();

        c.vEth = newVE;
        c.vTokens = newVT;
        c.realEth -= gross;
        c.sold -= amount;

        LaunchToken(token).transferFrom(msg.sender, address(this), amount);
        _distributeFee(c.creator, address(0), msg.sender, fee);
        emit Trade(token, msg.sender, false, net, amount, fee, newVE, newVT, block.timestamp);
        _send(msg.sender, net);
    }

    function _buy(address token, address buyer, uint256 value, uint256 minOut, address ref)
        internal
        returns (uint256 out, uint256 refund)
    {
        Curve storage c = curves[token];
        if (!c.exists) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();

        uint256 ethIn;
        uint256 fee;
        (out, ethIn, fee, refund) = _quoteBuy(c, value, currentFeeBps(token));
        if (out == 0) revert ZeroAmount();
        if (out < minOut) revert Slippage();

        c.vEth += ethIn;
        c.vTokens -= out;
        c.realEth += ethIn;
        c.sold += out;

        if (buyer == c.creator) {
            // creator tokens are locked and vest linearly: creator can never dump
            c.locked += out;
            if (c.locked > CREATOR_MAX) revert CreatorCap();
        } else {
            if (block.timestamp < uint256(c.createdAt) + EARLY_WINDOW) {
                earlyBought[token][buyer] += out;
                if (earlyBought[token][buyer] > EARLY_WALLET_MAX) revert EarlyWalletCap();
            }
            LaunchToken(token).transfer(buyer, out);
        }

        _distributeFee(c.creator, ref, buyer, fee);
        emit Trade(token, buyer, true, ethIn, out, fee, c.vEth, c.vTokens, block.timestamp);

        if (c.sold == CURVE_TOKENS) _graduate(token, c);
    }

    function _quoteBuy(Curve storage c, uint256 value, uint256 bps)
        internal
        view
        returns (uint256 out, uint256 ethIn, uint256 fee, uint256 refund)
    {
        fee = value * bps / 10_000;
        ethIn = value - fee;
        uint256 newVT = _ceilDiv(K, c.vEth + ethIn);
        out = c.vTokens - newVT;

        uint256 remaining = CURVE_TOKENS - c.sold;
        if (out >= remaining) {
            // final buy: only take what is left, refund the rest
            out = remaining;
            newVT = c.vTokens - out;
            ethIn = _ceilDiv(K, newVT) - c.vEth;
            uint256 gross = _ceilDiv(ethIn * 10_000, 10_000 - bps);
            if (gross > value) gross = value;
            fee = gross - ethIn;
            refund = value - gross;
        }
    }

    // ---------------------------------------------------------------- graduation
    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        address pair = LaunchToken(token).pair();

        uint256 eth = c.realEth;
        c.realEth = 0;
        uint256 gradFee = eth * GRADUATION_FEE_BPS / 10_000;
        pending[treasury] += gradFee;
        eth -= gradFee;

        IWETH(weth).deposit{value: eth}();
        IWETH(weth).transfer(pair, eth);
        LaunchToken(token).transfer(pair, LP_TOKENS);
        IUniswapV2Pair(pair).mint(DEAD); // LP burned: liquidity locked forever
        LaunchToken(token).markGraduated();

        emit Graduated(token, pair, eth, LP_TOKENS);
    }

    // ---------------------------------------------------------------- fees
    function currentFeeBps(address token) public view returns (uint256) {
        uint256 elapsed = block.timestamp - curves[token].createdAt;
        uint256 extra = elapsed >= SNIPER_DECAY ? 0 : SNIPER_EXTRA_BPS * (SNIPER_DECAY - elapsed) / SNIPER_DECAY;
        return BASE_FEE_BPS + extra;
    }

    function _distributeFee(address creator, address ref, address trader, uint256 fee) internal {
        uint256 creatorCut = fee * CREATOR_SHARE_BPS / 10_000;
        uint256 refCut = (ref != address(0) && ref != trader) ? fee * REFERRAL_SHARE_BPS / 10_000 : 0;
        pending[creator] += creatorCut;
        if (refCut > 0) pending[ref] += refCut;
        pending[treasury] += fee - creatorCut - refCut;
    }

    /// @notice Withdraw your accumulated fees (creator share, referrals, treasury).
    function claim() external nonReentrant {
        uint256 amount = pending[msg.sender];
        pending[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        if (amount > 0) _send(msg.sender, amount);
    }

    // ---------------------------------------------------------------- creator vesting
    function vestedAmount(address token) public view returns (uint256) {
        Curve storage c = curves[token];
        uint256 elapsed = block.timestamp - c.createdAt;
        if (elapsed > VEST_DURATION) elapsed = VEST_DURATION;
        return c.locked * elapsed / VEST_DURATION;
    }

    function claimVested(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (msg.sender != c.creator) revert NotCreator();
        uint256 amount = vestedAmount(token) - c.claimed;
        if (amount == 0) revert ZeroAmount();
        c.claimed += amount;
        LaunchToken(token).transfer(msg.sender, amount);
        emit VestedClaimed(token, msg.sender, amount);
    }

    // ---------------------------------------------------------------- utils
    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
