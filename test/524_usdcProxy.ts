const FYDai = artifacts.require('FYDai')
const DssPsm = artifacts.require('DssPsmMock')
const USDC = artifacts.require('USDCMock')
const USDCProxy = artifacts.require('USDCProxy')
const DSProxy = artifacts.require('DSProxy')
const DSProxyFactory = artifacts.require('DSProxyFactory')
const DSProxyRegistry = artifacts.require('ProxyRegistry')

import { BigNumber, BigNumberish } from 'ethers'
import { signatures } from '@yield-protocol/utils'
const { getSignatureDigest, getDaiDigest, getPermitDigest, privateKey0, signPacked, getDomainSeparator } = signatures
import {
  WETH,
  spot,
  wethTokens1,
  toWad,
  toRay,
  mulRay,
  bnify,
  MAX,
  functionSignature,
  name,
  chainId,
} from './shared/utils'
import { sellDai, buyDai, sellFYDai, buyFYDai } from './shared/yieldspace'
import { MakerEnvironment, YieldEnvironmentLite, YieldSpace, Contract } from './shared/fixtures'

// @ts-ignore
import { balance, BN, expectRevert } from '@openzeppelin/test-helpers'
import { assert, expect } from 'chai'

function toBigNumber(x: any) {
  if (typeof x == 'object') x = x.toString()
  if (typeof x == 'number') return new BN(x)
  else if (typeof x == 'string') {
    if (x.startsWith('0x') || x.startsWith('0X')) return new BN(x.substring(2), 16)
    else return new BN(x)
  }
}

function almostEqual(x: any, y: any, p: any) {
  // Check that abs(x - y) < p:
  const xb = toBigNumber(x)
  const yb = toBigNumber(y)
  const pb = toBigNumber(p)
  const diff = xb.gt(yb) ? xb.sub(yb) : yb.sub(xb)
  expect(diff).to.be.bignumber.lt(pb)
}

async function calculateTrade(pool: Contract, trade: any, amount: any): Promise<any> {
  const now = new BN((await web3.eth.getBlock(await web3.eth.getBlockNumber())).timestamp)
  const fyDai = await FYDai.at(await pool.fyDai())
  return new BN(
    trade(
      (await pool.getDaiReserves()).toString(),
      (await pool.getFYDaiReserves()).toString(),
      amount.toString(),
      new BN(await fyDai.maturity()).sub(now).toString()
    ).toString()
  )
}

