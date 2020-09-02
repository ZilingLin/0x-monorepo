/*

  Copyright 2019 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.9;
pragma experimental ABIEncoderV2;

import "@0x/contracts-utils/contracts/src/DeploymentConstants.sol";
import "./IMooniswap.sol";
import "./ApproximateBuys.sol";
import "./SamplerUtils.sol";


contract MooniswapSampler is
    DeploymentConstants,
    SamplerUtils,
    ApproximateBuys
{
    /// @dev Gas limit for Mooniswap calls.
    uint256 constant private MOONISWAP_CALL_GAS = 150e3; // 150k

    /// @dev Sample sell quotes from Mooniswap.
    /// @param takerToken Address of the taker token (what to sell).
    /// @param makerToken Address of the maker token (what to buy).
    /// @param takerTokenAmounts Taker token sell amount for each sample.
    /// @return makerTokenAmounts Maker amounts bought at each taker token
    ///         amount.
    function sampleSellsFromMooniswap(
        address takerToken,
        address makerToken,
        uint256[] memory takerTokenAmounts
    )
        public
        view
        returns (IMooniswap pool, uint256[] memory makerTokenAmounts)
    {
        _assertValidPair(makerToken, takerToken);
        uint256 numSamples = takerTokenAmounts.length;
        makerTokenAmounts = new uint256[](numSamples);

        address mooniswapTakerToken = takerToken == _getWethAddress() ? address(0) : takerToken;
        address mooniswapMakerToken = makerToken == _getWethAddress() ? address(0) : makerToken;
        // Find the pool for the pair, ETH is represented
        // as address(0)
        pool = IMooniswap(
            IMooniswapRegistry(_getMooniswapAddress()).pools(mooniswapTakerToken, mooniswapMakerToken)
        );
        // If there is no pool then return early
        if (address(pool) == address(0)) {
            return (pool, makerTokenAmounts);
        }

        for (uint256 i = 0; i < numSamples; i++) {
            uint256 buyAmount = sampleSingleSellFromMooniswapPool(
                pool,
                mooniswapTakerToken,
                mooniswapMakerToken,
                takerTokenAmounts[i]
            );
            // Exit early if the amount is too high for the source to serve
            if (buyAmount == 0) {
                break;
            }
            makerTokenAmounts[i] = buyAmount;
        }
    }

    function sampleSingleSellFromMooniswapPool(
        IMooniswap pool,
        address mooniswapTakerToken,
        address mooniswapMakerToken,
        uint256 takerTokenAmount
    )
        public
        view
        returns (uint256 makerTokenAmount)
    {
        uint256 poolBalance = mooniswapTakerToken == address(0)
            ? address(pool).balance
            : IERC20Token(mooniswapTakerToken).balanceOf(address(pool));

        // If the pool balance is smaller than the sell amount
        // don't sample to avoid multiplication overflow in buys
        if (poolBalance < takerTokenAmount) {
            return makerTokenAmount;
        }
        (bool didSucceed, bytes memory resultData) =
            address(pool).staticcall.gas(MOONISWAP_CALL_GAS)(
                abi.encodeWithSelector(
                    IMooniswap(0).getReturn.selector,
                    mooniswapTakerToken,
                    mooniswapMakerToken,
                    takerTokenAmount
                ));
        if (didSucceed) {
            makerTokenAmount = abi.decode(resultData, (uint256));
        }
    }

    /// @dev Sample buy quotes from Mooniswap.
    /// @param takerToken Address of the taker token (what to sell).
    /// @param makerToken Address of the maker token (what to buy).
    /// @param makerTokenAmounts Maker token sell amount for each sample.
    /// @return takerTokenAmounts Taker amounts sold at each maker token
    ///         amount.
    function sampleBuysFromMooniswap(
        address takerToken,
        address makerToken,
        uint256[] memory makerTokenAmounts
    )
        public
        view
        returns (IMooniswap pool, uint256[] memory takerTokenAmounts)
    {
        _assertValidPair(makerToken, takerToken);
        uint256 numSamples = takerTokenAmounts.length;
        makerTokenAmounts = new uint256[](numSamples);

        address mooniswapTakerToken = takerToken == _getWethAddress() ? address(0) : takerToken;
        address mooniswapMakerToken = makerToken == _getWethAddress() ? address(0) : makerToken;
        // Find the pool for the pair, ETH is represented
        // as address(0)
        pool = IMooniswap(
            IMooniswapRegistry(_getMooniswapAddress()).pools(mooniswapTakerToken, mooniswapMakerToken)
        );
        // If there is no pool then return early
        if (address(pool) == address(0)) {
            return (pool, takerTokenAmounts);
        }

        takerTokenAmounts = _sampleApproximateBuys(
            ApproximateBuyQuoteOpts({
                makerTokenData: abi.encode(mooniswapMakerToken, pool),
                takerTokenData: abi.encode(mooniswapTakerToken, pool),
                getSellQuoteCallback: _sampleSellForApproximateBuyFromMooniswap
            }),
            makerTokenAmounts
        );
    }

    function _sampleSellForApproximateBuyFromMooniswap(
        bytes memory takerTokenData,
        bytes memory makerTokenData,
        uint256 sellAmount
    )
        private
        view
        returns (uint256 buyAmount)
    {
        (address mooniswapTakerToken, IMooniswap pool) =
            abi.decode(takerTokenData, (address, IMooniswap));
        (address mooniswapMakerToken) =
            abi.decode(makerTokenData, (address));
        (bool success, bytes memory resultData) =
            address(this).staticcall(abi.encodeWithSelector(
                this.sampleSingleSellFromMooniswapPool.selector,
                pool,
                mooniswapTakerToken,
                mooniswapMakerToken,
                _toSingleValueArray(sellAmount)
            ));
        if (!success) {
            return 0;
        }
        // solhint-disable-next-line indent
        return abi.decode(resultData, (uint256[]))[0];
    }
}