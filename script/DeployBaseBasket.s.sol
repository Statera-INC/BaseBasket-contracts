// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../src/BaseBasketRouter.sol";
contract DeployBaseBasket is Script {
address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
address constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
address constant AERODROME_SLIPSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
address constant AERODROME_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
address constant ZERO_X_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
function run() external {
uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
address safeTreasury = vm.envAddress("SAFE_MULTISIG_ADDRESS");
uint256 proThresholdUsdc = 5_000e6;
uint256 whaleThresholdUsdc = 100_000e6;
uint256 timelockDelay = 86_400;
address[] memory proposers = new address;
proposers[0] = safeTreasury;
address[] memory executors = new address;
executors[0] = safeTreasury;
vm.startBroadcast(deployerPrivateKey);
TimelockController timelock = new TimelockController(
timelockDelay,
proposers,
executors,
address(0)
);
address deployer = vm.addr(deployerPrivateKey);
BaseBasketRouter router = new BaseBasketRouter(
safeTreasury,
deployer,
safeTreasury,
proThresholdUsdc,
whaleThresholdUsdc
);
router.setAllowedTarget(MORPHO_BLUE, true);
router.setAllowedTarget(AERODROME_ROUTER, true);
router.setAllowedTarget(AERODROME_SLIPSTREAM_ROUTER, true);
router.setAllowedTarget(AERODROME_POSITION_MANAGER, true);
router.setAllowedTarget(ZERO_X_ALLOWANCE_HOLDER, true);
router.setAllowedTarget(BASE_WETH, true);
router.transferOwnership(address(timelock));
vm.stopBroadcast();
console.log("TimelockController deployed at:", address(timelock));
console.log("BaseBasketRouter deployed at:", address(router));
}
}