contract('USDCProxy - USDC', async (accounts) => {
  let [owner, user1, user2] = accounts

  let vault: YieldEnvironmentLite
  let yieldSpace: YieldSpace
  let maker: MakerEnvironment
  let controller: Contract
  let treasury: Contract
  let weth: Contract
  let dai: Contract
  let usdc: Contract
  let vat: Contract
  let fyDai: Contract
  let pool: Contract
  let psm: Contract
  let proxy: Contract

  let proxyFactory: Contract
  let proxyRegistry: Contract
  let dsProxy: Contract

  // These values impact the pool results
  const rate1 = toRay(1.02)
  const daiDebt1 = toWad(96)
  const daiTokens1 = mulRay(daiDebt1, rate1)
  const fyDaiTokens1 = daiTokens1
  const oneToken = toWad(1)
  const oneUSDC = BigNumber.from("1000000")

  let maturity1: number
  let usdcSig: any
  let controllerSig: any
  let poolSig: any

  beforeEach(async () => {
    const block = await web3.eth.getBlockNumber()
    maturity1 = (await web3.eth.getBlock(block)).timestamp + 31556952 // One year
    vault = await YieldEnvironmentLite.setup([maturity1])
    yieldSpace = await YieldSpace.setup(vault)
    maker = vault.maker
    weth = maker.weth
    dai = maker.dai
    vat = maker.vat
    controller = vault.controller
    treasury = vault.treasury
    fyDai = vault.fyDais[0]

    pool = yieldSpace.pools[0]
    await yieldSpace.initPool(pool, toWad(1000), owner)

    usdc = await USDC.new()
    psm = await DssPsm.new(usdc.address, dai.address)
    await dai.rely(await psm.daiJoin())

    // Setup USDCProxy
    proxy = await USDCProxy.new(controller.address, psm.address, { from: owner })

    // Allow owner to mint fyDai the sneaky way, without recording a debt in controller
    await fyDai.orchestrate(owner, functionSignature('mint(address,uint256)'), { from: owner })

    await fyDai.approve(pool.address, MAX, { from: user1 })
    await dai.approve(pool.address, MAX, { from: user1 })

    // Setup DSProxyFactory and DSProxyCache
    proxyFactory = await DSProxyFactory.new({ from: owner })

    // Setup DSProxyRegistry
    proxyRegistry = await DSProxyRegistry.new(proxyFactory.address, { from: owner })

    await proxyRegistry.build({ from: user1 })
    dsProxy = await DSProxy.at(await proxyRegistry.proxies(user1))
  })

  describe('borrowing', () => {
    beforeEach(async () => {
      // Post some weth to controller
      await weth.deposit({ from: user1, value: bnify(wethTokens1).mul(2).toString() })
      await weth.approve(treasury.address, MAX, { from: user1 })
      await controller.post(WETH, user1, user1, bnify(wethTokens1).mul(2).toString(), { from: user1 })

      // Give some fyDai to user1
      await fyDai.mint(user1, fyDaiTokens1, { from: owner })

      await pool.sellFYDai(user1, user1, fyDaiTokens1.div(10), { from: user1 })
    })

    it.only('borrows usdc for maximum fyDai', async () => {
      const usdcBorrowed = oneUSDC
      const fyDaiDebt = await calculateTrade(pool, buyDai, oneToken) // To buy 1 USDC we will have to buy 1 Dai from a Pool
      const debtBefore = await controller.debtFYDai(WETH, maturity1, user1)

      await controller.addDelegate(proxy.address, { from: user1 })
      await proxy.borrowUSDCForMaximumFYDaiApprove(pool.address)
      await proxy.borrowUSDCForMaximumFYDai(pool.address, WETH, maturity1, user2, usdcBorrowed, fyDaiTokens1, {
        from: user1,
      })
      const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)

      assert.equal(await usdc.balanceOf(user2), usdcBorrowed.toString())
      almostEqual(
        debtAfter.toString(),
        debtBefore.add(fyDaiDebt).toString(),
        debtAfter.div(new BN('1000000')).toString()
      )
    })

    it('borrows usdc with a fee', async () => {
      await psm.setTout(toWad(0.01))

      const usdcBorrowed = new BN(oneToken.toString())
      const daiBorrowed = usdcBorrowed.add(usdcBorrowed.div(new BN('100')))
      const fyDaiDebt = await calculateTrade(pool, buyDai, daiBorrowed)

      const debtBefore = await controller.debtFYDai(WETH, maturity1, user1)

      await controller.addDelegate(proxy.address, { from: user1 })
      await proxy.borrowUSDCForMaximumFYDaiApprove(pool.address)
      await proxy.borrowUSDCForMaximumFYDai(pool.address, WETH, maturity1, user2, oneToken, fyDaiTokens1, {
        from: user1,
      })
      const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)

      assert.equal(await usdc.balanceOf(user2), oneToken.toString())
      almostEqual(
        debtAfter.toString(),
        debtBefore.add(fyDaiDebt).toString(),
        debtAfter.div(new BN('1000000')).toString()
      )
    })

    it('borrows usdc with a signature', async () => {
      // Authorize borrowProxy for the controller
      const controllerDigest = getSignatureDigest(
        name,
        controller.address,
        chainId,
        {
          user: user1,
          delegate: proxy.address,
        },
        (await controller.signatureCount(user1)).toString(),
        MAX
      )
      controllerSig = signPacked(controllerDigest, privateKey0)

      await proxy.borrowUSDCForMaximumFYDaiWithSignature(
        pool.address,
        WETH,
        maturity1,
        user2,
        oneToken,
        fyDaiTokens1,
        controllerSig,
        {
          from: user1,
        }
      )

      assert.equal(await usdc.balanceOf(user2), oneToken.toString())
    })

    it('borrows usdc through dsProxy', async () => {
      // Authorize dsProxy for the controller
      const controllerDigest = getSignatureDigest(
        name,
        controller.address,
        chainId,
        {
          user: user1,
          delegate: dsProxy.address,
        },
        (await controller.signatureCount(user1)).toString(),
        MAX
      )
      controllerSig = signPacked(controllerDigest, privateKey0)

      const calldata = proxy.contract.methods
        .borrowUSDCForMaximumFYDaiWithSignature(
          pool.address,
          WETH,
          maturity1,
          user2,
          oneToken,
          fyDaiTokens1,
          controllerSig
        )
        .encodeABI()
      await dsProxy.methods['execute(address,bytes)'](proxy.address, calldata, {
        from: user1,
      })

      assert.equal(await usdc.balanceOf(user2), oneToken.toString())
    })

    it("doesn't borrow usdc if limit exceeded", async () => {
      await controller.addDelegate(proxy.address, { from: user1 })
      await proxy.borrowUSDCForMaximumFYDaiApprove(pool.address)
      await expectRevert(
        proxy.borrowUSDCForMaximumFYDai(pool.address, WETH, maturity1, user2, oneToken, 0, {
          from: user1,
        }),
        'USDCProxy: Too much fyDai required'
      )
    })

    describe('once borrowed', () => {
      beforeEach(async () => {
        await controller.addDelegate(proxy.address, { from: user1 })
        await pool.addDelegate(proxy.address, { from: user1 })
        await proxy.borrowUSDCForMaximumFYDaiApprove(pool.address)
        await proxy.borrowUSDCForMaximumFYDai(pool.address, WETH, maturity1, user1, oneToken, fyDaiTokens1, {
          from: user1,
        })
      })

      // ---- Partial, early.

      it('repays some debt with USDC', async () => {
        const usdcRepayment = new BN(oneToken.div('2').toString())
        // dai = usdc * (1 - await psm.tin()) <- tin is 0 right now
        const daiRepayment = usdcRepayment
        const fyDaiRepayment = await calculateTrade(pool, sellDai, daiRepayment)

        // We borrowed 1 USDC before
        const usdcBefore = await usdc.balanceOf(user1)
        const debtBefore = await controller.debtFYDai(WETH, maturity1, user1)
        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)
        await proxy.repayDebtEarly(pool.address, WETH, maturity1, user1, usdcRepayment, 0, {
          from: user1,
        })
        const usdcAfter = await usdc.balanceOf(user1)
        const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)

        almostEqual(
          debtAfter.toString(),
          debtBefore.sub(fyDaiRepayment).toString(),
          debtBefore.div(new BN('1000000')).toString()
        )
        expect(usdcAfter.toString()).to.be.bignumber.eq(usdcBefore.sub(usdcRepayment).toString())
      })

      it('repays some debt with a fee', async () => {
        await psm.setTin(toWad(0.01))

        const usdcRepayment = new BN(oneToken.div('2').toString())
        const daiRepayment = usdcRepayment.sub(usdcRepayment.div(new BN('100')))
        const fyDaiRepayment = await calculateTrade(pool, sellDai, daiRepayment)

        // We borrowed 1 USDC before
        const usdcBefore = await usdc.balanceOf(user1)
        const debtBefore = await controller.debtFYDai(WETH, maturity1, user1)
        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)
        await proxy.repayDebtEarly(pool.address, WETH, maturity1, user1, usdcRepayment, 0, {
          from: user1,
        })
        const usdcAfter = await usdc.balanceOf(user1)
        const debtAfter = await controller.debtFYDai(WETH, maturity1, user1)

        almostEqual(
          debtAfter.toString(),
          debtBefore.sub(fyDaiRepayment).toString(),
          debtBefore.div(new BN('1000000')).toString()
        )
        expect(usdcAfter.toString()).to.be.bignumber.eq(usdcBefore.sub(usdcRepayment).toString())
      })


      it("doesn't repay with usdc if slippage exceeded", async () => {
        const usdcRepayment = new BN(oneToken.div('2').toString())
        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)
        await expectRevert(
          proxy.repayDebtEarly(pool.address, WETH, maturity1, user1, usdcRepayment, MAX, {
            from: user1,
          }),
          'USDCProxy: Not enough debt repaid'
        )
      })

      it('repays some debt with USDC, with signatures', async () => {
        await controller.revokeDelegate(proxy.address, { from: user1 })

        // Authorize USDC
        const usdcDigest = getPermitDigest(
          await usdc.name(),
          usdc.address,
          '2',
          chainId,
          {
            owner: user1,
            spender: proxy.address,
            value: MAX,
          },
          bnify(await usdc.nonces(user1)),
          MAX
        )
        usdcSig = signPacked(usdcDigest, privateKey0)

        // Authorize borrowProxy for the controller
        const controllerDigest = getSignatureDigest(
          name,
          controller.address,
          chainId,
          {
            user: user1,
            delegate: proxy.address,
          },
          (await controller.signatureCount(user1)).toString(),
          MAX
        )
        controllerSig = signPacked(controllerDigest, privateKey0)

        const debtBefore = await controller.debtDai(WETH, maturity1, user1)

        await proxy.repayDebtEarlyWithSignature(
          pool.address,
          WETH,
          maturity1,
          user1,
          oneToken,
          oneToken,
          usdcSig,
          controllerSig,
          {
            from: user1,
          }
        )
        const debtAfter = await controller.debtDai(WETH, maturity1, user1)

        expect(debtAfter.toString()).to.be.bignumber.lt(debtBefore.toString())
      })

      it('repays some debt with USDC, through dsProxy', async () => {
        // Authorize USDC
        const usdcDigest = getPermitDigest(
          await usdc.name(),
          usdc.address,
          '2',
          chainId,
          {
            owner: user1,
            spender: dsProxy.address,
            value: MAX,
          },
          bnify(await usdc.nonces(user1)),
          MAX
        )
        usdcSig = signPacked(usdcDigest, privateKey0)

        // Authorize borrowProxy for the controller
        const controllerDigest = getSignatureDigest(
          name,
          controller.address,
          chainId,
          {
            user: user1,
            delegate: dsProxy.address,
          },
          (await controller.signatureCount(user1)).toString(),
          MAX
        )
        controllerSig = signPacked(controllerDigest, privateKey0)

        const debtBefore = await controller.debtDai(WETH, maturity1, user1)

        const calldata = proxy.contract.methods
          .repayDebtEarlyWithSignature(
            pool.address,
            WETH,
            maturity1,
            user1,
            oneToken,
            oneToken,
            usdcSig,
            controllerSig
          )
          .encodeABI()
        await dsProxy.methods['execute(address,bytes)'](proxy.address, calldata, {
          from: user1,
        })
        const debtAfter = await controller.debtDai(WETH, maturity1, user1)

        expect(debtAfter.toString()).to.be.bignumber.lt(debtBefore.toString())
      })

      // ---- Total, early

      it('repays all debt with USDC', async () => {
        await usdc.mint(user1, oneToken.mul('2'), { from: user1 })

        const fyDaiRepayment = await controller.debtFYDai(WETH, maturity1, user1)
        const daiRepayment = await calculateTrade(pool, buyFYDai, fyDaiRepayment)
        // usdc = dai * (1 + await psm.tin()) <- tin is 0 right now
        const usdcRepayment = daiRepayment
        const usdcBefore = await usdc.balanceOf(user1)

        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)
        await proxy.repayAllEarly(pool.address, WETH, maturity1, user1, MAX, {
          from: user1,
        })
        const usdcAfter = await usdc.balanceOf(user1)

        expect((await controller.debtFYDai(WETH, maturity1, user1)).toString()).to.be.bignumber.eq('0')
        almostEqual(
          usdcAfter.toString(),
          usdcBefore.sub(usdcRepayment).toString(),
          usdcBefore.div(new BN('1000000')).toString()
        )
      })

      it("doesn't repay all with usdc if slippage exceeded", async () => {
        await usdc.mint(user1, oneToken.mul('2'), { from: user1 })

        const fyDaiRepayment = await controller.debtFYDai(WETH, maturity1, user1)
        const daiRepayment = await calculateTrade(pool, buyFYDai, fyDaiRepayment)
        // usdc = dai * (1 + await psm.tin()) <- tin is 0 right now
        const usdcRepayment = daiRepayment
        const usdcBefore = await usdc.balanceOf(user1)

        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)

        await expectRevert(
          proxy.repayAllEarly(pool.address, WETH, maturity1, user1, 0, {
            from: user1,
          }),
          'USDCProxy: Too much USDC required'
        )
      })

      it('repays all debt with USDC, with signatures', async () => {
        await controller.revokeDelegate(proxy.address, { from: user1 })
        await usdc.mint(user1, oneToken.mul('2'), { from: user1 })

        const fyDaiRepayment = await controller.debtFYDai(WETH, maturity1, user1)
        const daiRepayment = await calculateTrade(pool, buyFYDai, fyDaiRepayment)
        // usdc = dai * (1 + await psm.tin()) <- tin is 0 right now
        const usdcRepayment = daiRepayment
        const usdcBefore = await usdc.balanceOf(user1)

        // Authorize USDC
        const usdcDigest = getPermitDigest(
          await usdc.name(),
          usdc.address,
          '2',
          chainId,
          {
            owner: user1,
            spender: proxy.address,
            value: MAX,
          },
          bnify(await usdc.nonces(user1)),
          MAX
        )
        usdcSig = signPacked(usdcDigest, privateKey0)

        // Authorize borrowProxy for the controller
        const controllerDigest = getSignatureDigest(
          name,
          controller.address,
          chainId,
          {
            user: user1,
            delegate: proxy.address,
          },
          (await controller.signatureCount(user1)).toString(),
          MAX
        )
        controllerSig = signPacked(controllerDigest, privateKey0)

        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtEarlyApprove(pool.address)
        await proxy.repayAllEarlyWithSignature(pool.address, WETH, maturity1, user1, MAX, usdcSig, controllerSig, {
          from: user1,
        })
        const usdcAfter = await usdc.balanceOf(user1)

        expect((await controller.debtFYDai(WETH, maturity1, user1)).toString()).to.be.bignumber.eq('0')
        almostEqual(
          usdcAfter.toString(),
          usdcBefore.sub(usdcRepayment).toString(),
          usdcBefore.div(new BN('1000000')).toString()
        )
      })


      // ---- Partial, mature.

      it('repays some mature debt with USDC', async () => {
        await controller.revokeDelegate(proxy.address, { from: user1 })
        await psm.setTin(toWad(0.01))

        // Authorize USDC
        const usdcDigest = getPermitDigest(
          await usdc.name(),
          usdc.address,
          '2',
          chainId,
          {
            owner: user1,
            spender: proxy.address,
            value: MAX,
          },
          bnify(await usdc.nonces(user1)),
          MAX
        )
        usdcSig = signPacked(usdcDigest, privateKey0)

        // Authorize borrowProxy for the controller
        const controllerDigest = getSignatureDigest(
          name,
          controller.address,
          chainId,
          {
            user: user1,
            delegate: proxy.address,
          },
          (await controller.signatureCount(user1)).toString(),
          MAX
        )
        controllerSig = signPacked(controllerDigest, privateKey0)

        const usdcRepayment = new BN(oneToken.div('2').toString())
        const daiRepayment = usdcRepayment.sub(usdcRepayment.div(new BN('100')))

        // We borrowed 1 USDC before
        const usdcBefore = await usdc.balanceOf(user1)
        const debtBefore = await controller.debtDai(WETH, maturity1, user1)
        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayDebtMatureWithSignature(WETH, maturity1, user1, daiRepayment, usdcSig, controllerSig, {
          from: user1,
        })
        const usdcAfter = await usdc.balanceOf(user1)
        const debtAfter = await controller.debtDai(WETH, maturity1, user1)

        almostEqual(
          debtAfter.toString(),
          debtBefore.sub(daiRepayment).toString(),
          debtBefore.div(new BN('1000000')).toString()
        )
        expect(usdcAfter.toString()).to.be.bignumber.eq(usdcBefore.sub(usdcRepayment).toString())
      })


      // ---- Total, mature.

      it('repays all mature debt with USDC', async () => {
        await usdc.mint(user1, oneToken.mul('2'), { from: user1 })
        await controller.revokeDelegate(proxy.address, { from: user1 })
        await psm.setTin(toWad(0.01))

        // Authorize USDC
        const usdcDigest = getPermitDigest(
          await usdc.name(),
          usdc.address,
          '2',
          chainId,
          {
            owner: user1,
            spender: proxy.address,
            value: MAX,
          },
          bnify(await usdc.nonces(user1)),
          MAX
        )
        usdcSig = signPacked(usdcDigest, privateKey0)

        // Authorize borrowProxy for the controller
        const controllerDigest = getSignatureDigest(
          name,
          controller.address,
          chainId,
          {
            user: user1,
            delegate: proxy.address,
          },
          (await controller.signatureCount(user1)).toString(),
          MAX
        )
        controllerSig = signPacked(controllerDigest, privateKey0)

        // const usdcBefore = await usdc.balanceOf(user1)
        // const debtBefore = await controller.debtDai(WETH, maturity1, user1)
        await usdc.approve(proxy.address, MAX, { from: user1 })
        await proxy.repayAllMatureWithSignature(WETH, maturity1, user1, usdcSig, controllerSig, {
          from: user1,
        })
        // const usdcAfter = await usdc.balanceOf(user1)
        // const debtAfter = await controller.debtDai(WETH, maturity1, user1)

        expect((await controller.debtFYDai(WETH, maturity1, user1)).toString()).to.be.bignumber.eq('0')
        // expect(usdcAfter.toString()).to.be.bignumber.eq(usdcBefore.sub(usdcRepayment).toString())
      })
    })
  })
})
