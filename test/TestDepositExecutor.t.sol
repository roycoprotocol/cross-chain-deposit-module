// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, IWETH } from "../src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, WeirollWallet, RewardStyle, Points } from "./utils/RecipeMarketHubTestBase.sol";
import { DepositExecutor } from "../src/core/DepositExecutor.sol";
import { IOFT } from "../src/interfaces/IOFT.sol";
import { Vm } from "../lib/forge-std/src/Vm.sol";
import { OFTComposeMsgCodec } from "../src/libraries/OFTComposeMsgCodec.sol";
import { CCDMFeeLib } from "../src/libraries/CCDMFeeLib.sol";

/**
 * @title E2E_Test_DepositExecutor
 * @notice Tests bridging flows from the DepositLocker on the source chain to the DepositExecutor on the destination chain,
 *         including recipe execution logic, deposit distribution, and final withdrawals.
 */
contract E2E_Test_DepositExecutor is RecipeMarketHubTestBase {
    using OFTComposeMsgCodec for bytes;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    uint256 mainnetFork;
    uint256 polygonFork;

    bytes32[23][10] internal merkleProofs = [
        [
            bytes32(hex"a012c49d0c0e1d874413f2e13052640878fe87e79a7a359e61fba00717154553"),
            bytes32(hex"d29b1bf4c0e4bf5e7414d53868ece8fe3b06064b783c969264ae09b22298d2b1"),
            bytes32(hex"04bd1ba8da37089323ed194a25867ec9adeab0c6b9f7ce2651d9da95c67e672f"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"1f49569426ebb7547e6374fb300e0e5b68c55d5e2adf345fdd3b30f426bf6838"),
            bytes32(hex"d29b1bf4c0e4bf5e7414d53868ece8fe3b06064b783c969264ae09b22298d2b1"),
            bytes32(hex"04bd1ba8da37089323ed194a25867ec9adeab0c6b9f7ce2651d9da95c67e672f"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"d2fc385f69d8462fa14fa16f3bdac117764151d1fdcb1ec0d2c6ad9cac8c3c67"),
            bytes32(hex"a75e843c67e58f3b47d99d067b88be3374bce9ec305d06f9d3a1f009c307e1fc"),
            bytes32(hex"04bd1ba8da37089323ed194a25867ec9adeab0c6b9f7ce2651d9da95c67e672f"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"aa223c71fb30532fb75e9b055d28e4d8824974fe9c0eadb0490abddccddf7dc3"),
            bytes32(hex"a75e843c67e58f3b47d99d067b88be3374bce9ec305d06f9d3a1f009c307e1fc"),
            bytes32(hex"04bd1ba8da37089323ed194a25867ec9adeab0c6b9f7ce2651d9da95c67e672f"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"cb128b2e66780d5aaf645c34ea8eded7a859ff568770b258d31864e4153660d6"),
            bytes32(hex"e153a3ec315672ab00fe8a09f6fc6e9b1b62e921ea3a1d6240ad8f9f948c4d20"),
            bytes32(hex"28d2ed7ef79ea24b6b86265c591cbbc18e0e46b4b113553fc6349c8608cb01ca"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"722cbf8429bce1f5c8d760ee6ac1dc8d4e48180dfeb59ac5318c6079fc6081ae"),
            bytes32(hex"e153a3ec315672ab00fe8a09f6fc6e9b1b62e921ea3a1d6240ad8f9f948c4d20"),
            bytes32(hex"28d2ed7ef79ea24b6b86265c591cbbc18e0e46b4b113553fc6349c8608cb01ca"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"a5d65ffd023df551993097ea2733e77a679f87e7f5e7e16e56f6ce7a6d4cb3a9"),
            bytes32(hex"bf5127c28633e4df22435f4c99de1e8b70ec8e24c3d5a7f8fd23c344937dbb40"),
            bytes32(hex"28d2ed7ef79ea24b6b86265c591cbbc18e0e46b4b113553fc6349c8608cb01ca"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"081f7a9826416f09f03b662c002a30be8278f3975c52c802564870770d123772"),
            bytes32(hex"bf5127c28633e4df22435f4c99de1e8b70ec8e24c3d5a7f8fd23c344937dbb40"),
            bytes32(hex"28d2ed7ef79ea24b6b86265c591cbbc18e0e46b4b113553fc6349c8608cb01ca"),
            bytes32(hex"66173640e2255217550448fa3fe9aef9573d0d0432cee7ffbadaaebc2eb8b07c"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"f763543317e0e6e8825a5d9f6130e71d4504cb432f9732197ac28a19cbe7d07b"),
            bytes32(hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5"),
            bytes32(hex"b4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30"),
            bytes32(hex"409d81b7a0256d99d937b13343bbddc0e4b0c4e9b42701567b978a39fc4b440d"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ],
        [
            bytes32(hex"068628237ffa766f7b73f6a9e05ab85887ad677ebd93db2b0b806e0fd4ddf831"),
            bytes32(hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5"),
            bytes32(hex"b4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30"),
            bytes32(hex"409d81b7a0256d99d937b13343bbddc0e4b0c4e9b42701567b978a39fc4b440d"),
            bytes32(hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"),
            bytes32(hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"),
            bytes32(hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"),
            bytes32(hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"),
            bytes32(hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"),
            bytes32(hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"),
            bytes32(hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"),
            bytes32(hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"),
            bytes32(hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"),
            bytes32(hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"),
            bytes32(hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"),
            bytes32(hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"),
            bytes32(hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"),
            bytes32(hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"),
            bytes32(hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"),
            bytes32(hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"),
            bytes32(hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"),
            bytes32(hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"),
            bytes32(hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377")
        ]
    ];

    struct BridgeDepositsResult {
        bytes32 marketHash;
        address[] depositors;
        uint256[] depositAmounts;
        address depositLocker;
        bytes encodedPayload;
        bytes32 guid;
        uint256 actualNumberOfDepositors;
        bytes32 merkleRoot;
        uint256 merkleAmountDeposited;
    }

    struct DepositExecutorSetup {
        DepositExecutor depositExecutor;
        WeirollWalletHelper walletHelper;
    }

    /**
     * @notice Sets up the mainnet and polygon forks for testing.
     */
    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        polygonFork = vm.createFork(POLYGON_RPC_URL);
    }

    function test_ExecutorOnBridge_MerkleDeposits_WithDepositRecipeExecution(uint256 unlockTimestamp, uint256 dustAmount) external {
        // Bounds
        uint256 numDepositors = 10;
        uint256 offerAmount = 1_000_000e6;
        uint256 dustAmount = bound(dustAmount, 0, 10_000e6);

        // 1. Bridge deposits on the source chain
        BridgeDepositsResult memory bridgeResult = _bridgeMerkleDeposits(offerAmount, numDepositors);

        // 2. Switch to the Polygon fork
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        // Bound the unlockTimestamp
        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 7 days);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        // 3. Deploy the DepositExecutor on the destination
        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101, // Destination chain LZ EID
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        // 4. Transfer ownership of the campaign to IP_ADDRESS
        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        // 5. Build the deposit recipe
        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        // 6. Initialize the campaign on the destination
        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        // 7. Verify the campaign
        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // 8. Simulate bridging tokens (fund the depositExecutor)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        // 9. Compose the message
        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.GAS_FOR_MERKLE_BRIDGE }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // 10. Analyze logs: WeirollWallet creation
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // 11. Basic checks on the WeirollWallet
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);

        // Check the deposit tokens remain in depositExecutor, not the wallet
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        // 12. Execute deposit recipe
        address[] memory weirollWallets = new address[](1);
        weirollWallets[0] = address(weirollWalletCreatedForBridge);

        (bytes32 merkleRoot, uint256 totalMerkleTreeSourceAmountLeftToWithdraw) =
            depositExecutor.getMerkleInfoForWeirollWallet(bridgeResult.marketHash, address(weirollWalletCreatedForBridge));

        assertEq(merkleRoot, bridgeResult.merkleRoot);
        assertEq(totalMerkleTreeSourceAmountLeftToWithdraw, bridgeResult.merkleAmountDeposited);

        vm.startPrank(IP_ADDRESS);
        depositExecutor.executeDepositRecipes(bridgeResult.marketHash, weirollWallets);
        vm.stopPrank();

        // Confirm no tokens left in the WeirollWallet prior to dust
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);

        // 13. Simulate dust leftover
        deal(USDC_POLYGON_ADDRESS, address(weirollWalletCreatedForBridge), dustAmount);
        uint256 initialReceiptTokenBalance = ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge));

        // 14. Warp beyond the unlock time
        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        // 15. Each depositor withdraws
        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            vm.warp(unlockTimestamp + (i * 1 hours));

            // Suppose merkleProofs[i] is a bytes32[23] memory
            bytes32[23] memory fixedProof = merkleProofs[i];

            // Build a new dynamic array of the same length
            bytes32[] memory dynamicProof = new bytes32[](23);

            // Copy each element
            for (uint256 j = 0; j < 23; j++) {
                dynamicProof[j] = fixedProof[j];
            }

            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdrawMerkleDeposit(address(weirollWalletCreatedForBridge), i, bridgeResult.depositAmounts[i], dynamicProof);
            vm.stopPrank();

            // Check that depositor got their share of receipt tokens
            assertGe(ERC20(aUSDC_POLYGON).balanceOf(bridgeResult.depositors[i]), ((initialReceiptTokenBalance * bridgeResult.depositAmounts[i]) / offerAmount));

            // If there's dust, check it was distributed proportionally
            if (dustAmount > 1e6) {
                assertApproxEqRel(
                    ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), ((dustAmount * bridgeResult.depositAmounts[i]) / offerAmount), 0.01e18
                );
            }
        }

        // Confirm WeirollWallet is drained
        assertEq(ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        if (dustAmount > 1e6) {
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        }
    }

    function test_ExecutorOnBridge_MerkleDeposits_NoDepositRecipeExecution(uint256 unlockTimestamp) external {
        // Bounds
        uint256 numDepositors = 10;
        uint256 offerAmount = 1_000_000e6;

        // 1. Bridge deposits on the source chain
        BridgeDepositsResult memory bridgeResult = _bridgeMerkleDeposits(offerAmount, numDepositors);

        // 2. Switch to the Polygon fork
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        // Bound the unlockTimestamp
        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 7 days);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        // 3. Deploy the DepositExecutor on the destination
        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101, // Destination chain LZ EID
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        // 4. Transfer ownership of the campaign to IP_ADDRESS
        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        // 5. Build the deposit recipe
        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        // 6. Initialize the campaign on the destination
        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        // 7. Verify the campaign
        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // 8. Simulate bridging tokens (fund the depositExecutor)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        // 9. Compose the message
        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.GAS_FOR_MERKLE_BRIDGE }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // 10. Analyze logs: WeirollWallet creation
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // 11. Basic checks on the WeirollWallet
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);

        // Check the deposit tokens remain in depositExecutor, not the wallet
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        // 12. Execute deposit recipe
        address[] memory weirollWallets = new address[](1);
        weirollWallets[0] = address(weirollWalletCreatedForBridge);

        (bytes32 merkleRoot, uint256 totalMerkleTreeSourceAmountLeftToWithdraw) =
            depositExecutor.getMerkleInfoForWeirollWallet(bridgeResult.marketHash, address(weirollWalletCreatedForBridge));

        assertEq(merkleRoot, bridgeResult.merkleRoot);
        assertEq(totalMerkleTreeSourceAmountLeftToWithdraw, bridgeResult.merkleAmountDeposited);

        // 14. Warp beyond the unlock time
        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        // 15. Each depositor withdraws
        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            vm.warp(unlockTimestamp + (i * 1 hours));

            // Suppose merkleProofs[i] is a bytes32[23] memory
            bytes32[23] memory fixedProof = merkleProofs[i];

            // Build a new dynamic array of the same length
            bytes32[] memory dynamicProof = new bytes32[](23);

            // Copy each element
            for (uint256 j = 0; j < 23; j++) {
                dynamicProof[j] = fixedProof[j];
            }

            vm.expectEmit(true, true, false, true, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(depositExecutor), bridgeResult.depositors[i], bridgeResult.depositAmounts[i]);

            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdrawMerkleDeposit(address(weirollWalletCreatedForBridge), i, bridgeResult.depositAmounts[i], dynamicProof);
            vm.stopPrank();

            // Confirm that depositor got their original deposit
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), bridgeResult.depositAmounts[i]);
        }

        // Confirm WeirollWallet is drained
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
    }

    /**
     * @notice Tests bridging (with deposit recipe execution) from the source chain to the destination chain.
     * @param offerAmount The amount offered for deposit.
     * @param numDepositors The number of depositors participating.
     * @param unlockTimestamp The timestamp when deposits can be unlocked.
     * @param dustAmount A leftover token amount in the Weiroll Wallet to simulate dust.
     */
    function test_ExecutorOnBridge_IndividualDeposits_WithDepositRecipeExecution(
        uint256 offerAmount,
        uint256 numDepositors,
        uint256 unlockTimestamp,
        uint256 dustAmount
    )
        external
    {
        // Bounds
        offerAmount = bound(offerAmount, 10e6, 1_000_000e6);
        dustAmount = bound(dustAmount, 0, 1_000_000e6);

        // 1. Bridge deposits on the source chain
        BridgeDepositsResult memory bridgeResult = _bridgeDeposits(offerAmount, numDepositors);
        numDepositors = bridgeResult.actualNumberOfDepositors;

        // 2. Switch to the Polygon fork
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        // Bound the unlockTimestamp
        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 7 days);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        // 3. Deploy the DepositExecutor on the destination
        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101, // Destination chain LZ EID
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        // 4. Transfer ownership of the campaign to IP_ADDRESS
        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        // 5. Build the deposit recipe
        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        // 6. Initialize the campaign on the destination
        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        // 7. Verify the campaign
        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // 8. Simulate bridging tokens (fund the depositExecutor)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        // 9. Compose the message
        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.estimateIndividualDepositorsBridgeGasLimit(numDepositors) }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // 10. Analyze logs: WeirollWallet creation
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // 11. Basic checks on the WeirollWallet
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);

        // Check the deposit tokens remain in depositExecutor, not the wallet
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        // 12. Execute deposit recipe
        address[] memory weirollWallets = new address[](1);
        weirollWallets[0] = address(weirollWalletCreatedForBridge);

        vm.startPrank(IP_ADDRESS);
        depositExecutor.executeDepositRecipes(bridgeResult.marketHash, weirollWallets);
        vm.stopPrank();

        // Confirm no tokens left in the WeirollWallet prior to dust
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);

        // 13. Simulate dust leftover
        deal(USDC_POLYGON_ADDRESS, address(weirollWalletCreatedForBridge), dustAmount);
        uint256 initialReceiptTokenBalance = ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge));

        // 14. Warp beyond the unlock time
        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        // 15. Each depositor withdraws
        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            vm.warp(unlockTimestamp + (i * 1 hours));

            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdrawIndividualDeposits(walletsToWithdraw);
            vm.stopPrank();

            // Check that depositor got their share of receipt tokens
            assertGe(ERC20(aUSDC_POLYGON).balanceOf(bridgeResult.depositors[i]), ((initialReceiptTokenBalance * bridgeResult.depositAmounts[i]) / offerAmount));

            // If there's dust, check it was distributed proportionally
            if (dustAmount > 1e6) {
                assertApproxEqRel(
                    ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), ((dustAmount * bridgeResult.depositAmounts[i]) / offerAmount), 0.01e18
                );
            }
        }

        // Confirm WeirollWallet is drained
        assertEq(ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        if (dustAmount > 1e6) {
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        }
    }

    /**
     * @notice Tests bridging (without deposit recipe execution).
     * @param offerAmount The amount offered for deposit.
     * @param numDepositors The number of depositors participating.
     * @param unlockTimestamp The timestamp when deposits can be unlocked.
     */
    function test_ExecutorOnBridge_IndividualDeposits_NoDepositRecipeExecution(uint256 offerAmount, uint256 numDepositors, uint256 unlockTimestamp) external {
        offerAmount = bound(offerAmount, 1e6, type(uint48).max);

        // 1. Bridge deposits on the source chain
        BridgeDepositsResult memory bridgeResult = _bridgeDeposits(offerAmount, numDepositors);
        numDepositors = bridgeResult.actualNumberOfDepositors;

        // 2. Switch to polygon fork
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        // Bound the unlockTimestamp
        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 120 days);

        weirollImplementation = new WeirollWallet();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        // 3. Deploy deposit executor
        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101,
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        // 4. Build deposit recipe (though we won't execute it)
        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // 5. Simulate bridging tokens
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.estimateIndividualDepositorsBridgeGasLimit(numDepositors) }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // 6. Check logs for WeirollWallet creation
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // Basic checks
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);

        // Check the deposit tokens remain in depositExecutor
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        // 7. Each depositor withdraws
        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            vm.expectCall(USDC_POLYGON_ADDRESS, abi.encodeCall(ERC20.transfer, (bridgeResult.depositors[i], bridgeResult.depositAmounts[i])));
            vm.expectEmit(true, true, false, true, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(depositExecutor), bridgeResult.depositors[i], bridgeResult.depositAmounts[i]);

            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdrawIndividualDeposits(walletsToWithdraw);
            vm.stopPrank();

            // Confirm that depositor got their original deposit
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), bridgeResult.depositAmounts[i]);
        }

        // Confirm WeirollWallet is drained
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
    }

    /**
     * @notice Simulates bridging deposits by setting up environment, creating depositors, bridging tokens on the source chain.
     * @param offerAmount The total amount offered for deposits.
     * @param numDepositors The number of depositors to simulate.
     * @return result A struct containing all relevant data about the bridged deposits.
     */
    function _bridgeDeposits(uint256 offerAmount, uint256 numDepositors) internal returns (BridgeDepositsResult memory result) {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;
        vm.makePersistent(IP_ADDRESS);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS);
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS);
        depositTokens[1] = ERC20(WBTC_MAINNET_ADDRESS);
        lzV2OFTs[1] = IOFT(WBTC_OFT_ADAPTER_MAINNET_ADDRESS);

        // Deploy the DepositLocker
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        result.depositLocker = address(depositLocker);

        // Bound number of depositors
        numDepositors = bound(numDepositors, 1, depositLocker.MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE());
        result.actualNumberOfDepositors = numDepositors;

        // Build deposit + withdrawal recipes
        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), USDC_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        result.marketHash = recipeMarketHub.createMarket(USDC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create an IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(result.marketHash, offerAmount, IP_ADDRESS);

        result.depositors = new address[](numDepositors);
        result.depositAmounts = new uint256[](numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            result.depositors[i] = ap;

            // Fund AP
            deal(USDC_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);
            ERC20(USDC_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            // Destructure the tuple for depositor info
            (uint256 totalAmountDeposited,) = depositLocker.marketHashToDepositorToIndividualDepositorInfo(result.marketHash, ap);
            result.depositAmounts[i] = totalAmountDeposited;
        }

        // Set campaign owners
        bytes32[] memory marketHashes = new bytes32[](1);
        marketHashes[0] = result.marketHash;
        address[] memory owners = new address[](1);
        owners[0] = IP_ADDRESS;

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setCampaignOwners(marketHashes, owners);
        vm.stopPrank();

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(result.marketHash);
        vm.stopPrank();

        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.recordLogs();
        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(result.marketHash, result.depositors);
        vm.stopPrank();

        // Extract logs => store in result
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (result.encodedPayload,,) = abi.decode(logs[logs.length - 3].data, (bytes, bytes, address));
        result.guid = logs[logs.length - 1].topics[1];
    }

    /**
     * @notice Extracts a slice of bytes from the given data starting at a specific index.
     * @param begin The starting index for the slice.
     * @param data The bytes data to slice.
     * @return A new bytes array containing the sliced data.
     */
    function getSlice(uint256 begin, bytes memory data) internal pure returns (bytes memory) {
        bytes memory a = new bytes(data.length - begin);
        for (uint256 i = 0; i < data.length - begin; i++) {
            a[i] = data[i + begin];
        }
        return a;
    }

    function _bridgeMerkleDeposits(uint256 offerAmount, uint256 numDepositors) internal returns (BridgeDepositsResult memory result) {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18;
        uint256 minimumFrontendFee = 0.001e18;
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;
        vm.makePersistent(IP_ADDRESS);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // For example
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS);
        depositTokens[1] = ERC20(WBTC_MAINNET_ADDRESS);
        lzV2OFTs[1] = IOFT(WBTC_OFT_ADAPTER_MAINNET_ADDRESS);

        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);
        result.depositLocker = address(depositLocker);

        result.actualNumberOfDepositors = numDepositors;

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.merkleDeposit.selector, address(walletHelper), USDC_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        result.marketHash = recipeMarketHub.createMarket(USDC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        (bytes32 offerHash,) = createIPOffer_WithPoints(result.marketHash, offerAmount, IP_ADDRESS);

        result.depositors = new address[](numDepositors);
        result.depositAmounts = new uint256[](numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            result.depositors[i] = ap;

            deal(USDC_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);
            ERC20(USDC_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = offerAmount - ((numDepositors - 1) * fillAmount);
            }

            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            result.depositAmounts[i] = fillAmount;
        }

        bytes32[] memory marketHashes = new bytes32[](1);
        marketHashes[0] = result.marketHash;
        address[] memory owners = new address[](1);
        owners[0] = IP_ADDRESS;

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setCampaignOwners(marketHashes, owners);
        vm.stopPrank();

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(result.marketHash);
        vm.stopPrank();

        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        (, bytes32 marketMerkleRoot, uint256 merkleAmountDeposited) = depositLocker.marketHashToMerkleDepositsInfo(result.marketHash);
        result.merkleRoot = marketMerkleRoot;
        result.merkleAmountDeposited = merkleAmountDeposited;

        vm.recordLogs();
        vm.startPrank(IP_ADDRESS);
        depositLocker.merkleBridgeSingleTokens{ value: 5 ether }(result.marketHash);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (result.encodedPayload,,) = abi.decode(logs[logs.length - 3].data, (bytes, bytes, address));
        result.guid = logs[logs.length - 1].topics[1];
    }
}
