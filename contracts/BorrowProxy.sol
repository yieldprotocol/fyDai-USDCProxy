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
import "@yield-protocol/utils/contracts/interfaces/weth/IWeth.sol";
import "dss-interfaces/src/dss/DaiAbstract.sol";
import "./interfaces/AuthGemJoinAbstract.sol";
import "./interfaces/DssPsmAbstract.sol";


contract BorrowProxy is DecimalMath {
    using SafeCast for uint256;
    using SafeMath for uint256;
    using YieldAuth for DaiAbstract;
    using YieldAuth for IFYDai;
    using YieldAuth for IController;
    using YieldAuth for IPool;

    IWeth public immutable weth;
    DaiAbstract public immutable dai;
    IERC20 public immutable usdc;
    IController public immutable controller;
    DssPsmAbstract public immutable psm;

    address public immutable treasury;

    bytes32 public constant WETH = "ETH-A";

    constructor(IController _controller, DssPsmAbstract psm_) public {
        ITreasury _treasury = _controller.treasury();
        weth = _treasury.weth();
        dai = _treasury.dai();
        treasury = address(_treasury);
        controller = _controller;
        psm = psm_;
        usdc = IERC20(AuthGemJoinAbstract(psm_.gemJoin()).gem());
    }

    /// @dev The WETH9 contract will send ether to BorrowProxy on `weth.withdraw` using this function.
    receive() external payable { }

    /// @dev Users use `post` in BorrowProxy to post ETH to the Controller (amount = msg.value), which will be converted to Weth here.
    /// @param to Yield Vault to deposit collateral in.
    function post(address to)
        external payable {
        // Approvals in the constructor don't work for contracts calling this via `addDelegatecall`
        if (weth.allowance(address(this), treasury) < type(uint256).max) weth.approve(treasury, type(uint256).max);

        weth.deposit{ value: msg.value }();
        controller.post(WETH, address(this), to, msg.value);
    }

    /// @dev Users wishing to withdraw their Weth as ETH from the Controller should use this function.
    /// Users must have called `controller.addDelegate(borrowProxy.address)` or `withdrawWithSignature` to authorize BorrowProxy to act in their behalf.
    /// @param to Wallet to send Eth to.
    /// @param amount Amount of weth to move.
    function withdraw(address payable to, uint256 amount)
        public {
        controller.withdraw(WETH, msg.sender, address(this), amount);
        weth.withdraw(amount);
        to.transfer(amount);
    }

    /// @dev Borrow fyDai from Controller and sell it immediately for Dai, for a maximum fyDai debt.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `borrowDaiForMaximumFYDaiWithSignature`.
    /// Caller must have called `borrowDaiForMaximumFYDaiWithSignature` at least once before to set proxy approvals.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param daiToBorrow Exact amount of Dai that should be obtained.
    /// @param maximumFYDai Maximum amount of FYDai to borrow.
    function borrowDaiForMaximumFYDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 daiToBorrow,
        uint256 maximumFYDai
    )
        public
        returns (uint256)
    {
        uint256 fyDaiToBorrow = pool.buyDaiPreview(daiToBorrow.toUint128()); // If not calculated on-chain, there will be fyDai left as slippage
        require (fyDaiToBorrow <= maximumFYDai, "BorrowProxy: Too much fyDai required");

        // The collateral for this borrow needs to have been posted beforehand
        controller.borrow(collateral, maturity, msg.sender, address(this), fyDaiToBorrow);
        pool.buyDai(address(this), to, daiToBorrow.toUint128());

        return fyDaiToBorrow;
    }

    /// @dev Borrow fyDai from Controller and sell it immediately for a minimum amount of Dai.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `borrowDaiForMaximumFYDaiWithSignature`.
    /// Caller must have called `borrowMinDaiForFYDaiWithSignature` at least once before to set proxy approvals.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param fyDaiDebt FYDai debt to acquire.
    /// @param minDaiOut Minimum amount of Dai that should be obtained.
    function borrowMinDaiForFYDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 fyDaiDebt,
        uint256 minDaiOut
    )
        public
        returns (uint256)
    {
        // The collateral for this borrow needs to have been posted beforehand
        controller.borrow(collateral, maturity, msg.sender, address(this), fyDaiDebt);
        uint256 daiOut = pool.buyDai(address(this), to, fyDaiDebt.toUint128());
        require (daiOut >= minDaiOut, "BorrowProxy: Not enough Dai obtained");

        return daiOut;
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
        require (fyDaiToBorrow <= maximumFYDai, "BorrowProxy: Too much fyDai required");

        // The collateral for this borrow needs to have been posted beforehand
        controller.borrow(collateral, maturity, msg.sender, address(this), fyDaiToBorrow);
        pool.buyDai(address(this), address(this), daiToBuy.toUint128());
        psm.buyGem(to, usdcToBorrow);

        return fyDaiToBorrow;
    }

    /// @dev Borrow fyDai from Controller, sell it immediately for Dai in a pool, and sell the Dai for USDC in Maker's PSM, for a maximum fyDai debt.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `borrowDaiForMaximumFYDaiWithSignature`.
    /// Caller must have called `borrowDaiForMaximumFYDaiWithSignature` at least once before to set proxy approvals.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param fyDaiDebt Amount of FYDai to borrow.
    /// @param minUSDCToBorrow Minumum amount of USDC that should be obtained.
    function borrowMinUSDCForFYDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 fyDaiDebt, // Calculated off-chain
        uint256 minUSDCToBorrow
    )
        public
        returns (uint256)
    {
        // The collateral for this borrow needs to have been posted beforehand
        controller.borrow(collateral, maturity, msg.sender, address(this), fyDaiDebt);
        uint256 daiBought = pool.sellFYDai(address(this), address(this), fyDaiDebt.toUint128());
        uint256 usdcToBorrow = divd(daiBought, psm.tout() + 1e18);
        require(usdcToBorrow >= minUSDCToBorrow, "BorrowProxy: Not enough USDC obtained");
        psm.buyGem(to, usdcToBorrow);

        return usdcToBorrow;
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of Dai exchanged for fyDai at pool rates, with a minimum of fyDai debt required to be paid.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// If `repaymentInDai` exceeds the existing debt, only the necessary Dai will be used.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param minimumFYDaiRepayment Minimum amount of fyDai debt to repay.
    /// @param repaymentInDai Exact amount of Dai that should be spent on the repayment.
    function repayMinimumFYDaiDebtForDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 minimumFYDaiRepayment,
        uint256 repaymentInDai
    )
        public
        returns (uint256)
    {
        uint256 fyDaiRepayment = pool.sellDaiPreview(repaymentInDai.toUint128());
        uint256 fyDaiDebt = controller.debtFYDai(collateral, maturity, to);
        if(fyDaiRepayment <= fyDaiDebt) { // Sell no more Dai than needed to cancel all the debt
            pool.sellDai(msg.sender, address(this), repaymentInDai.toUint128());
        } else { // If we have too much Dai, then don't sell it all and buy the exact amount of fyDai needed instead.
            pool.buyFYDai(msg.sender, address(this), fyDaiDebt.toUint128());
            fyDaiRepayment = fyDaiDebt;
        }
        require (fyDaiRepayment >= minimumFYDaiRepayment, "BorrowProxy: Not enough fyDai debt repaid");
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiRepayment);

        return fyDaiRepayment;
    }

    /// @dev Repay an amount of fyDai debt in Controller using a maximum amount of Dai exchanged for fyDai at pool rates.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayFYDaiDebtForMaximumDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayFYDaiDebtForMaximumDaiWithSignature`.
    /// If trying to repay more fyDai debt than existing, the surplus won't be refunded.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param fyDaiDebt Amount of fyDai debt to repay.
    /// @param maxDaiIn Maximum amount of Dai that should be spent on the repayment.
    function repayFYDaiDebtForMaximumDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 fyDaiDebt,
        uint256 maxDaiIn
    )
        public
        returns (uint256)
    {
        uint256 daiIn = pool.buyFYDai(msg.sender, address(this), fyDaiDebt.toUint128());
        require (daiIn <= maxDaiIn, "BorrowProxy: Too much Dai required");

        // TODO: Maybe have a different function to repay a whole vault using pool.buyFYDai
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiDebt);

        return daiIn;
    }

    /// @dev Repay all debt in Controller using for a maximum amount of Dai, reverting if surpassed.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayAllWithFYDaiWithSignature`.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param maxDaiIn Maximum amount of Dai that should be spent on the repayment.
    function repayAllWithFYDai(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 maxDaiIn
    )
        public
        returns (uint256)
    {
        uint256 fyDaiDebt = controller.debtFYDai(collateral, maturity, to);
        uint256 daiIn = pool.buyFYDai(msg.sender, address(this), fyDaiDebt.toUint128());
        require (daiIn <= maxDaiIn, "BorrowProxy: Too much Dai required");
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiDebt);

        return daiIn;
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of USDC exchanged Dai in Maker's PSM, and then for fyDai at pool rates, with a minimum of fyDai debt required to be paid.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// If `repaymentInDai` exceeds the existing debt, only the necessary Dai will be used.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param fyDaiDebt Amount of fyDai debt to repay.
    /// @param repaymentInUSDC Exact amount of USDC that should be spent on the repayment.
    function repayMinimumFYDaiDebtForUSDC(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 repaymentInUSDC,
        uint256 fyDaiDebt // Calculate off-chain, works as slippage protection
    )
        public
        returns (uint256)
    {
        uint256 fee = repaymentInUSDC.mul(psm.tin()) / 1e18; // Fees in PSM are fixed point in WAD
        uint256 daiObtained = repaymentInUSDC.sub(fee);

        usdc.transferFrom(msg.sender, address(this), repaymentInUSDC);
        psm.sellGem(address(this), repaymentInUSDC);
        pool.buyFYDai(msg.sender, address(this), fyDaiDebt.toUint128()); // Find out fyDaiDebt off-chain, see previous method.
        controller.repayFYDai(collateral, maturity, address(this), to, fyDaiDebt);

        return daiObtained;
    }


    /// @dev Sell fyDai for Dai
    /// Caller must have approved the fyDai transfer with `fyDai.approve(fyDaiIn)` or with `sellFYDaiWithSignature`.
    /// Caller must have approved the proxy using`pool.addDelegate(borrowProxy)` or with `sellFYDaiWithSignature`.
    /// @param to Wallet receiving the dai being bought
    /// @param fyDaiIn Amount of fyDai being sold
    /// @param minDaiOut Minimum amount of dai being bought
    function sellFYDai(IPool pool, address to, uint128 fyDaiIn, uint128 minDaiOut)
        public
        returns(uint256)
    {
        uint256 daiOut = pool.sellFYDai(msg.sender, to, fyDaiIn);
        require(
            daiOut >= minDaiOut,
            "BorrowProxy: Limit not reached"
        );
        return daiOut;
    }

    /// @dev Buy fyDai with Dai
    /// Caller must have approved the dai transfer with `dai.approve(maxDaiIn)` or with `sellDaiWithSignature`.
    /// Caller must have approved the proxy using`pool.addDelegate(borrowProxy)` or with `sellDaiWithSignature`.
    /// @param to Wallet receiving the fyDai being bought
    /// @param fyDaiOut Amount of fyDai being bought
    /// @param maxDaiIn Maximum amount of Dai being paid for the fyDai
    function buyFYDai(IPool pool, address to, uint128 fyDaiOut, uint128 maxDaiIn)
        public
        returns(uint256)
    {
        uint256 daiIn = pool.buyFYDai(msg.sender, to, fyDaiOut);
        require(
            daiIn <= maxDaiIn,
            "BorrowProxy: Limit exceeded"
        );
        return daiIn;
    }

    /// @dev Sell Dai for fyDai
    /// Caller must have approved the dai transfer with `dai.approve(daiIn)` or with `sellDaiWithSignature`.
    /// Caller must have approved the proxy using`pool.addDelegate(borrowProxy)` or with `sellDaiWithSignature`.
    /// @param to Wallet receiving the fyDai being bought
    /// @param daiIn Amount of dai being sold
    /// @param minFYDaiOut Minimum amount of fyDai being bought
    function sellDai(IPool pool, address to, uint128 daiIn, uint128 minFYDaiOut)
        public
        returns(uint256)
    {
        uint256 fyDaiOut = pool.sellDai(msg.sender, to, daiIn);
        require(
            fyDaiOut >= minFYDaiOut,
            "BorrowProxy: Limit not reached"
        );
        return fyDaiOut;
    }

    /// @dev Buy Dai for fyDai
    /// Caller must have approved the fyDai transfer with `fyDai.approve(maxFYDaiIn)` or with `buyDaiWithSignature`.
    /// Caller must have approved the proxy using`pool.addDelegate(borrowProxy)` or with `buyDaiWithSignature`.
    /// @param to Wallet receiving the dai being bought
    /// @param daiOut Amount of dai being bought
    /// @param maxFYDaiIn Maximum amount of fyDai being sold
    function buyDai(IPool pool, address to, uint128 daiOut, uint128 maxFYDaiIn)
        public
        returns(uint256)
    {
        uint256 fyDaiIn = pool.buyDai(msg.sender, to, daiOut);
        require(
            maxFYDaiIn >= fyDaiIn,
            "BorrowProxy: Limit exceeded"
        );
        return fyDaiIn;
    }

    /// --------------------------------------------------
    /// Signature method wrappers
    /// --------------------------------------------------

    /// @dev Determine whether all approvals and signatures are in place for `withdrawWithSignature`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `withdrawWithSignature` must be called with a controller signature.
    /// If `return` is `(true, true)`, `withdrawWithSignature` won't fail because of missing approvals or signatures.
    function withdrawCheck() public view returns (bool, bool) {
        bool approvals = true; // sellFYDai doesn't need proxy approvals
        bool controllerSig = controller.delegated(msg.sender, address(this));
        return (approvals, controllerSig);
    }

    /// @dev Users wishing to withdraw their Weth as ETH from the Controller should use this function.
    /// @param to Wallet to send Eth to.
    /// @param amount Amount of weth to move.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function withdrawWithSignature(address payable to, uint256 amount, bytes memory controllerSig)
        public {
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        withdraw(to, amount);
    }

    /// @dev Determine whether all approvals and signatures are in place for `borrowDaiForMaximumFYDai` with a given pool.
    /// If `return[0]` is `false`, calling `borrowDaiForMaximumFYDaiWithSignature` will set the approvals.
    /// If `return[1]` is `false`, `borrowDaiForMaximumFYDaiWithSignature` must be called with a controller signature
    /// If `return` is `(true, true)`, `borrowDaiForMaximumFYDai` won't fail because of missing approvals or signatures.
    function borrowDaiForMaximumFYDaiCheck(IPool pool) public view returns (bool, bool) {
        bool approvals = pool.fyDai().allowance(address(this), address(pool)) >= type(uint112).max;
        bool controllerSig = controller.delegated(msg.sender, address(this));
        return (approvals, controllerSig);
    }

    /// @dev Set proxy approvals for `borrowDaiForMaximumFYDai` with a given pool.
    function borrowDaiForMaximumFYDaiApprove(IPool pool) public {
        // allow the pool to pull FYDai/dai from us for trading
        if (pool.fyDai().allowance(address(this), address(pool)) < type(uint112).max)
            pool.fyDai().approve(address(pool), type(uint256).max);
    }

    /// @dev Borrow fyDai from Controller and sell it immediately for Dai, for a maximum fyDai debt.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Wallet to send the resulting Dai to.
    /// @param daiToBorrow Exact amount of Dai that should be obtained.
    /// @param maximumFYDai Maximum amount of FYDai to borrow.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function borrowDaiForMaximumFYDaiWithSignature(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 daiToBorrow,
        uint256 maximumFYDai,
        bytes memory controllerSig
    )
        public
        returns (uint256)
    {
        borrowDaiForMaximumFYDaiApprove(pool);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        return borrowDaiForMaximumFYDai(pool, collateral, maturity, to, daiToBorrow, maximumFYDai);
    }



    /// @dev Determine whether all approvals and signatures are in place for `borrowUSDCForMaximumFYDai` with a given pool.
    /// If `return[0]` is `false`, calling `borrowUSDCForMaximumFYDaiWithSignature` will set the approvals.
    /// If `return[1]` is `false`, `borrowDaiForMaximumFYDaiWithSignature` must be called with a controller signature
    /// If `return` is `(true, true)`, `borrowDaiForMaximumFYDai` won't fail because of missing approvals or signatures.
    function borrowUSDCForMaximumFYDaiCheck(IPool pool) public view returns (bool, bool) {
        bool approvals = pool.fyDai().allowance(address(this), address(pool)) >= type(uint112).max;
        approvals = approvals && dai.allowance(address(this), address(psm)) == type(uint256).max;
        approvals = approvals && usdc.allowance(address(this), address(psm.gemJoin())) >= type(uint112).max;
        bool controllerSig = controller.delegated(msg.sender, address(this));
        return (approvals, controllerSig);
    }

    /// @dev Set proxy approvals for `borrowUSDCForMaximumFYDai` with a given pool.
    function borrowUSDCForMaximumFYDaiApprove(IPool pool) public {
        // allow the pool to pull FYDai/dai from us for trading
        if (pool.fyDai().allowance(address(this), address(pool)) < type(uint112).max)
            pool.fyDai().approve(address(pool), type(uint256).max);
        
        if (dai.allowance(address(this), address(psm)) < type(uint256).max)
            dai.approve(address(psm), type(uint256).max); // Approve to provide Dai to the PSM

        if (usdc.allowance(address(this), address(psm.gemJoin())) < type(uint112).max) // TODO: Check if USDC reduces allowances when set to MAX
            usdc.approve(address(psm.gemJoin()), type(uint256).max); // TODO: Move to repay with USDC
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



    /// @dev Determine whether all approvals and signatures are in place for `repayDaiWithSignature`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `repayDaiWithSignature` must be called with a dai permit signature.
    /// If `return[2]` is `false`, `repayDaiWithSignature` must be called with a controller signature.
    /// If `return` is `(true, true, true)`, `repayDaiWithSignature` won't fail because of missing approvals or signatures.
    /// If `return` is `(true, true, any)`, `controller.repayDai` can be called directly and won't fail because of missing approvals or signatures.
    function repayDaiCheck() public view returns (bool, bool, bool) {
        bool approvals = true; // repayDai doesn't need proxy approvals
        bool daiSig = dai.allowance(msg.sender, treasury) == type(uint256).max;
        bool controllerSig = controller.delegated(msg.sender, address(this));
        return (approvals, daiSig, controllerSig);
    }

    /// @dev Burns Dai from caller to repay debt in a Yield Vault.
    /// User debt is decreased for the given collateral and fyDai series, in Yield vault `to`.
    /// The amount of debt repaid changes according to series maturity and MakerDAO rate and chi, depending on collateral type.
    /// `A signature is provided as a parameter to this function, so that `dai.approve()` doesn't need to be called.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield vault to repay debt for.
    /// @param daiAmount Amount of Dai to use for debt repayment.
    /// @param daiSig packed signature for permit of dai transfers to this proxy. Ignored if '0x'.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    function repayDaiWithSignature(
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 daiAmount,
        bytes memory daiSig,
        bytes memory controllerSig
    )
        external
        returns(uint256)
    {
        if (daiSig.length > 0) dai.permitPackedDai(treasury, daiSig);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        controller.repayDai(collateral, maturity, msg.sender, to, daiAmount);
    }

    /// @dev Set proxy approvals for `repayMinimumFYDaiDebtForDai` with a given pool.
    function repayMinimumFYDaiDebtForDaiApprove(IPool pool) public {
        // allow the treasury to pull FYDai from us for repaying
        if (pool.fyDai().allowance(address(this), treasury) < type(uint112).max)
            pool.fyDai().approve(treasury, type(uint256).max);
    }

    /// @dev Determine whether all approvals and signatures are in place for `repayMinimumFYDaiDebtForDai` with a given pool.
    /// If `return[0]` is `false`, calling `repayMinimumFYDaiDebtForDaiWithSignature` will set the approvals.
    /// If `return[1]` is `false`, `repayMinimumFYDaiDebtForDaiWithSignature` must be called with a controller signature
    /// If `return[2]` is `false`, `repayMinimumFYDaiDebtForDaiWithSignature` must be called with a pool signature
    /// If `return` is `(true, true, true)`, `repayMinimumFYDaiDebtForDai` won't fail because of missing approvals or signatures.
    function repayMinimumFYDaiDebtForDaiCheck(IPool pool) public view returns (bool, bool, bool) {
        bool approvals = pool.fyDai().allowance(address(this), treasury) >= type(uint112).max;
        bool controllerSig = controller.delegated(msg.sender, address(this));
        bool poolSig = pool.delegated(msg.sender, address(this));
        return (approvals, controllerSig, poolSig);
    }

    /// @dev Repay an amount of fyDai debt in Controller using a given amount of Dai exchanged for fyDai at pool rates, with a minimum of fyDai debt required to be paid.
    /// Must have approved the operator with `controller.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// Must have approved the operator with `pool.addDelegate(borrowProxy.address)` or with `repayMinimumFYDaiDebtForDaiWithSignature`.
    /// If `repaymentInDai` exceeds the existing debt, only the necessary Dai will be used.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param to Yield Vault to repay fyDai debt for.
    /// @param minimumFYDaiRepayment Minimum amount of fyDai debt to repay.
    /// @param repaymentInDai Exact amount of Dai that should be spent on the repayment.
    /// @param controllerSig packed signature for delegation of this proxy in the controller. Ignored if '0x'.
    /// @param poolSig packed signature for delegation of this proxy in a pool. Ignored if '0x'.
    function repayMinimumFYDaiDebtForDaiWithSignature(
        IPool pool,
        bytes32 collateral,
        uint256 maturity,
        address to,
        uint256 minimumFYDaiRepayment,
        uint256 repaymentInDai,
        bytes memory controllerSig,
        bytes memory poolSig
    )
        public
        returns (uint256)
    {
        repayMinimumFYDaiDebtForDaiApprove(pool);
        if (controllerSig.length > 0) controller.addDelegatePacked(controllerSig);
        if (poolSig.length > 0) pool.addDelegatePacked(poolSig);
        return repayMinimumFYDaiDebtForDai(pool, collateral, maturity, to, minimumFYDaiRepayment, repaymentInDai);
    }

    /// @dev Determine whether all approvals and signatures are in place for `sellFYDai`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `sellFYDaiWithSignature` must be called with a fyDai permit signature.
    /// If `return[2]` is `false`, `sellFYDaiWithSignature` must be called with a pool signature.
    /// If `return` is `(true, true, true)`, `sellFYDai` won't fail because of missing approvals or signatures.
    function sellFYDaiCheck(IPool pool) public view returns (bool, bool, bool) {
        bool approvals = true; // sellFYDai doesn't need proxy approvals
        bool fyDaiSig = pool.fyDai().allowance(msg.sender, address(pool)) >= type(uint112).max;
        bool poolSig = pool.delegated(msg.sender, address(this));
        return (approvals, fyDaiSig, poolSig);
    }

    /// @dev Sell fyDai for Dai
    /// @param to Wallet receiving the dai being bought
    /// @param fyDaiIn Amount of fyDai being sold
    /// @param minDaiOut Minimum amount of dai being bought
    /// @param fyDaiSig packed signature for approving fyDai transfers to a pool. Ignored if '0x'.
    /// @param poolSig packed signature for delegation of this proxy in a pool. Ignored if '0x'.
    function sellFYDaiWithSignature(
        IPool pool,
        address to,
        uint128 fyDaiIn,
        uint128 minDaiOut,
        bytes memory fyDaiSig,
        bytes memory poolSig
    )
        public
        returns(uint256)
    {
        if (fyDaiSig.length > 0) pool.fyDai().permitPacked(address(pool), fyDaiSig);
        if (poolSig.length > 0) pool.addDelegatePacked(poolSig);
        return sellFYDai(pool, to, fyDaiIn, minDaiOut);
    }

    /// @dev Determine whether all approvals and signatures are in place for `buyFYDai`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `buyFYDaiWithSignature` must be called with a dai permit signature.
    /// If `return[2]` is `false`, `buyFYDaiWithSignature` must be called with a pool signature.
    /// If `return` is `(true, true, true)`, `sellDai` won't fail because of missing approvals or signatures.
    function buyFYDaiCheck(IPool pool) public view returns (bool, bool, bool) {
        bool approvals = true; // buyFYDai doesn't need proxy approvals
        bool daiSig = dai.allowance(msg.sender, address(pool)) == type(uint256).max;
        bool poolSig = pool.delegated(msg.sender, address(this));
        return (approvals, daiSig, poolSig);
    }

    /// @dev Buy FYDai with Dai
    /// @param to Wallet receiving the fyDai being bought
    /// @param fyDaiOut Amount of fyDai being bought
    /// @param maxDaiIn Maximum amount of Dai to pay
    /// @param daiSig packed signature for approving Dai transfers to a pool. Ignored if '0x'.
    /// @param poolSig packed signature for delegation of this proxy in a pool. Ignored if '0x'.
    function buyFYDaiWithSignature(
        IPool pool,
        address to,
        uint128 fyDaiOut,
        uint128 maxDaiIn,
        bytes memory daiSig,
        bytes memory poolSig
    )
        external
        returns(uint256)
    {
        if (daiSig.length > 0) dai.permitPackedDai(address(pool), daiSig);
        if (poolSig.length > 0) pool.addDelegatePacked(poolSig);
        return buyFYDai(pool, to, fyDaiOut, maxDaiIn);
    }

    /// @dev Determine whether all approvals and signatures are in place for `sellDai`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `buyDaiWithSignature` must be called with a fyDai permit signature.
    /// If `return[2]` is `false`, `buyDaiWithSignature` must be called with a pool signature.
    /// If `return` is `(true, true, true)`, `sellDai` won't fail because of missing approvals or signatures.
    function sellDaiCheck(IPool pool) public view returns (bool, bool, bool) {
        return buyFYDaiCheck(pool);
    }

    /// @dev Sell Dai for fyDai
    /// @param to Wallet receiving the fyDai being bought
    /// @param daiIn Amount of dai being sold
    /// @param minFYDaiOut Minimum amount of fyDai being bought
    /// @param daiSig packed signature for approving Dai transfers to a pool. Ignored if '0x'.
    /// @param poolSig packed signature for delegation of this proxy in a pool. Ignored if '0x'.
    function sellDaiWithSignature(
        IPool pool,
        address to,
        uint128 daiIn,
        uint128 minFYDaiOut,
        bytes memory daiSig,
        bytes memory poolSig
    )
        external
        returns(uint256)
    {
        if (daiSig.length > 0) dai.permitPackedDai(address(pool), daiSig);
        if (poolSig.length > 0) pool.addDelegatePacked(poolSig);
        return sellDai(pool, to, daiIn, minFYDaiOut);
    }

    /// @dev Determine whether all approvals and signatures are in place for `buyDai`.
    /// `return[0]` is always `true`, meaning that no proxy approvals are ever needed.
    /// If `return[1]` is `false`, `buyDaiWithSignature` must be called with a fyDai permit signature.
    /// If `return[2]` is `false`, `buyDaiWithSignature` must be called with a pool signature.
    /// If `return` is `(true, true, true)`, `buyDai` won't fail because of missing approvals or signatures.
    function buyDaiCheck(IPool pool) public view returns (bool, bool, bool) {
        return sellFYDaiCheck(pool);
    }

    /// @dev Buy Dai for fyDai
    /// @param to Wallet receiving the dai being bought
    /// @param daiOut Amount of dai being bought
    /// @param maxFYDaiIn Maximum amount of fyDai being sold
    /// @param fyDaiSig packed signature for approving fyDai transfers to a pool. Ignored if '0x'.
    /// @param poolSig packed signature for delegation of this proxy in a pool. Ignored if '0x'.
    function buyDaiWithSignature(
        IPool pool,
        address to,
        uint128 daiOut,
        uint128 maxFYDaiIn,
        bytes memory fyDaiSig,
        bytes memory poolSig
    )
        external
        returns(uint256)
    {
        if (fyDaiSig.length > 0) pool.fyDai().permitPacked(address(pool), fyDaiSig);
        if (poolSig.length > 0) pool.addDelegatePacked(poolSig);
        return buyDai(pool, to, daiOut, maxFYDaiIn);
    }

}
