// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library SafeCast {
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SafeCast: value doesn't fit in 16 bits");
        return uint16(value);
    }
}

library BytesLib {
    function toUint16(bytes memory _bytes, uint256 _start) internal pure returns (uint16) {
        require(_bytes.length >= _start + 2, "toUint16_outOfBounds");
        uint16 tempUint;
        assembly {
            tempUint := mload(add(add(_bytes, 0x2), _start))
        }
        return tempUint;
    }
}

library ExecutorOptions {
    uint8 internal constant WORKER_ID = 1;
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;

    function encodeLzComposeOption(
        uint16 _index,
        uint128 _gas,
        uint128 _value
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(_index, _gas, _value);
    }
}

library OptionsBuilder {
    using SafeCast for uint256;
    using BytesLib for bytes;

    uint16 internal constant TYPE_3 = 3;

    error InvalidOptionType(uint16 optionType);

    modifier onlyType3(bytes memory _options) {
        if (_options.toUint16(0) != TYPE_3) revert InvalidOptionType(_options.toUint16(0));
        _;
    }

    function newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(TYPE_3);
    }

    function addExecutorLzComposeOption(
        bytes memory _options,
        uint16 _index,
        uint128 _gas,
        uint128 _value
    ) internal pure onlyType3(_options) returns (bytes memory) {
        bytes memory option = ExecutorOptions.encodeLzComposeOption(_index, _gas, _value);
        return addExecutorOption(_options, ExecutorOptions.OPTION_TYPE_LZCOMPOSE, option);
    }

    function addExecutorOption(
        bytes memory _options,
        uint8 _optionType,
        bytes memory _option
    ) internal pure onlyType3(_options) returns (bytes memory) {
        return abi.encodePacked(
            _options,
            ExecutorOptions.WORKER_ID,
            _option.length.toUint16() + 1, // +1 for _optionType
            _optionType,
            _option
        );
    }
}
