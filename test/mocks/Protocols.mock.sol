// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV3Router, ICooler} from "../../src/interfaces/Protocols.sol";

contract MockToken is ERC20 {
    uint8 private immutable precision;
    uint256 public taxBps;

    constructor(string memory symbol_, uint8 precision_) ERC20(symbol_, symbol_) {
        precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 tax = from != address(0) && to != address(0) ? amount * taxBps / 10000 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
    }
}

contract MockFeed {
    int256 public answer = 100_000e8;
    uint256 public updatedAt;
    uint80 public round = 1;
    uint80 public answeredRound = 1;

    constructor() {
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(int256 answer_, uint256 timestamp_) external {
        answer = answer_;
        updatedAt = timestamp_;
    }

    function setRound(uint80 answered) external {
        answeredRound = answered;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, answeredRound);
    }
}

contract MockFxPool {
    address public immutable collateralToken;
    address public poolManager;
    mapping(uint256 => uint256) public collateral;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => address) public owner;
    uint256 public next = 1;
    uint256 public px = 100_000e18;

    constructor(address token) {
        collateralToken = token;
    }

    function setManager(address manager) external {
        require(poolManager == address(0));
        poolManager = manager;
    }

    function setPrice(uint256 p) external {
        px = p;
    }

    function getDebtRatioRange() external pure returns (uint256, uint256) {
        return (0, 0.85e18);
    }

    function getPosition(uint256 id) external view returns (uint256, uint256) {
        return (collateral[id], debt[id]);
    }

    function getPositionDebtRatio(uint256 id) external view returns (uint256) {
        return
            debt[id] == 0 ? 0 : Math.mulDiv(debt[id], 1e18, Math.mulDiv(collateral[id], px, 1e18), Math.Rounding.Ceil);
    }

    function accrue(uint256 id, uint256 debtAdded) external {
        debt[id] += debtAdded;
    }

    function liquidate(uint256 id) external {
        collateral[id] = 0;
        debt[id] = 0;
    }

    function operate(uint256 id, int256 c, int256 d, address caller) external returns (uint256, uint256, uint256) {
        require(msg.sender == poolManager);
        if (id == 0) {
            id = next++;
            owner[id] = caller;
        }
        require(owner[id] == caller);
        uint256 withdrawal;
        uint256 repaid;
        if (c > 0) {
            collateral[id] += uint256(c) * 1e10;
        } else if (c < 0) {
            withdrawal = c == type(int256).min ? collateral[id] / 1e10 : uint256(-c);
            collateral[id] -= withdrawal * 1e10;
        }
        if (d > 0) {
            debt[id] += uint256(d);
        } else if (d < 0) {
            repaid = d == type(int256).min ? debt[id] : Math.min(uint256(-d), debt[id]);
            debt[id] -= repaid;
        }
        require(debt[id] <= Math.mulDiv(Math.mulDiv(collateral[id], px, 1e18), 85, 100), "fx unhealthy");
        if (withdrawal != 0) IERC20(collateralToken).transfer(caller, withdrawal);
        return (id, withdrawal, repaid);
    }
}

