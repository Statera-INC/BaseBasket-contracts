// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/BaseBasketRouter.sol";
contract BaseBasketRouterTest is Test {
BaseBasketRouter router;
address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
address safeTreasury = makeAddr("safeTreasury");
address timelock = makeAddr("timelock");
address user = makeAddr("user");
function setUp() public {
router = new BaseBasketRouter(safeTreasury, timelock, safeTreasury, 5_000e6, 100_000e6);
vm.prank(timelock);
router.setAllowedTarget(BASE_WETH, true);
}
function testThreeTierFees() public {
deal(BASE_USDC, user, 200_000e6);
BaseBasketRouter.Approval[] memory approvals = new BaseBasketRouter.Approval;
BaseBasketRouter.Call[] memory calls = new BaseBasketRouter.Call;
address[] memory sweeps = new address;
vm.startPrank(user);
IERC20(BASE_USDC).approve(address(router), 200_000e6);
router.executeAtomicBasket(BASE_USDC, 1_000e6, 150, address(0), 0, approvals, calls, sweeps);
assertEq(IERC20(BASE_USDC).balanceOf(safeTreasury), 15e6);
router.executeAtomicBasket(BASE_USDC, 10_000e6, 60, address(0), 0, approvals, calls, sweeps);
assertEq(IERC20(BASE_USDC).balanceOf(safeTreasury), 75e6);
router.executeAtomicBasket(BASE_USDC, 100_000e6, 15, address(0), 0, approvals, calls, sweeps);
assertEq(IERC20(BASE_USDC).balanceOf(safeTreasury), 225e6);
vm.stopPrank();
}
}
