// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";
import {console} from "forge-std/console.sol";

import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IVariableDebtToken} from "@aave/contracts/interfaces/IVariableDebtToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Aave v3 reverts `Errors.InvalidBurnAmount()` (0x2075cc10) when a repay rounds to zero debt shares.
/// Iris forwards the venue's debt balance as the repay amount, so a position whose Aave debt is one wei can
/// never be repaid through it: `Iris.repay` reverts and the loan cannot be closed.
contract AaveDustRepayDosTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    bytes4 internal constant INVALID_BURN_AMOUNT = 0x2075cc10;
    uint256 internal constant VARIABLE_RATE = 2;

    function _openAaveLoan(uint256 collateral, uint256 debt, uint256 seed)
        internal
        returns (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter)
    {
        (address collateralToken_, address debtToken_, bytes memory data_, IVenueAdapter adapter_) =
            _randomMarket(seed, uint256(VenueId.AAVE_V3));
        collateralToken = collateralToken_;

        vm.prank(owner);
        blm.setParams(debtToken_, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) =
            _boundHealthyPosition(collateralToken, debtToken_, collateral, debt, uint256(VenueId.AAVE_V3), data_);

        Quote memory quote = _buildQuote(
            collateralToken, debtToken_, collateral, debt, MIN_DURATION, 0, uint256(VenueId.AAVE_V3), data_
        );

        pod = _openLoan(quote);
        return (pod, collateralToken, debtToken_, data_, adapter_);
    }

    /// @dev Venue-only reproduction: on a real position, repaying one wei of the debt token reverts.
    function testAdapterRejectsOneWeiRepay(uint256 collateral, uint256 debt, uint256 seed) public {
        (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _openAaveLoan(collateral, debt, seed);

        deal(debtToken, pod, 1);

        vm.prank(address(iris));
        vm.expectRevert(abi.encodeWithSelector(INVALID_BURN_AMOUNT));
        IPod(pod)
            .delegateCall(
                address(adapter), abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, uint256(1), data)
            );
    }

    /// @dev End to end: with the venue debt at one wei, `Iris.repay` reverts and the loan stays open.
    function testCloseRevertsOnOneWeiOfVenueDebt(uint256 collateral, uint256 debt, uint256 seed) public {
        (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _openAaveLoan(collateral, debt, seed);

        // Pin the reported venue debt to one wei.
        (uint256 venueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        _mockPositionAssets(adapter, pod, collateralToken, debtToken, data, venueCollateral, 1);

        deal(debtToken, borrower, 1e30);
        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(INVALID_BURN_AMOUNT));
        iris.repay(pod);
        vm.stopPrank();

        assertTrue(iris.getPosition(pod).debt != 0);
    }

    /// @dev Control: the same position closes normally when the venue debt is fully repaid first.
    /// @dev Same state built only from real pool state: repay everything but one wei on the venue, no mocking.
    function testRealVenueDebtOfOneWei(uint256 collateral, uint256 debt, uint256 seed) public {
        (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _openAaveLoan(collateral, debt, seed);
        (, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        vm.assume(venueDebt > 1);

        IPool pool = IPool(address(AaveV3Adapter(address(adapter)).POOL()));
        // Repay down to a single outstanding debt share, the smallest non-zero debt the venue can hold.
        IVariableDebtToken debtShare = IVariableDebtToken(pool.getReserveData(debtToken).variableDebtTokenAddress);
        uint256 shares = debtShare.scaledBalanceOf(pod);
        uint256 payback =
            ((shares - 1) * pool.getReserveNormalizedVariableDebt(debtToken) + 1e27 - 1) / 1e27;
        deal(debtToken, pod, payback);
        vm.startPrank(pod);
        debtToken.safeApprove(address(pool), type(uint256).max);
        pool.repay(debtToken, payback, VARIABLE_RATE, pod);
        vm.stopPrank();

        (, uint256 dust) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(debtShare.scaledBalanceOf(pod), 1, "one share left");
        assertEq(dust, 2, "one debt share is worth two wei");

        // the amount liquidateBond would forward for a dust bond: 1 wei floors to zero shares
        deal(debtToken, pod, dust);
        vm.prank(pod);
        debtToken.safeApprove(address(adapter), type(uint256).max);
        // the amount liquidateBond would compute for a dust bond
        bytes memory call1 = abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, 1, data);
        vm.prank(address(iris));
        vm.expectRevert(abi.encodeWithSelector(INVALID_BURN_AMOUNT));
        IPod(pod).delegateCall(address(adapter), call1);
        bytes memory call2 = abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, dust, data);
        vm.prank(address(iris));
        IPod(pod).delegateCall(address(adapter), call2);

        (, uint256 left) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(left, 0, "the full share clears the venue debt");
    }

    function testPositionClosesWithZeroVenueDebt(uint256 collateral, uint256 debt, uint256 seed) public {
        (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _openAaveLoan(collateral, debt, seed);

        (, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);

        deal(debtToken, pod, venueDebt);
        vm.prank(address(iris));
        IPod(pod)
            .delegateCall(
                address(adapter), abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, venueDebt, data)
            );

        deal(debtToken, borrower, 1e30);
        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), type(uint256).max);
        iris.repay(pod);
        vm.stopPrank();

        assertEq(iris.getLoan(pod).debtToken, debtToken);
    }

    /// @dev Control on reachability: an Aave liquidation sized at `debt - 1` still closes the debt entirely, because
    /// v3.4 forbids leaving dust and rounds the payback up. So on Aave the one wei state comes from a partial repay.
    function testVenueLiquidationFullyCloses(uint256 collateral, uint256 debt, uint256 seed) public {
        (address pod, address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _openAaveLoan(collateral, debt, seed);

        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        vm.assume(venueDebt > 2);

        IPool pool = IPool(address(AaveV3Adapter(address(adapter)).POOL()));
        address provider = address(pool.ADDRESSES_PROVIDER());
        address oracle =
            abi.decode(_staticcall(provider, abi.encodeWithSignature("getPriceOracle()")), (address));

        // Price the collateral so the bonus seizure of `debt - 1` consumes exactly the whole collateral: Aave skips
        // the dust rule when all collateral is seized, which is the only way a liquidation may leave one wei.
        uint256 price = adapter.price(collateralToken, debtToken, data);
        uint256 crash = (1.05e18 * (venueDebt - 1)).mulDivDown(1e36, venueCollateral.mulDivDown(price, 1));
        uint256 rawPrice = abi.decode(_staticcall(oracle, abi.encodeWithSignature("getAssetPrice(address)", collateralToken)), (uint256));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("getAssetPrice(address)", collateralToken),
            abi.encode(rawPrice.mulDivDown(crash, 1e18))
        );

        (,,,,, uint256 hfAfter) = pool.getUserAccountData(pod);
        assertLt(hfAfter, 1e18, "position must be liquidatable");
        uint256 cover = venueDebt - 1;
        deal(debtToken, address(this), cover);
        debtToken.safeApproveWithRetry(address(pool), cover);
        // Landing the seizure exactly on the whole collateral is a one wei window; skip the draws that miss it.
        bool ok;
        try pool.liquidationCall(collateralToken, debtToken, pod, cover, true) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.assume(ok);
        vm.clearMockedCalls();

        iris.rebase(pod);
        (, uint256 dust) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(dust, 0, "liquidation is expected to clear the debt");
        assertEq(iris.getPosition(pod).debt, 0);
    }

    /// @dev End to end: a one wei bond turns `liquidateBond` into a one wei repay, which the venue rejects.
    function testLiquidateBondRevertsOnDerivedOneWeiRepay(uint256 seed) public {
        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, uint256(VenueId.AAVE_V3));

        uint256 debt = 1e6;
        uint256 collateral = (debt * 3).mulDivUp(1e36, adapter.price(collateralToken, debtToken, data));

        // requirement = debt * (slope * duration / 1 days + intercept) / WAD -> exactly one wei
        vm.prank(owner);
        blm.setParams(debtToken, 1, 1e18 / debt);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, 0, uint256(VenueId.AAVE_V3), data);
        assertEq(quote.bond, 1, "bond requirement must be one wei");
        quote.fixedRate = 0; // let the floating leg run past the fixed leg, which makes the bond unhealthy

        address pod = _openLoan(quote);
        vm.warp(block.timestamp + 4 hours);

        (, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertGt(venueDebt, 1, "venue debt must exceed one wei");

        // seized = 1 * lif / WAD = 0, so repaid = min(bond - seized, venueDebt) = 1
        vm.expectRevert(abi.encodeWithSelector(INVALID_BURN_AMOUNT));
        iris.liquidateBond(pod, receiver);
    }

    function _staticcall(address target, bytes memory cd) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(cd);
        require(ok, "staticcall failed");
        return ret;
    }

    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 venueId_,
        bytes memory data
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken;
        quote.debtToken = debtToken;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = duration;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = overduePeriod;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3;
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = data;
        quote.bond = blm.bondRequirement(quote);
    }
}
