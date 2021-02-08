// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "@openzeppelin/contracts/math/SafeMath.sol"; // TODO: Bring into @yield-protocol/utils
import "@yield-protocol/utils/contracts/math/DecimalMath.sol"; // TODO: Make into library
import "@yield-protocol/utils/contracts/utils/SafeCast.sol";
import "@yield-protocol/utils/contracts/utils/YieldAuth.sol";
import "@yield-protocol/vault-v1/contracts/interfaces/IFYDai.sol";
import "@yield-protocol/vault-v1/contracts/interfaces/ITreasury.sol";
import "@yield-protocol/vault-v1/contracts/interfaces/IController.sol";
import "@yield-protocol/yieldspace-v1/contracts/interfaces/IPool.sol";
import "dss-interfaces/src/dss/AuthGemJoinAbstract.sol";
import "dss-interfaces/src/dss/DaiAbstract.sol";
import "./interfaces/IUSDC.sol";
import "./interfaces/DssPsmAbstract.sol";
import "hardhat/console.sol";


contract USDCProxy is DecimalMath {
    using SafeCast for uint256;
    using SafeMath for uint256;
    using YieldAuth for DaiAbstract;
    using YieldAuth for IFYDai;
    using YieldAuth for IUSDC;
    using YieldAuth for IController;
    using YieldAuth for IPool;

    DaiAbstract public immutable dai;
    IUSDC public immutable usdc;
    IController public immutable controller;
    DssPsmAbstract public immutable psm;

    address public immutable treasury;

    bytes32 public constant WETH = "ETH-A";

    constructor(IController _controller, DssPsmAbstract psm_) public {
        ITreasury _treasury = _controller.treasury();
        dai = _treasury.dai();
        treasury = address(_treasury);
        controller = _controller;
        psm = psm_;
        usdc = IUSDC(AuthGemJoinAbstract(psm_.gemJoin()).gem());
    }

    /// @dev Borrow fyDai from Controller, sell it immediately for Dai in a pool, and sell the Dai for USDC in Maker's PSM, for a maximum fyDai debt.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `borrowDaiForMaximumFYDaiWithSignature`.
    /// Caller must have called `borrowDaiForMaximumFYDaiWithSignature` at least once before to set proxy approvals.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param usdcToBorrow Exact amount of USDC that should be obtained.
    /// @param maximumFYDai Maximum amount of FYDai to borrow.
    function borrowUSDCForMaximumFYDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 usdcToBorrow,
        uint256 maximumFYDai
    )
        public
        returns (uint256)
    {
        pool.fyDai().approve(address(pool), type(uint256).max); // TODO: Move to right place
        
        uint256 fee = usdcToBorrow.mul(psm.tout()) / 1e18;
        uint256 daiToBuy = usdcToBorrow.add(fee);

        uint256 fyDaiToBorrow = pool.buyDaiPreview(daiToBuy.toUint128()); // If not calculated on-chain, there will be fyDai left as slippage
        require (fyDaiToBorrow <= maximumFYDai, "USDCProxy: Too much fyDai required");

        // The collateral for this borrow needs to have been posted beforehand
        controller.borrow(collateral, maturity, msg.sender, address(this), fyDaiToBorrow);
        pool.buyDai(address(this), address(this), daiToBuy.toUint128());
        psm.buyGem(to, usdcToBorrow);

        return fyDaiToBorrow;
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of USDC exchanged Dai in Maker's PSM, and then for fyDai at pool rates, with a minimum of fyDai debt required to be paid.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// If `repaymentInUSDC` exceeds the existing debt, the surplus will be locked in the proxy.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param usdcRepayment Exact amount of USDC that should be spent on the repayment.
    /// @param minFYDaiRepayment Minimum amount of fyDai debt to repay.
    function repayDebtEarlyWithUSDC(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 usdcRepayment,
        uint256 minFYDaiRepayment
    )
        public
        returns (uint256)
    {
        uint256 fee = usdcRepayment.mul(psm.tin()) / 1e18; // Fees in PSM are fixed point in WAD
        uint256 daiObtained = usdcRepayment.sub(fee); // If not right, the `sellDai` might revert.

        usdc.transferFrom(msg.sender, address(this), usdcRepayment);
        psm.sellGem(address(this), usdcRepayment); // Thanks for not returning how much dai was the USDC sold for.
        uint256 fyDaiRepayment =  pool.sellDai(address(this), address(this), daiObtained.toUint128());
        require(fyDaiRepayment >= minFYDaiRepayment, "USDCProxy: Not enough debt repaid");
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiRepayment);

        return daiObtained;
    }

    /// @dev Repay all debt in Controller using for a maximum amount of USDC, reverting if surpassed.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param maxUSDCIn Maximum amount of USDC that should be spent on the repayment.
    function repayAllEarlyWithUSDC(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 maxUSDCIn
    )
        public
        returns (uint256)
    {
        uint256 fyDaiDebt = controller.debtFYDai(collateral, maturity, to);
        uint256 daiIn = pool.buyFYDaiPreview(fyDaiDebt.toUint128());
        uint256 usdcIn = (daiIn * 1e18) / (1e18 + psm.tin()); // Fixed point division with 18 decimals

        require (usdcIn <= maxUSDCIn, "USDCProxy: Too much USDC required");
        usdc.transferFrom(msg.sender, address(this), usdcIn);
        psm.sellGem(address(this), usdcIn);
        pool.buyFYDai(address(this), address(this), fyDaiDebt.toUint128());
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiDebt);

        return usdcIn;
    }

    /// @dev Repay an exact amount of Dai-denominated debt in Controller using USDC.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param usdcRepayment Amount of USDC that should be spent on the repayment.
    function repayDebtMatureWithUSDC(
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 usdcRepayment
    )
        public
        returns (uint256)
    {
        usdc.transferFrom(msg.sender, address(this), usdcRepayment);
        psm.sellGem(address(this), usdcRepayment);
        uint256 daiRepayment = (usdcRepayment * (1e18 - psm.tin())) / 1e18;
        controller.repayDai(collateral, maturity, address(this), to, daiRepayment);

        return daiRepayment;
    }

    /// --------------------------------------------------
    /// Signature method wrappers
    /// --------------------------------------------------

    /// @dev Set proxy approvals for `borrowUSDCForMaximumFYDai` with a given pool.
    function borrowUSDCForMaximumFYDaiApprove(IPool pool) public {
        // allow the pool to pull FYDai/dai from us for trading
        if (pool.fyDai().allowance(address(this), address(pool)) < type(uint112).max)
            pool.fyDai().approve(address(pool), type(uint256).max);
        
        if (dai.allowance(address(this), address(psm)) < type(uint256).max)
            dai.approve(address(psm), type(uint256).max); // Approve to provide Dai to the PSM
    }

    /// @dev Borrow fyDai from Controller, sell it immediately for Dai in a pool, and sell the Dai for USDC in Maker's PSM, for a maximum fyDai debt.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `borrowDaiForMaximumFYDaiWithSignature`.
    /// Caller must have called `borrowDaiForMaximumFYDaiWithSignature` at least once before to set proxy approvals.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param usdcToBorrow Exact amount of USDC that should be obtained.
    /// @param maximumFYDai Maximum amount of FYDai to borrow.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function borrowUSDCForMaximumFYDaiWithSignature(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 usdcToBorrow,
        uint256 maximumFYDai,
        
        bytes memory controllerSig
    )
        public
        returns (uint256)
    {
        borrowUSDCForMaximumFYDaiApprove(pool);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        return borrowUSDCForMaximumFYDai(pool, collateral, maturity, to, usdcToBorrow, maximumFYDai);
    }

    /// @dev Set proxy approvals for `repayDebtEarlyWithUSDC` with a given pool.
    function repayDebtEarlyWithUSDCApprove(IPool pool) public {
        // Send the USDC to the PSM
        if (usdc.allowance(address(this), address(psm.gemJoin())) < type(uint112).max) // USDC reduces allowances when set to MAX
            usdc.approve(address(psm.gemJoin()), type(uint256).max);
        
        // Send the Dai to the Pool
        if (dai.allowance(address(this), address(pool)) < type(uint256).max)
            dai.approve(address(pool), type(uint256).max);

        // Send the fyDai to the Treasury
        if (pool.fyDai().allowance(address(this), treasury) < type(uint112).max)
            pool.fyDai().approve(treasury, type(uint256).max);
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of USDC exchanged Dai in Maker's PSM, and then for fyDai at pool rates, with a minimum of fyDai debt required to be paid.
    /// If `repaymentInDai` exceeds the existing debt, only the necessary Dai will be used.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param fyDaiDebt Amount of fyDai debt to repay.
    /// @param repaymentInUSDC Exact amount of USDC that should be spent on the repayment.
    /// @param usdcSig packed signature for permit of USDC transfers to this proxy. Ignored if '0x'.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function repayDebtEarlyWithUSDCWithSignature(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 repaymentInUSDC,
        uint256 fyDaiDebt, // Calculate off-chain, works as slippage protection
        bytes memory usdcSig,
        bytes memory controllerSig
    )
        public
        returns (uint256)
    {
        repayDebtEarlyWithUSDCApprove(pool);
        if (usdcSig.length > 0) usdc.permitPacked(address(this), usdcSig);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        return repayDebtEarlyWithUSDC(pool, collateral, maturity, to, repaymentInUSDC, fyDaiDebt);
    }

    /// @dev Set proxy approvals for `repayDebtMatureWithUSDC`
    function repayDebtMatureWithUSDCApprove() public {
        // Send the USDC to the PSM
        if (usdc.allowance(address(this), address(psm.gemJoin())) < type(uint112).max) // USDC reduces allowances when set to MAX
            usdc.approve(address(psm.gemJoin()), type(uint256).max);
        
        // Send the Dai to the Treasury
        if (dai.allowance(address(this), address(treasury)) < type(uint256).max)
            dai.approve(address(treasury), type(uint256).max);
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of USDC exchanged Dai in Maker's PSM.
    /// If the amount of Dai obtained by selling USDC exceeds the existing debt, the surplus will be locked in the proxy.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param repaymentInUSDC Exact amount of USDC that should be spent on the repayment.
    /// @param usdcSig packed signature for permit of USDC transfers to this proxy. Ignored if '0x'.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function repayDebtMatureWithUSDCWithSignature(
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 repaymentInUSDC,
        bytes memory usdcSig,
        bytes memory controllerSig
    )
        public
        returns (uint256)
    {
        repayDebtMatureWithUSDCApprove();
        if (usdcSig.length > 0) usdc.permitPacked(address(this), usdcSig);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        return repayDebtMatureWithUSDC(collateral, maturity, to, repaymentInUSDC);
    }

    /// @dev Repay all debt in Controller using for a maximum amount of USDC, reverting if surpassed.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param maxUSDCIn Maximum amount of USDC that should be spent on the repayment.
    /// @param usdcSig packed signature for permit of USDC transfers to this proxy. Ignored if '0x'.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function repayAllEarlyWithUSDCWithSignature(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 maxUSDCIn,
        bytes memory usdcSig,
        bytes memory controllerSig
    )
        public
        returns (uint256)
    {
        repayDebtEarlyWithUSDCApprove(pool); // Same permissions
        if (usdcSig.length > 0) usdc.permitPacked(address(this), usdcSig);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        return repayAllEarlyWithUSDC(pool, collateral, maturity, to, maxUSDCIn);
    }
}