contract MockFxManager {
    MockToken public immutable token;
    MockFxPool public immutable pool;
    uint256 public supplyFeeBps;
    uint256 public borrowFeeBps;
    uint256 public repayFeeBps;
    uint256 public scale = 1e28;
    bool public enforceTransactionLock;
    uint256 public operateCalls;

    error ErrorPoolManagerLocked();

    function setTransactionLock(bool enabled) external {
        enforceTransactionLock = enabled;
    }

    /// @dev Test-only transaction boundary: Foundry runs multiple user actions in one transaction.
    function nextTransaction() external {
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    constructor(address token_, address pool_) {
        token = MockToken(token_);
        pool = MockFxPool(pool_);
    }

    function fxUSD() external view returns (address) {
        return address(token);
    }

    function getTokenScalingFactor(address) external view returns (uint256) {
        return scale;
    }

    function setScale(uint256 x) external {
        scale = x;
    }

    function setFees(uint256 supply, uint256 borrow_, uint256 repay_) external {
        supplyFeeBps = supply;
        borrowFeeBps = borrow_;
        repayFeeBps = repay_;
    }

    function operate(address pool_, uint256 id, int256 c, int256 d) external returns (uint256) {
        if (enforceTransactionLock) {
            bool isLocked;
            assembly ("memory-safe") {
                isLocked := tload(0)
                tstore(0, 1)
            }
            if (isLocked) revert ErrorPoolManagerLocked();
        }
        ++operateCalls;
        require(pool_ == address(pool));
        if (c > 0) {
            IERC20(pool.collateralToken()).transferFrom(msg.sender, address(pool), uint256(c));
            c -= int256(uint256(c) * supplyFeeBps / 10000);
        }
        uint256 repaid;
        (id,, repaid) = pool.operate(id, c, d, msg.sender);
        if (d > 0) token.mint(msg.sender, uint256(d) - uint256(d) * borrowFeeBps / 10000);
        if (repaid != 0) token.burn(msg.sender, repaid + repaid * repayFeeBps / 10000);
        return id;
    }
}

contract MockStaking {
    address public immutable OHM;
    address public immutable gOHM;
    bool public warmup;

    constructor(address ohm_, address gohm_) {
        OHM = ohm_;
        gOHM = gohm_;
    }

    function setWarmup(bool v) external {
        warmup = v;
    }

    function stake(address to, uint256 amount, bool rebasing, bool claim) external returns (uint256 out) {
        require(!rebasing && claim);
        IERC20(OHM).transferFrom(msg.sender, address(this), amount);
        if (warmup) return 0;
        out = amount * 1e9 / 200;
        MockToken(gOHM).mint(to, out);
    }

    function unstake(address to, uint256 amount, bool trigger, bool rebasing) external returns (uint256 out) {
        require(!trigger && !rebasing);
        IERC20(gOHM).transferFrom(msg.sender, address(this), amount);
        MockToken(gOHM).burn(address(this), amount);
        out = amount * 200 / 1e9;
        IERC20(OHM).transfer(to, out);
    }
}

contract MockCooler {
    address public immutable collateralToken;
    address public debtToken;
    address public immutable ohm;
    address public immutable staking;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    bool public paused;
    uint256 public disbursementShortfall;

    function setDisbursementShortfall(uint256 amount) external {
        disbursementShortfall = amount;
    }

    constructor(address gohm_, address usds_, address ohm_, address staking_) {
        collateralToken = gohm_;
        debtToken = usds_;
        ohm = ohm_;
        staking = staking_;
    }

    function setDebtToken(address t) external {
        debtToken = t;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function accrue(address a, uint256 amount) external {
        debt[a] += amount;
    }

    function liquidate(address a) external {
        collateral[a] = 0;
        debt[a] = 0;
    }

    function accountPosition(address a) external view returns (ICooler.AccountPosition memory p) {
        p.collateral = collateral[a];
        p.currentDebt = debt[a];
        p.maxOriginationDebtAmount = collateral[a] * 2500;
        p.liquidationDebtAmount = collateral[a] * 2600;
        p.healthFactor = debt[a] == 0 ? type(uint256).max : p.liquidationDebtAmount * 1e18 / debt[a];
    }

    function addCollateral(uint128 amount, address a, ICooler.DelegationRequest[] calldata requests) external {
        require(a == msg.sender && requests.length == 0 && amount != 0);
        IERC20(collateralToken).transferFrom(msg.sender, address(this), amount);
        collateral[a] += amount;
    }

    function borrow(uint128 amount, address a, address to) external returns (uint128) {
        require(!paused && a == msg.sender);
        debt[a] += amount;
        require(debt[a] <= collateral[a] * 2500 && debt[a] >= 1000e18, "cooler limits");
        IERC20(debtToken).transfer(to, amount - disbursementShortfall);
        return amount;
    }

    function repay(uint128 amount, address a) external returns (uint128) {
        require(debt[a] != 0);
        uint256 paid = Math.min(amount, debt[a]);
        IERC20(debtToken).transferFrom(msg.sender, address(this), paid);
        debt[a] -= paid;
        require(debt[a] == 0 || debt[a] >= 1000e18, "dust debt");
        return uint128(paid);
    }

    function withdrawCollateral(uint128 amount, address a, address to, ICooler.DelegationRequest[] calldata requests)
        external
        returns (uint128)
    {
        require(a == msg.sender && requests.length == 0);
        collateral[a] -= amount;
        require(debt[a] <= collateral[a] * 2500);
        IERC20(collateralToken).transfer(to, amount);
        return amount;
    }
}

contract MockRouter is IV3Router {
    mapping(address => uint256) public prices;
    uint256 public feeBps;
    bool public lie;
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;

    function setPrice(address t, uint256 price_) external {
        prices[t] = price_;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setLie(bool v) external {
        lie = v;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function quoteExactInput(bytes calldata path, uint256 amount) external view returns (uint256 out) {
        (address from, address to) = endpoints(path);
        uint256 value = Math.mulDiv(amount, prices[from], 10 ** IERC20Metadata(from).decimals());
        out = Math.mulDiv(value, 10 ** IERC20Metadata(to).decimals(), prices[to]);
        out -= out * feeBps / 10000;
    }

    function quoteExactOutput(bytes calldata path, uint256 amount) external view returns (uint256 used) {
        (address to, address from) = endpoints(path);
        uint256 value = Math.mulDiv(amount, prices[to], 10 ** IERC20Metadata(to).decimals(), Math.Rounding.Ceil);
        used = Math.mulDiv(value, 10 ** IERC20Metadata(from).decimals(), prices[from], Math.Rounding.Ceil);
        used = Math.mulDiv(used, 10000, 10000 - feeBps, Math.Rounding.Ceil);
    }

    function endpoints(bytes calldata path) private pure returns (address a, address b) {
        a = address(bytes20(path[:20]));
        b = address(bytes20(path[path.length - 20:]));
    }

    function _hook() private {
        if (hookTarget != address(0)) (hookSucceeded,) = hookTarget.call(hookData);
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        require(block.timestamp <= p.deadline);
        (address from, address to) = endpoints(p.path);
        IERC20(from).transferFrom(msg.sender, address(this), p.amountIn);
        _hook();
        uint256 value = Math.mulDiv(p.amountIn, prices[from], 10 ** IERC20Metadata(from).decimals());
        out = Math.mulDiv(value, 10 ** IERC20Metadata(to).decimals(), prices[to]);
        out -= out * feeBps / 10000;
        require(out >= p.amountOutMinimum, "minOut");
        if (!lie) IERC20(to).transfer(p.recipient, out);
    }

    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256 used) {
        require(block.timestamp <= p.deadline);
        (address to, address from) = endpoints(p.path);
        uint256 value = Math.mulDiv(p.amountOut, prices[to], 10 ** IERC20Metadata(to).decimals(), Math.Rounding.Ceil);
        used = Math.mulDiv(value, 10 ** IERC20Metadata(from).decimals(), prices[from], Math.Rounding.Ceil);
        used = Math.mulDiv(used, 10000, 10000 - feeBps, Math.Rounding.Ceil);
        require(used <= p.amountInMaximum, "maxIn");
        IERC20(from).transferFrom(msg.sender, address(this), used);
        _hook();
        if (!lie) IERC20(to).transfer(p.recipient, p.amountOut);
    }
}

interface IFlashReceiver {
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external;
}

contract MockMorpho {
    uint256 public mode;

    function setMode(uint256 m) external {
        mode = m;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        if (mode == 1) return;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        if (mode != 4) IERC20(token).transfer(msg.sender, assets);
        bytes memory callbackData = data;
        if (mode == 5) callbackData[callbackData.length - 1] ^= bytes1(uint8(1));
        IFlashReceiver(msg.sender).onMorphoFlashLoan(mode == 2 ? assets + 1 : assets, callbackData);
        if (mode == 3) IFlashReceiver(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        require(IERC20(token).balanceOf(address(this)) == beforeBalance, "flash conservation");
    }
}
