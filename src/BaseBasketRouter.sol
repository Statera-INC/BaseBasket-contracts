// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BaseBasketRouter
/// @notice Stateless-per-call, 100% non-custodial atomic execution router for Base L2.
/// @dev Enforces 3-tier volume fee ceilings (Retail, Pro, Institutional), onchain slippage checks,
///      instant guardian pause, and zero-dust sweeps.
contract BaseBasketRouter is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    address public immutable feeCollector;
    address public guardian;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_RETAIL_FEE_BPS = 150; // 1.50% max cap (< Pro threshold)
    uint256 public constant MAX_PRO_FEE_BPS = 75;     // 0.75% max cap (Pro to Whale threshold)
    uint256 public constant MAX_WHALE_FEE_BPS = 25;   // 0.25% max cap (>= Whale threshold)

    uint256 public proThreshold;   // e.g., 5,000 USDC (5_000e6)
    uint256 public whaleThreshold; // e.g., 100,000 USDC (100_000e6)

    mapping(address => bool) public allowedTargets;

    struct Approval {
        address token;
        address spender;
        uint256 amount;
    }

    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

    event BasketExecuted(
        address indexed user,
        address indexed inputToken,
        uint256 netAmount,
        uint256 feeAmount,
        uint8 tier
    );
    event TargetStatusUpdated(address indexed target, bool allowed);
    event GuardianUpdated(address indexed newGuardian);
    event FeeThresholdsUpdated(uint256 newProThreshold, uint256 newWhaleThreshold);
    event DustSwept(address indexed user, address indexed token, uint256 amount);
    event EthDustSwept(address indexed user, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidThresholds();
    error FeeExceedsCap(uint256 feeBps, uint256 maxAllowedBps);
    error TargetNotWhitelisted(address target);
    error SpenderNotWhitelisted(address spender);
    error ExternalCallFailed(address target, uint256 index);
    error SlippageExceeded(uint256 received, uint256 minRequired);
    error EthRefundFailed();
    error InsufficientEthForCalls(uint256 required, uint256 available);

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert Unauthorized();
        _;
    }

    constructor(
        address _feeCollector,
        address _initialOwner,
        address _guardian,
        uint256 _proThreshold,
        uint256 _whaleThreshold
    ) Ownable(_initialOwner) {
        if (
            _feeCollector == address(0) ||
            _initialOwner == address(0) ||
            _guardian == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_whaleThreshold > 0 && _proThreshold >= _whaleThreshold) {
            revert InvalidThresholds();
        }
        feeCollector = _feeCollector;
        guardian = _guardian;
        proThreshold = _proThreshold;
        whaleThreshold = _whaleThreshold;
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit TargetStatusUpdated(target, allowed);
    }

    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert ZeroAddress();
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    function setFeeThresholds(uint256 _proThreshold, uint256 _whaleThreshold) external onlyOwner {
        if (_whaleThreshold > 0 && _proThreshold >= _whaleThreshold) {
            revert InvalidThresholds();
        }
        proThreshold = _proThreshold;
        whaleThreshold = _whaleThreshold;
        emit FeeThresholdsUpdated(_proThreshold, _whaleThreshold);
    }

    function getTierAndMaxFee(uint256 amount) public view returns (uint8 tier, uint256 maxAllowedBps) {
        if (whaleThreshold > 0 && amount >= whaleThreshold) {
            return (2, MAX_WHALE_FEE_BPS);
        }
        if (proThreshold > 0 && amount >= proThreshold) {
            return (1, MAX_PRO_FEE_BPS);
        }
        return (0, MAX_RETAIL_FEE_BPS);
    }

    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function executeAtomicBasket(
        address inputToken,
        uint256 totalAmount,
        uint256 feeBps,
        address outputToken,
        uint256 minOutputAmount,
        Approval[] calldata approvals,
        Call[] calldata calls,
        address[] calldata sweepTokens
    ) external payable nonReentrant whenNotPaused {
        if (inputToken == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();

        (uint8 tier, uint256 maxAllowedBps) = getTierAndMaxFee(totalAmount);
        if (feeBps > maxAllowedBps) revert FeeExceedsCap(feeBps, maxAllowedBps);

        uint256 ethBefore = address(this).balance - msg.value;
        uint256 userOutputBefore = outputToken != address(0)
            ? IERC20(outputToken).balanceOf(msg.sender)
            : 0;

        uint256[] memory sweepBefore = new uint256[](sweepTokens.length);
        for (uint256 j = 0; j < sweepTokens.length; j++) {
            address tokenAddr = sweepTokens[j];
            if (tokenAddr != address(0)) {
                sweepBefore[j] = IERC20(tokenAddr).balanceOf(address(this));
            }
        }

        uint256 inputBefore = IERC20(inputToken).balanceOf(address(this));
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 actualReceived = IERC20(inputToken).balanceOf(address(this)) - inputBefore;
        if (actualReceived == 0) revert ZeroAmount();

        uint256 feeAmount = (actualReceived * feeBps) / BPS_DENOMINATOR;
        uint256 netAmount = actualReceived - feeAmount;
        if (feeAmount > 0) {
            IERC20(inputToken).safeTransfer(feeCollector, feeAmount);
        }

        for (uint256 a = 0; a < approvals.length; a++) {
            address spender = approvals[a].spender;
            if (!allowedTargets[spender]) revert SpenderNotWhitelisted(spender);
            IERC20(approvals[a].token).forceApprove(spender, approvals[a].amount);
        }

        for (uint256 i = 0; i < calls.length; i++) {
            address target = calls[i].target;
            uint256 callValue = calls[i].value;
            if (!allowedTargets[target]) revert TargetNotWhitelisted(target);
            if (callValue > address(this).balance) {
                revert InsufficientEthForCalls(callValue, address(this).balance);
            }
            (bool success, bytes memory result) = target.call{value: callValue}(
                calls[i].callData
            );
            if (!success) {
                if (result.length > 0) {
                    assembly {
                        revert(add(32, result), mload(result))
                    }
                }
                revert ExternalCallFailed(target, i);
            }
        }

        for (uint256 a = 0; a < approvals.length; a++) {
            IERC20(approvals[a].token).forceApprove(approvals[a].spender, 0);
        }

        uint256 inputAfter = IERC20(inputToken).balanceOf(address(this));
        if (inputAfter > inputBefore) {
            uint256 inputDust = inputAfter - inputBefore;
            IERC20(inputToken).safeTransfer(msg.sender, inputDust);
            emit DustSwept(msg.sender, inputToken, inputDust);
        }

        for (uint256 j = 0; j < sweepTokens.length; j++) {
            address tokenAddr = sweepTokens[j];
Use code with caution.
if (tokenAddr != address(0) && tokenAddr != inputToken) {
uint256 balanceAfter = IERC20(tokenAddr).balanceOf(address(this));
if (balanceAfter > sweepBefore[j]) {
uint256 dust = balanceAfter - sweepBefore[j];
IERC20(tokenAddr).safeTransfer(msg.sender, dust);
emit DustSwept(msg.sender, tokenAddr, dust);
}
}
}
uint256 ethAfter = address(this).balance;
if (ethAfter > ethBefore) {
uint256 remainingEth = ethAfter - ethBefore;
(bool ethSuccess, ) = payable(msg.sender).call{value: remainingEth}("");
if (!ethSuccess) revert EthRefundFailed();
emit EthDustSwept(msg.sender, remainingEth);
}
if (outputToken != address(0) && minOutputAmount > 0) {
uint256 userOutputGained = IERC20(outputToken).balanceOf(msg.sender) - userOutputBefore;
if (userOutputGained < minOutputAmount) {
revert SlippageExceeded(userOutputGained, minOutputAmount);
}
}
emit BasketExecuted(msg.sender, inputToken, netAmount, feeAmount, tier);
}
receive() external payable {}
}
