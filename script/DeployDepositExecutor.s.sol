// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Usage: source .env && forge script ./script/DeployDepositExecutor.s.sol --rpc-url=$CARTIO_RPC_URL --broadcast

import "forge-std/Script.sol";

import { DepositExecutor, IWETH } from "src/core/DepositExecutor.sol";

// Deployer
address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Deployment Configuration
address constant DEPOSIT_EXECUTOR_OWNER = 0x77777Cc68b333a2256B436D675E8D257699Aa667;
address constant LZ_V2_ENDPOINT = 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff;
uint32 constant SOURCE_CHAIN_LZ_EID = 40_161; // ETH SEPOLIA
address constant DEPOSIT_LOCKER = address(0);
address constant CAMPAIGN_VERIFIER = address(1);
IWETH constant WRAPPED_NATIVE_ASSET = IWETH(0x6969696969696969696969696969696969696969);

// Deployment salts
string constant DEPOSIT_EXECUTOR_SALT = "CCDM_DEPOSIT_EXECUTOR_02348b91cb3ab7939679deaa8b038ca74da64514";

// Expected deployment addresses after simulating deployment
address constant EXPECTED_DEPOSIT_EXECUTOR_ADDRESS = 0x907a876A54776Cb56BFC7b3e6580D7DFA774C16A;

contract DeployDepositExecutor is Script {
    error Create2DeployerNotDeployed();
    error DeploymentFailed(bytes reason);
    error AddressDoesNotContainBytecode(address addr);
    error NotDeployedToExpectedAddress(address expected, address actual);
    error UnexpectedDeploymentAddress(address expected, address actual);
    error DepositExecutorOwnerIncorrect(address expected, address actual);

    function _generateUint256SaltFromString(string memory _salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_salt)));
    }

    function _generateDeterminsticAddress(string memory _salt, bytes memory _creationCode) internal pure returns (address) {
        uint256 salt = _generateUint256SaltFromString(_salt);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDRESS, salt, keccak256(_creationCode)));
        return address(uint160(uint256(hash)));
    }

    function _checkDeployer() internal view {
        if (CREATE2_FACTORY_ADDRESS.code.length == 0) {
            revert Create2DeployerNotDeployed();
        }
    }

    function _verifyDepositExecutorDeployment(DepositExecutor _depositExecutor) internal view {
        if (address(_depositExecutor) != EXPECTED_DEPOSIT_EXECUTOR_ADDRESS) {
            revert UnexpectedDeploymentAddress(EXPECTED_DEPOSIT_EXECUTOR_ADDRESS, address(_depositExecutor));
        }

        if (_depositExecutor.owner() != DEPOSIT_EXECUTOR_OWNER) revert DepositExecutorOwnerIncorrect(DEPOSIT_EXECUTOR_OWNER, _depositExecutor.owner());
    }

    function _deploy(string memory _salt, bytes memory _creationCode) internal returns (address deployedAddress) {
        (bool success, bytes memory data) = CREATE2_FACTORY_ADDRESS.call(abi.encodePacked(_generateUint256SaltFromString(_salt), _creationCode));

        if (!success) {
            revert DeploymentFailed(data);
        }

        assembly ("memory-safe") {
            deployedAddress := shr(0x60, mload(add(data, 0x20)))
        }
    }

    function _deployWithSanityChecks(string memory _salt, bytes memory _creationCode) internal returns (address) {
        address expectedAddress = _generateDeterminsticAddress(_salt, _creationCode);

        if (address(expectedAddress).code.length != 0) {
            console2.log("contract already deployed at: ", expectedAddress);
            return expectedAddress;
        }

        address addr = _deploy(_salt, _creationCode);

        if (addr != expectedAddress) {
            revert NotDeployedToExpectedAddress(expectedAddress, addr);
        }

        if (address(addr).code.length == 0) {
            revert AddressDoesNotContainBytecode(addr);
        }

        return addr;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console2.log("Deploying with address: ", deployerAddress);
        console2.log("Deployer Balance: ", address(deployerAddress).balance);

        address[] memory LZ_V2_OFTs = new address[](3);
        LZ_V2_OFTs[0] = 0x370DC69d5B49E6844C867efA752b419EaC49ABa8;
        LZ_V2_OFTs[1] = 0x87C367a0522AEb8aD9F9660D2250f1eAC403C70F;
        LZ_V2_OFTs[2] = 0x4F5F42799d1E01662B629Ede265baEa223e9f9C7;

        bytes32[] memory SOURCE_MARKET_HASHES = new bytes32[](0);
        address[] memory CAMPAIGN_OWNERS = new address[](0);

        vm.startBroadcast(deployerPrivateKey);

        _checkDeployer();
        console2.log("Deployer is ready\n");

        // Deploy PointsFactory
        console2.log("Deploying DepositExecutor");
        bytes memory depositExecutorCreationCode = abi.encodePacked(
            vm.getCode("DepositExecutor"),
            abi.encode(
                DEPOSIT_EXECUTOR_OWNER,
                LZ_V2_ENDPOINT,
                CAMPAIGN_VERIFIER,
                WRAPPED_NATIVE_ASSET,
                SOURCE_CHAIN_LZ_EID,
                DEPOSIT_LOCKER,
                LZ_V2_OFTs,
                SOURCE_MARKET_HASHES,
                CAMPAIGN_OWNERS
            )
        );
        DepositExecutor depositExecutor = DepositExecutor(payable(_deployWithSanityChecks(DEPOSIT_EXECUTOR_SALT, depositExecutorCreationCode)));

        console2.log("Verifying DepositExecutor deployment");
        _verifyDepositExecutorDeployment(depositExecutor);
        console2.log("DepositExecutor deployed at: ", address(depositExecutor), "\n");

        vm.stopBroadcast();
    }
}
