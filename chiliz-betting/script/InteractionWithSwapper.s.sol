pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MyChzSwapper.sol";

contract InteractSwap is Script {
    function run() external {
        // Load env variables
        uint256 amountIn       = 5 * 10**18;
        uint256 amountOutMin   = 2;
        address fanToken       = 0xb0Fa395a3386800658B9617F90e834E2CeC76Dd3; //$PSG
        address USDT           = 0xd1CD747B46750D807076BfC75f98b6c5b236898D; 

        // Path: [wCHZ, USDT] 
        address wCHZ = 0x678c34581db0a7808d0aC669d7025f1408C9a3C6 ;
        address[] memory path = new address[](2);
        path[0] = wCHZ;
        path[1] = USDT;

        uint256 deployerPrivateKey = vm.envUint("SPICY_TESTNET_PK");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Instantiate the deployed swapper contract
        MyChzSwapper swapper = MyChzSwapper(payable(0xB5A4Db33256782398D6bd42C49c42819a4b9953D));

        // Perform the swap: send CHZ native
        swapper.swapChzForFan(amountOutMin, path);

        vm.stopBroadcast();
    }
}
