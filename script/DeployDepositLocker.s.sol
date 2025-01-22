// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { DepositLocker, RecipeMarketHubBase, IWETH, IUniswapV2Router01, IOFT } from "src/core/DepositLocker.sol";

// Deployer
address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Deployment Configuration
address constant DEPOSIT_LOCKER_OWNER = 0xCe6EC1D4401A3CbaEF79942ff257de2dFbC7714f;
uint32 constant DESTINATION_CHAIN_LZ_EID = 30_362; // Berachain
address constant DEPOSIT_EXECUTOR = address(0); // Will be set through setter once deployed
uint128 constant BASE_LZ_RECEIVE_GAS_LIMIT = 200_000;
address constant GREEN_LIGHTER = 0x5D1B9186Ac01B7c364734618172CD4487E68bC92;
RecipeMarketHubBase constant RECIPE_MARKET_HUB = RecipeMarketHubBase(0x783251f103555068c1E9D755f69458f39eD937c0);
IUniswapV2Router01 constant UNISWAP_V2_ROUTER = IUniswapV2Router01(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

// Deployment salts
string constant DEPOSIT_LOCKER_SALT = "BOYCO_CCDM_DEPOSIT_LOCKER";

// Expected deployment addresses after simulating deployment
address constant EXPECTED_DEPOSIT_LOCKER_ADDRESS = 0x7f4d49CF81bd0a25d0C1a66f302d250472B5352c;

contract DeployDepositLocker is Script {
    error Create2DeployerNotDeployed();
    error DeploymentFailed(bytes reason);
    error AddressDoesNotContainBytecode(address addr);
    error NotDeployedToExpectedAddress(address expected, address actual);
    error UnexpectedDeploymentAddress(address expected, address actual);
    error DepositLockerOwnerIncorrect(address expected, address actual);

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

    function _verifyDepositLockerDeployment(DepositLocker _depositLocker) internal view {
        if (address(_depositLocker) != EXPECTED_DEPOSIT_LOCKER_ADDRESS) {
            revert UnexpectedDeploymentAddress(EXPECTED_DEPOSIT_LOCKER_ADDRESS, address(_depositLocker));
        }

        if (_depositLocker.owner() != DEPOSIT_LOCKER_OWNER) revert DepositLockerOwnerIncorrect(DEPOSIT_LOCKER_OWNER, _depositLocker.owner());
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

        // Boyco Mainnet OFTs
        IOFT[] memory LZ_V2_OFTs = new IOFT[](30);
        LZ_V2_OFTs[0] = IOFT(0x77b2043768d28E9C9aB44E1aBfC95944bcE57931); // Stargate Pool Native
        LZ_V2_OFTs[1] = IOFT(0xc026395860Db2d07ee33e05fE50ed7bD583189C7); // Stargate Pool USDC
        LZ_V2_OFTs[2] = IOFT(0xB12979Ff302Ac903849948037A51792cF7186E8e); // SolvBTC OFT Adapter
        LZ_V2_OFTs[3] = IOFT(0x94DaBd84Cd36c4D364FcDD5CdABf41E73dBc99e6); // SolvBTC.bbn OFT Adapter
        LZ_V2_OFTs[4] = IOFT(0x628885bD8408781F681aD35FA480ed930FE94691); // SBTC OFT Adapter
        LZ_V2_OFTs[5] = IOFT(0x31290E76C7AD21867E4BDbe67E871DE1919E9776); // STONE OFT Adapter
        LZ_V2_OFTs[6] = IOFT(0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3); // rsETH OFT Adapter
        LZ_V2_OFTs[7] = IOFT(0x8A60E489004Ca22d775C5F2c657598278d17D9c2); // USDa Native OFT
        LZ_V2_OFTs[8] = IOFT(0x2B66AAdE1e9C062FF411bd47C44E0Ad696d43BD9); // sUSDa Native OFT
        LZ_V2_OFTs[9] = IOFT(0xf0e9f6D9Ba5D1B3f76e0f82F9DCDb9eBEef4b4dA); // rUSDC OFT Adapter
        LZ_V2_OFTs[10] = IOFT(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34); // USDe OFT Adapter
        LZ_V2_OFTs[11] = IOFT(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2); // sUSDe OFT Adapter
        LZ_V2_OFTs[12] = IOFT(0xcd2eb13D6831d4602D80E5db9230A57596CDCA63); // weETH OFT Adapter
        LZ_V2_OFTs[13] = IOFT(0x99de5239a8AD65ed86Db3d36e0fd9F9cBA7d63d5); // enzoBTC OFT Adapter
        LZ_V2_OFTs[14] = IOFT(0xbcE9988376C6b9c0c035bdbc9060568031d51130); // stBTC OFT Adapter
        LZ_V2_OFTs[15] = IOFT(0x37016812a5c2c54793Fd277b7f75086a47377d28); // waBTC OFT Adapter
        LZ_V2_OFTs[16] = IOFT(0xADc9c900b05F39f48bB6F402A1BAE60929F4f9A8); // pumpBTC.bera Native OFT
        LZ_V2_OFTs[17] = IOFT(0x17C3B688BaDD6dd11244096A9FBc4ae0ADd551ab); // uniBTC OFT Adapter
        LZ_V2_OFTs[18] = IOFT(0x1290A6b480f7eF14925229fdB66f5680aD8F44AD); // LBTC OFT Adapter
        LZ_V2_OFTs[19] = IOFT(0x0b835f07a2a54C0e80c1F585e5b6Dd732816dA3F); // fBTC OFT Adapter
        LZ_V2_OFTs[20] = IOFT(0xAfb6A7742639F661fFA703920070926463012B7B); // ylrsETH OFT Adapter
        LZ_V2_OFTs[21] = IOFT(0xaFC13b62e0177575d88ba18471f7526CBf4AAFDB); // ylPumpBTC OFT Adapter
        LZ_V2_OFTs[22] = IOFT(0x237978176C3811A1648F3106797E3c3e070F48Ec); // ylBTCLST OFT Adapter
        LZ_V2_OFTs[23] = IOFT(0xcb742C033310A2136Ed571e0c63d74773C0563eD); // yluniBTC OFT Adapter
        LZ_V2_OFTs[24] = IOFT(0x67a9197AA9f5b449FC480044EC04AC5aa7694DD6); // ylstETH OFT Adapter
        LZ_V2_OFTs[25] = IOFT(0x1486D39646cdee84619bd05997319545A8575079); // rswETH OFT Adapter
        LZ_V2_OFTs[26] = IOFT(0xE5169F892000fC3BEd5660f62C67FAEE7F97718B); // MIM OFT Adapter
        LZ_V2_OFTs[27] = IOFT(0xE14C486b93C3B62F76F88cf8FE4B36fb672f3B26); // USD0 OFT Adapter
        LZ_V2_OFTs[28] = IOFT(0xd155d91009cbE9B0204B06CE1b62bf1D793d3111); // USD0++ OFT Adapter
        LZ_V2_OFTs[29] = IOFT(0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee); // USDT0 OFT Adapter

        vm.startBroadcast(deployerPrivateKey);

        _checkDeployer();
        console2.log("Deployer is ready\n");

        // Deploy PointsFactory
        console2.log("Deploying DepositLocker");
        bytes memory depositLockerCreationCode = abi.encodePacked(
            vm.getCode("DepositLocker"),
            abi.encode(
                DEPOSIT_LOCKER_OWNER,
                DESTINATION_CHAIN_LZ_EID,
                DEPOSIT_EXECUTOR,
                BASE_LZ_RECEIVE_GAS_LIMIT,
                GREEN_LIGHTER,
                RECIPE_MARKET_HUB,
                UNISWAP_V2_ROUTER,
                LZ_V2_OFTs
            )
        );
        DepositLocker depositLocker = DepositLocker(payable(_deployWithSanityChecks(DEPOSIT_LOCKER_SALT, depositLockerCreationCode)));

        console2.log("Verifying DepositLocker deployment");
        _verifyDepositLockerDeployment(depositLocker);
        console2.log("DepositLocker deployed at: ", address(depositLocker), "\n");

        vm.stopBroadcast();
    }
}
